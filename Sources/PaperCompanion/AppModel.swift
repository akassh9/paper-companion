import Foundation
import PDFKit
import SwiftUI
import Observation

/// What the reader has selected in the PDF right now.
struct LiveSelection: Equatable {
    var span: SpanRef
    var text: String
}

/// A span to highlight in the PDF.
struct HighlightSpec: Equatable {
    var id: UUID           // quote block id or passage id
    var span: SpanRef
    var colorIndex: Int
    var muted: Bool        // other threads' passages: a faint gray hint
}

/// Positions of things in the shared "space" coordinate system, used to draw beams.
@Observable
final class SpaceGeometry {
    /// Highlighted spans in the PDF view, in the PDF view's own top-left coordinates.
    var sourceRects: [UUID: CGRect] = [:]
    /// The right edge of each span's page, in the PDF view's coordinates.
    var sourcePageEdge: [UUID: CGFloat] = [:]
    /// Frame of the PDF view in space coordinates.
    var pdfFrame: CGRect = .zero
    /// Frames of quote slips in space coordinates.
    var slipFrames: [UUID: CGRect] = [:]
    /// The visible part of the answer sheet in space coordinates.
    var sheetViewport: CGRect = .zero
    /// The highlight whose beam is emphasized (the pointer is over its quote or its span in the paper).
    var hoveredSource: UUID?
}

@MainActor
@Observable
final class AppModel {
    // Document
    var document: PDFDocument?
    var documentURL: URL?
    var index: PaperIndex?
    private var archiveKey: String?

    // Threads
    var threads: [PaperThread] = []
    var openThreadID: UUID?

    // Interaction
    var selection: LiveSelection?
    var question = ""
    var mode: ComposeMode = .compose
    var isComposing = false
    var composingProgress = 0
    var composingQuestion = ""
    var errorMessage: String?
    var showKeySheet = false
    var showThreadList = false
    /// View ▸ Backdrop. Frosted (default) blurs the desktop behind the window; Dimmed is the darker
    /// "space" from the Figma design; Clear shows the desktop as it is.
    var backdrop = Backdrop(rawValue: UserDefaults.standard.string(forKey: "backdrop") ?? "") ?? .frosted {
        didSet { UserDefaults.standard.set(backdrop.rawValue, forKey: "backdrop") }
    }

    let geometry = SpaceGeometry()
    let pdf = PDFController()

    init() {
        pdf.model = self
        // Test flag: `--backdrop frosted|dimmed|clear`.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--backdrop"), args.indices.contains(i + 1),
           let b = Backdrop(rawValue: args[i + 1]) {
            backdrop = b
        }
    }

    var openThread: PaperThread? { threads.first { $0.id == openThreadID } }

    var paperFontName: String { index?.bodyFontName ?? "Times New Roman" }

    // MARK: Opening

    func open(url: URL) {
        guard let data = try? Data(contentsOf: url), let doc = PDFDocument(data: data) else {
            errorMessage = "Couldn't open \(url.lastPathComponent) as a PDF."
            return
        }
        document = doc
        documentURL = url
        index = PaperIndex(document: doc, fallbackTitle: url.deletingPathExtension().lastPathComponent)
        let key = ThreadStore.key(for: data)
        archiveKey = key
        let archive = ThreadStore.load(key: key)
        threads = archive?.threads ?? []
        openThreadID = archive?.openThreadID ?? threads.last?.id
        selection = nil
        self.question = ""
        geometry.sourceRects = [:]
        geometry.slipFrames = [:]
        UserDefaults.standard.set(url.path, forKey: "lastPDF")
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        updateDefaultMode()
    }

    func openSample() {
        if let url = Bundle.main.url(forResource: "sparse-routing-attention", withExtension: "pdf") {
            open(url: url)
        }
    }

