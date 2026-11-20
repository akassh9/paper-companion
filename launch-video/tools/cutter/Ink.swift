import AppKit
import CoreImage

// A small pen-on-paper drawing engine. Everything is built once as timed strokes in world coordinates
// (canvas pixels before the camera), then drawn at any time t through a camera, so lines stay crisp at
// every zoom.

struct RGBA { var r, g, b, a: CGFloat
    static let ink = RGBA(r: 0.1, g: 0.1, b: 0.13, a: 0.92)
    static let inkLight = RGBA(r: 0.1, g: 0.1, b: 0.13, a: 0.5)
    static let purple = RGBA(r: 175 / 255, g: 82 / 255, b: 222 / 255, a: 1)
    static let teal = RGBA(r: 0.1, g: 0.6, b: 0.68, a: 1)
    static let green = RGBA(r: 0.16, g: 0.66, b: 0.33, a: 1)
    static let orange = RGBA(r: 0.95, g: 0.55, b: 0.05, a: 1)
    static let gray = RGBA(r: 0.55, g: 0.55, b: 0.58, a: 1)
    func with(a: CGFloat) -> RGBA { RGBA(r: r, g: g, b: b, a: a) }
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

enum StrokeKind { case pen, marker, dashed, ribbon }

struct Stroke {
    var points: [CGPoint]
    var width: CGFloat
    var start: Double
    var duration: Double
    var color: RGBA = .ink
    var kind: StrokeKind = .pen
    var fadeOut: Double? = nil      // time it fades away (for transitions)
    var lengths: [CGFloat] = []
    var total: CGFloat { lengths.last ?? 0 }

