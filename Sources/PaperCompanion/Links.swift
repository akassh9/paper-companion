import SwiftUI
import PDFKit

// MARK: Model

/// Idea E: a link the reader drew between two passages. The line is the question; Claude names the
/// relationship, and once confirmed the link stays in the paper as a labelled ribbon.
struct PaperLink: Codable, Identifiable {
    struct End: Codable, Equatable {
        var id = UUID()            // highlight id
        var span: SpanRef
        var text: String
    }

    enum Relation: String, Codable, CaseIterable, Identifiable {
        case same = "same_as", supports, contradicts, defines, dependsOn = "depends_on"
        var id: String { rawValue }
    }

    var id = UUID()
    var a: End
    var b: End
    var relation: Relation
    var note: String               // Claude's reason, or empty if the reader chose without waiting
    var createdAt = Date()
}

extension PaperLink.Relation {
    var label: String {
        switch self {
        case .same: "Same as"; case .supports: "Supports"; case .contradicts: "Contradicts"
        case .defines: "Defines"; case .dependsOn: "Depends on"
        }
    }
    var symbol: String {
        switch self {
        case .same: "equal.circle.fill"; case .supports: "checkmark.circle.fill"
        case .contradicts: "exclamationmark.triangle.fill"; case .defines: "book.closed.fill"
        case .dependsOn: "arrow.turn.down.right"
        }
    }
    var rgb: HighlightSpec.RGB {
        switch self {
        case .same: .init(r: 48, g: 176, b: 199)
        case .supports: .init(r: 52, g: 199, b: 89)
        case .contradicts: .init(r: 255, g: 69, b: 58)
        case .defines: .init(r: 175, g: 82, b: 222)
        case .dependsOn: .init(r: 255, g: 149, b: 0)
        }
    }
    var color: Color { Color(red: rgb.r / 255, green: rgb.g / 255, blue: rgb.b / 255) }
    var key: KeyEquivalent { KeyEquivalent(Character("\((Self.allCases.firstIndex(of: self) ?? 0) + 1)")) }
    var keyLabel: String { "⌘\((Self.allCases.firstIndex(of: self) ?? 0) + 1)" }
}

/// A link being drawn, or drawn and waiting for the reader to say what it is.
struct LinkDraft {
    var a: PaperLink.End
    var b: PaperLink.End?
    var pointer: CGPoint?          // in space coordinates, while dragging
    var suggestion: (relation: PaperLink.Relation, why: String)?
    var isAsking = false
    var error: String?
    var question = ""
}

enum LinkPrompt {
    static func user(_ a: PaperLink.End, _ b: PaperLink.End) -> String {
        """
        <task>
        This request is not a question, and it is not answered as HTML. The reader drew a line between two \
        passages of the paper to ask how they relate.

        <passage_a page="\(a.span.page + 1)">\(a.text)</passage_a>
        <passage_b page="\(b.span.page + 1)">\(b.text)</passage_b>

        Choose the one relation that fits best:
        - "same_as": they state the same fact or number, perhaps in other words or units
        - "supports": one gives evidence for the other
        - "contradicts": they disagree, or sit in tension
        - "defines": one defines a term or quantity the other uses
        - "depends_on": one only holds if the other does

        Reply with only this JSON, nothing before or after it:
        {"relation": "...", "why": "One or two plain sentences that say which passage does what, naming the specific words or numbers that connect them."}
        </task>
        """
    }

    static func parse(_ text: String) -> (PaperLink.Relation, String)? {
        guard let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(text[s...e].utf8)) as? [String: Any],
              let r = (obj["relation"] as? String).flatMap(PaperLink.Relation.init(rawValue:))
        else { return nil }
        return (r, obj["why"] as? String ?? "")
    }
}

// MARK: Finding the passage under the pointer

