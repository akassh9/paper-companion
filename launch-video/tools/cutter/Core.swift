import AVFoundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Metal

// MARK: Canvas

let W: CGFloat = 3840, H: CGFloat = 2160
let FPS = 60
let canvas = CGRect(x: 0, y: 0, width: W, height: H)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let ciContext = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!,
                          options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                    .outputColorSpace: sRGB, .cacheIntermediates: false])
let projectRoot: URL = {
    // launch-video/tools/bin/cutter -> launch-video/
    URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}()
func asset(_ rel: String) -> String { projectRoot.appendingPathComponent(rel).path }

func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CIImage {
    CIImage(color: CIColor(red: r, green: g, blue: b, alpha: a)).cropped(to: canvas)
}
let black = solid(0, 0, 0)

// MARK: Easing

func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
func smooth(_ t: Double) -> Double { let x = clamp01(t); return x * x * (3 - 2 * x) }
func easeInOut(_ t: Double) -> Double { let x = clamp01(t); return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
func easeOut(_ t: Double) -> Double { let x = clamp01(t); return 1 - pow(1 - x, 3) }
func easeIn(_ t: Double) -> Double { let x = clamp01(t); return x * x * x }
/// Opacity of something that fades in at `a` over `fin` and out at `b` over `fout`.
func window(_ t: Double, _ a: Double, _ b: Double, fin: Double = 0.5, fout: Double = 0.5) -> Double {
    if t < a || t > b { return 0 }
    return min(smooth((t - a) / fin), smooth((b - t) / fout))
}

// MARK: Image helpers

extension CIImage {
    func fit(in rect: CGRect, fill: Bool = false) -> CIImage {
        let e = extent
        let s = fill ? max(rect.width / e.width, rect.height / e.height) : min(rect.width / e.width, rect.height / e.height)
        let scaled = transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY).concatenating(.init(scaleX: s, y: s)))
        let se = scaled.extent
        return scaled.transformed(by: .init(translationX: rect.midX - se.width / 2, y: rect.midY - se.height / 2))
    }
    /// Scales about a point (canvas coordinates) and translates: the virtual camera.
    func camera(scale s: Double, about c: CGPoint = CGPoint(x: W / 2, y: H / 2), dx: Double = 0, dy: Double = 0) -> CIImage {
        transformed(by: CGAffineTransform(translationX: -c.x, y: -c.y)
            .concatenating(.init(scaleX: s, y: s))
            .concatenating(.init(translationX: c.x + dx, y: c.y + dy)))
    }
    func opacity(_ a: Double) -> CIImage {
        if a >= 0.999 { return self }
        return applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)])
    }
    func over(_ bg: CIImage) -> CIImage { composited(over: bg) }
    func blur(_ r: Double) -> CIImage {
        r < 0.05 ? self : clampedToExtent().applyingGaussianBlur(sigma: r).cropped(to: extent)
    }
    func canvasCrop() -> CIImage { cropped(to: canvas) }
}

/// Loads an image file as a CIImage (sRGB).
func loadImage(_ path: String) -> CIImage {
    guard let img = CIImage(contentsOf: URL(fileURLWithPath: path)) else { fatalError("missing image \(path)") }
    return img
}

// MARK: Video sources (sequential decode)

/// Reads a movie sequentially. Ask for frames at increasing source times.
final class VideoSource {
    let path: String
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var cur: (t: Double, img: CIImage)?
    private var nxt: (t: Double, img: CIImage)?
    private var startedAt = -1.0
    let pixelAspect: CGFloat
    let size: CGSize
    let duration: Double

    init(_ path: String) {
        self.path = path
        let a = AVURLAsset(url: URL(fileURLWithPath: path))
        let track = a.tracks(withMediaType: .video).first!
        let fd = track.formatDescriptions.first as! CMFormatDescription
        if let par = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) as? [String: Any],
           let h = par["HorizontalSpacing"] as? Double, let v = par["VerticalSpacing"] as? Double, v > 0 {
            pixelAspect = h / v
        } else { pixelAspect = 1 }
        size = track.naturalSize
        duration = a.duration.seconds
    }

    private func open(at t: Double) {
        let a = AVURLAsset(url: URL(fileURLWithPath: path))
        let track = a.tracks(withMediaType: .video).first!
        let r = try! AVAssetReader(asset: a)
        r.timeRange = CMTimeRange(start: CMTime(seconds: max(0, t - 0.1), preferredTimescale: 6000), duration: .positiveInfinity)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        o.alwaysCopiesSampleData = false
        r.add(o)
        r.startReading()
        reader = r; output = o; cur = nil; nxt = nil; startedAt = t
        nxt = pull()
    }

    private func pull() -> (Double, CIImage)? {
        guard let o = output, let sb = o.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else { return nil }
        let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        var img = CIImage(cvPixelBuffer: pb)
        if abs(pixelAspect - 1) > 0.01 { img = img.transformed(by: .init(scaleX: pixelAspect, y: 1)) }
        // Copy out of the reader's buffer so it can be reused.
        let rendered = ciContext.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: sRGB)!
        return (t, CIImage(cgImage: rendered))
    }

    /// The frame showing at source time `t`.
    func frame(at t: Double) -> CIImage {
        if reader == nil || t < (cur?.t ?? startedAt) - 0.001 || t > (nxt?.t ?? 1e9) + 1.0 { open(at: t) }
        while let n = nxt, n.t <= t + 0.0005 {
            cur = n
            nxt = pull()
        }
        if cur == nil { cur = nxt; nxt = pull() }
        return cur?.img ?? CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
    }
}

