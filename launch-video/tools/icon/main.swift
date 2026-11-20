// Draws the Paper Companion app icon with the film's ink engine: warm paper, fountain-pen ink, the purple link.
//
//   swiftc -O -o ../bin/icon ../cutter/Core.swift ../cutter/Ink.swift main.swift
//   ../bin/icon <concept> <out.png> [size]      concept: ask | question | margin
//
// World units are a 1024-pt macOS icon canvas (y up). The paper body follows Apple's grid: an 824-pt
// rounded square (continuous corners) centred on the canvas, with a soft drop shadow below it.
import Foundation
import CoreImage
import CoreGraphics

let args = CommandLine.arguments
let concept = args.count > 1 ? args[1] : "ask"
let outPath = args.count > 2 ? args[2] : "icon.png"
let outSize = args.count > 3 ? CGFloat(Double(args[3]) ?? 1024) : 1024
let SS: CGFloat = 2048                       // render at 2x, downsample for clean edges
let k = SS / 1024

// MARK: Shape

/// Apple-style continuous-corner rounded square (a superellipse blend), in world units.
func squircle(_ r: CGRect) -> CGPath {
    let path = CGMutablePath()
    let n = 5.0, cx = r.midX, cy = r.midY, a = r.width / 2, b = r.height / 2
    for i in 0...720 {
        let t = Double(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * CGFloat(copysign(pow(abs(c), 2 / n), c))
        let y = cy + b * CGFloat(copysign(pow(abs(s), 2 / n), s))
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

let body = CGRect(x: 100, y: 100, width: 824, height: 824)

func mask(_ path: CGPath) -> CIImage {
    let ctx = CGContext(data: nil, width: Int(SS), height: Int(SS), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.scaleBy(x: k, y: k)
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.addPath(path); ctx.fillPath()
    return CIImage(cgImage: ctx.makeImage()!)
}

// MARK: Drawings

let d = Drawing(seed: 1921)
let P = RGBA.purple
/// Ink at `a` laid over paper, as an opaque colour (translucent strokes bead where their round caps overlap).
func onPaper(_ c: RGBA, _ a: CGFloat) -> RGBA {
    let p = Paper.color
    return RGBA(r: p.r + (c.r - p.r) * a, g: p.g + (c.g - p.g) * a, b: p.b + (c.b - p.b) * a, a: 1)
}
let INK = onPaper(.ink, 0.96)

func pen(_ pts: [CGPoint], _ w: CGFloat, _ color: RGBA = INK) { d.add(Stroke(pts, width: w, start: 0, duration: 1, color: color)) }
func swipe(_ a: CGPoint, _ b: CGPoint, _ w: CGFloat, alpha: CGFloat = 0.32) {
    d.add(Stroke(d.handLine(a, b, wobble: 2), width: w, start: 0, duration: 1, color: P.with(a: alpha), kind: .marker))
}
/// A hand-drawn page outline: four overshooting strokes, slightly rotated.
func pageOutline(_ r: CGRect, deg: Double, w: CGFloat) {
    let c = CGPoint(x: r.midX, y: r.midY)
    let cs = [CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.minY)]
        .map { Drawing.rotate($0, about: c, deg) }
    for i in 0..<4 {
        let a = cs[i], b = cs[(i + 1) % 4], dx = b.x - a.x, dy = b.y - a.y, l = hypot(dx, dy)
        pen(d.handLine(CGPoint(x: a.x - dx / l * 10, y: a.y - dy / l * 10), CGPoint(x: b.x + dx / l * 16, y: b.y + dy / l * 16), wobble: 2.2), w)
    }
}
/// Word-dash text lines inside a page; returns each line's (start, end).
func textLines(_ r: CGRect, deg: Double, rows: [CGFloat], w: CGFloat, ink: CGFloat = 0.6) -> [(CGPoint, CGPoint)] {
    let c = CGPoint(x: r.midX, y: r.midY)
    var out: [(CGPoint, CGPoint)] = []
    for (i, frac) in rows.enumerated() {
        let y = r.maxY - CGFloat(i + 1) * r.height / CGFloat(rows.count + 1)
        let x0 = r.minX + r.width * 0.16, x1 = x0 + (r.width * 0.68) * frac
        var x = x0
        while x < x1 - 12 {
            let wl = min(CGFloat(40 + d.rng.unit() * 70), x1 - x)
            pen(d.handLine(Drawing.rotate(CGPoint(x: x, y: y), about: c, deg), Drawing.rotate(CGPoint(x: x + wl, y: y), about: c, deg), wobble: 1.2), w, onPaper(.ink, ink))
            x += wl + CGFloat(16 + d.rng.unit() * 8)
        }
        out.append((Drawing.rotate(CGPoint(x: x0, y: y), about: c, deg), Drawing.rotate(CGPoint(x: x1, y: y), about: c, deg)))
    }
    return out
}

switch concept {
case "question":
    // One big hand-drawn question mark, underlined with the purple highlighter.
    swipe(CGPoint(x: 300, y: 262), CGPoint(x: 690, y: 272), 56, alpha: 0.5)
    d.hand("?", at: CGPoint(x: 330, y: 300), size: 480, start: 0, duration: 1, color: INK, width: 34)

case "margin":
    // A page with one highlighted line; the purple link runs from it into the margin, to a bubble with a question.
    let r = CGRect(x: 205, y: 225, width: 360, height: 540)
    pageOutline(r, deg: -3, w: 17)
    let lines = textLines(r, deg: -3, rows: [1, 0.85, 1, 0.6, 0.95, 0.7], w: 11)
    let hl = lines[2]
    swipe(CGPoint(x: hl.0.x - 8, y: hl.0.y - 2), CGPoint(x: hl.1.x + 8, y: hl.1.y - 2), 50, alpha: 0.45)
    let bubble = CGPoint(x: 800, y: 640)
    pen(d.sCurve(CGPoint(x: hl.1.x + 22, y: hl.1.y), CGPoint(x: bubble.x - 98, y: bubble.y - 10), reach: 0.6, wobble: 2), 15, P)
    let loop = (0...40).map { i -> CGPoint in
        let a = (0.62 + Double(i) / 40 * 1.06) * 2 * .pi
        return CGPoint(x: bubble.x + CGFloat(cos(a)) * 92, y: bubble.y + CGFloat(sin(a)) * 84)
    }
    pen(loop, 17)
    d.hand("?", at: CGPoint(x: bubble.x - 34, y: bubble.y - 50), size: 104, start: 0, duration: 1, color: INK, width: 15)

default: // "ask"
    // The film's Ask moment: two pages, a highlighted passage, and the purple line that links them.
    let a = CGRect(x: 178, y: 300, width: 330, height: 450), b = CGRect(x: 548, y: 270, width: 300, height: 410)
    pageOutline(a, deg: 3, w: 15)
    pageOutline(b, deg: -4, w: 15)
    let la = textLines(a, deg: 3, rows: [1, 0.8, 1, 0.55, 0.9], w: 10)
    let lb = textLines(b, deg: -4, rows: [0.9, 1, 0.7, 1], w: 10)
    swipe(la[1].0, la[1].1, 44, alpha: 0.45)
    swipe(lb[2].0, lb[2].1, 44, alpha: 0.45)
    pen(d.sCurve(CGPoint(x: la[1].1.x + 16, y: la[1].1.y), CGPoint(x: lb[2].0.x - 14, y: lb[2].0.y), reach: 0.7, wobble: 1.5), 13, P)
}

// MARK: Compose

// Centre the drawing and scale it to Apple's content area (about 600 pt of the 824-pt body).
let allPts = d.strokes.flatMap { $0.points }
let minX = allPts.map(\.x).min()!, maxX = allPts.map(\.x).max()!, minY = allPts.map(\.y).min()!, maxY = allPts.map(\.y).max()!
let fit = (concept == "question" ? 540 : 610) / max(maxX - minX, maxY - minY)
Paper.viewport = CGRect(x: W / 2 - SS / 2, y: H / 2 - SS / 2, width: SS, height: SS)
let ink = d.renderInk(t: 10, zoom: k * fit, focus: CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2))
    .transformed(by: .init(translationX: -Paper.viewport.minX, y: -Paper.viewport.minY))
let square = CGRect(x: 0, y: 0, width: SS, height: SS)

// Paper: warm base, fibers, light from the upper left falling off to a warmer edge.
let fibers = grain(frame: 4242, size: 3.0, amount: 0.035)
var paper = fibers.applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: solid(Paper.color.r, Paper.color.g, Paper.color.b)])
let light = CIFilter(name: "CIRadialGradient", parameters: [
    "inputCenter": CIVector(x: SS * 0.38, y: SS * 0.70), "inputRadius0": SS * 0.12, "inputRadius1": SS * 0.95,
    "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0), "inputColor1": CIColor(red: 0.30, green: 0.22, blue: 0.12, alpha: 0.30),
])!.outputImage!
paper = light.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: paper]).cropped(to: square)
paper = ink.over(paper)
paper = addGrain(paper, frame: 7, size: 1.4, amount: 0.02)

let m = mask(squircle(body))
// A faint darker rim inside the edge, like the curl of a thick sheet.
let rim = m.applyingGaussianBlur(sigma: Double(18 * k)).cropped(to: square)
    .applyingFilter("CIColorInvert")
    .applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0.22, y: 0, z: 0, w: 0),
        "inputBiasVector": CIVector(x: 0.22, y: 0.16, z: 0.08, w: 0),
    ])
paper = rim.over(paper).cropped(to: square)
let clear = CIImage(color: .clear).cropped(to: square)
let sheet = paper.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: m])

// Drop shadow (Apple's template: about 12 pt down, soft).
let shadowMask = m.transformed(by: .init(translationX: 0, y: -12 * k)).applyingGaussianBlur(sigma: Double(14 * k)).cropped(to: square)
let shadow = solid(0, 0, 0, 0.32).cropped(to: square)
    .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: shadowMask])
let icon = sheet.over(shadow).cropped(to: square)

writePNG(icon, outPath, scale: outSize / SS)
print("wrote", outPath)
