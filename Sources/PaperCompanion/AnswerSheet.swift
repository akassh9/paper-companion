import SwiftUI
import Charts

/// The AI's composed answer: a Liquid Glass sheet. Quotes inside it are paper.
struct AnswerSheet: View {
    @Bindable var model: AppModel
    let thread: PaperThread
    @State private var dropTargeted = false

    var body: some View {
        let version = thread.current
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                header(version)
                    .padding(.horizontal, 30)
                    .padding(.top, 22)
                    .padding(.bottom, 10)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let version {
                            Text(version.title)
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 4)
                            ForEach(version.blocks) { block in
                                BlockView(model: model, block: block)
                            }
                        }
                        if model.isComposing, model.openThreadID == thread.id {
                            ComposingRow(model: model)
                        }
                        if dropTargeted {
                            Capsule().fill(Color.accentColor).frame(height: 2).padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.top, 6)
                    .padding(.bottom, 30)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("space")) } action: {
                    model.geometry.sheetViewport = $0
                }
            }
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let text = items.first else { return false }
            model.dropPassage(text)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    @ViewBuilder
    private func header(_ version: AnswerVersion?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
            Text("Answer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            if let version {
                let n = version.sourceCount
                Text(n == 1 ? "1 source" : "\(n) sources")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if thread.versions.count > 1 {
                HStack(spacing: 4) {
                    Button { model.showVersion(-1) } label: { Image(systemName: "chevron.left") }
                        .disabled(thread.currentVersion == 0)
                        .help("Earlier version")
                    Text("\(thread.currentVersion + 1) of \(thread.versions.count)")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button { model.showVersion(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(thread.currentVersion >= thread.versions.count - 1)
                        .help("Later version")
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.trailing, 10)
            }
            Group {
                Button { model.mode = .branch } label: { Image(systemName: "arrow.triangle.branch") }
                    .help("Branch: select another passage in the paper, then ask to add it to this answer")
                    .disabled(model.selection == nil)
                Button { model.copyAnswerAsText() } label: { Image(systemName: "square.and.arrow.up") }
                    .help("Copy this answer as text")
                Menu {
                    Button("Close Answer") { model.select(thread: nil) }
                    Divider()
                    Button("Delete Thread", role: .destructive) { model.deleteOpenThread() }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuIndicator(.hidden)
                    .menuStyle(.button)
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
        }
    }
}

/// One block of the answer.
struct BlockView: View {
    let model: AppModel
    let block: AnswerBlock

    var body: some View {
        switch block.kind {
        case .prose:
            Text(markdown(block.text))
                .font(.system(size: 15))
                .lineSpacing(3)
                .foregroundStyle(Color.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, 4)
        case .heading:
            VStack(alignment: .leading, spacing: 2) {
                Text(block.text)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                if let s = block.subtitle, !s.isEmpty {
                    Text(s).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 14)
        case .quote:
            QuoteSlip(model: model, block: block)
        case .instrument:
            if let inst = block.instrument { InstrumentView(instrument: inst) }
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

/// A transcluded passage: a slip of paper in the paper's own typeface, highlighted like its source.
struct QuoteSlip: View {
    let model: AppModel
    let block: AnswerBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(highlighted)
                .font(.custom(model.paperFontName, size: 16.5))
                .lineSpacing(5.5)
                .foregroundStyle(Color(white: 0.06))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                .onHover { inside in
                    guard let sid = model.sourceID(for: block) else { return }
                    if inside { model.geometry.hoveredSource = sid }
                    else if model.geometry.hoveredSource == sid { model.geometry.hoveredSource = nil }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("space")) } action: {
                    model.geometry.slipFrames[block.id] = $0
                }

            sourceLine
        }
        .padding(.vertical, 4)
    }

    private var highlighted: AttributedString {
        var s = AttributedString(block.text)
        if block.span != nil {
            s.backgroundColor = SourcePalette.color(block.colorIndex ?? 0).opacity(0.3)
        }
        return s
    }

    @ViewBuilder
    private var sourceLine: some View {
        if let span = block.span {
            Button {
                model.pdf.reveal(span)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.text")
                    Text(sourceLabel(span))
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show this passage in the paper")
        } else {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle")
                Text("Couldn't find this exact text in the paper")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
        }
    }

    private func sourceLabel(_ span: SpanRef) -> String {
        if let l = block.location, !l.isEmpty { return "Page \(span.page + 1) · \(l)" }
        return "Page \(span.page + 1)"
    }
}

/// While Claude writes.
struct ComposingRow: View {
    let model: AppModel
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.mode != .extend || model.openThread == nil {
                Text(model.composingQuestion)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.composingProgress == 0 ? "Reading the paper…" : "Composing from the paper…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 10)
    }
}

/// A small live chart Claude builds for the question. Drag the slider to move along x.
struct InstrumentView: View {
    let instrument: Instrument
    @State private var index: Double = 0
    @State private var didSet = false

    private static let seriesColors: [Color] = [
        Color(red: 1.0, green: 0.27, blue: 0.23), Color(red: 0.04, green: 0.52, blue: 1.0),
        Color(red: 0.2, green: 0.78, blue: 0.35), Color(red: 1.0, green: 0.62, blue: 0.04),
    ]

    var body: some View {
        let i = Int(index.rounded())
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                Chart {
                    ForEach(Array(instrument.series.enumerated()), id: \.offset) { si, series in
                        ForEach(Array(series.values.enumerated()), id: \.offset) { xi, v in
                            LineMark(x: .value(instrument.xLabel, instrument.xValues[xi]), y: .value(series.unit, v))
                                .foregroundStyle(by: .value("Series", series.name))
                                .interpolationMethod(.monotone)
                            PointMark(x: .value(instrument.xLabel, instrument.xValues[xi]), y: .value(series.unit, v))
                                .foregroundStyle(by: .value("Series", series.name))
                                .symbolSize(xi == i ? 60 : 14)
                        }
                    }
                    RuleMark(x: .value(instrument.xLabel, instrument.xValues[i]))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .chartForegroundStyleScale(domain: instrument.series.map(\.name),
                                           range: Array(Self.seriesColors.prefix(max(1, instrument.series.count))))
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks { _ in AxisValueLabel().foregroundStyle(Color.secondary) }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.1))
                        AxisValueLabel().foregroundStyle(Color.secondary)
                    }
                }
                .frame(height: 140)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(instrument.series.enumerated()), id: \.offset) { si, series in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(format(series.values[i]))
                                    .font(.system(size: 30, weight: .semibold))
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                                Text(series.unit).font(.system(size: 15, weight: .semibold)).opacity(0.7)
                            }
                            .foregroundStyle(Self.seriesColors[si % Self.seriesColors.count])
                            Text("\(series.name) at \(instrument.xValues[i])")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 112, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(instrument.xLabel).foregroundStyle(.secondary)
                    Spacer()
                    Text(instrument.xValues[i]).fontWeight(.semibold).foregroundStyle(.primary)
                }
                .font(.system(size: 13))
                Slider(value: $index.animation(.snappy), in: 0...Double(max(1, instrument.xValues.count - 1)), step: 1)
                    .disabled(instrument.xValues.count < 2)
                HStack {
                    ForEach(Array(instrument.xValues.enumerated()), id: \.offset) { xi, x in
                        Text(x).frame(maxWidth: .infinity, alignment: xi == 0 ? .leading : (xi == instrument.xValues.count - 1 ? .trailing : .center))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
        }
        .padding(17)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.vertical, 4)
        .onAppear {
            if !didSet { index = Double(instrument.startIndex); didSet = true }
        }
    }

    private func format(_ v: Double) -> String {
        if v.rounded() == v, abs(v) < 10_000 { return String(Int(v)) }
        return abs(v) >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }
}