var sources: [String: VideoSource] = [:]
func video(_ rel: String) -> VideoSource {
    if let s = sources[rel] { return s }
    let s = VideoSource(asset(rel)); sources[rel] = s; return s
}

// MARK: Type

struct TypeStyle: Hashable {
    var size: CGFloat = 104
    var weight: CGFloat = 0.4       // NSFont.Weight raw value; semibold ≈ 0.3, bold 0.4
    var tracking: CGFloat = -0.012  // em
    var color: [CGFloat] = [1, 1, 1, 1]
    var italic = false
    var serif = false               // New York, for the paper's voice
    var lineHeight: CGFloat = 1.12
    var align: NSTextAlignment = .center
    var maxWidth: CGFloat = 3000
}

private var typeCache: [String: CIImage] = [:]

/// A line (or lines, split on \n) of type, centered on the origin.
func typeImage(_ text: String, _ st: TypeStyle) -> CIImage {
    let key = "\(text)|\(st.hashValue)"
    if let c = typeCache[key] { return c }
    var font: NSFont
    if st.serif {
        let d = NSFontDescriptor(name: "New York", size: st.size)
        font = NSFont(descriptor: d, size: st.size) ?? NSFont.systemFont(ofSize: st.size)
        if let ny = NSFont.systemFont(ofSize: st.size, weight: NSFont.Weight(st.weight)).fontDescriptor.withDesign(.serif) {
            font = NSFont(descriptor: ny, size: st.size) ?? font
        }
    } else {
        font = NSFont.systemFont(ofSize: st.size, weight: NSFont.Weight(st.weight))
    }
    if st.italic, let d = font.fontDescriptor.withSymbolicTraits(.italic) as NSFontDescriptor? {
        font = NSFont(descriptor: d, size: st.size) ?? font
    }
    let para = NSMutableParagraphStyle()
    para.alignment = st.align
    para.minimumLineHeight = st.size * st.lineHeight
    para.maximumLineHeight = st.size * st.lineHeight
    let color = NSColor(srgbRed: st.color[0], green: st.color[1], blue: st.color[2], alpha: st.color[3])
    let attr = NSAttributedString(string: text, attributes: [
        .font: font, .foregroundColor: color, .kern: st.tracking * st.size, .paragraphStyle: para,
    ])
    let bounds = attr.boundingRect(with: CGSize(width: st.maxWidth, height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading])
    let pad: CGFloat = 40
    let w = Int(ceil(bounds.width + pad * 2)), h = Int(ceil(bounds.height + pad * 2))
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns
    attr.draw(with: CGRect(x: pad, y: pad, width: bounds.width, height: bounds.height), options: [.usesLineFragmentOrigin, .usesFontLeading])
    NSGraphicsContext.restoreGraphicsState()
    let img = CIImage(cgImage: ctx.makeImage()!).transformed(by: .init(translationX: -CGFloat(w) / 2, y: -CGFloat(h) / 2))
    typeCache[key] = img
    return img
}

/// Apple-style type entrance: fades up while a slight blur clears and it settles a few pixels upward.
func typeCard(_ text: String, _ st: TypeStyle, at p: CGPoint, t: Double, a: Double, b: Double,
              fin: Double = 0.7, fout: Double = 0.5) -> CIImage? {
    let o = window(t, a, b, fin: fin, fout: fout)
    guard o > 0.001 else { return nil }
    let inP = easeOut((t - a) / fin)
    let outP = clamp01((t - (b - fout)) / fout)
    let blurR = (1 - inP) * 14 + easeIn(outP) * 10
    let dy = (1 - inP) * -18
    return typeImage(text, st).blur(blurR).opacity(o).transformed(by: .init(translationX: p.x, y: p.y + dy))
}

// MARK: Grain, grade

private let noise = CIFilter.randomGenerator().outputImage!

/// Monochrome grain, `size` = grain size in pixels, re-seeded every frame.
func grain(frame: Int, size: Double = 1.6, amount: Double = 0.06) -> CIImage {
    var rng = SplitMix(seed: UInt64(frame &* 7919 &+ 17))
    let ox = Double(rng.next() % 4000), oy = Double(rng.next() % 4000)
    let mono = noise.transformed(by: .init(translationX: -ox, y: -oy))
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.33, y: 0.33, z: 0.34, w: 0),
            "inputGVector": CIVector(x: 0.33, y: 0.33, z: 0.34, w: 0),
            "inputBVector": CIVector(x: 0.33, y: 0.33, z: 0.34, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        .transformed(by: .init(scaleX: size, y: size))
        .applyingGaussianBlur(sigma: size * 0.35)
        .cropped(to: canvas)
    // Map to mid-gray ± amount, for an overlay blend.
    return mono.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: amount * 2, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: amount * 2, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: amount * 2, w: 0),
        "inputBiasVector": CIVector(x: 0.5 - amount, y: 0.5 - amount, z: 0.5 - amount, w: 0),
    ])
}