    init(_ points: [CGPoint], width: CGFloat, start: Double, duration: Double, color: RGBA = .ink, kind: StrokeKind = .pen) {
        self.points = points; self.width = width; self.start = start; self.duration = duration
        self.color = color; self.kind = kind
        lengths = [0]
        for i in 1..<max(points.count, 1) {
            lengths.append(lengths[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
        }
    }
    var end: Double { start + duration }
}

struct TypeMark {
    var text: String
    var style: TypeStyle
    var at: CGPoint
    var deg: Double = 0
    var start: Double
    var fade: Double = 0.25
}

struct PrintMark {
    var clip: String
    var srcStart: Double
    var center: CGPoint
    var height: CGFloat
    var deg: Double
    var start: Double
    var end: Double = 1e9
}

struct Line { var a: CGPoint; var b: CGPoint; var y: CGFloat }   // world endpoints of a ruled text line

final class Drawing {
    var strokes: [Stroke] = []
    var types: [TypeMark] = []
    var prints: [PrintMark] = []
    var rng: SplitMix

    init(seed: UInt64) { rng = SplitMix(seed: seed) }

    func add(_ s: Stroke) { strokes.append(s) }

    // MARK: Primitives

    struct Wobble {
        var phases: [Double]; var freqs: [Double]; var amps: [Double]
        init(_ rng: inout SplitMix, amp: Double, scale: Double = 1) {
            phases = (0..<3).map { _ in rng.unit() * 6.28 }
            freqs = [0.9, 2.3, 5.1].map { $0 * scale * (0.8 + rng.unit() * 0.4) }
            amps = [1, 0.45, 0.18].map { $0 * amp }
        }
        func at(_ u: Double) -> Double { zip(zip(phases, freqs), amps).reduce(0) { $0 + sin($1.0.1 * u * 6.28 + $1.0.0) * $1.1 } }
    }

    func handLine(_ a: CGPoint, _ b: CGPoint, wobble: Double = 3) -> [CGPoint] {
        let len = max(hypot(b.x - a.x, b.y - a.y), 1)
        let n = max(2, Int(len / 6))
        let w = Wobble(&rng, amp: wobble, scale: Double(len) / 600)
        let nx = -(b.y - a.y) / len, ny = (b.x - a.x) / len
        return (0...n).map { i in
            let u = Double(i) / Double(n), o = w.at(u)
            return CGPoint(x: a.x + (b.x - a.x) * u + nx * o, y: a.y + (b.y - a.y) * u + ny * o)
        }
    }

    /// A beam-like S curve with horizontal tangents at both ends (the app's beam shape), slightly hand-wobbled.
    func sCurve(_ a: CGPoint, _ b: CGPoint, reach: CGFloat = 0.55, wobble: Double = 2) -> [CGPoint] {
        let dx = (b.x - a.x) * reach
        let c1 = CGPoint(x: a.x + dx, y: a.y), c2 = CGPoint(x: b.x - dx, y: b.y)
        let w = Wobble(&rng, amp: wobble, scale: 2)
        let n = max(40, Int(hypot(b.x - a.x, b.y - a.y) / 8))
        return (0...n).map { i in
            let t = CGFloat(i) / CGFloat(n), m = 1 - t
            let x = m * m * m * a.x + 3 * m * m * t * c1.x + 3 * m * t * t * c2.x + t * t * t * b.x
            let y = m * m * m * a.y + 3 * m * m * t * c1.y + 3 * m * t * t * c2.y + t * t * t * b.y
            return CGPoint(x: x, y: y + w.at(Double(t)))
        }
    }

    static func rotate(_ p: CGPoint, about c: CGPoint, _ deg: Double) -> CGPoint {
        let r = deg * .pi / 180, dx = p.x - c.x, dy = p.y - c.y
        return CGPoint(x: c.x + dx * cos(r) - dy * sin(r), y: c.y + dx * sin(r) + dy * cos(r))
    }

    static func catmull(_ p: [CGPoint], _ n: Int) -> [CGPoint] {
        guard p.count > 2 else { return p }
        var out: [CGPoint] = []
        for i in 0..<(p.count - 1) {
            let p0 = p[max(0, i - 1)], p1 = p[i], p2 = p[i + 1], p3 = p[min(p.count - 1, i + 2)]
            for k in 0..<n {
                let t = CGFloat(k) / CGFloat(n), t2 = t * t, t3 = t2 * t
                out.append(CGPoint(
                    x: 0.5 * ((2 * p1.x) + (-p0.x + p2.x) * t + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3),
                    y: 0.5 * ((2 * p1.y) + (-p0.y + p2.y) * t + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)))
            }
        }
        out.append(p.last!)
        return out
    }

    // MARK: Pages

    struct PageResult { var lines: [Line]; var center: CGPoint; var corners: [CGPoint]; var end: Double }

    /// A hand-drawn page: outline, a title, then paragraphs of word-dashes. `gaps` leaves room on line
    /// index → (x fraction, width) for typeset words. Returns each text line's endpoints.
    @discardableResult
    func page(_ r: CGRect, deg: Double, start: Double, speed: Double = 1, paragraphs: [Int]? = nil,
              lineGap: CGFloat = 56, textWidth: CGFloat = 3.6, gaps: [Int: (CGFloat, CGFloat)] = [:],
              title: Bool = true, outline: Bool = true) -> PageResult {
        let c = CGPoint(x: r.midX, y: r.midY)
        let corners = [CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
                       CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.minY)].map { Self.rotate($0, about: c, deg) }
        let k = r.width / 1080           // scale relative to the reference page size
        if outline {
            for i in 0..<4 {
                let a = corners[i], b = corners[(i + 1) % 4]
                let dx = b.x - a.x, dy = b.y - a.y, l = hypot(dx, dy)
                let a2 = CGPoint(x: a.x - dx / l * 14 * k, y: a.y - dy / l * 14 * k)
                let b2 = CGPoint(x: b.x + dx / l * 22 * k, y: b.y + dy / l * 22 * k)
                add(Stroke(handLine(a2, b2, wobble: 2.5 * k), width: 5.2 * max(k, 0.5), start: start + Double(i) * 0.14 / speed, duration: 0.18 / speed))
            }
        }
        var lines: [Line] = []
        var t = start + 0.6 / speed
        var y = r.maxY - 150 * k
        let left = r.minX + 110 * k, right = r.maxX - 110 * k
        func words(_ y: CGFloat, _ x0: CGFloat, _ x1: CGFloat, width: CGFloat, ink: CGFloat, gap: (CGFloat, CGFloat)? = nil) {
            var x = x0
            while x < x1 - 40 * k {
                if let g = gap {
                    let gx = left + (right - left) * g.0
                    if x + 60 * k > gx - 16 * k && x < gx + g.1 + 16 * k { x = gx + g.1 + 22 * k; continue }
                }
                var wl = CGFloat(50 + rng.unit() * 150) * k
                if let g = gap { let gx = left + (right - left) * g.0; if x < gx, x + wl > gx - 16 * k { wl = max(20 * k, gx - 16 * k - x) } }
                let xe = min(x + wl, x1)
                let a = Self.rotate(CGPoint(x: x, y: y), about: c, deg)
                let b = Self.rotate(CGPoint(x: xe, y: y + CGFloat(rng.unit() * 4 - 2) * k), about: c, deg)
                add(Stroke(handLine(a, b, wobble: 1.6 * k), width: width * max(k, 0.45), start: t, duration: 0.05 / speed, color: RGBA.ink.with(a: ink)))
                t += 0.016 / speed
                x = xe + CGFloat(26 + rng.unit() * 18) * k
            }
        }
        if title {
            words(y, left + 90 * k, right - 90 * k - CGFloat(rng.unit() * 120) * k, width: 9, ink: 0.85)
            y -= 130 * k
        }
        let paras = paragraphs ?? [5, 6, 4, 5]
        var index = 0
        for (pi, n) in paras.enumerated() {
            for l in 0..<n where y > r.minY + 95 * k {
                let x0 = l == 0 ? left + 50 * k : left
                let x1 = l == n - 1 ? left + (right - left) * CGFloat(0.35 + rng.unit() * 0.4) : right
                words(y, x0, x1, width: textWidth, ink: 0.55, gap: gaps[index])
                lines.append(Line(a: Self.rotate(CGPoint(x: x0, y: y), about: c, deg), b: Self.rotate(CGPoint(x: x1, y: y), about: c, deg), y: y))
                index += 1
                y -= lineGap * k
            }
            if pi < paras.count - 1 { y -= 52 * k }
        }
        return PageResult(lines: lines, center: c, corners: corners, end: t)
    }

    // MARK: Marks

    /// A highlighter swipe along text lines (behind the ink).
    func marker(_ line: Line, from u0: CGFloat = 0, to u1: CGFloat = 1, start: Double, duration: Double, color: RGBA = .purple, width: CGFloat = 44) {
        let a = CGPoint(x: line.a.x + (line.b.x - line.a.x) * u0 - 8, y: line.a.y + (line.b.y - line.a.y) * u0 - 4)
        let b = CGPoint(x: line.a.x + (line.b.x - line.a.x) * u1 + 8, y: line.a.y + (line.b.y - line.a.y) * u1 - 4)
        add(Stroke(handLine(a, b, wobble: 1.5), width: width, start: start, duration: duration, color: color.with(a: 0.26), kind: .marker))
    }

    /// A pen box around a region (two strokes, overlapping at a corner).
    func box(_ r: CGRect, start: Double, duration: Double, color: RGBA = .ink, width: CGFloat = 4.5) {
        let pts = [CGPoint(x: r.minX - 6, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY + 2), CGPoint(x: r.maxX + 1, y: r.minY),
                   CGPoint(x: r.minX, y: r.minY - 2), CGPoint(x: r.minX - 1, y: r.maxY + 10)]
        var all: [CGPoint] = []
        for i in 0..<(pts.count - 1) { all += handLine(pts[i], pts[i + 1], wobble: 1.6) }
        add(Stroke(all, width: width, start: start, duration: duration, color: color))
    }

    /// Ruled lines inside a box (an evidence card or a quote).
    func ruled(_ r: CGRect, lines n: Int, start: Double, perLine: Double = 0.06, ink: CGFloat = 0.5) {
        for i in 0..<n {
            let rows = CGFloat(n) + 0.6
            let y: CGFloat = r.maxY - (CGFloat(i) + 0.8) * r.height / rows
            let x1 = i == n - 1 ? r.minX + r.width * CGFloat(0.4 + rng.unit() * 0.4) : r.maxX - 24
            add(Stroke(handLine(CGPoint(x: r.minX + 24, y: y), CGPoint(x: x1, y: y), wobble: 1.2), width: 3.2,
                       start: start + Double(i) * perLine, duration: perLine, color: RGBA.ink.with(a: ink)))
        }
    }

    // MARK: Handwriting

    static let glyphs: [Character: (adv: CGFloat, strokes: [[CGPoint]])] = {
        func p(_ v: Double...) -> [CGPoint] { stride(from: 0, to: v.count - 1, by: 2).map { CGPoint(x: v[$0], y: v[$0 + 1]) } }
        func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, from a0: CGFloat = 0.25) -> [CGPoint] {
            (0...24).map { i in let a = (a0 + CGFloat(i) / 24 * 1.05) * 2 * .pi; return CGPoint(x: cx + cos(a) * rx, y: cy + sin(a) * ry) }
        }
        var g: [Character: (adv: CGFloat, strokes: [[CGPoint]])] = [:]
        g["0"] = (0.72, [ellipse(0.36, 0.5, 0.28, 0.5)])
        g["1"] = (0.5, [p(0.1, 0.78, 0.32, 1.0, 0.32, 0.0)])
        g["2"] = (0.7, [p(0.08, 0.78, 0.28, 0.98, 0.56, 0.98, 0.66, 0.76, 0.5, 0.45, 0.06, 0.0, 0.7, 0.02)])
        g["3"] = (0.68, [p(0.08, 0.86, 0.34, 1.0, 0.6, 0.88, 0.56, 0.62, 0.32, 0.53, 0.62, 0.42, 0.64, 0.14, 0.38, 0.0, 0.06, 0.12)])
        g["4"] = (0.72, [p(0.52, 0.0, 0.52, 1.0, 0.04, 0.3, 0.7, 0.3)])
        g["5"] = (0.68, [p(0.64, 1.0, 0.18, 1.0, 0.12, 0.56, 0.42, 0.62, 0.64, 0.44, 0.6, 0.12, 0.36, 0.0, 0.06, 0.1)])
        g["6"] = (0.7, [p(0.62, 0.96, 0.32, 0.86, 0.1, 0.46, 0.14, 0.1, 0.4, 0.0, 0.64, 0.18, 0.6, 0.44, 0.34, 0.52, 0.12, 0.36)])
        g["7"] = (0.66, [p(0.06, 1.0, 0.66, 1.0, 0.26, 0.0)])
        g["8"] = (0.7, [p(0.36, 0.53, 0.12, 0.72, 0.16, 0.95, 0.36, 1.0, 0.58, 0.93, 0.6, 0.72, 0.36, 0.53, 0.1, 0.3, 0.12, 0.06, 0.36, 0.0, 0.62, 0.08, 0.64, 0.3, 0.36, 0.53)])
        g["9"] = (0.7, [p(0.62, 0.66, 0.4, 0.5, 0.14, 0.62, 0.16, 0.92, 0.42, 1.0, 0.64, 0.85, 0.62, 0.5, 0.48, 0.1, 0.18, 0.0)])
        g["."] = (0.3, [p(0.12, 0.02, 0.15, 0.06, 0.13, 0.0)])
        g["?"] = (0.78, [p(0.08, 0.72, 0.18, 0.94, 0.44, 1.0, 0.66, 0.88, 0.64, 0.66, 0.42, 0.5, 0.38, 0.28), p(0.37, 0.05, 0.39, 0.08, 0.38, 0.02)])
        g["✓"] = (0.95, [p(0.0, 0.42, 0.28, 0.08, 0.9, 1.0)])
        g["~"] = (1.0, [p(0.0, 0.42, 0.22, 0.6, 0.5, 0.44, 0.76, 0.28, 1.0, 0.46)])
        g["o"] = (0.9, [ellipse(0.42, 0.45, 0.4, 0.42, from: 0.15)])
        g["→"] = (1.15, [p(0.0, 0.45, 1.0, 0.45), p(0.72, 0.68, 1.02, 0.45, 0.72, 0.22)])
        return g
    }()

