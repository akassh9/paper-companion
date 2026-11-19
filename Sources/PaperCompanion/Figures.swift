import SwiftUI
import Charts

/// A chart Claude drew for the question. Points carry their labels; pointing at one reads it out.
/// Underneath, a line says where the numbers came from, and for computed figures, the code.
struct FigureView: View {
    let figure: FigureSpec
    @State private var hovered: Hovered?
    @State private var showCode = false

    struct Hovered: Equatable { var series: String; var point: FigureSpec.Point }

    static let colors: [Color] = [.blue, .orange, .teal, .pink, .purple, .green, .gray]

    private var categorical: Bool { !figure.xCategories.isEmpty }
    private var allPoints: [FigureSpec.Point] { figure.series.flatMap(\.points) }
    private var labelPoints: Bool { figure.series.filter { $0.style == .points }.map(\.points.count).reduce(0, +) <= 90 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            legend
            ZStack(alignment: .topLeading) {
                chart.frame(height: 260)
                readout
            }
            provenance
        }
        .padding(16)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.vertical, 4)
    }

    // MARK: Chart

    private var chart: some View {
        Chart {
            ForEach(Array(figure.series.enumerated()), id: \.offset) { si, series in
                ForEach(Array(sorted(series).enumerated()), id: \.offset) { _, p in
                    mark(series, p)
                }
            }
            if let hovered {
                RuleMark(x: .value(figure.xLabel, hovered.point.x))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartForegroundStyleScale(domain: figure.series.map(\.name),
                                   range: figure.series.indices.map { Self.colors[$0 % Self.colors.count] })
        .chartSymbolScale(domain: figure.series.map(\.name),
                          range: figure.series.indices.map { [BasicChartSymbolShape.circle, .triangle, .square, .diamond, .cross][$0 % 5] })
        .chartLegend(.hidden)
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(xText(v)) }
                }
                .foregroundStyle(Color.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel().foregroundStyle(Color.secondary)
            }
        }
        .chartXAxisLabel(figure.xLabel, alignment: .center)
        .chartYAxisLabel(position: .top, alignment: .leading, spacing: 8) {
            Text(figure.yLabel).lineLimit(1)
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): hovered = nearest(to: location, proxy: proxy, geo: geo)
                        case .ended: hovered = nil
                        }
                    }
            }
        }
    }

    @ChartContentBuilder
    private func mark(_ series: FigureSpec.Series, _ p: FigureSpec.Point) -> some ChartContent {
        let name = series.name
        let isHovered = hovered?.series == name && hovered?.point == p
        switch series.style {
        case .points:
            PointMark(x: .value(figure.xLabel, p.x), y: .value(figure.yLabel, p.y))
                .foregroundStyle(by: .value("Series", name))
                .symbol(by: .value("Series", name))
                .symbolSize(isHovered ? 90 : 34)
                .annotation(position: .top, spacing: 1) {
                    if labelPoints, !p.label.isEmpty {
                        Text(p.label).font(.system(size: 7.5, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
        case .line, .dashed:
            LineMark(x: .value(figure.xLabel, p.x), y: .value(figure.yLabel, p.y), series: .value("Series", name))
                .foregroundStyle(by: .value("Series", name))
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: series.style == .dashed ? [5, 4] : []))
        case .bars:
            BarMark(x: .value(figure.xLabel, p.x), y: .value(figure.yLabel, p.y), width: .fixed(18))
                .foregroundStyle(by: .value("Series", name))
                .cornerRadius(3)
        }
    }

    private func sorted(_ series: FigureSpec.Series) -> [FigureSpec.Point] {
        series.style == .line || series.style == .dashed ? series.points.sorted { $0.x < $1.x } : series.points
    }

    private var xDomain: ClosedRange<Double> {
        if categorical { return -0.6...Double(figure.xCategories.count) - 0.4 }
        return padded(allPoints.map(\.x))
    }

    private var yDomain: ClosedRange<Double> {
        var ys = allPoints.map(\.y)
        if figure.series.contains(where: { $0.style == .bars }) { ys.append(0) }
        return padded(ys)
    }

    private func padded(_ values: [Double]) -> ClosedRange<Double> {
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let pad = hi > lo ? (hi - lo) * 0.07 : max(abs(hi) * 0.1, 1)
        return (lo - pad)...(hi + pad)
    }

    private func xText(_ v: Double) -> String {
        if categorical {
            let i = Int(v.rounded())
            return abs(v - Double(i)) < 0.01 && figure.xCategories.indices.contains(i) ? figure.xCategories[i] : ""
        }
        return Self.format(v)
    }

    private func nearest(to location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> Hovered? {
        guard let plot = proxy.plotFrame else { return nil }
        let origin = geo[plot].origin
        var best: (Hovered, CGFloat)?
        for series in figure.series {
            for p in series.points {
                guard let px = proxy.position(forX: p.x), let py = proxy.position(forY: p.y) else { continue }
                let d = hypot(px + origin.x - location.x, py + origin.y - location.y)
                if d < (best?.1 ?? 28) { best = (Hovered(series: series.name, point: p), d) }
            }
        }
        return best?.0
    }

    // MARK: Around the chart

    private var legend: some View {
        FlowLayout(spacing: 14, lineSpacing: 5) {
            ForEach(Array(figure.series.enumerated()), id: \.offset) { i, s in
                HStack(spacing: 5) {
                    swatch(s.style, Self.colors[i % Self.colors.count], symbol: i)
                    Text(s.name).lineLimit(1)
                }
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func swatch(_ style: FigureSpec.Series.Style, _ color: Color, symbol: Int) -> some View {
        switch style {
        case .points:
            Image(systemName: ["circle.fill", "triangle.fill", "square.fill", "diamond.fill", "plus"][symbol % 5])
                .font(.system(size: 7)).foregroundStyle(color)
        case .line, .dashed:
            Path { p in p.move(to: CGPoint(x: 0, y: 1)); p.addLine(to: CGPoint(x: 14, y: 1)) }
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: style == .dashed ? [3, 2.5] : []))
                .frame(width: 14, height: 2)
        case .bars:
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
        }
    }

    @ViewBuilder
    private var readout: some View {
        if let hovered {
            HStack(spacing: 6) {
                if !hovered.point.label.isEmpty { Text(hovered.point.label).fontWeight(.semibold) }
                Text("\(xText(hovered.point.x)), \(Self.format(hovered.point.y))").monospacedDigit()
                Text(hovered.series).foregroundStyle(.secondary)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .padding(.leading, 40)
            .allowsHitTesting(false)
        }
    }

    private var provenance: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: figure.basis == .paper ? "doc.text" : figure.basis == .computed ? "function" : "eye")
                Text(provenanceText)
                if figure.code != nil {
                    Button(showCode ? "Hide code" : "Show code") { withAnimation(.snappy) { showCode.toggle() } }
                        .buttonStyle(.link)
                        .padding(.leading, 4)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)

            if showCode, let code = figure.code {
                ScrollView(.horizontal) {
                    Text(code)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.8))
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(10)
                }
                .frame(maxHeight: 220)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private var provenanceText: String {
        let source = figure.source.isEmpty ? "the paper" : figure.source
        switch figure.basis {
        case .paper: return "From \(source)"
        case .computed: return "Worked out by Claude from \(source)"
        case .readOffFigure: return "Read approximately off \(source)"
        }
    }

    /// Up to three significant decimals, no trailing zeros: 0.48, -1.21, 7.29, 1470.
    static func format(_ v: Double) -> String {
        if abs(v) >= 1000 { return String(format: "%.0f", v) }
        var s = String(format: abs(v) >= 100 ? "%.1f" : "%.3f", v)
        while s.contains("."), s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }
}

/// Lays children out left to right, wrapping onto new lines, so long legend entries never get cut off.
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].items.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].items.isEmpty {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + lineSpacing))
            }
            var row = rows[rows.count - 1]
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
