import CoreImage

struct Segment { let a: Double; let b: Double; let render: (Double, Int) -> CIImage }
struct Transition { let at: Double; let d: Double }
struct Card { let text: String; let a: Double; let b: Double; let onPaper: Bool; var y: CGFloat = 190 }

enum Timeline {
    static let length = 62.7
    static func arch(_ clip: String) -> String { "assets/archival/\(clip).mp4" }

    /// An archive shot in black space (cold open): graded print, slow push.
    /// `toPaper` (local seconds) is when the black around the print starts turning into paper: the print
    /// gains a white border and a shadow and becomes a photograph lying on the sheet.
    static func archive(_ clip: String, src: Double, push: (Double, Double) = (1.02, 1.05), dur: Double, fadeIn: Double = 0,
                        toPaper: Double? = nil) -> (Double, Int) -> CIImage {
        { t, f in
            let p = lerp(push.0, push.1, t / dur)
            let center = CGPoint(x: W / 2, y: H / 2 + 110)
            var print = archivePrint(video(arch(clip)).frame(at: src + t), frame: f, height: 1500, push: p, center: center)
            if fadeIn > 0 { print = print.opacity(smooth((t - 0.35) / fadeIn)) }
            guard let tp = toPaper, t > tp else { return Paper.layerOnly ? print.over(Paper.clear) : print.over(black) }
            let k = smooth((t - tp) / 0.6)
            let rect = print.extent, border: CGFloat = 1500 * 0.028
            let white = CIImage(color: CIColor(red: 0.97, green: 0.965, blue: 0.95)).cropped(to: rect.insetBy(dx: -border, dy: -border))
            let shadow = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35)).cropped(to: rect.insetBy(dx: -border, dy: -border).offsetBy(dx: 0, dy: -18))
                .applyingGaussianBlur(sigma: 27)
            let photo = print.over(white.opacity(k)).over(shadow.opacity(k))
            if Paper.layerOnly { return photo.over(Paper.clear) }
            let ground = black.opacity(1 - k).over(addGrain(Paper.base, frame: f, size: 1.3, amount: 0.022))
            return photo.over(ground).canvasCrop()
        }
    }

    static let segments: [Segment] = [
        Segment(a: 0.0, b: 2.64, render: archive("Libraria1947__000750-000845", src: 10.6, push: (1.0, 1.03), dur: 2.64, fadeIn: 1.4)),
        Segment(a: 2.64, b: 4.0, render: archive("Libraria1947__000020-000045", src: 2.0, dur: 1.36)),
        Segment(a: 4.0, b: 5.45, render: archive("Libraria1947__000420-000445", src: 12.2, dur: 1.45)),
        Segment(a: 5.45, b: 7.4, render: archive("Libraria1947__000420-000445", src: 0.1, push: (1.03, 1.07), dur: 1.95, toPaper: 1.3)),
        Segment(a: 7.4, b: 18.23, render: Scenes.askFrame),
        Segment(a: 18.23, b: 19.2, render: Scenes.printScene(clip: arch("MakingBo1947__000050-000140"), src: 0.3, deg: -1.5, seed: 5)),
        Segment(a: 19.2, b: 23.38, render: Scenes.claimsFrame),
        Segment(a: 23.38, b: 25.51, render: Scenes.printScene(clip: arch("Libraria1947__000250-000340"), src: 0.5, deg: 1.2, seed: 6)),
        Segment(a: 25.51, b: 29.22, render: Scenes.linksFrame),
        Segment(a: 29.22, b: 30.66, render: Scenes.printScene(clip: arch("MakingBo1947__000050-000140"), src: 17.0, deg: -1.0, seed: 7)),
        Segment(a: 30.66, b: 34.94, render: Scenes.whatIfFrame),
        Segment(a: 34.94, b: 52.68) { t, f in Scenes.webFrame(t, f, length: 17.74) },
        Segment(a: 52.68, b: 54.2) { _, _ in black },
        Segment(a: 54.2, b: 62.7) { t, f in
            let img = Scenes.titleFrame(t, f)
            let k = smooth((t - 7.6) / 0.9)
            return k > 0 ? black.opacity(k).over(img) : img
        },
    ]

    static let cards: [Card] = [
        Card(text: "Every paper is an argument.", a: 2.75, b: 5.3, onPaper: false),
        Card(text: "We've always answered it alone.", a: 5.6, b: 6.85, onPaper: false),
        Card(text: "Ask the paper.", a: 9.7, b: 12.9, onPaper: true),
        Card(text: "Answers made from its own words.", a: 14.8, b: 17.75, onPaper: true),
        Card(text: "See which claims hold up.", a: 19.6, b: 22.9, onPaper: true),
        Card(text: "Draw how ideas connect.", a: 25.95, b: 28.75, onPaper: true),
        Card(text: "Change a number. See what follows.", a: 31.1, b: 34.4, onPaper: true),
    ]

    /// Slides between scenes on paper: the camera glides across one continuous sheet, centred on each cut.
    static let transitions: [Transition] = [
        Transition(at: 7.5, d: 0.9), Transition(at: 18.23, d: 0.8), Transition(at: 19.2, d: 0.8), Transition(at: 23.38, d: 0.9),
        Transition(at: 25.51, d: 0.9), Transition(at: 29.22, d: 0.85), Transition(at: 30.66, d: 0.85), Transition(at: 34.94, d: 1.0),
    ]

    static func slide(_ tr: Transition, t: Double, f: Int) -> CIImage {
        // The cut point is the segment boundary nearest the transition centre.
        let bi = segments.indices.min { abs(segments[$0].a - tr.at) < abs(segments[$1].a - tr.at) }!
        let a = segments[bi - 1], b = segments[bi]
        let p = clamp01((t - (tr.at - tr.d / 2)) / tr.d)
        let e = 0.5 - 0.5 * cos(.pi * p)                       // sine ease: a glide, not a whip
        let v = Double(W) * .pi / 2 * sin(.pi * p) / (tr.d * Double(FPS))   // px per frame
        Paper.layerOnly = true
        // The outgoing scene is drawn a frame-width past its right edge, the incoming one a frame-width past its
        // left, so nothing is cut off at the old frame edges as they slide.
        Paper.viewport = CGRect(x: 0, y: 0, width: 2 * W, height: H)
        let la = a.render(t - a.a, f).transformed(by: .init(translationX: -CGFloat(e) * W, y: 0))
        Paper.viewport = CGRect(x: -W, y: 0, width: 2 * W, height: H)
        let lb = b.render(t - b.a, f).transformed(by: .init(translationX: CGFloat(1 - e) * W, y: 0))
        Paper.viewport = canvas
        Paper.layerOnly = false
        var content = lb.over(la)
        if v > 1 {
            content = content.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: min(34, v * 0.2), kCIInputAngleKey: 0])
                .cropped(to: canvas)
        }
        return addGrain(content.over(Paper.base), frame: f, size: 1.3, amount: 0.022).canvasCrop()
    }

    /// How scenes on paper meet: `glide` (slide across one sheet), `land` (a beat cut softened by a few frames
    /// of dissolve; the new scene settles with a small push-in), or `hard` (straight cuts). Set with CUT_STYLE.
    static let style = ProcessInfo.processInfo.environment["CUT_STYLE"] ?? "land"

    static func cut(t: Double, f: Int, current s: Segment) -> CIImage {
        if style == "glide", let tr = transitions.first(where: { abs(t - $0.at) < $0.d / 2 }) { return slide(tr, t: t, f: f) }
        let i = segments.firstIndex { $0.a == s.a }!
        // The cold open's last print, now lying on paper, gives way to the first page with a slow dissolve.
        let coldOpen = 7.4
        if style != "glide", t >= coldOpen - 0.15, t < coldOpen + 0.45 {
            let a = segments[3], b = segments[4]
            let k = smooth((t - (coldOpen - 0.15)) / 0.6)
            return b.render(t - b.a, f).opacity(k).over(a.render(t - a.a, f))
        }
        guard style == "land", i > 4, i < 12 else { return s.render(t - s.a, f) }   // paper scenes only
        // Dissolve: 3 frames before the beat to 6 after.
        let local = t - s.a
        var img = s.render(local, f)
        if local < 0.1 {
            let prev = segments[i - 1]
            img = img.opacity(smooth((local + 0.05) / 0.15)).over(prev.render(t - prev.a, f))
        } else if let next = segments.indices.contains(i + 1) ? segments[i + 1] : nil, i + 1 < 12, next.a - t < 0.05 {
            img = next.render(t - next.a, f).camera(scale: 1.025).canvasCrop().opacity(smooth((0.05 - (next.a - t)) / 0.15)).over(img)
        }
        // Landing: the new scene arrives 2.5% large and settles, like a camera finding its mark.
        if local >= 0, local < 0.8 {
            let k = 1 + 0.025 * (1 - easeOut(local / 0.8))
            let incoming = s.render(local, f).camera(scale: k).canvasCrop()
            img = local < 0.1 ? img : incoming
            if local < 0.1 {
                let prev = segments[i - 1]
                img = incoming.opacity(smooth((local + 0.05) / 0.15)).over(prev.render(t - prev.a, f))
            }
        }
        return img
    }

    static let blackCard = TypeStyle(size: 72, weight: 0.23, tracking: -0.005, color: [0.88, 0.88, 0.9, 1])
    static let paperCard = TypeStyle(size: 80, weight: 0.3, tracking: -0.012, color: [0.1, 0.1, 0.13, 1])

    static func frame(at t: Double, index f: Int) -> CIImage {
        guard let s = segments.last(where: { t >= $0.a - 1e-9 }) else { return black }
        var img: CIImage
        img = cut(t: t, f: f, current: s)
        for c in cards where t >= c.a && t <= c.b {
            if c.onPaper {
                // A wash of paper under the line, so it never sits on top of the drawing.
                let o = window(t, c.a - 0.1, c.b + 0.1, fin: 0.4, fout: 0.4)
                let pc = Paper.color
                let wash = CIFilter(name: "CILinearGradient", parameters: [
                    "inputPoint0": CIVector(x: 0, y: 60), "inputPoint1": CIVector(x: 0, y: 470),
                    "inputColor0": CIColor(red: pc.r * 0.97, green: pc.g * 0.97, blue: pc.b * 0.97, alpha: 0.94),
                    "inputColor1": CIColor(red: pc.r, green: pc.g, blue: pc.b, alpha: 0)])!.outputImage!.cropped(to: canvas)
                img = wash.opacity(o).over(img)
            }
            if let ti = typeCard(c.text, c.onPaper ? paperCard : blackCard, at: CGPoint(x: W / 2, y: c.y), t: t, a: c.a, b: c.b, fin: 0.55, fout: 0.35) {
                img = ti.over(img)
            }
        }
        return img.canvasCrop()
    }

    /// The drawings on screen, with when their scenes start and end (film time), for the pen sounds.
    static var drawings: [(offset: Double, until: Double, d: Drawing)] {
        [(7.4, 18.23, Scenes.ask.d), (19.2, 23.38, Scenes.claims), (25.51, 29.22, Scenes.links),
         (30.66, 34.94, Scenes.whatIf), (34.94, 52.68, Scenes.web.d)]
    }

    static func exportEvents(_ path: String) {
        var rows: [String] = []
        for (off, until, d) in drawings {
            for s in d.strokes where s.start >= 0 && off + s.start < until {
                let kind: String
                switch s.kind { case .pen: kind = "pen"; case .marker: kind = "marker"; case .dashed: kind = "dashed"; case .ribbon: kind = "ribbon" }
                rows.append(String(format: "{\"t\":%.4f,\"d\":%.4f,\"w\":%.2f,\"len\":%.1f,\"kind\":\"%@\",\"web\":%@}",
                                   off + s.start, min(s.duration, until - off - s.start), s.width, s.total, kind, off == 34.94 ? "true" : "false"))
            }
        }
        for (off, until, d) in drawings { for p in d.prints where off + p.start < until {
            rows.append(String(format: "{\"t\":%.4f,\"d\":0.3,\"w\":0,\"len\":0,\"kind\":\"print\",\"web\":%@}", off + p.start, off == 34.94 ? "true" : "false")) } }
        try! ("[" + rows.joined(separator: ",\n") + "]").write(toFile: path, atomically: true, encoding: .utf8)
        print("wrote \(rows.count) events to \(path)")
    }

    static func renderFilm(to path: String, from: Double, to: Double) {
        let w = MovieWriter(path)
        let n0 = Int(from * Double(FPS)), n1 = Int(min(to, length) * Double(FPS))
        let started = Date()
        for i in n0..<n1 {
            autoreleasepool { w.append(frame(at: Double(i) / Double(FPS), index: i)) }
            if i % 120 == 0 { print(String(format: "frame %d / %d  (%.1fs elapsed)", i, n1, Date().timeIntervalSince(started))) }
        }
        w.finish()
        print("wrote \(path)")
    }
}
