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
    struct RGB: Equatable { var r: Double; var g: Double; var b: Double }
    var id: UUID           // quote block id, passage id, or claim id
    var span: SpanRef
    var colorIndex: Int
    var muted: Bool        // other threads' passages: a faint gray hint
    var rgb: RGB? = nil    // a color outside the source palette (a claim's strength)
}

/// Positions of things in the shared "space" coordinate system, used to draw beams.
@Observable
final class SpaceGeometry {
    /// Highlighted spans in the PDF view, in the PDF view's own top-left coordinates.
    var sourceRects: [UUID: CGRect] = [:]
    /// The right edge of each span's page, in the PDF view's coordinates.
    var sourcePageEdge: [UUID: CGFloat] = [:]
    /// The page each span is on, in the PDF view's top-left coordinates.
    var sourcePageFrames: [UUID: CGRect] = [:]
    /// The first line of each span, where a link between passages lands.
    var sourceFirstLines: [UUID: CGRect] = [:]
    /// Frame of the PDF view in space coordinates.
    var pdfFrame: CGRect = .zero
    /// Frames of quote slips in space coordinates.
    var slipFrames: [UUID: CGRect] = [:]
    /// The visible part of the answer sheet in space coordinates.
    var sheetViewport: CGRect = .zero
    /// The highlight whose beam is emphasized (the pointer is over its quote or its span in the paper).
    var hoveredSource: UUID?
}

/// The app's motion, in one place. Reduce Motion (System Settings ▸ Accessibility) turns springs and
/// movement into short fades.
enum Motion {
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var mode: Animation { reduce ? .easeInOut(duration: 0.18) : .spring(duration: 0.42, bounce: 0.08) }
    static var dissolveSeconds: Double { reduce ? 0.15 : 0.26 }
    static var dissolve: Animation { .easeInOut(duration: dissolveSeconds) }
    static var hover: Animation { .easeOut(duration: reduce ? 0.08 : 0.16) }
    static var appear: Animation { reduce ? .easeOut(duration: 0.15) : .spring(duration: 0.32, bounce: 0.1) }
    /// Swapping what's inside the glass: the old content leaves fast, then the new fades in, so the two never
    /// sit on top of each other.
    static var swap: AnyTransition {
        .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.07)),
                    removal: .opacity.animation(.easeIn(duration: 0.07)))
    }
}

@MainActor
@Observable
final class AppModel {
    // Document
    var document: PDFDocument?
    var documentURL: URL?
    var index: PaperIndex?
    private(set) var archiveKey: String?

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
    /// What Claude is doing right now, in plain words ("Running Python", "Looking at page 15").
    var composingStep = ""
    var errorMessage: String?
    var showKeySheet = false

    // Claims map (idea F)
    var claims: ClaimsMap?
    var showingClaims = false
    var isMappingClaims = false
    var claimsStep = ""
    var claimsError: String?
    var claimsScope = "the abstract"

    // Links (idea E)
    var links: [PaperLink] = []
    var showingLinks = false
    var linkDraft: LinkDraft?
    /// The sentence under the pointer in Links mode: what a line drawn from here would connect.
    var linkHover: PaperLink.End?
    var hoveredLink: UUID?
    var placeBeforeLinks: PDFDestination?

    // What-if (idea G)
    var showingWhatIf = false
    var whatIf: WhatIf?
    /// The field over a selected number, before the new value is sent.
    var whatIfEditing: WhatIfEdit?
    /// Original / What-if: whether the estimated changes show on the paper.
    var whatIfShowsEdit = true
    var whatIfFocus: UUID?

    // Mode switches: a still of the paper as it was, dissolving into the new layout.
    struct PaperSnapshot { var image: NSImage; var frame: CGRect; var shown: CGRect; var faded = false }
    var paperSnapshot: PaperSnapshot?
    var paperHidden = false

