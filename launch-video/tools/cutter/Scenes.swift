import CoreImage

/// The drawings, each built once. Times are local to the scene (seconds from its first frame).
enum Scenes {
    static let cx = W / 2, cy = H / 2

    // MARK: Ask: a passage marked, a question in the margin, the answer page drawn from its words.

    struct Ask { let d: Drawing; let pageA: Drawing.PageResult; let pageB: Drawing.PageResult }
    static let ask: Ask = {
        let d = Drawing(seed: 11)
        let a = d.page(CGRect(x: 820, y: 350, width: 1080, height: 1460), deg: -1.2, start: 0.0, speed: 2.4, paragraphs: [5, 6, 5, 4])
        // The question: a passage swiped with the marker, a "?" in the margin.
        let q0 = a.lines[6], q1 = a.lines[7]
        d.hand("?", at: CGPoint(x: q0.b.x + 70, y: q0.b.y - 40), size: 120, start: 1.45, duration: 0.4, width: 7)
        d.marker(q0, from: 0.08, to: 1, start: 2.0, duration: 0.22)
        d.marker(q1, from: 0, to: 0.7, start: 2.2, duration: 0.18)
        // The answer page, beside it: prose, a boxed quote, prose, a boxed quote, prose.
        let b = d.page(CGRect(x: 2160, y: 350, width: 1080, height: 1460), deg: 0.9, start: 2.45, speed: 2.8, paragraphs: [3, 3, 3, 3, 3])
        func quoteBox(_ i: Int, _ t: Double) -> CGRect {
            let top = b.lines[i].a.y + 34, bottom = b.lines[i + 2].a.y - 30
            let r = CGRect(x: b.lines[i].a.x - 26, y: bottom, width: (b.lines[i].b.x - b.lines[i].a.x) + 52, height: top - bottom)
            d.box(r, start: t, duration: 0.35)
            return r
        }
        let box1 = quoteBox(3, 3.55), box2 = quoteBox(9, 3.85)
        // Each quote joined back to where it came from.
        let src1 = CGPoint(x: q0.b.x + 18, y: (q0.b.y + q1.b.y) / 2 - 6)
        d.add(Stroke(d.sCurve(src1, CGPoint(x: box1.minX - 6, y: box1.midY)), width: 7, start: 4.15, duration: 0.55, color: .purple, kind: .ribbon))
        let q2 = a.lines[14]
        d.marker(q2, from: 0.15, to: 0.9, start: 4.3, duration: 0.2)
        d.add(Stroke(d.sCurve(CGPoint(x: q2.b.x + 18, y: q2.b.y - 4), CGPoint(x: box2.minX - 6, y: box2.midY)), width: 7, start: 4.55, duration: 0.55, color: .purple, kind: .ribbon))
        // The archive print laid on the paper mid-scene, linked to the page it inspired.
        d.prints.append(PrintMark(clip: "assets/archival/Libraria1947__000750-000845.mp4", srcStart: 51.2,
                                  center: CGPoint(x: 560, y: 560), height: 560, deg: -5, start: 5.95, end: 7.0))
        return Ask(d: d, pageA: a, pageB: b)
    }()

    static func askFrame(_ t: Double, _ f: Int) -> CIImage {
        // Starts close on the first page, pulls out to both as the answer arrives, eases in on a link.
        let zoom: CGFloat, focus: CGPoint
        let p1 = CGPoint(x: 1360, y: 1080), both = CGPoint(x: 2030, y: 1080), link = CGPoint(x: 2050, y: 1150)
        if t < 2.0 { zoom = 1.22 - 0.04 * CGFloat(easeOut(t / 2)); focus = p1 }
        else if t < 3.2 { let k = CGFloat(easeInOut((t - 2) / 1.2)); zoom = 1.18 - 0.2 * k; focus = mix(p1, both, k) }
        else if t < 5.4 { zoom = 0.98 - 0.02 * CGFloat(smooth((t - 3.2) / 2.2)); focus = both }
        else if t < 7.4 { let k = CGFloat(easeInOut((t - 5.4) / 1.4)); zoom = 0.96 - 0.08 * k; focus = mix(both, CGPoint(x: 1800, y: 1000), k) }
        else { let k = CGFloat(easeInOut((t - 7.4) / 3.0)); zoom = 0.88 + 0.5 * k; focus = mix(CGPoint(x: 1800, y: 1000), link, k) }
        return Paper.frame(ask.d, t: t, frame: f, zoom: zoom, focus: focus)
    }