    /// Writes `text` by hand with its baseline starting at `at`. Glyphs are `size` px tall, slanted a little.
    @discardableResult
    func hand(_ text: String, at: CGPoint, size: CGFloat, start: Double, duration: Double, color: RGBA = .ink, width: CGFloat = 6) -> CGFloat {
        let chars = Array(text)
        let per = duration / Double(max(chars.count, 1))
        var x = at.x
        for (i, ch) in chars.enumerated() {
            guard let g = Self.glyphs[ch] else { x += size * 0.4; continue }
            let jx = CGFloat(rng.unit() - 0.5) * size * 0.04, jy = CGFloat(rng.unit() - 0.5) * size * 0.05
            let sub = per / Double(g.strokes.count)
            for (j, s) in g.strokes.enumerated() {
                let pts = s.map { CGPoint(x: x + jx + ($0.x + $0.y * 0.16) * size, y: at.y + jy + $0.y * size) }
                add(Stroke(Self.catmull(pts, 8), width: width, start: start + Double(i) * per + Double(j) * sub, duration: sub * 0.9, color: color))
            }
            x += g.adv * size
        }
        return x
    }

    /// A strike-through over a typeset word: a quick, slightly rising line.
    func strike(_ r: CGRect, start: Double, color: RGBA, width: CGFloat = 6) {
        add(Stroke(handLine(CGPoint(x: r.minX - 10, y: r.midY - 4), CGPoint(x: r.maxX + 12, y: r.midY + 8), wobble: 1), width: width,
                   start: start, duration: 0.14, color: color))
    }