    /// Switches mode the way a native app does: light things (the glass panel, the bars) spring to their new
    /// places; the paper, which is expensive to lay out, cross-dissolves from a still of its old layout.
    func switchMode(_ change: () -> Void) {
        let twoUpBefore = showingLinks || showingWhatIf
        if paperSnapshot == nil, let image = pdf.snapshot(), geometry.pdfFrame.width > 0 {
            paperSnapshot = PaperSnapshot(image: image, frame: geometry.pdfFrame, shown: geometry.pdfFrame)
            paperHidden = true
        }
        withAnimation(Motion.mode) { change() }
        // On the next pass, once the new layout (and the reader's place in it) has landed: dissolve.
        DispatchQueue.main.async { [weak self] in
            guard let self, let snap = self.paperSnapshot else { return }
            // When the paper only changes width, the still scales into the new layout so the two line up and
            // the page reads as one sheet shrinking or growing. Two-up pages can't line up: those just dissolve.
            let new = self.geometry.pdfFrame
            if twoUpBefore == (self.showingLinks || self.showingWhatIf), new.width > 0 {
                let k = new.width / snap.frame.width
                withAnimation(Motion.mode) {
                    self.paperSnapshot?.shown = CGRect(x: new.minX, y: new.minY, width: new.width, height: snap.frame.height * k)
                }
            }
            withAnimation(.easeIn(duration: Motion.dissolveSeconds * 0.7)) { self.paperSnapshot?.faded = true }
            withAnimation(Motion.dissolve) { self.paperHidden = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.dissolveSeconds + 0.05) { [weak self] in
                self?.paperSnapshot = nil
            }
        }
    }
    /// Where the reader was before the claims map narrowed the paper.
    private var placeBeforeClaims: PDFDestination?
    var showThreadList = false
    /// View ▸ Backdrop. Frosted (default) blurs the desktop behind the window; Dimmed is the darker
    /// "space" from the Figma design; Clear shows the desktop as it is.
    /// View ▸ Model. Haiku is quick and cheap; Sonnet is better when an answer needs code or a figure.
    var answerModel = AnswerModel(rawValue: UserDefaults.standard.string(forKey: "answerModel") ?? "") ?? .haiku {
        didSet { UserDefaults.standard.set(answerModel.rawValue, forKey: "answerModel") }
    }

    var backdrop = Backdrop(rawValue: UserDefaults.standard.string(forKey: "backdrop") ?? "") ?? .frosted {
        didSet { if !backdropFromTestFlag { UserDefaults.standard.set(backdrop.rawValue, forKey: "backdrop") } }
    }
    /// A `--backdrop` test flag only changes this window, never the reader's saved choice.
    @ObservationIgnored private var backdropFromTestFlag = false

    let geometry = SpaceGeometry()
    let pdf = PDFController()

