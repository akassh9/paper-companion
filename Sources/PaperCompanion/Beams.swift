import SwiftUI

/// One beam: a thin line of the source's color from a highlighted span on the page to its quote slip.
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
        guard let version = model.openThread?.current else { return [] }
        let g = model.geometry
        guard g.pdfFrame.width > 0 else { return [] }
        var result: [Beam] = []

        for block in version.quoteBlocks {
            guard let sid = model.sourceID(for: block),
                  let local = g.sourceRects[sid],
                  let edge = g.sourcePageEdge[sid],
                  let slip = g.slipFrames[block.id]
            else { continue }

            // Skip quotes scrolled out of the answer sheet; their highlight in the paper still shows.
            let vp = g.sheetViewport
            if vp.height > 0, slip.maxY < vp.minY + 12 || slip.minY > vp.maxY - 12 { continue }

            // Source: the page's right edge, at the height of the highlighted lines.
            let lineHeight = min(max(local.height, 6), 12)
            var sy = g.pdfFrame.minY + local.midY
            let top = g.pdfFrame.minY + 10, bottom = g.pdfFrame.maxY - 10
            var offscreen = false
            if sy < top { sy = top; offscreen = true }
            if sy > bottom { sy = bottom; offscreen = true }
            let sx = min(g.pdfFrame.minX + edge, g.pdfFrame.maxX)

            // Target: the slip's left edge, at its middle, clamped to what's visible.
            var ty = slip.midY
            if vp.height > 0 { ty = min(max(ty, vp.minY + 16), vp.maxY - 16) }

            result.append(Beam(
                id: block.id, sourceID: sid, color: SourcePalette.color(block.colorIndex ?? 0),
                start: CGPoint(x: sx, y: sy), end: CGPoint(x: slip.minX, y: ty),
                startThickness: lineHeight, endThickness: lineHeight, sourceOffscreen: offscreen))
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

    /// The beam's shape: a thin ribbon whose edges ease out of each end horizontally.
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
        let beams = BeamLayout.beams(model: model)
        let hovered = model.geometry.hoveredSource
        Canvas { ctx, _ in
            // Quiet beams first, the hovered one last so it sits on top.
            let ordered = beams.sorted { ($0.sourceID == hovered ? 1 : 0) < ($1.sourceID == hovered ? 1 : 0) }
            for beam in ordered {
                let strength: Double = hovered == nil ? 0.35 : (beam.sourceID == hovered ? 1.0 : 0.15)
                let length = max(1, beam.end.x - beam.start.x)
                let fadeIn = beam.sourceOffscreen ? 0.55 : min(0.4, 20 / length)
                let stops: [Gradient.Stop] = [
                    .init(color: beam.color.opacity(0), location: 0),
                    .init(color: beam.color.opacity(0.8 * strength * (beam.sourceOffscreen ? 0.5 : 1)), location: fadeIn),
                    .init(color: beam.color.opacity(0.65 * strength), location: max(fadeIn, 0.55)),
                    .init(color: beam.color.opacity(0.9 * strength), location: 1),
                ]
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(stops: stops),
                    startPoint: CGPoint(x: beam.start.x, y: 0), endPoint: CGPoint(x: beam.end.x, y: 0))
                let path = BeamLayout.ribbon(beam)
                if beam.sourceID == hovered {
                    var glow = ctx
                    glow.addFilter(.blur(radius: 8))
                    glow.opacity = 0.5
                    glow.fill(path, with: shading)
                }
                ctx.fill(path, with: shading)
            }
        }
        .allowsHitTesting(false)
        .animation(.smooth(duration: 0.2), value: hovered)
    }
}