    // MARK: Claims: sentences weighed, evidence fanned out.

    static let claims: Drawing = {
        let d = Drawing(seed: 23)
        let p = d.page(CGRect(x: 560, y: 350, width: 1080, height: 1460), deg: -0.8, start: -3, speed: 3, paragraphs: [7, 5, 5])
        let marks: [(Int, RGBA, Character, StrokeKind)] = [(1, .green, "✓", .ribbon), (3, .orange, "~", .dashed), (5, .gray, "o", .dashed)]
        var boxY: CGFloat = 1660
        for (k, (li, color, glyph, kind)) in marks.enumerated() {
            let line = p.lines[li]
            let t0 = 0.25 + Double(k) * 0.55
            d.marker(line, from: 0.04, to: 0.96, start: t0, duration: 0.2, color: color)
            d.hand(String(glyph), at: CGPoint(x: line.b.x + 50, y: line.b.y - 24), size: 70, start: t0 + 0.2, duration: 0.22, color: color, width: 7)
            let nBoxes = k == 0 ? 2 : 1
            for j in 0..<nBoxes {
                let r = CGRect(x: 2200, y: boxY - 300, width: 1050, height: 300)
                let tb = t0 + 0.35 + Double(j) * 0.2
                d.box(r, start: tb, duration: 0.3, color: k == 2 ? RGBA.gray.with(a: 0.7) : .ink, width: 4)
                if k == 2 {
                    d.hand("?", at: CGPoint(x: r.midX - 30, y: r.midY - 40), size: 90, start: tb + 0.3, duration: 0.25, color: .gray, width: 6)
                } else {
                    d.ruled(r, lines: 3, start: tb + 0.25)
                }
                d.add(Stroke(d.sCurve(CGPoint(x: line.b.x + 140, y: line.b.y - 4), CGPoint(x: r.minX - 10, y: r.midY), reach: 0.5),
                             width: k == 0 ? 6 : 5, start: tb + 0.05, duration: 0.4, color: color, kind: kind))
                boxY -= 340
            }
        }
        return d
    }()

    static func claimsFrame(_ t: Double, _ f: Int) -> CIImage {
        let k = CGFloat(easeInOut(t / 4.2))
        return Paper.frame(claims, t: t, frame: f, zoom: 1.0 + 0.06 * k, focus: CGPoint(x: 1900 + 40 * k, y: 1080 + 30 * k))
    }

    // MARK: Links: a ribbon drawn between two sentences, and what it means.

    static let links: Drawing = {
        let d = Drawing(seed: 31)
        let a = d.page(CGRect(x: 640, y: 330, width: 1080, height: 1460), deg: -1.6, start: -3, speed: 3)
        let b = d.page(CGRect(x: 2120, y: 360, width: 1080, height: 1460), deg: 1.2, start: -3, speed: 3)
        let la = a.lines[6], lb = b.lines[12]
        d.marker(la, from: 0.1, to: 1, start: 0.2, duration: 0.25, color: .purple)
        d.marker(lb, from: 0, to: 0.85, start: 0.55, duration: 0.25, color: .purple)
        let start = CGPoint(x: la.b.x + 16, y: la.b.y - 4), end = CGPoint(x: lb.a.x - 16, y: lb.a.y - 4)
        d.add(Stroke(d.sCurve(start, end, reach: 0.6), width: 9, start: 0.9, duration: 0.9, color: .purple, kind: .ribbon))
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        d.types.append(TypeMark(text: "supports", style: TypeStyle(size: 52, weight: 0.23, tracking: 0, color: [0.45, 0.22, 0.6, 1], italic: true),
                                at: CGPoint(x: mid.x, y: mid.y + 70), start: 1.85, fade: 0.35))
        return d
    }()