extension PDFController {
    /// The sentence under a point in the PDF view, as a passage. PDF text breaks lines with newlines,
    /// which would end every "sentence" at a line end, so they're read as spaces (same length, same indices).
    func passage(at viewPoint: NSPoint) -> PaperLink.End? {
        guard let pdfView, let doc = pdfView.document,
              let page = pdfView.page(for: viewPoint, nearest: false), let raw = page.string else { return nil }
        let idx = page.characterIndex(at: pdfView.convert(viewPoint, to: page))
        let s = raw.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") as NSString
        guard idx >= 0, idx < s.length else { return nil }
        let window = NSRange(location: max(0, idx - 800), length: min(s.length, idx + 800) - max(0, idx - 800))
        var found: NSRange?
        s.enumerateSubstrings(in: window, options: [.bySentences, .substringNotRequired]) { _, r, _, stop in
            if NSLocationInRange(idx, r) { found = r; stop.pointee = true }
        }
        guard var r = found else { return nil }
        // Trim trailing spaces, and keep a runaway "sentence" (a table, a list) to a readable length.
        while r.length > 0, s.character(at: r.location + r.length - 1) == 32 { r.length -= 1 }
        if r.length > 420 { r = NSRange(location: max(r.location, idx - 200), length: 400) }
        guard r.length >= 8, let sel = page.selection(for: r), let text = sel.string else { return nil }
        let clean = PaperIndex.normalize(text).normalized as String
        return PaperLink.End(span: SpanRef(page: doc.index(for: page), location: r.location, length: r.length),
                             text: clean.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A point in the PDF view, in the shared space coordinates the overlays draw in.
    func spacePoint(_ p: NSPoint) -> CGPoint? {
        guard let pdfView, let model else { return nil }
        let y = pdfView.isFlipped ? p.y : pdfView.bounds.height - p.y
        return CGPoint(x: model.geometry.pdfFrame.minX + p.x, y: model.geometry.pdfFrame.minY + y)
    }

    // The draw-a-link gesture, while the paper is in Links mode.

    func linkMouseDown(_ event: NSEvent) -> Bool {
        guard let pdfView, let model, model.showingLinks else { return false }
        let p = pdfView.convert(event.locationInWindow, from: nil)
        guard let end = passage(at: p) else { model.linkDraft = nil; return true }
        model.linkDraft = LinkDraft(a: end, pointer: spacePoint(p))
        return true
    }

    func linkMouseDragged(_ event: NSEvent) {
        guard let pdfView, let model, model.linkDraft?.b == nil else { return }
        let p = pdfView.convert(event.locationInWindow, from: nil)
        model.linkDraft?.pointer = spacePoint(p)
        let under = passage(at: p)
        if model.linkHover?.span != under?.span { model.linkHover = under }
    }

    func linkMouseUp(_ event: NSEvent) {
        guard let pdfView, let model, var draft = model.linkDraft, draft.b == nil else { return }
        let p = pdfView.convert(event.locationInWindow, from: nil)
        model.linkHover = nil
        guard let end = passage(at: p), !end.span.overlaps(draft.a.span) else {
            model.linkDraft = nil      // a click, or a line that ends where it started
            return
        }
        draft.b = end
        draft.pointer = nil
        model.linkDraft = draft
        model.suggestRelation()
    }

    func linkHover(_ event: NSEvent) {
        guard let pdfView, let model, model.showingLinks, model.linkDraft == nil else { return }
        let under = passage(at: pdfView.convert(event.locationInWindow, from: nil))
        if model.linkHover?.span != under?.span { model.linkHover = under }
    }
}

// MARK: Drawing links

/// Everything Links mode draws over the paper: saved links as ribbons with their label, the line being
/// drawn, and the card that asks what a new link is.
struct LinkLayer: View {
    @Bindable var model: AppModel

    var body: some View {
        let g = model.geometry
        let saved = model.links.compactMap { link in
            LinkGeometry.ribbon(from: link.a.id, to: link.b.id, g: g).map { (link, $0) }
        }
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for (link, shape) in saved {
                    draw(shape, color: link.relation.color, strong: model.hoveredLink == link.id, in: &ctx)
                }
                if let draft = model.linkDraft {
                    if let b = draft.b, let shape = LinkGeometry.ribbon(from: draft.a.id, to: b.id, g: g) {
                        draw(shape, color: draft.suggestion?.relation.color ?? .white, strong: true, in: &ctx)
                    } else if let pointer = draft.pointer, let start = LinkGeometry.anchor(draft.a.id, toward: pointer, g: g) {
                        var p = Path()
                        p.move(to: start)
                        let dx = (pointer.x - start.x) * 0.5
                        p.addCurve(to: pointer, control1: CGPoint(x: start.x + dx, y: start.y),
                                   control2: CGPoint(x: pointer.x - dx, y: pointer.y))
                        var glow = ctx
                        glow.addFilter(.blur(radius: 6))
                        glow.stroke(p, with: .color(.white.opacity(0.7)), lineWidth: 4)
                        ctx.stroke(p, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        ctx.fill(Path(ellipseIn: CGRect(x: pointer.x - 5, y: pointer.y - 5, width: 10, height: 10)),
                                 with: .color(.white))
                    }
                }
            }
            .allowsHitTesting(false)

            ForEach(saved, id: \.0.id) { link, shape in
                LinkLabel(model: model, link: link)
                    .fixedSize()
                    .position(shape.mid)
            }

            if let draft = model.linkDraft, let b = draft.b {
                // Beside the link when it's in view; if the paper has scrolled it away, the card stays put.
                let shape = LinkGeometry.ribbon(from: draft.a.id, to: b.id, g: g)
                RelationPicker(model: model, draft: draft)
                    .frame(width: 300)
                    .fixedSize(horizontal: false, vertical: true)
                    .position(x: min(max(shape?.mid.x ?? g.pdfFrame.midX, 170), g.pdfFrame.maxX - 170),
                              y: shape.map { pickerY($0, in: g.pdfFrame) } ?? g.pdfFrame.maxY - 230)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Puts the card where it hides neither end of the link: below it, above it, or between its ends.
    private func pickerY(_ shape: LinkGeometry.Shape, in frame: CGRect) -> CGFloat {
        let h: CGFloat = 420, gap: CGFloat = 28
        let top = min(shape.start.y, shape.end.y), bottom = max(shape.start.y, shape.end.y)
        if bottom + gap + h <= frame.maxY { return bottom + gap + h / 2 }
        if top - gap - h >= frame.minY { return top - gap - h / 2 }
        if bottom - top >= h + 2 * gap { return (top + bottom) / 2 }
        return min(max(bottom + gap + h / 2, frame.minY + h / 2), frame.maxY - h / 2)
    }

    private func draw(_ shape: LinkGeometry.Shape, color: Color, strong: Bool, in ctx: inout GraphicsContext) {
        let o: Double = strong ? 0.75 : 0.55
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(stops: [.init(color: color.opacity(o), location: 0), .init(color: color.opacity(o * 0.5), location: 0.5),
                             .init(color: color.opacity(o), location: 1)]),
            startPoint: shape.start, endPoint: shape.end)
        // Stroked along its spine, so the ribbon keeps its width even where it falls steeply between pages.
        let style = StrokeStyle(lineWidth: (shape.startHeight + shape.endHeight) / 2, lineCap: .butt)
        var glow = ctx
        glow.addFilter(.blur(radius: 10))
        glow.opacity = strong ? 0.6 : 0.35
        glow.stroke(shape.spine, with: shading, style: style)
        ctx.stroke(shape.spine, with: shading, style: style)
        for (pt, h) in [(shape.start, shape.startHeight), (shape.end, shape.endHeight)] {
            let tab = Path(roundedRect: CGRect(x: pt.x - 3.5, y: pt.y - h / 2, width: 7, height: h),
                           cornerRadius: 3.5, style: .continuous)
            ctx.fill(tab, with: .color(color.opacity(0.9)))
            ctx.stroke(tab, with: .color(.white.opacity(0.5)), lineWidth: 0.75)
        }
    }
}

enum LinkGeometry {
    struct Shape { var path: Path; var spine: Path; var start: CGPoint; var end: CGPoint; var mid: CGPoint; var startHeight: CGFloat; var endHeight: CGFloat }

    /// A ribbon between two highlighted spans. It leaves each span at the edge of its page that faces the
    /// other; two spans in the same column loop out past the page's right edge.
    @MainActor
    static func ribbon(from a: UUID, to b: UUID, g: SpaceGeometry) -> Shape? {
        guard let ra = rect(a, g), let rb = rect(b, g), let pa = page(a, g), let pb = page(b, g) else { return nil }
        let visible = g.pdfFrame.insetBy(dx: 0, dy: 6)
        guard visible.intersects(ra), visible.intersects(rb) else { return nil }
        var (left, right, pl, pr) = ra.midX <= rb.midX ? (ra, rb, pa, pb) : (rb, ra, pb, pa)
        let sideBySide = pl.maxX < pr.minX - 8
        let ha = min(max(left.height + 4, 8), 34), hb = min(max(right.height + 4, 8), 34)
        let start: CGPoint, end: CGPoint, c1: CGPoint, c2: CGPoint
        if sideBySide {
            start = CGPoint(x: pl.maxX, y: left.midY); end = CGPoint(x: pr.minX, y: right.midY)
            let dx = (end.x - start.x) * 0.5
            c1 = CGPoint(x: start.x + dx, y: start.y); c2 = CGPoint(x: end.x - dx, y: end.y)
        } else {
            if left.minY > right.minY { swap(&left, &right); swap(&pl, &pr) }
            start = CGPoint(x: pl.maxX, y: left.midY); end = CGPoint(x: pr.maxX, y: right.midY)
            let reach = min(140, 50 + abs(end.y - start.y) * 0.25)
            c1 = CGPoint(x: start.x + reach, y: start.y); c2 = CGPoint(x: end.x + reach, y: end.y)
        }
        var p = Path()
        p.move(to: CGPoint(x: start.x, y: start.y - ha / 2))
        p.addCurve(to: CGPoint(x: end.x, y: end.y - hb / 2), control1: CGPoint(x: c1.x, y: c1.y - ha / 2), control2: CGPoint(x: c2.x, y: c2.y - hb / 2))
        p.addLine(to: CGPoint(x: end.x, y: end.y + hb / 2))
        p.addCurve(to: CGPoint(x: start.x, y: start.y + ha / 2), control1: CGPoint(x: c2.x, y: c2.y + hb / 2), control2: CGPoint(x: c1.x, y: c1.y + ha / 2))
        p.closeSubpath()
        var spine = Path()
        spine.move(to: start)
        spine.addCurve(to: end, control1: c1, control2: c2)
        // The curve's midpoint, where its label sits.
        let mid = CGPoint(x: 0.125 * start.x + 0.375 * c1.x + 0.375 * c2.x + 0.125 * end.x,
                          y: 0.125 * start.y + 0.375 * c1.y + 0.375 * c2.y + 0.125 * end.y)
        return Shape(path: p, spine: spine, start: start, end: end, mid: mid, startHeight: ha, endHeight: hb)
    }

    /// Where a line being drawn leaves its first passage: the page edge nearer the pointer.
    @MainActor
    static func anchor(_ id: UUID, toward p: CGPoint, g: SpaceGeometry) -> CGPoint? {
        guard let r = rect(id, g), let pg = page(id, g) else { return nil }
        return CGPoint(x: p.x < r.midX ? pg.minX : pg.maxX, y: r.midY)
    }

    @MainActor private static func rect(_ id: UUID, _ g: SpaceGeometry) -> CGRect? {
        (g.sourceFirstLines[id] ?? g.sourceRects[id]).map { $0.offsetBy(dx: g.pdfFrame.minX, dy: g.pdfFrame.minY) }
    }
    @MainActor private static func page(_ id: UUID, _ g: SpaceGeometry) -> CGRect? {
        g.sourcePageFrames[id].map { $0.offsetBy(dx: g.pdfFrame.minX, dy: g.pdfFrame.minY) }
    }
}

/// The label on a saved link. Hover for Claude's reason; click to change or remove it.
struct LinkLabel: View {
    let model: AppModel
    let link: PaperLink

    var body: some View {
        Menu {
            ForEach(PaperLink.Relation.allCases) { r in
                Button { model.setRelation(r, for: link.id) } label: {
                    if r == link.relation { Label(r.label, systemImage: "checkmark") } else { Text(r.label) }
                }
            }
            Divider()
            Button("Delete Link", role: .destructive) { model.deleteLink(link.id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: link.relation.symbol).foregroundStyle(link.relation.color)
                Text(link.relation.label).fontWeight(.semibold)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassEffect(.regular.interactive(), in: Capsule())
        .help(link.note.isEmpty ? "\(link.relation.label): click to change or remove" : link.note)
        .onHover { inside in model.hoveredLink = inside ? link.id : (model.hoveredLink == link.id ? nil : model.hoveredLink) }
    }
}

/// "How are these related?" Claude's suggestion on top with its reason, every relation one key away,
/// and a field to ask about the link in words instead.
struct RelationPicker: View {
    @Bindable var model: AppModel
    let draft: LinkDraft
    @FocusState private var askFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("How are these related?", systemImage: "link")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 4)

            if let s = draft.suggestion {
                Button { model.confirmLink(s.relation) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Image(systemName: s.relation.symbol).foregroundStyle(s.relation.color)
                            Text(s.relation.label).font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Label("Suggested", systemImage: "sparkles")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        if !s.why.isEmpty {
                            Text(s.why)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            } else if draft.isAsking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading both passages…").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .padding(10)
            } else if let error = draft.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange).padding(10)
            }

            ForEach(PaperLink.Relation.allCases.filter { $0 != draft.suggestion?.relation }) { r in
                Button { model.confirmLink(r) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: r.symbol).foregroundStyle(r.color).frame(width: 18)
                        Text(r.label).font(.system(size: 14))
                        Spacer()
                        Text(r.keyLabel).font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(r.key, modifiers: .command)
            }

            Divider().padding(.vertical, 4)
            TextField("Or ask about this link…", text: Binding(
                get: { model.linkDraft?.question ?? "" }, set: { model.linkDraft?.question = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($askFocused)
                .onSubmit { model.askAboutLink() }
                .padding(.horizontal, 10).padding(.bottom, 6)

            Button("") { model.linkDraft = nil }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0).opacity(0)
        }
        .padding(8)
        // A solid backing under the glass: the card often sits over white paper, where clear glass is unreadable.
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
    }
}

/// Top bar: enters Links mode, and while it's on, says how many links are showing and leaves it.
struct LinksPill: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Button { model.showingLinks ? model.closeLinks() : model.openLinks() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "link").font(.system(size: 13, weight: .medium))
                    Text("Links").font(.system(size: 13, weight: .semibold))
                    if model.showingLinks {
                        Text(model.links.isEmpty ? "none yet" : "\(model.links.count) in this paper")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Capsule())
            }
            .help(model.showingLinks ? "Leave Links" : "Draw links between passages")
            if model.showingLinks {
                Button { model.closeLinks() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                .help("Leave Links")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: Capsule())
        .fixedSize()
    }
}

/// The one instruction Links mode needs, at the bottom where the question bar usually is.
struct LinkHint: View {
    var body: some View {
        Label("Draw between two passages to ask how they relate", systemImage: "scribble")
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 18).padding(.vertical, 10)
            .glassEffect(.regular, in: Capsule())
    }
}

