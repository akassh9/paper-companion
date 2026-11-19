import SwiftUI

/// One beam: a ribbon of the source's color from a highlighted span to its quote slip. It is as tall as
/// the highlighted lines where it leaves the paper and as tall as the slip where it arrives.
struct Beam: Identifiable {
    let id: UUID              // quote block id
    let sourceID: UUID        // highlight id (shared when a passage is quoted twice)
    let color: Color
    var start: CGPoint        // on the page's right edge, at the highlighted lines' middle
    var end: CGPoint          // on the slip's left edge
    var startThickness: CGFloat
    var endThickness: CGFloat
    var sourceOffscreen: Bool // the span is scrolled out of view: fade out toward the PDF's edge
    var curve: CGFloat = 0.5  // how far the control points reach (gentler when beams would cross)
}

enum BeamLayout {
    /// Pairs each linked quote in the open answer with its source span, in space coordinates.
    @MainActor
    static func beams(model: AppModel) -> [Beam] {
        // What to join: (target id in slipFrames, highlight id in sourceRects, color).
        var links: [(id: UUID, sid: UUID, color: Color)] = []
        if model.showingLinks || model.showingWhatIf { return [] }
        if model.showingClaims {
            guard !model.isMappingClaims else { return [] }
            links = (model.claims?.claims ?? []).filter { $0.span != nil }.map { ($0.id, $0.id, $0.strength.color) }
        } else if let version = model.openThread?.current {
            links = version.quoteBlocks.compactMap { b in
                model.sourceID(for: b).map { (b.id, $0, SourcePalette.color(b.colorIndex ?? 0)) }
            }
        }
        let g = model.geometry
        guard g.pdfFrame.width > 0 else { return [] }
        let vp = g.sheetViewport
        var result: [Beam] = []

        for link in links {
            let sid = link.sid
            guard let local = g.sourceRects[sid],
                  let edge = g.sourcePageEdge[sid],
                  let slip = g.slipFrames[link.id]
            else { continue }

            // Skip quotes scrolled out of the answer sheet; their highlight in the paper still shows.
            if vp.height > 0, slip.maxY < vp.minY + 12 || slip.minY > vp.maxY - 12 { continue }

            // Source: the page's right edge, at the height of the highlighted lines.
            var sy = g.pdfFrame.minY + local.midY
            let top = g.pdfFrame.minY + 10, bottom = g.pdfFrame.maxY - 10
            var offscreen = false
            if g.pdfFrame.minY + local.maxY < top + 4 { sy = top; offscreen = true }
            if g.pdfFrame.minY + local.minY > bottom - 4 { sy = bottom; offscreen = true }
            sy = min(max(sy, top), bottom)
            let sx = min(g.pdfFrame.minX + edge, g.pdfFrame.maxX)

            // Target: the slip's left edge, as tall as the part of the slip that is visible.
            var t0 = slip.minY, t1 = slip.maxY
            if vp.height > 0 { t0 = max(t0, vp.minY + 4); t1 = min(t1, vp.maxY - 4) }

            result.append(Beam(
                id: link.id, sourceID: sid, color: link.color,
                start: CGPoint(x: sx, y: sy), end: CGPoint(x: slip.minX, y: (t0 + t1) / 2),
                startThickness: offscreen ? 8 : min(max(local.height + 4, 8), 64),
                endThickness: max(12, t1 - t0), sourceOffscreen: offscreen))
        }

        untangle(&result)
        return result
    }

    /// Beams keep the answer's order, so some must cross. Two beams with the same S-curve cross in a
    /// long braid; giving the one that travels farther a gentler curve makes them cross once, cleanly.
    static func untangle(_ beams: inout [Beam]) {
        for i in beams.indices {
            for j in beams.indices where j > i {
                let a = beams[i], b = beams[j]
                let crosses = (a.start.y - b.start.y) * (a.end.y - b.end.y) < 0
                guard crosses else { continue }
                let aTravel = abs(a.end.y - a.start.y), bTravel = abs(b.end.y - b.start.y)
                if aTravel > bTravel { beams[i].curve = 0.3; beams[j].curve = max(beams[j].curve, 0.7) }
                else { beams[j].curve = 0.3; beams[i].curve = max(beams[i].curve, 0.7) }
            }
        }
    }