    func reopenLast() {
        if let path = UserDefaults.standard.string(forKey: "lastPDF"), FileManager.default.fileExists(atPath: path) {
            open(url: URL(fileURLWithPath: path))
        }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url: url) }
    }

    /// Off in demo mode, so layout tests never touch saved threads.
    var persistenceEnabled = true

    private func save() {
        guard persistenceEnabled, let key = archiveKey, let url = documentURL else { return }
        ThreadStore.save(PaperArchive(pdfPath: url.path, threads: threads, openThreadID: openThreadID), key: key)
    }

    // MARK: Threads

    func select(thread id: UUID?) {
        openThreadID = id
        geometry.slipFrames = [:]
        updateDefaultMode()
        save()
    }

    func showVersion(_ delta: Int) {
        guard let i = threads.firstIndex(where: { $0.id == openThreadID }) else { return }
        let n = threads[i].versions.count
        threads[i].currentVersion = min(max(0, threads[i].currentVersion + delta), n - 1)
        geometry.slipFrames = [:]
        save()
    }

    func deleteOpenThread() {
        threads.removeAll { $0.id == openThreadID }
        openThreadID = threads.last?.id
        updateDefaultMode()
        save()
    }

    func selectionChanged(_ sel: LiveSelection?) {
        selection = sel
        updateDefaultMode()
    }

    /// Picks the mode that matches what the reader is doing, so the default is usually right.
    func updateDefaultMode() {
        if openThread == nil { mode = .compose; return }
        if selection != nil, mode == .extend || mode == .rewrite { mode = .compose }
        if selection == nil, mode == .compose || mode == .branch { mode = .extend }
    }

    func isAvailable(_ m: ComposeMode) -> Bool {
        switch m {
        case .compose: true
        case .extend, .rewrite: openThread != nil
        case .branch: openThread != nil && selection != nil
        }
    }

    // MARK: Highlights

    /// What to highlight in the PDF: the open answer's quotes and passages in color, other threads faintly.
    var highlightSpecs: [HighlightSpec] {
        var specs: [HighlightSpec] = []
        if let t = openThread {
            for p in t.passages {
                specs.append(HighlightSpec(id: p.id, span: p.span, colorIndex: p.colorIndex, muted: false))
            }
            if let v = t.current {
                for b in v.quoteBlocks {
                    guard let span = b.span else { continue }
                    if t.passages.contains(where: { $0.span == span }) { continue }
                    specs.append(HighlightSpec(id: b.id, span: span, colorIndex: b.colorIndex ?? 0, muted: false))
                }
            }
        }
        for t in threads where t.id != openThreadID {
            for p in t.passages {
                specs.append(HighlightSpec(id: p.id, span: p.span, colorIndex: 0, muted: true))
            }
        }
        return specs
    }

    /// For a quote block, which highlight id carries its beam (a quote of a passage reuses that passage's highlight).
    func sourceID(for block: AnswerBlock) -> UUID? {
        guard let span = block.span else { return nil }
        if let p = openThread?.passages.first(where: { $0.span == span }) { return p.id }
        return block.id
    }

    // MARK: Composing

    func send() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isComposing, let index else { return }
        guard let key = APIKeyStore.read() ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] else {
            showKeySheet = true
            return
        }
        guard isAvailable(mode) else { return }

        let mode = self.mode
        let existing = mode == .compose ? nil : openThread
        var passages = existing?.passages ?? []
        if let sel = selection, !passages.contains(where: { $0.span == sel.span }) {
            let used = Set(passages.map(\.colorIndex))
            let color = (0..<SourcePalette.rgb.count).first { !used.contains($0) } ?? passages.count
            passages.append(Passage(span: sel.span, text: sel.text, colorIndex: color))
        }

        isComposing = true
        composingProgress = 0
        composingQuestion = q
        errorMessage = nil

        let system = Prompts.system(paperTitle: index.title, paperText: index.promptText)
        let user = Prompts.user(mode: mode, question: q, passages: passages, thread: existing)
        let client = ClaudeClient(apiKey: key)

        Task {
            do {
                let doc = try await client.compose(system: system, user: user) { [weak self] n in
                    self?.composingProgress = n
                }
                finish(doc: doc, mode: mode, question: q, passages: passages, threadID: existing?.id)
            } catch let error as ClaudeError {
                if case .badKey = error { showKeySheet = true }
                errorMessage = error.localizedDescription
            } catch {
                errorMessage = "Couldn't reach Claude: \(error.localizedDescription)"
            }
            isComposing = false
        }
    }

    func finish(doc: AIDocument, mode: ComposeMode, question: String, passages: [Passage], threadID: UUID?) {
        guard let index else { return }
        // Claude keeps the reader's wording for the title, which is often all lowercase.
        var doc = doc
        doc.title = doc.title.prefix(1).uppercased() + doc.title.dropFirst()
        var colorsInUse = passages.map(\.colorIndex)
        var newBlocks: [AnswerBlock] = []

        if mode == .extend {
            newBlocks.append(AnswerBlock(kind: .heading, text: doc.title, subtitle: nil))
        }
        // Colors already used by quotes in the version being extended.
        let base = threadID.flatMap { id in threads.first { $0.id == id }?.current }
        if mode == .extend, let base {
            colorsInUse += base.quoteBlocks.compactMap(\.colorIndex)
        }
        var quoteColors: [SpanRef: Int] = [:]
        for b in base?.quoteBlocks ?? [] where mode == .extend {
            if let s = b.span, let c = b.colorIndex { quoteColors[s] = c }
        }

        for b in doc.normalizedBlocks {
            switch b.kind {
            case "prose":
                if let t = b.text, !t.isEmpty { newBlocks.append(AnswerBlock(kind: .prose, text: t)) }
            case "heading":
                newBlocks.append(AnswerBlock(kind: .heading, text: b.text ?? "", subtitle: b.subtitle?.isEmpty == false ? b.subtitle : nil))
            case "quote":
                guard let t = b.text, !t.isEmpty else { continue }
                let span = index.locate(t, preferredPage: b.page.map { $0 - 1 })
                var block = AnswerBlock(kind: .quote, text: t, location: b.location)
                if let span {
                    // The paper's own words for this span (Claude's copy may differ in tiny ways).
                    if let doc = document {
                        let paperText = index.text(of: span, in: doc)
                        if !paperText.isEmpty { block.text = paperText }
                    }
                    block.span = span
                    if let p = passages.first(where: { $0.span.overlaps(span) }) {
                        block.colorIndex = p.colorIndex
                        if p.span != span { block.span = span }
                    } else if let c = quoteColors.first(where: { $0.key.overlaps(span) })?.value {
                        block.colorIndex = c
                    } else {
                        let c = (0..<SourcePalette.rgb.count).first { !colorsInUse.contains($0) }
                            ?? (colorsInUse.count % SourcePalette.rgb.count)
                        colorsInUse.append(c)
                        quoteColors[span] = c
                        block.colorIndex = c
                    }
                    // A quote of exactly the selected passage shares its highlight.
                    if let p = passages.first(where: { $0.span.overlaps(span) }), p.span.range.length >= span.range.length / 2 {
                        block.span = p.span
                        block.text = p.text
                    }
                }
                newBlocks.append(block)
            case "instrument":
                guard let xs = b.chart?.x_values ?? b.x_values, let series = b.chart?.series ?? b.series,
                      !xs.isEmpty, !series.isEmpty else { continue }
                let clean = series.filter { $0.values.count == xs.count }
                guard !clean.isEmpty else { continue }
                let inst = Instrument(
                    xLabel: b.chart?.x_label ?? b.x_label ?? "",
                    xValues: xs,
                    series: clean.map { InstrumentSeries(name: $0.name, unit: $0.unit, values: $0.values) },
                    startIndex: min(max(0, b.chart?.start_index ?? b.start_index ?? 0), xs.count - 1)
                )
                newBlocks.append(AnswerBlock(kind: .instrument, instrument: inst))
            default:
                continue
            }
        }

        if let threadID, let i = threads.firstIndex(where: { $0.id == threadID }) {
            let old = threads[i].current
            let blocks = mode == .extend ? (old?.blocks ?? []) + newBlocks : newBlocks
            let title = mode == .extend ? (old?.title ?? doc.title) : (old?.title ?? doc.title)
            let version = AnswerVersion(question: question, mode: mode, title: mode == .rewrite ? doc.title : title, blocks: blocks)
            threads[i].passages = passages
            threads[i].versions.append(version)
            threads[i].currentVersion = threads[i].versions.count - 1
            openThreadID = threadID
        } else {
            let version = AnswerVersion(question: question, mode: .compose, title: doc.title, blocks: newBlocks)
            let thread = PaperThread(passages: passages, versions: [version], currentVersion: 0)
            threads.append(thread)
            openThreadID = thread.id
        }
        geometry.slipFrames = [:]
        self.question = ""
        selection = nil
        pdf.clearSelection()
        self.mode = .extend
        save()
    }

    // MARK: Dragging a passage into the answer

    /// The reader dropped text from the paper onto the answer: add it as a quote in a new version.
    func dropPassage(_ text: String) {
        guard let index, let i = threads.firstIndex(where: { $0.id == openThreadID }),
              let current = threads[i].current,
              let span = index.locate(text, preferredPage: selection?.span.page)
        else { return }
        let used = Set(threads[i].passages.map(\.colorIndex) + current.quoteBlocks.compactMap(\.colorIndex))
        let color = (0..<SourcePalette.rgb.count).first { !used.contains($0) } ?? used.count
        let paperText = document.map { index.text(of: span, in: $0) } ?? text
        let passage = Passage(span: span, text: paperText, colorIndex: color)
        let quote = AnswerBlock(kind: .quote, text: paperText, span: span,
                                location: "Added by you", colorIndex: color)
        var version = current
        version.id = UUID()
        version.blocks.append(quote)
        version.mode = .branch
        version.question = "Added a passage"
        version.createdAt = Date()
        threads[i].passages.append(passage)
        threads[i].versions.append(version)
        threads[i].currentVersion = threads[i].versions.count - 1
        selection = nil
        pdf.clearSelection()
        save()
    }

    func copyAnswerAsText() {
        guard let v = openThread?.current else { return }
        let text = "# \(v.title)\n\n" + Prompts.render(v)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