    static func linksFrame(_ t: Double, _ f: Int) -> CIImage {
        let k = CGFloat(easeInOut(t / 4))
        return Paper.frame(links, t: t, frame: f, zoom: 1.04 + 0.12 * k, focus: CGPoint(x: 1920, y: 1060 - 20 * k))
    }

    // MARK: What if: change a number, watch it ripple.

    static let numStyle = TypeStyle(size: 60, weight: 0.0, tracking: 0, color: [0.1, 0.1, 0.13, 1], serif: true)
    static let whatIf: Drawing = {
        let d = Drawing(seed: 47)
        let gapW: CGFloat = 130
        let a = d.page(CGRect(x: 560, y: 350, width: 1080, height: 1460), deg: -0.6, start: -3, speed: 3, gaps: [7: (0.42, gapW)])
        let b = d.page(CGRect(x: 2200, y: 350, width: 1080, height: 1460), deg: 0.7, start: -3, speed: 3,
                       gaps: [2: (0.6, gapW), 9: (0.2, gapW), 15: (0.5, gapW)])
        func place(_ p: Drawing.PageResult, _ line: Int, _ frac: CGFloat, _ text: String) -> CGRect {
            let l = p.lines[line]
            let left = l.a.x + (line == 0 ? -50 : 0)
            _ = left
            // Lines run from x0 to the page's right text margin; gaps are measured from the left margin.
            let x0 = p.corners[0].x + 110, x1 = p.corners[1].x - 110
            let x = x0 + (x1 - x0) * frac + gapW / 2
            let y = l.a.y + (l.b.y - l.a.y) * ((x - l.a.x) / max(l.b.x - l.a.x, 1)) + 8
            d.types.append(TypeMark(text: text, style: numStyle, at: CGPoint(x: x, y: y), start: -1))
            return CGRect(x: x - 60, y: y - 26, width: 120, height: 52)
        }
        let n0 = place(a, 7, 0.42, "0.94")
        let others = [(place(b, 2, 0.6, "206"), "112"), (place(b, 9, 0.2, "0.94"), "0.50"), (place(b, 15, 0.5, "1.20"), "0.71")]
        // The edit.
        d.strike(n0, start: 0.35, color: .teal)
        d.hand("0.5", at: CGPoint(x: n0.minX + 14, y: n0.maxY + 40), size: 70, start: 0.55, duration: 0.42, color: .teal, width: 6.5)
        // The ripple: each knock-on number joined to the edit, struck, rewritten.
        var prev = CGPoint(x: n0.maxX + 30, y: n0.midY + 30)
        for (i, (r, new)) in others.enumerated() {
            let t0 = 1.25 + Double(i) * 0.55
            d.add(Stroke(d.sCurve(prev, CGPoint(x: r.minX - 18, y: r.midY + 4), reach: 0.5), width: 4.5, start: t0, duration: 0.35, color: RGBA.teal.with(a: 0.8), kind: .dashed))
            d.strike(r, start: t0 + 0.3, color: .teal)
            d.hand(new, at: CGPoint(x: r.minX + 10, y: r.maxY + 38), size: 64, start: t0 + 0.42, duration: 0.3, color: .teal, width: 6)
            prev = CGPoint(x: r.maxX + 20, y: r.midY)
        }
        return d
    }()

    static func whatIfFrame(_ t: Double, _ f: Int) -> CIImage {
        let k = CGFloat(easeInOut(t / 4.5))
        return Paper.frame(whatIf, t: t, frame: f, zoom: 1.12 - 0.1 * k, focus: CGPoint(x: 1450 + 500 * k, y: 1100))
    }

    // MARK: The opening page, drawn as the paper world arrives.