    init() {
        pdf.model = self
        // Test flag: `--backdrop frosted|dimmed|clear`.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--backdrop"), args.indices.contains(i + 1),
           let b = Backdrop(rawValue: args[i + 1]) {
            backdropFromTestFlag = true
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
        claims = archive?.claims
        showingClaims = false
        links = archive?.links ?? []
        showingLinks = false
        linkDraft = nil
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

    func save() {
        guard persistenceEnabled, let key = archiveKey, let url = documentURL else { return }
        ThreadStore.save(PaperArchive(pdfPath: url.path, threads: threads, openThreadID: openThreadID, claims: claims, links: links), key: key)
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
        if showingWhatIf, let sel { beginWhatIf(sel) }
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
        // What-if shows the edited number and, unless comparing with the original, everything it moved.
        if showingWhatIf {
            if let e = whatIfEditing ?? whatIf?.edit {
                specs.append(HighlightSpec(id: e.id, span: e.span, colorIndex: 0, muted: false, rgb: WhatIfStyle.tealRGB))
            }
            if whatIfShowsEdit {
                for c in whatIf?.result?.changes ?? [] {
                    guard let span = c.span, !specs.contains(where: { $0.span == span }) else { continue }
                    specs.append(HighlightSpec(id: c.id, span: span, colorIndex: 0, muted: false, rgb: WhatIfStyle.tealRGB))
                }
            }
            return specs
        }
        // Links mode shows the links, the one being drawn, and the sentence under the pointer.
        if showingLinks {
            for l in links {
                specs.append(HighlightSpec(id: l.a.id, span: l.a.span, colorIndex: 0, muted: false, rgb: l.relation.rgb))
                specs.append(HighlightSpec(id: l.b.id, span: l.b.span, colorIndex: 0, muted: false, rgb: l.relation.rgb))
            }
            let drawing = HighlightSpec.RGB(r: 10, g: 132, b: 255)
            for end in [linkDraft?.a, linkDraft?.b].compactMap({ $0 }) where !specs.contains(where: { $0.span == end.span }) {
                specs.append(HighlightSpec(id: end.id, span: end.span, colorIndex: 0, muted: false, rgb: drawing))
            }
            // The sentence under the pointer: only a faint hint of what a line from here would join.
            if let h = linkHover, !specs.contains(where: { $0.span.overlaps(h.span) }) {
                specs.append(HighlightSpec(id: h.id, span: h.span, colorIndex: 0, muted: true))
            }
            return specs
        }
        // The claims map shows only its claims, in the color of their strength.
        if showingClaims {
            for c in (isMappingClaims ? [] : claims?.claims ?? []) {
                guard let span = c.span else { continue }
                specs.append(HighlightSpec(id: c.id, span: span, colorIndex: 0, muted: false, rgb: c.strength.rgb))
            }
            return specs
        }
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

    /// Sends the question. `given` passages (from a drawn link) start a new answer about exactly those.
    func send(passages given: [Passage]? = nil) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isComposing, let index else { return }
        guard let key = APIKeyStore.read() ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] else {
            showKeySheet = true
            return
        }
        guard isAvailable(mode) else { return }

        let mode = self.mode
        let existing = mode == .compose ? nil : openThread
        var passages = given ?? existing?.passages ?? []
        if given == nil, let sel = selection, !passages.contains(where: { $0.span == sel.span }) {
            let used = Set(passages.map(\.colorIndex))
            let color = (0..<SourcePalette.rgb.count).first { !used.contains($0) } ?? passages.count
            passages.append(Passage(span: sel.span, text: sel.text, colorIndex: color))
        }

        isComposing = true
        composingProgress = 0
        composingQuestion = q
        errorMessage = nil

        composingStep = ""
        let system = Prompts.system(paperTitle: index.title, paperText: index.promptText)
        let user = Prompts.user(mode: mode, question: q, passages: passages, thread: existing)
        guard let document, let paperKey = archiveKey else { return }
        let agent = PaperAgent(apiKey: key, model: answerModel.rawValue, document: document,
                               paperText: index.promptText, paperKey: paperKey)

        Task {
            do {
                let result = try await agent.run(system: system, user: user) { [weak self] step in
                    self?.composingStep = step
                }
                finishHTML(result.html, code: result.code, mode: mode, question: q, passages: passages,
                           threadID: existing?.id)
            } catch let error as ClaudeError {
                if case .badKey = error { showKeySheet = true }
                errorMessage = error.localizedDescription
            } catch {
                errorMessage = "Couldn't reach Claude: \(error.localizedDescription)"
            }
            isComposing = false
            composingStep = ""
        }
    }

    func finish(doc: AIDocument, mode: ComposeMode, question: String, passages: [Passage], threadID: UUID?,
                code: [String] = []) {
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
                guard let xs = b.x_values, let series = b.series, !xs.isEmpty, !series.isEmpty else { continue }
                let clean = series.filter { $0.values.count == xs.count }
                guard !clean.isEmpty else { continue }
                let inst = Instrument(
                    xLabel: b.x_label ?? "",
                    xValues: xs,
                    series: clean.map { InstrumentSeries(name: $0.name, unit: $0.unit, values: $0.values) },
                    startIndex: min(max(0, b.start_index ?? 0), xs.count - 1)
                )
                newBlocks.append(AnswerBlock(kind: .instrument, instrument: inst))
            case "figure":
                guard let f = b.figure else { continue }
                let series = f.series.compactMap { s -> FigureSpec.Series? in
                    let points = s.points.filter { $0.x.isFinite && $0.y.isFinite }
                    guard !points.isEmpty else { return nil }
                    return FigureSpec.Series(name: s.name, style: FigureSpec.Series.Style(rawValue: s.style) ?? .points,
                                             points: points.map { FigureSpec.Point(x: $0.x, y: $0.y, label: $0.label) })
                }
                guard !series.isEmpty else { continue }
                let basis = FigureSpec.Basis(rawValue: f.basis) ?? .computed
                let spec = FigureSpec(xLabel: f.x_label, yLabel: f.y_label, xCategories: f.x_categories, series: series,
                                      basis: basis, source: f.source,
                                      code: basis == .computed && !code.isEmpty ? code.joined(separator: "\n\n") : nil)
                newBlocks.append(AnswerBlock(kind: .figure, figure: spec))
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

    /// Stores an answer Claude wrote as HTML. Each <paper-quote> is checked against the PDF, replaced with
    /// the paper's exact words, and given a source color, so beams and highlights work as before.
    func finishHTML(_ raw: String, code: [String], mode: ComposeMode, question: String, passages: [Passage], threadID: UUID?) {
        guard let index else { return }
        let base = threadID.flatMap { id in threads.first { $0.id == id }?.current }
        var colorsInUse = passages.map(\.colorIndex)
        var quoteColors: [SpanRef: Int] = [:]
        if mode == .extend, let base {
            colorsInUse += base.quoteBlocks.compactMap(\.colorIndex)
            for b in base.quoteBlocks { if let s = b.span, let c = b.colorIndex { quoteColors[s] = c } }
        }

        // A quote is its own slip, so punctuation Claude put right after one would sit alone on a line.
        let raw = raw.replacingOccurrences(of: #"(</paper-quote\s*>)\s*[.,;:]"#, with: "$1", options: .regularExpression)
        var html = raw
        var quotes: [AnswerBlock] = []
        let tags = AnswerHTML.quoteTags(in: raw)
        for tag in tags {
            var block = AnswerBlock(kind: .quote, text: tag.text, location: tag.location)
            if let span = index.locate(tag.text, preferredPage: tag.page.map { $0 - 1 }) {
                if let document {
                    let paperText = index.text(of: span, in: document)
                    if !paperText.isEmpty { block.text = paperText }
                }
                block.span = span
                if let p = passages.first(where: { $0.span.overlaps(span) }) {
                    block.colorIndex = p.colorIndex
                } else if let c = quoteColors.first(where: { $0.key.overlaps(span) })?.value {
                    block.colorIndex = c
                } else {
                    let c = (0..<SourcePalette.rgb.count).first { !colorsInUse.contains($0) }
                        ?? (colorsInUse.count % SourcePalette.rgb.count)
                    colorsInUse.append(c)
                    quoteColors[span] = c
                    block.colorIndex = c
                }
            }
            quotes.append(block)
        }
        for (tag, block) in zip(tags, quotes).reversed() {
            html.replaceSubrange(tag.range, with: AnswerHTML.resolvedTag(block))
        }
        html += AnswerHTML.codeDisclosure(code)

        var title = AnswerHTML.title(of: html) ?? question
        title = title.prefix(1).uppercased() + title.dropFirst()

        if let threadID, let i = threads.firstIndex(where: { $0.id == threadID }) {
            let old = threads[i].current
            var version: AnswerVersion
            if mode == .extend, let old {
                let oldHTML = old.html ?? Self.html(fromBlocks: old)
                version = AnswerVersion(question: question, mode: mode, title: old.title,
                                        blocks: old.quoteBlocks + quotes,
                                        html: oldHTML + "\n<hr>\n" + AnswerHTML.demoteHeadings(html))
            } else {
                version = AnswerVersion(question: question, mode: mode, title: mode == .rewrite ? title : (old?.title ?? title),
                                        blocks: quotes, html: html)
            }
            threads[i].passages = passages
            threads[i].versions.append(version)
            threads[i].currentVersion = threads[i].versions.count - 1
            openThreadID = threadID
        } else {
            let version = AnswerVersion(question: question, mode: .compose, title: title, blocks: quotes, html: html)
            threads.append(PaperThread(passages: passages, versions: [version], currentVersion: 0))
            openThreadID = threads.last?.id
        }
        geometry.slipFrames = [:]
        self.question = ""
        selection = nil
        pdf.clearSelection()
        self.mode = .extend
        save()
    }

    /// An older block-based answer as HTML, so a follow-up can extend it in the new form.
    static func html(fromBlocks v: AnswerVersion) -> String {
        var out = "<h1>\(AnswerHTML.escape(v.title))</h1>\n"
        for b in v.blocks {
            switch b.kind {
            case .prose: out += "<p>\(AnswerHTML.escape(b.text))</p>\n"
            case .heading: out += "<h2>\(AnswerHTML.escape(b.text))</h2>\n"
            case .quote: out += AnswerHTML.resolvedTag(b) + "\n"
            case .instrument, .figure: out += "<p><em>(Chart from an earlier version of the app.)</em></p>\n"
            }
        }
        return out
    }

    // MARK: Claims map

    /// Shows the claims map: the saved one for the abstract, or a new one for the selected passage.
    func mapClaims(force: Bool = false) {
        guard let index, let document, let paperKey = archiveKey else { return }
        let sel = selection
        if showingLinks { closeLinks() }
        if showingWhatIf { closeWhatIf() }
        geometry.slipFrames = [:]
        geometry.hoveredSource = nil
        if !showingClaims { placeBeforeClaims = pdf.place }
        if isMappingClaims || (!force && sel == nil && claims != nil) {
            if !showingClaims { switchMode { showingClaims = true } }
            focusClaims()
            return
        }
        guard let key = APIKeyStore.read() ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] else {
            showKeySheet = true
            return
        }
        if !showingClaims { switchMode { showingClaims = true } }
        isMappingClaims = true
        claimsError = nil
        claimsStep = ""
        claimsScope = sel == nil ? "the abstract" : "this passage"
        let system = Prompts.system(paperTitle: index.title, paperText: index.promptText)
        let user = ClaimsPrompt.user(passage: sel?.text, page: sel?.span.page)
        let agent = PaperAgent(apiKey: key, model: answerModel.rawValue, document: document,
                               paperText: index.promptText, paperKey: paperKey)
        Task {
            do {
                let result = try await agent.run(system: system, user: user) { [weak self] step in
                    self?.claimsStep = step == "Composing the answer" ? "Writing the map" : step
                }
                var map = try ClaimsPrompt.parse(result.html)
                resolve(&map)
                withAnimation(Motion.appear) { claims = map }
                selection = nil
                pdf.clearSelection()
                save()
                focusClaims()
            } catch let error as ClaudeError {
                if case .badKey = error { showKeySheet = true }
                claimsError = error.localizedDescription
            } catch {
                claimsError = "Couldn't reach Claude: \(error.localizedDescription)"
            }
            isMappingClaims = false
            claimsStep = ""
        }
    }

    func closeClaims() {
        switchMode { showingClaims = false }
        geometry.slipFrames = [:]
        geometry.hoveredSource = nil
        if let place = placeBeforeClaims {
            pdf.hold(.place(place))
        }
        placeBeforeClaims = nil
    }

    /// Once the paper has narrowed, scrolls it to the first claim so the beams have somewhere to start.
    private func focusClaims() {
        guard showingClaims, let span = claims?.claims.first(where: { $0.span != nil })?.span else { return }
        pdf.hold(.span(span))
    }

    /// Finds each claim and piece of evidence in the PDF. Evidence shows the paper's exact words.
    private func resolve(_ map: inout ClaimsMap) {
        guard let index, let document else { return }
        for i in map.claims.indices {
            map.claims[i].span = index.locate(map.claims[i].quote, preferredPage: map.claims[i].page - 1)
            for j in map.claims[i].evidence.indices {
                let e = map.claims[i].evidence[j]
                if let span = index.locate(e.quote, preferredPage: e.page - 1) {
                    map.claims[i].evidence[j].span = span
                    let text = index.text(of: span, in: document)
                    if !text.isEmpty { map.claims[i].evidence[j].quote = text }
                }
            }
        }
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
        if let html = version.html { version.html = html + "\n" + AnswerHTML.resolvedTag(quote) }
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
        let text = v.html.map { AnswerHTML.plainText($0) } ?? ("# \(v.title)\n\n" + Prompts.render(v))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