    /// The beam's shape: a ribbon whose edges ease out of each end horizontally.
    static func ribbon(_ b: Beam) -> Path {
        let dx = (b.end.x - b.start.x) * b.curve
        let s0 = CGPoint(x: b.start.x, y: b.start.y - b.startThickness / 2)
        let s1 = CGPoint(x: b.start.x, y: b.start.y + b.startThickness / 2)
        let t0 = CGPoint(x: b.end.x, y: b.end.y - b.endThickness / 2)
        let t1 = CGPoint(x: b.end.x, y: b.end.y + b.endThickness / 2)
        var p = Path()
        p.move(to: s0)
        p.addCurve(to: t0, control1: CGPoint(x: s0.x + dx, y: s0.y), control2: CGPoint(x: t0.x - dx, y: t0.y))
        p.addLine(to: t1)
        p.addCurve(to: s1, control1: CGPoint(x: t1.x - dx, y: t1.y), control2: CGPoint(x: s1.x + dx, y: s1.y))
        p.closeSubpath()
        return p
    }
}

/// Draws the beams. They sit above the glass so each one visibly reaches its white slip of paper.
struct BeamRibbons: View {
    let model: AppModel

    var body: some View {
        BeamCanvas(beams: BeamLayout.beams(model: model), hovered: model.geometry.hoveredSource)
            .allowsHitTesting(false)
    }
}

struct BeamCanvas: View {
    let beams: [Beam]
    let hovered: UUID?

    var body: some View {
        Canvas { ctx, _ in
            // Quiet beams first, the hovered one last so it sits on top.
            let ordered = beams.sorted { ($0.sourceID == hovered ? 1 : 0) < ($1.sourceID == hovered ? 1 : 0) }
            for beam in ordered {
                let strength: Double = hovered == nil ? 0.62 : (beam.sourceID == hovered ? 1.0 : 0.2)
                let stops: [Gradient.Stop]
                if beam.sourceOffscreen {
                    stops = [.init(color: beam.color.opacity(0), location: 0),
                             .init(color: beam.color.opacity(0.3 * strength), location: 0.55),
                             .init(color: beam.color.opacity(0.6 * strength), location: 1)]
                } else {
                    stops = [.init(color: beam.color.opacity(0.62 * strength), location: 0),
                             .init(color: beam.color.opacity(0.3 * strength), location: 0.5),
                             .init(color: beam.color.opacity(0.6 * strength), location: 1)]
                }
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(stops: stops),
                    startPoint: CGPoint(x: beam.start.x, y: 0), endPoint: CGPoint(x: beam.end.x, y: 0))
                let path = BeamLayout.ribbon(beam)

                // A soft glow under every beam, stronger on the one being pointed at.
                var glow = ctx
                glow.addFilter(.blur(radius: beam.sourceID == hovered ? 12 : 9))
                glow.opacity = beam.sourceID == hovered ? 0.6 : 0.35 * strength
                glow.fill(path, with: shading)
                ctx.fill(path, with: shading)

                // A tab on the paper's edge where the beam leaves it.
                if !beam.sourceOffscreen {
                    let h = max(beam.startThickness, 12)
                    let tab = Path(roundedRect: CGRect(x: beam.start.x - 3, y: beam.start.y - h / 2, width: 7, height: h),
                                   cornerRadius: 3.5, style: .continuous)
                    ctx.fill(tab, with: .color(beam.color.opacity(0.35 + 0.55 * strength)))
                    ctx.stroke(tab, with: .color(.white.opacity(0.35 * strength)), lineWidth: 0.75)
                }
            }
        }
        .animation(.smooth(duration: 0.2), value: hovered)
    }
}
