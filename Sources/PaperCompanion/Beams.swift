import SwiftUI

/// One beam: a ribbon from a highlighted span in the paper to its quote in the answer.
struct BeamEnds: Identifiable {
    let id: UUID
    let color: Color
    var source: CGRect      // bead on the page edge, spanning the highlighted lines
    var target: CGRect      // bead on the slip's left edge, spanning the slip
    var opacity: Double
}

enum BeamLayout {
    static let beadWidth: CGFloat = 8

    /// Pairs each linked quote in the open answer with its source span, in space coordinates.
    @MainActor
    static func beams(model: AppModel) -> [BeamEnds] {
        guard let version = model.openThread?.current else { return [] }
        let g = model.geometry
        var result: [BeamEnds] = []
        var seenSources = Set<UUID>()
        for block in version.quoteBlocks {
            guard let sid = model.sourceID(for: block),
                  let local = g.sourceRects[sid],
                  let edge = g.sourcePageEdge[sid],
                  let slip = g.slipFrames[block.id],
                  g.pdfFrame.width > 0
            else { continue }

            // Source: on the page's right edge, as tall as the highlighted lines.
            var sTop = g.pdfFrame.minY + local.minY
            var sBottom = g.pdfFrame.minY + local.maxY
            var opacity = 1.0
            let pdfTop = g.pdfFrame.minY + 8, pdfBottom = g.pdfFrame.maxY - 8
            if sBottom < pdfTop { sTop = pdfTop; sBottom = pdfTop + 10; opacity *= 0.35 }
            else if sTop > pdfBottom { sBottom = pdfBottom; sTop = pdfBottom - 10; opacity *= 0.35 }
            else { sTop = max(sTop, pdfTop); sBottom = min(sBottom, pdfBottom) }
            let sx = min(g.pdfFrame.minX + edge, g.pdfFrame.maxX) - beadWidth / 2

            // Target: the slip's left edge, clamped to the visible part of the sheet.
            var tTop = slip.minY + 4, tBottom = slip.maxY - 4
            let vp = g.sheetViewport
            if vp.height > 0 {
                if tBottom < vp.minY { tTop = vp.minY; tBottom = vp.minY + 10; opacity *= 0.35 }
                else if tTop > vp.maxY { tBottom = vp.maxY; tTop = vp.maxY - 10; opacity *= 0.35 }
                else { tTop = max(tTop, vp.minY); tBottom = min(tBottom, vp.maxY) }
            }
            let tx = slip.minX - beadWidth / 2

            // A passage quoted twice gets one bead at the source.
            let sourceRect = CGRect(x: sx, y: sTop, width: beadWidth, height: max(10, sBottom - sTop))
            let targetRect = CGRect(x: tx, y: tTop, width: beadWidth, height: max(10, tBottom - tTop))
            seenSources.insert(sid)
            result.append(BeamEnds(id: block.id, color: SourcePalette.color(block.colorIndex ?? 0),
                                   source: sourceRect, target: targetRect, opacity: opacity))
        }
        return result
    }

    /// The ribbon shape between two beads: two cubic edges that ease out of each bead horizontally.
    static func ribbon(from s: CGRect, to t: CGRect) -> Path {
        let x0 = s.midX, x1 = t.midX
        let dx = (x1 - x0) * 0.55
        var p = Path()
        p.move(to: CGPoint(x: x0, y: s.minY))
        p.addCurve(to: CGPoint(x: x1, y: t.minY),
                   control1: CGPoint(x: x0 + dx, y: s.minY), control2: CGPoint(x: x1 - dx, y: t.minY))
        p.addLine(to: CGPoint(x: x1, y: t.maxY))
        p.addCurve(to: CGPoint(x: x0, y: s.maxY),
                   control1: CGPoint(x: x1 - dx, y: t.maxY), control2: CGPoint(x: x0 + dx, y: s.maxY))
        p.closeSubpath()
        return p
    }

    static func edge(from a: CGPoint, to b: CGPoint) -> Path {
        let dx = (b.x - a.x) * 0.55
        var p = Path()
        p.move(to: a)
        p.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y), control2: CGPoint(x: b.x - dx, y: b.y))
        return p
    }
}

/// Ribbons, drawn beneath the answer sheet so the glass softens them as they arrive.
struct BeamRibbons: View {
    let model: AppModel

    var body: some View {
        let beams = BeamLayout.beams(model: model)
        Canvas { ctx, _ in
            for beam in beams {
                let path = BeamLayout.ribbon(from: beam.source, to: beam.target)
                let start = CGPoint(x: beam.source.midX, y: 0), end = CGPoint(x: beam.target.midX, y: 0)
                let gradient = Gradient(stops: [
                    .init(color: beam.color.opacity(0.55 * beam.opacity), location: 0),
                    .init(color: beam.color.opacity(0.16 * beam.opacity), location: 0.5),
                    .init(color: beam.color.opacity(0.42 * beam.opacity), location: 1),
                ])
                // Glow
                var glow = ctx
                glow.addFilter(.blur(radius: 14))
                glow.fill(path, with: .linearGradient(gradient, startPoint: start, endPoint: end))
                // Ribbon
                ctx.fill(path, with: .linearGradient(gradient, startPoint: start, endPoint: end))
                // Hairline edges
                let edgeGradient = Gradient(colors: [beam.color.opacity(0.7 * beam.opacity), beam.color.opacity(0.25 * beam.opacity)])
                for (a, b) in [(CGPoint(x: beam.source.midX, y: beam.source.minY), CGPoint(x: beam.target.midX, y: beam.target.minY)),
                               (CGPoint(x: beam.source.midX, y: beam.source.maxY), CGPoint(x: beam.target.midX, y: beam.target.maxY))] {
                    ctx.stroke(BeamLayout.edge(from: a, to: b),
                               with: .linearGradient(edgeGradient, startPoint: start, endPoint: end), lineWidth: 0.75)
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.smooth(duration: 0.25), value: beams.map(\.source))
    }
}

/// Small glass beads at both ends of each beam, drawn above everything.
struct BeamBeads: View {
    let model: AppModel

    var body: some View {
        let beams = BeamLayout.beams(model: model)
        ZStack(alignment: .topLeading) {
            ForEach(beams) { beam in
                bead(beam.source, beam.color, beam.opacity)
                bead(beam.target, beam.color, beam.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func bead(_ r: CGRect, _ color: Color, _ opacity: Double) -> some View {
        Capsule()
            .fill(color.opacity(0.6))
            .frame(width: r.width, height: r.height)
            .glassEffect(.regular.tint(color.opacity(0.5)), in: Capsule())
            .shadow(color: color.opacity(0.5), radius: 4)
            .opacity(opacity)
            .offset(x: r.minX, y: r.minY)
    }
}