    // MARK: Drawing it

    /// Renders ink (and markers) at time `t` through a camera that puts world point `focus` at the canvas
    /// centre, scaled by `zoom`. `fade` multiplies every stroke's opacity.
    func renderInk(t: Double, zoom: CGFloat, focus: CGPoint, fade: Double = 1, only: ((Stroke) -> Bool)? = nil) -> CIImage {
        // The area drawn: the frame, or wider while a transition slides this scene in or out.
        let vp = Paper.viewport
        let ctx = CGContext(data: nil, width: Int(vp.width), height: Int(vp.height), bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: -vp.minX, y: -vp.minY)
        ctx.translateBy(x: W / 2, y: H / 2)
        ctx.scaleBy(x: zoom, y: zoom)
        ctx.translateBy(x: -focus.x, y: -focus.y)
        ctx.setLineJoin(.round)
        let ordered = strokes.filter { $0.kind == .marker } + strokes.filter { $0.kind != .marker }
        for s in ordered {
            if let only, !only(s) { continue }
            let f = clamp01((t - s.start) / s.duration)
            guard f > 0, s.points.count > 1 else { continue }
            var alpha = Double(s.color.a) * fade
            if let fo = s.fadeOut { alpha *= 1 - smooth((t - fo) / 0.4) }
            guard alpha > 0.003 else { continue }
            let target = s.total * CGFloat(easeInOut(f) * 0.7 + f * 0.3)
            ctx.setStrokeColor(s.color.with(a: CGFloat(alpha)).cg)
            switch s.kind {
            case .marker:
                ctx.setLineCap(.butt)
                ctx.setLineWidth(s.width)
                ctx.addLines(between: prefix(s, target))
                ctx.strokePath()
            case .dashed:
                ctx.setLineCap(.round)
                ctx.setLineWidth(s.width)
                ctx.setLineDash(phase: 0, lengths: [s.width * 3, s.width * 2.6])
                ctx.addLines(between: prefix(s, target))
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
            case .pen, .ribbon:
                ctx.setLineCap(.round)
                // Fountain-pen taper: thicker mid-stroke, thinner at the ends.
                var prev = s.points[0]
                for i in 1..<s.points.count {
                    if s.lengths[i - 1] > target { break }
                    let u = Double(s.lengths[i] / max(s.total, 1))
                    let taper = s.kind == .ribbon ? 1 : 0.55 + 0.45 * sin(.pi * min(1, max(0, u)))
                    ctx.setLineWidth(s.width * CGFloat(taper))
                    var b = s.points[i]
                    if s.lengths[i] > target {
                        let kk = (target - s.lengths[i - 1]) / max(s.lengths[i] - s.lengths[i - 1], 0.001)
                        b = CGPoint(x: prev.x + (b.x - prev.x) * kk, y: prev.y + (b.y - prev.y) * kk)
                    }
                    ctx.move(to: prev); ctx.addLine(to: b); ctx.strokePath()
                    prev = s.points[i]
                }
            }
        }
        return CIImage(cgImage: ctx.makeImage()!).transformed(by: .init(translationX: vp.minX, y: vp.minY))
    }