    static func introFrame(_ t: Double, _ f: Int) -> CIImage {
        // The same drawing as Ask, seen before it begins: the page draws and the "?" is written.
        askFrame(t, f)
    }

    // MARK: Prints on paper between beats, each crossed by a purple line heading for the next idea.

    static func printScene(clip: String, src: Double, deg: Double, seed: UInt64) -> (Double, Int) -> CIImage {
        let d = Drawing(seed: seed)
        d.prints.append(PrintMark(clip: clip, srcStart: src, center: CGPoint(x: cx - 120, y: cy + 40), height: 1260, deg: deg, start: -1.0))
        let from = CGPoint(x: cx + 840 * 1.0 + 40, y: cy + 120)
        d.add(Stroke(d.sCurve(from, CGPoint(x: W + 300, y: cy - 260), reach: 0.5), width: 8, start: 0.35, duration: 0.8, color: .purple, kind: .ribbon))
        d.add(Stroke(d.handLine(CGPoint(x: cx - 960, y: cy - 600), CGPoint(x: cx + 700, y: cy - 612), wobble: 2), width: 5, start: 0.2, duration: 0.5))
        return { t, f in
            let k = CGFloat(easeOut(t / 1.6))
            return Paper.frame(d, t: t, frame: f, zoom: 0.98 + 0.05 * k, focus: CGPoint(x: cx + 30 * k, y: cy))
        }
    }

    // MARK: Montage: a sheet of pages that draw faster and faster, joined by more and more links.

    struct Web { let d: Drawing; let size: CGSize }
    static let web: Web = {
        let d = Drawing(seed: 1960)
        let cols = 8, rows = 5
        let pw: CGFloat = 1080, ph: CGFloat = 1460, sx: CGFloat = 1380, sy: CGFloat = 1760
        let origin = CGPoint(x: W / 2 - CGFloat(cols - 1) * sx / 2 - pw / 2, y: H / 2 - CGFloat(rows - 1) * sy / 2 - ph / 2)
        var pages: [(Int, Int, Drawing.PageResult)] = []
        let clips: [(String, Double)] = [
            ("assets/archival/Libraria1947__000250-000340.mp4", 2), ("assets/archival/MakingBo1947__000050-000140.mp4", 18),
            ("assets/archival/Libraria1947__000420-000445.mp4", 4), ("assets/archival/Libraria1947__000020-000045.mp4", 3),
            ("assets/archival/MakingBo1947__000620-000645.mp4", 6), ("assets/archival/Libraria1947__000750-000845.mp4", 3),
            ("assets/archival/Libraria1947__000920-000945.mp4", 2), ("assets/archival/Libraria1947__000250-000340.mp4", 20),
        ]
        var printCells: Set<Int> = [3, 10, 17, 22, 28, 33, 12, 37]
        // Cells start nearest the centre first, then outward, faster and faster.
        let center = (Double(cols - 1) / 2, Double(rows - 1) / 2)
        let order = (0..<(cols * rows)).sorted { a, b in
            let da = hypot(Double(a % cols) - center.0, Double(a / cols) - center.1), db = hypot(Double(b % cols) - center.0, Double(b / cols) - center.1)
            return da < db
        }
        var clipIndex = 0
        for (rank, cell) in order.enumerated() {
            let c = cell % cols, r = cell / cols
            let start = 6.2 * pow(Double(rank) / Double(cols * rows), 0.75) - 0.3
            let rect = CGRect(x: origin.x + CGFloat(c) * sx + CGFloat(d.rng.unit() - 0.5) * 80,
                              y: origin.y + CGFloat(r) * sy + CGFloat(d.rng.unit() - 0.5) * 80, width: pw, height: ph)
            let deg = (d.rng.unit() - 0.5) * 4
            if printCells.contains(cell) && rank > 0 {
                printCells.remove(cell)
                let (clip, src) = clips[clipIndex % clips.count]; clipIndex += 1
                d.prints.append(PrintMark(clip: clip, srcStart: src, center: CGPoint(x: rect.midX, y: rect.midY), height: 900, deg: deg * 1.5, start: start + 0.2))
                continue
            }
            let p = d.page(rect, deg: deg, start: start, speed: 2.6 + Double(rank) * 0.12)
            pages.append((c, r, p))
        }
        // Links between neighbouring pages, more and more of them.
        var t = 1.4
        var n = 0
        while t < 15.5 && n < 140 {
            let i = Int(d.rng.next() % UInt64(pages.count))
            let (c, r, p) = pages[i]
            let neighbours = pages.enumerated().filter { abs($0.element.0 - c) + abs($0.element.1 - r) == 1 && $0.element.0 > c - (d.rng.unit() < 0.3 ? 1 : 0) }
            guard let nb = neighbours.randomElement(using: &RNGBox.shared) else { t += 0.05; continue }
            let q = nb.element.2
            let la = p.lines[Int(d.rng.next() % UInt64(p.lines.count))], lb = q.lines[Int(d.rng.next() % UInt64(q.lines.count))]
            let (s, e) = la.b.x < lb.a.x ? (CGPoint(x: la.b.x + 14, y: la.b.y), CGPoint(x: lb.a.x - 14, y: lb.a.y))
                                          : (CGPoint(x: la.a.x, y: la.a.y), CGPoint(x: lb.b.x, y: lb.b.y))
            let pts = abs(s.x - e.x) > 200 ? d.sCurve(s, e, reach: 0.55) : d.sCurve(s, e, reach: 0.3, wobble: 3)
            d.add(Stroke(pts, width: 10, start: t, duration: 0.5, color: .purple, kind: .ribbon))
            t += max(0.04, 0.42 * pow(0.965, Double(n)))
            n += 1
        }
        return Web(d: d, size: CGSize(width: CGFloat(cols) * sx, height: CGFloat(rows) * sy))
    }()