// MARK: Links on the model

extension AppModel {
    func openLinks() {
        if showingClaims { closeClaims() }
        if showingWhatIf { closeWhatIf() }
        placeBeforeLinks = pdf.place
        showingLinks = true
        linkDraft = nil
        geometry.slipFrames = [:]
        if let place = placeBeforeLinks {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.pdf.go(to: place) }
        }
    }

    func closeLinks() {
        showingLinks = false
        linkDraft = nil
        linkHover = nil
        if let place = placeBeforeLinks {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.pdf.go(to: place) }
        }
        placeBeforeLinks = nil
    }

    /// Asks Claude what the drawn link is. The reader can pick a relation before it answers.
    func suggestRelation() {
        guard let draft = linkDraft, let b = draft.b, let index, let document, let paperKey = archiveKey,
              let key = APIKeyStore.read() ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] else { return }
        linkDraft?.isAsking = true
        let a = draft.a
        let agent = PaperAgent(apiKey: key, model: answerModel.rawValue, document: document,
                               paperText: index.promptText, paperKey: paperKey)
        let system = Prompts.system(paperTitle: index.title, paperText: index.promptText)
        Task {
            do {
                let result = try await agent.run(system: system, user: LinkPrompt.user(a, b)) { _ in }
                guard linkDraft?.a == a, linkDraft?.b == b else { return }   // the reader moved on
                if let (r, why) = LinkPrompt.parse(result.html) {
                    linkDraft?.suggestion = (r, why)
                } else {
                    linkDraft?.error = "Claude's suggestion couldn't be read. Pick one below."
                }
            } catch {
                guard linkDraft?.a == a, linkDraft?.b == b else { return }
                linkDraft?.error = (error as? ClaudeError)?.localizedDescription ?? "Couldn't reach Claude."
            }
            linkDraft?.isAsking = false
        }
    }

    func confirmLink(_ relation: PaperLink.Relation) {
        guard let draft = linkDraft, let b = draft.b else { return }
        let note = draft.suggestion?.relation == relation ? draft.suggestion?.why ?? "" : ""
        links.append(PaperLink(a: draft.a, b: b, relation: relation, note: note))
        linkDraft = nil
        save()
    }

    func setRelation(_ r: PaperLink.Relation, for id: UUID) {
        guard let i = links.firstIndex(where: { $0.id == id }) else { return }
        if links[i].relation != r { links[i].relation = r; links[i].note = "" }
        save()
    }

    func deleteLink(_ id: UUID) {
        links.removeAll { $0.id == id }
        save()
    }

    /// "Or ask about this link…": a new answer about both passages, back in the answer view.
    func askAboutLink() {
        guard let draft = linkDraft, let b = draft.b else { return }
        let q = draft.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let passages = [Passage(span: draft.a.span, text: draft.a.text, colorIndex: 0),
                        Passage(span: b.span, text: b.text, colorIndex: 1)]
        closeLinks()
        mode = .compose
        question = q
        send(passages: passages)
    }
}
