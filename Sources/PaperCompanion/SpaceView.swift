import SwiftUI

/// The parallel space: the paper on the left, the composed answer on the right, beams between them.
struct SpaceView: View {
    @Bindable var model: AppModel

    var body: some View {
        GeometryReader { geo in
            let sheetWidth: CGFloat = min(540, max(420, geo.size.width * 0.34))
            let pdfWidth: CGFloat = min(820, max(520, geo.size.width - sheetWidth - 64 - 64 - 160))

            ZStack(alignment: .topLeading) {
                SpaceBackground()

                if model.document != nil {
                    // Paper
                    PDFPane(model: model)
                        .frame(width: pdfWidth)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("space")) } action: {
                            model.geometry.pdfFrame = $0
                            model.pdf.layoutChanged()
                        }
                        .padding(.top, 64)
                        .padding(.bottom, 96)
                        .padding(.leading, 48)

                    // Beams pass beneath the glass sheet.
                    BeamRibbons(model: model)

                    // Answer (AI, glass)
                    HStack {
                        Spacer()
                        Group {
                            if let thread = model.openThread {
                                AnswerSheet(model: model, thread: thread)
                            } else {
                                GuideSheet(model: model)
                            }
                        }
                        .frame(width: sheetWidth)
                    }
                    .padding(.top, 40)
                    .padding(.bottom, 100)
                    .padding(.trailing, 40)

                    BeamBeads(model: model)

                    TopBar(model: model)
                        .padding(.top, 12)
                        .padding(.leading, 84)

                    VStack {
                        Spacer()
                        QuestionBar(model: model)
                            .frame(maxWidth: 820)
                            .padding(.bottom, 22)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    WelcomeView(model: model)
                }
            }
            .coordinateSpace(.named("space"))
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showKeySheet) { APIKeySheet(model: model) }
    }
}

/// A dark, softly lit space behind everything (stands in for a blurred wallpaper).
struct SpaceBackground: View {
    var body: some View {
        ZStack {
            MeshGradient(
                width: 3, height: 3,
                points: [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.55, 0.45], [1, 0.5], [0, 1], [0.5, 1], [1, 1]],
                colors: [
                    Color(red: 0.05, green: 0.08, blue: 0.16), Color(red: 0.08, green: 0.12, blue: 0.24), Color(red: 0.10, green: 0.10, blue: 0.20),
                    Color(red: 0.06, green: 0.14, blue: 0.26), Color(red: 0.14, green: 0.22, blue: 0.40), Color(red: 0.20, green: 0.14, blue: 0.28),
                    Color(red: 0.04, green: 0.07, blue: 0.13), Color(red: 0.07, green: 0.12, blue: 0.22), Color(red: 0.09, green: 0.08, blue: 0.16),
                ]
            )
            RadialGradient(colors: [.clear, .black.opacity(0.45)], center: .center, startRadius: 200, endRadius: 1200)
        }
        .ignoresSafeArea()
    }
}

/// Top-left: the paper's name and its threads.
struct TopBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                if model.threads.isEmpty {
                    Text("No threads yet")
                } else {
                    ForEach(model.threads.reversed()) { t in
                        Button {
                            model.select(thread: t.id)
                        } label: {
                            if t.id == model.openThreadID {
                                Label(t.title, systemImage: "checkmark")
                            } else {
                                Text(t.title)
                            }
                        }
                    }
                }
                Divider()
                Button("Open Another PDF…") { model.presentOpenPanel() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.on.square")
                        .font(.system(size: 13, weight: .medium))
                    Text(model.index?.title ?? "Paper")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: 320, alignment: .leading)
                    Text(model.threads.count == 1 ? "1 thread" : "\(model.threads.count) threads")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .glassEffect(.regular.interactive(), in: Capsule())
        }
    }
}

/// Shown in the answer's place before any thread is open: three plain steps.
struct GuideSheet: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text("Ask the paper").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.9))

            Text("Answers here are built from the paper itself.")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white.opacity(0.94))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 14) {
                step(1, "Select a passage in the paper.", "Drag across any sentence you're curious about.")
                step(2, "Type your question below.", "Press Return to send.")
                step(3, "Read the answer.", "Every quote is the paper's own words, joined to where it came from.")
            }
            if model.isComposing {
                ComposingRow(model: model)
            }
            if let error = model.errorMessage {
                Text(error).font(.system(size: 13)).foregroundStyle(.orange)
            }
            Spacer()
        }
        .padding(30)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular.tint(Color(red: 0.05, green: 0.06, blue: 0.09).opacity(0.35)),
                     in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                Text(detail).font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

/// First launch: open a PDF or try the sample.
struct WelcomeView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
            Text("Read a paper with Claude")
                .font(.system(size: 26, weight: .bold))
            Text("Open a PDF, select a passage, and ask about it.\nAnswers are composed from the paper's own words.")
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.6))
            HStack(spacing: 12) {
                Button("Open a PDF…") { model.presentOpenPanel() }
                    .buttonStyle(.glassProminent)
                Button("Try the Sample Paper") { model.openSample() }
                    .buttonStyle(.glass)
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
        .padding(44)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