    static func webFrame(_ t: Double, _ f: Int, length: Double) -> CIImage {
        // From one page, filling the frame, to the whole sheet.
        let k = easeInOut(t / length)
        let zoom = CGFloat(exp(lerp(log(1.05), log(0.215), k)))
        return Paper.frame(web.d, t: t, frame: f, zoom: zoom, focus: CGPoint(x: W / 2 + 60, y: H / 2 + CGFloat(40 * k)))
    }

    // MARK: Title

    static func titleFrame(_ t: Double, _ f: Int) -> CIImage {
        // The paper comes up out of the black, then the words arrive.
        var img = black.opacity(1 - smooth(t / 0.9)).over(Paper.base)
        let ink: [CGFloat] = [0.1, 0.1, 0.13, 1]
        if let c = typeCard("Paper Companion", TypeStyle(size: 180, weight: 0.3, tracking: -0.02, color: ink), at: CGPoint(x: cx, y: cy + 60), t: t, a: 0.45, b: 99, fin: 0.9) { img = c.over(img) }
        if let c = typeCard("Ask the paper.", TypeStyle(size: 84, weight: 0.0, tracking: -0.005, color: [0.42, 0.41, 0.42, 1]), at: CGPoint(x: cx, y: cy - 90), t: t, a: 2.0, b: 99, fin: 0.9) { img = c.over(img) }
        if let c = typeCard("Coming to Mac", TypeStyle(size: 44, weight: 0.23, tracking: 0.01, color: [0.5, 0.49, 0.5, 1]), at: CGPoint(x: cx, y: 250), t: t, a: 3.2, b: 99, fin: 0.9) { img = c.over(img) }
        return addGrain(img, frame: f, size: 1.3, amount: 0.022).canvasCrop()
    }
}

func mix(_ a: CGPoint, _ b: CGPoint, _ k: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k) }

/// A seeded generator for `randomElement(using:)`.
struct RNGBox: RandomNumberGenerator {
    static var shared = RNGBox()
    var s = SplitMix(seed: 77)
    mutating func next() -> UInt64 { s.next() }
}