    private func prefix(_ s: Stroke, _ target: CGFloat) -> [CGPoint] {
        var out = [s.points[0]]
        for i in 1..<s.points.count {
            if s.lengths[i] <= target { out.append(s.points[i]); continue }
            let kk = (target - s.lengths[i - 1]) / max(s.lengths[i] - s.lengths[i - 1], 0.001)
            let a = s.points[i - 1], b = s.points[i]
            out.append(CGPoint(x: a.x + (b.x - a.x) * kk, y: a.y + (b.y - a.y) * kk))
            break
        }
        return out
    }

    /// Typeset words and laid-down prints at time `t`, through the same camera, over `base`.
    func renderMarks(t: Double, frame: Int, zoom: CGFloat, focus: CGPoint, over base: CIImage, fade: Double = 1) -> CIImage {
        var img = base
        let cam = CGAffineTransform(translationX: -focus.x, y: -focus.y).concatenating(.init(scaleX: zoom, y: zoom))
            .concatenating(.init(translationX: W / 2, y: H / 2))
        for p in prints where t >= p.start && t <= p.end + 0.4 {
            let appear = easeOut((t - p.start) / 0.45)
            let leave = 1 - smooth((t - p.end) / 0.35)
            let v = video(p.clip)
            var st = p.srcStart + (t - p.start)
            if st > v.duration - 0.1 { st = p.srcStart + fmod(st - p.srcStart, max(0.5, v.duration - 0.1 - p.srcStart)) }
            let src = v.frame(at: st)
            var pr = paperPrint(src, frame: frame, height: p.height)
            let settle = 1.04 - 0.04 * appear
            pr = pr.transformed(by: CGAffineTransform(rotationAngle: CGFloat(p.deg * .pi / 180)).concatenating(.init(scaleX: settle, y: settle))
                .concatenating(.init(translationX: p.center.x, y: p.center.y)))
            img = pr.transformed(by: cam).opacity(appear * leave * fade).over(img)
        }
        for m in types where t >= m.start {
            let o = smooth((t - m.start) / m.fade) * fade
            let ti = typeImage(m.text, m.style).transformed(by: CGAffineTransform(rotationAngle: CGFloat(m.deg * .pi / 180))
                .concatenating(.init(translationX: m.at.x, y: m.at.y)))
            img = ti.transformed(by: cam).opacity(o).over(img)
        }
        return img
    }
}

// MARK: Paper and prints

enum Paper {
    static let color = (r: 0.958, g: 0.942, b: 0.902)

