import SwiftUI

/// The parallel space: the paper on the left, the composed answer on the right, beams between them.
struct SpaceView: View {
    @Bindable var model: AppModel

    var body: some View {
        GeometryReader { geo in
            let sheetWidth: CGFloat = min(540, max(420, geo.size.width * 0.34))
            let pdfWidth: CGFloat = min(820, max(520, geo.size.width - sheetWidth - 64 - 64 - 160))

            ZStack(alignment: .topLeading) {
                SpaceBackdrop(backdrop: model.backdrop)
                // A faint strip along the top, so the window can still be dragged.
                Color.primary.opacity(0.01)
                    .frame(height: 40)
                    .gesture(WindowDragGesture())

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

                    // Earlier versions of the answer, stacked behind it as their own sheets.
                    if let thread = model.openThread {
                        HStack {
                            Spacer()
                            VersionStack(count: thread.versions.count).frame(width: sheetWidth)
                        }
                        .padding(.top, 40)
                        .padding(.bottom, 100)
                        .padding(.trailing, 40)
                    }

                    // Everything the AI makes is Liquid Glass, grouped so the shapes render together.
                    GlassEffectContainer(spacing: 24) {
                        ZStack(alignment: .topLeading) {
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
                        }
                    }

                    // Beams sit above the glass, so each one reaches its white slip of paper.
                    BeamRibbons(model: model)
                } else {
                    WelcomeView(model: model)
                }
            }
            .coordinateSpace(.named("space"))
        }
        .ignoresSafeArea()
        .background(TransparentWindow(hasShadow: model.backdrop != .clear))
        .containerBackground(.clear, for: .window)
        .preferredColorScheme(model.backdrop == .dimmed ? .dark : nil)
        .sheet(isPresented: $model.showKeySheet) { APIKeySheet(model: model) }
    }
}

/// The window's own background. Frosted: the desktop, blurred behind the window, with a light dim.
/// Dimmed: the same blur under a deep blue-black wash, like the Figma "space". Clear: nothing.
struct SpaceBackdrop: View {
    let backdrop: Backdrop
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            if backdrop != .clear {
                BehindWindowBlur()
                switch backdrop {
                case .frosted:
                    Color.black.opacity(scheme == .dark ? 0.25 : 0.05)
                case .dimmed:
                    LinearGradient(colors: [Color(red: 0.04, green: 0.06, blue: 0.13).opacity(0.78),
                                            Color(red: 0.07, green: 0.06, blue: 0.14).opacity(0.70)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                case .clear:
                    EmptyView()
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// A behind-window blur, the way standard macOS windows get their frosted, desktop-tinted background.
struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.material = .underWindowBackground
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = 16
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Makes the hosting NSWindow transparent, so Liquid Glass samples the desktop and other windows.
struct TransparentWindow: NSViewRepresentable {
    var hasShadow: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }
    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        if window.isOpaque {
            window.isOpaque = false
            window.backgroundColor = .clear
        }
        if window.hasShadow != hasShadow {
            window.hasShadow = hasShadow
            window.invalidateShadow()
        }
    }
}

/// Earlier versions of the answer: glass sheets peeking out above the current one.
struct VersionStack: View {
    let count: Int
    var body: some View {
        let behind = min(2, max(0, count - 1))
        ZStack(alignment: .top) {
            ForEach(0..<behind, id: \.self) { i in
                let depth = CGFloat(behind - i)
                Color.clear
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .opacity(0.55 + 0.2 * Double(i))
                    .padding(.horizontal, 10 * depth)
                    .offset(y: -10 * depth)
            }
        }
        .allowsHitTesting(false)
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
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
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
            .foregroundStyle(.primary)

            Text("Answers here are built from the paper itself.")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.primary)
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
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(.primary)
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
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
                .foregroundStyle(.primary)
            Text("Read a paper with Claude")
                .font(.system(size: 26, weight: .bold))
            Text("Open a PDF, select a passage, and ask about it.\nAnswers are composed from the paper's own words.")
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
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