func addGrain(_ img: CIImage, frame: Int, size: Double = 1.6, amount: Double = 0.05) -> CIImage {
    grain(frame: frame, size: size, amount: amount).applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: img])
        .cropped(to: img.extent)
}

/// The archive grade: neutral black-and-white, lifted blacks, soft shoulder, gentle vignette.
func archiveGrade(_ img: CIImage) -> CIImage {
    let mono = img.applyingFilter("CIPhotoEffectMono")
    let curve = mono.applyingFilter("CIToneCurve", parameters: [
        "inputPoint0": CIVector(x: 0, y: 0.055),
        "inputPoint1": CIVector(x: 0.25, y: 0.22),
        "inputPoint2": CIVector(x: 0.5, y: 0.5),
        "inputPoint3": CIVector(x: 0.75, y: 0.76),
        "inputPoint4": CIVector(x: 1, y: 0.93),
    ])
    // A whisper of warmth in the highlights, like a print.
    let warm = curve.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 1.0, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: 0.985, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 0.95, w: 0),
    ])
    return warm
}

func vignette(_ img: CIImage, intensity: Double = 0.6, radius: Double = 1.1) -> CIImage {
    img.applyingFilter("CIVignetteEffect", parameters: [
        kCIInputCenterKey: CIVector(x: img.extent.midX, y: img.extent.midY),
        kCIInputRadiusKey: max(img.extent.width, img.extent.height) * radius * 0.5,
        kCIInputIntensityKey: intensity,
        "inputFalloff": 0.6,
    ]).cropped(to: img.extent)
}

/// Archive footage presented as a 4:3 print in black space. `push` is the shot's own slow camera.
func archivePrint(_ src: CIImage, frame: Int, height: CGFloat = 1560, push: Double = 1.0, pan: CGPoint = .zero,
                  center: CGPoint = CGPoint(x: W / 2, y: H / 2)) -> CIImage {
    // Trim the soft, dirty edges of the scan.
    let e = src.extent
    let inset = src.cropped(to: e.insetBy(dx: e.width * 0.025, dy: e.height * 0.03))
    let ie = inset.extent
    let printW = height * 4 / 3
    let frameRect = CGRect(x: center.x - printW / 2, y: center.y - height / 2, width: printW, height: height)
    // Gate weave: a slow sub-pixel wander.
    let wx = sin(Double(frame) * 0.37) * 0.9 + sin(Double(frame) * 0.113) * 0.7
    let wy = cos(Double(frame) * 0.29) * 0.8
    let s = max(frameRect.width / ie.width, frameRect.height / ie.height) * push
    var img = inset.transformed(by: CGAffineTransform(translationX: -ie.midX, y: -ie.midY)
        .concatenating(.init(scaleX: s, y: s))
        .concatenating(.init(translationX: frameRect.midX + pan.x + wx, y: frameRect.midY + pan.y + wy)))
    img = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 1.0])
    img = archiveGrade(img).cropped(to: frameRect)
    // Flicker: tiny exposure breathing.
    let flick = 1 + (sin(Double(frame) * 1.7) * 0.012 + sin(Double(frame) * 0.61) * 0.01)
    img = img.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: flick, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: flick, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: flick, w: 0),
    ])
    img = vignette(img, intensity: 0.5, radius: 1.25)
    img = addGrain(img, frame: frame, size: 2.4, amount: 0.07)
    // Soft-edged print: feather the frame a little so it sits in the black.
    return img.cropped(to: frameRect)
}

// MARK: RNG

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

// MARK: Output

final class MovieWriter {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    var n = 0

    init(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        writer = try! AVAssetWriter(outputURL: URL(fileURLWithPath: path), fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422HQ,
            AVVideoWidthKey: Int(W), AVVideoHeightKey: Int(H),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(W), kCVPixelBufferHeightKey as String: Int(H),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ img: CIImage) {
        while !input.isReadyForMoreMediaData { usleep(500) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        ciContext.render(img.cropped(to: canvas), to: pb!, bounds: canvas, colorSpace: sRGB)
        adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(n), timescale: CMTimeScale(FPS)))
        n += 1
    }

    func finish() {
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
    }
}

func writePNG(_ img: CIImage, _ path: String, scale: CGFloat = 1) {
    var out = img.cropped(to: canvas)
    if scale != 1 { out = out.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale]) }
    let url = URL(fileURLWithPath: path)
    try? ciContext.writePNGRepresentation(of: out, to: url, format: .RGBA8, colorSpace: sRGB)
}