    /// Warm paper, rendered once: fibers and a soft light falloff.
    static let base: CIImage = {
        let base = solid(color.r, color.g, color.b)
        let fibers = grain(frame: 4242, size: 3.2, amount: 0.03)
        let tex = fibers.applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: base]).cropped(to: canvas)
        let light = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: W * 0.45, y: H * 0.6), "inputRadius0": 400, "inputRadius1": 3200,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0), "inputColor1": CIColor(red: 0.28, green: 0.22, blue: 0.14, alpha: 0.42),
        ])!.outputImage!.cropped(to: canvas)
        let lit = light.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: tex]).cropped(to: canvas)
        return CIImage(cgImage: ciContext.createCGImage(lit, from: canvas)!)
    }()

    /// A full frame of paper world: paper, prints and type, then ink, then fine grain.
    /// While a transition slides two scenes past each other, each renders only its content (prints, type,
    /// ink) on a clear background; the transition lays both over one sheet of paper, so there is no seam.
    static var layerOnly = false
    static var clear: CIImage { CIImage(color: .clear).cropped(to: viewport) }
    /// The region scenes render into. Wider than the frame only during a transition.
    static var viewport = canvas

    static func frame(_ d: Drawing, t: Double, frame: Int, zoom: CGFloat = 1, focus: CGPoint = CGPoint(x: W / 2, y: H / 2),
                      fade: Double = 1, extra: ((CIImage) -> CIImage)? = nil) -> CIImage {
        var img = d.renderMarks(t: t, frame: frame, zoom: zoom, focus: focus, over: layerOnly ? clear : base, fade: fade)
        img = d.renderInk(t: t, zoom: zoom, focus: focus, fade: fade).over(img)
        if let extra { img = extra(img) }
        if layerOnly { return img.cropped(to: viewport) }
        return addGrain(img, frame: frame, size: 1.3, amount: 0.022).canvasCrop()
    }
}

/// An archive frame as a photographic print lying on paper: graded, thin white border, soft shadow.
/// Returned centred on the origin.
func paperPrint(_ src: CIImage, frame: Int, height: CGFloat) -> CIImage {
    let e = src.extent
    let inset = src.cropped(to: e.insetBy(dx: e.width * 0.025, dy: e.height * 0.03))
    let ie = inset.extent
    let w = height * 4 / 3
    let s = max(w / ie.width, height / ie.height)
    let wx = sin(Double(frame) * 0.37) * 0.8, wy = cos(Double(frame) * 0.29) * 0.7
    var img = inset.transformed(by: CGAffineTransform(translationX: -ie.midX, y: -ie.midY)
        .concatenating(.init(scaleX: s, y: s)).concatenating(.init(translationX: wx, y: wy)))
    let rect = CGRect(x: -w / 2, y: -height / 2, width: w, height: height)
    img = archiveGrade(img).cropped(to: rect)
    img = vignette(img, intensity: 0.45, radius: 1.3)
    img = addGrainLocal(img, frame: frame)
    let border = height * 0.028
    let paperWhite = CIImage(color: CIColor(red: 0.97, green: 0.965, blue: 0.95)).cropped(to: rect.insetBy(dx: -border, dy: -border))
    let shadow = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35)).cropped(to: rect.insetBy(dx: -border, dy: -border).offsetBy(dx: 0, dy: -height * 0.012))
        .applyingGaussianBlur(sigma: Double(height) * 0.018)
    return img.cropped(to: rect).over(paperWhite).over(shadow)
}

/// Grain for an image not aligned with the canvas.
func addGrainLocal(_ img: CIImage, frame: Int) -> CIImage {
    let g = grain(frame: frame, size: 2.2, amount: 0.07).transformed(by: .init(translationX: img.extent.minX, y: img.extent.minY))
    return g.applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: img]).cropped(to: img.extent)
}
