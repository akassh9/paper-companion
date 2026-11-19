import SwiftUI
import PDFKit

// MARK: Model

/// Idea G: the reader changes a number in the paper and Claude carries it through. Changes float above the
/// paper in glass, with the original struck through, so the paper itself is never overwritten.
struct WhatIfEdit: Equatable {
    var id = UUID()                // highlight id
    var span: SpanRef
    var original: String
    var value: String
    var context: String            // the sentence it sits in
}

struct WhatIfChange: Identifiable {
    enum Direction: String { case up, down, same }
    var id = UUID()
    var label: String
    var location: String           // "Table 1", "Section V-D"
    var page: Int                  // 1-based, as Claude gave it
    var quote: String
    var old: String
    var new: String
    var unit: String
    var direction: Direction
    var good: Bool?
    var span: SpanRef?             // the old value on the page, when found
}

struct WhatIfResult {
    var title: String
    var basis: String
    var verdict: String
    var changes: [WhatIfChange]
}

struct WhatIf {
    var edit: WhatIfEdit
    var result: WhatIfResult?
    var isEstimating = false
    var step = ""
    var error: String?
}

enum WhatIfPrompt {
    static func user(_ e: WhatIfEdit) -> String {
        """
        <task>
        This request is not a question, and it is not answered as HTML. The reader is trying a what-if edit on \
        the paper. On page \(e.span.page + 1), in this sentence:
        <context>\(e.context)</context>
        they changed "\(e.original)" to "\(e.value)".

        Work out how the paper would read if the authors had used the new value. Ground every estimate in the \
        paper's own evidence: ablations, tables, equations, reported relationships. Use code to compute when it \
        helps. Only estimate what the paper gives grounds for.

        Tables lose their columns in the extracted text, so before you estimate anything in a table, or if the \
        edited number sits in one, look at that table's page with view_page and read the cells from the image.

        Reply with only this JSON, nothing before or after it:
        {
          "title": "If ... (the edit in plain words, at most 10 words)",
          "basis": "Where the estimates come from, e.g. Estimated from the ablations in Section V-D",
          "changes": [
            {
              "label": "What this number is, 2 to 4 words",
              "where": "Table 1, or a section name",
              "page": page number,
              "quote": "A short exact phrase from the paper text, 4 to 15 words, containing the number as printed",
              "old": "The number or words exactly as printed in that phrase",
              "new": "The estimated new value, in the same format",
              "unit": "GB, %, or empty",
              "direction": "up" | "down" | "same",
              "good": true if the change is better for what the paper is trying to achieve, false if worse, null if neither
            }
          ],
          "verdict": "One or two sentences on what the edit means for the paper's conclusions."
        }

        Rules:
        - Never list the reader's own edit. Other places that state the edited value (a method description, \
        the abstract) are changes.
        - Give 2 to 8 changes, the most important first. Leave out numbers the edit would not move.
        - If the paper gives no grounds to estimate anything, return an empty "changes" list and say why in "verdict".
        </task>
        """
    }

    /// If Claude reported changes in tables it never looked at (or the edit sits in a table it never looked
    /// at), the app sends those pages back once and asks it to check every value against the printed cells.
    static func review(_ text: String, viewed: Set<Int>, edit: WhatIfEdit) -> AgentReview? {
        guard let r = try? parse(text) else { return nil }
        var pages = Set(r.changes.filter {
            $0.location.localizedCaseInsensitiveContains("table") || $0.location.localizedCaseInsensitiveContains("panel")
        }.map(\.page))
        // A "sentence" that is mostly numbers is a table row: the edit itself sits in a table. (Prose that
        // quotes a few numbers, like "column (1), 0.52, indicates a 1.14-log-point difference", is not.)
        let words = edit.context.split(whereSeparator: \.isWhitespace)
        let numeric = words.filter { w in
            let t = w.trimmingCharacters(in: CharacterSet(charactersIn: "()[],;:%−-–"))
            return !t.isEmpty && t.allSatisfy { $0.isNumber || $0 == "." }
        }
        if numeric.count >= 5, Double(numeric.count) >= 0.4 * Double(words.count) { pages.insert(edit.span.page + 1) }
        let missing = pages.subtracting(viewed).filter { $0 > 0 }.sorted().prefix(4)
        guard !missing.isEmpty else { return nil }
        return AgentReview(text: """
            Here are the pages with the tables you cited, as images: \(missing.map(String.init).joined(separator: ", ")). \
            Check every "old" value against the printed cell, and every "where" and "page" against where it \
            actually is. Correct anything that's off, including estimates that depend on it, and reply with \
            the corrected JSON only, in the same format.
            """, pages: Array(missing))
    }

    static func parse(_ text: String) throws -> WhatIfResult {
        guard let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(text[s...e].utf8)) as? [String: Any]
        else { throw ClaudeError.unreadable }
        let changes: [WhatIfChange] = (obj["changes"] as? [[String: Any]] ?? []).compactMap { c in
            guard let old = c["old"].map({ "\($0)" }), let new = c["new"].map({ "\($0)" }) else { return nil }
            return WhatIfChange(label: c["label"] as? String ?? "", location: c["where"] as? String ?? "",
                                page: c["page"] as? Int ?? 1, quote: c["quote"] as? String ?? "",
                                old: old, new: new, unit: c["unit"] as? String ?? "",
                                direction: WhatIfChange.Direction(rawValue: c["direction"] as? String ?? "") ?? .same,
                                good: c["good"] as? Bool)
        }
        return WhatIfResult(title: obj["title"] as? String ?? "What if", basis: obj["basis"] as? String ?? "",
                            verdict: obj["verdict"] as? String ?? "", changes: changes)
    }
}

extension PDFController {
    /// The sentence a span sits in, for context.
    func sentence(around span: SpanRef) -> String {
        guard let page = pdfView?.document?.page(at: span.page), let raw = page.string else { return "" }
        let s = raw.replacingOccurrences(of: "\n", with: " ") as NSString
        let lo = max(0, span.location - 600), hi = min(s.length, span.location + span.length + 600)
        var out: [String] = []
        s.enumerateSubstrings(in: NSRange(location: lo, length: hi - lo), options: .bySentences) { sub, r, _, _ in
            if NSIntersectionRange(r, span.range).length > 0 || NSLocationInRange(span.location, r) { out.append(sub ?? "") }
        }
        return out.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

// MARK: On the paper

/// Over the paper: the field where the reader types the new value, each estimated change as a numbered
/// glass badge above its struck-through original, and dashed lines from the edit to what it moved.
struct WhatIfLayer: View {
    @Bindable var model: AppModel

    var body: some View {
        let g = model.geometry
        ZStack(alignment: .topLeading) {
            if let w = model.whatIf, model.whatIfShowsEdit {
                let editRect = rect(w.edit.id, g)
                let changes = (w.result?.changes ?? []).enumerated().compactMap { i, c in
                    rect(c.id, g).flatMap { visible($0, g) ? (i, c, $0) : nil }
                }
                Canvas { ctx, _ in
                    for (_, _, r) in changes {
                        // The original, struck through.
                        var strike = Path()
                        strike.move(to: CGPoint(x: r.minX - 1, y: r.midY))
                        strike.addLine(to: CGPoint(x: r.maxX + 1, y: r.midY))
                        ctx.stroke(strike, with: .color(Color(red: 1, green: 0.27, blue: 0.23).opacity(0.85)), lineWidth: 1.5)
                        if let e = editRect, visible(e, g) {
                            var p = Path()
                            p.move(to: CGPoint(x: e.midX, y: e.midY))
                            let to = CGPoint(x: r.minX, y: r.midY)
                            let dx = (to.x - e.midX) * 0.5
                            p.addCurve(to: to, control1: CGPoint(x: e.midX + dx, y: e.midY), control2: CGPoint(x: to.x - dx, y: to.y))
                            ctx.stroke(p, with: .color(WhatIfStyle.teal.opacity(0.55)),
                                       style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [3, 4]))
                        }
                    }
                }
                .allowsHitTesting(false)

                ForEach(changes, id: \.1.id) { i, c, r in
                    ChangeBadge(number: i + 1, change: c)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .fixedSize()
                        .position(x: r.maxX + 4, y: r.minY - 13)
                        .onTapGesture { model.whatIfFocus = c.id }
                }

                if let e = editRect, visible(e, g) {
                    EditField(model: model, edit: w.edit)
                        .fixedSize()
                        .position(x: e.midX, y: e.midY)
                }
            } else if let editing = model.whatIfEditing, let e = rect(editing.id, g) {
                EditField(model: model, edit: editing)
                    .fixedSize()
                    .position(x: e.midX, y: e.midY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func rect(_ id: UUID, _ g: SpaceGeometry) -> CGRect? {
        g.sourceRects[id].map { $0.offsetBy(dx: g.pdfFrame.minX, dy: g.pdfFrame.minY) }
    }
    private func visible(_ r: CGRect, _ g: SpaceGeometry) -> Bool {
        g.pdfFrame.insetBy(dx: 0, dy: 8).intersects(r)
    }
}

enum WhatIfStyle {
    static let teal = Color(red: 48 / 255, green: 176 / 255, blue: 199 / 255)
    static let tealRGB = HighlightSpec.RGB(r: 48, g: 176, b: 199)
    static let up = Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)
    static let down = Color(red: 1, green: 69 / 255, blue: 58 / 255)

    static func arrowColor(_ c: WhatIfChange) -> Color {
        switch c.good { case true: up; case false: down; default: .secondary }
    }
    static func arrow(_ c: WhatIfChange) -> String? {
        switch c.direction { case .up: "arrow.up"; case .down: "arrow.down"; case .same: nil }
    }
}

/// A changed number on the paper: its number in the list, which way it moved, and its new value.
struct ChangeBadge: View {
    let number: Int
    let change: WhatIfChange

    var body: some View {
        HStack(spacing: 5) {
            NumberDot(number: number, size: 17)
            if let a = WhatIfStyle.arrow(change) {
                Image(systemName: a).font(.system(size: 10, weight: .bold)).foregroundStyle(WhatIfStyle.arrowColor(change))
            }
            Text(change.new).font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
        }
        .padding(.leading, 4).padding(.trailing, 9).padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .glassEffect(.regular, in: Capsule())
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        .help("\(change.label): \(change.old) → \(change.new)\(change.unit.isEmpty ? "" : " " + change.unit)")
    }
}

struct NumberDot: View {
    let number: Int
    var size: CGFloat = 20
    var body: some View {
        Text("\(number)")
            .font(.system(size: size * 0.6, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(WhatIfStyle.teal, in: Circle())
    }
}

/// The field over the number being changed. Before sending, it's where the reader types; after, it shows
/// the new value with the original above it.
struct EditField: View {
    @Bindable var model: AppModel
    let edit: WhatIfEdit
    @FocusState private var focused: Bool

    var body: some View {
        let sent = model.whatIf?.edit.id == edit.id
        VStack(alignment: .leading, spacing: 3) {
            Text("was \(edit.original)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.black.opacity(0.65), in: Capsule())
            if sent {
                Text(edit.value)
                    .font(.custom(model.paperFontName, size: 17).italic())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(WhatIfStyle.teal, lineWidth: 1.5))
            } else {
                TextField("New value", text: Binding(get: { model.whatIfEditing?.value ?? "" },
                                                     set: { model.whatIfEditing?.value = $0 }))
                    .textFieldStyle(.plain)
                    .font(.custom(model.paperFontName, size: 17))
                    .foregroundStyle(.black)
                    .frame(minWidth: 70, idealWidth: 120, maxWidth: 220)
                    .fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(WhatIfStyle.teal, lineWidth: 1.5))
                    .shadow(color: WhatIfStyle.teal.opacity(0.4), radius: 8)
                    .focused($focused)
                    .onSubmit { model.estimateWhatIf() }
                    .onExitCommand { model.whatIfEditing = nil }
                    .onAppear { focused = true }
            }
        }
        // Sits so the field covers the original number, with "was …" just above it.
        .offset(y: -9)
    }
}

// MARK: The panel

/// What the edit moved, in order, with the verdict, and the controls: compare, revert, or keep it.
struct WhatIfPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let w = model.whatIf {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.sparkles").font(.system(size: 13, weight: .medium))
                    Text("What-if").font(.system(size: 13, weight: .semibold))
                    Text("· estimates, not the paper").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(w.result?.title ?? "If \(w.edit.original) were \(w.edit.value)")
                        .font(.system(size: 22, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let basis = w.result?.basis, !basis.isEmpty {
                        Text(basis).font(.system(size: 13)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if w.isEstimating {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text((w.step.isEmpty ? "Carrying the change through the paper" : w.step) + "…")
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                } else if let error = w.error {
                    Text(error).font(.system(size: 13)).foregroundStyle(.orange)
                }

                if let r = w.result {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(r.changes.enumerated()), id: \.1.id) { i, c in
                                ChangeRow(model: model, number: i + 1, change: c)
                                if i < r.changes.count - 1 { Divider().opacity(0.5) }
                            }
                        }
                        if !r.verdict.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Verdict").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                                Text(r.verdict).font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .padding(.top, 12)
                        }
                    }
                    .scrollIndicators(.never)
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    Picker("Show", selection: $model.whatIfShowsEdit) {
                        Text("Original").tag(false)
                        Text("What-if").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    Button { model.revertWhatIf() } label: { Label("Revert", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(.glass)
                    Button { model.keepWhatIfAsBranch() } label: { Label("Keep as branch", systemImage: "arrow.triangle.branch") }
                        .buttonStyle(.glassProminent)
                        .disabled(w.result == nil)
                }
                .controlSize(.large)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.sparkles").font(.system(size: 13, weight: .medium))
                    Text("What-if").font(.system(size: 13, weight: .semibold))
                }
                Text("Change a number in the paper.")
                    .font(.system(size: 22, weight: .bold))
                Text("Select a number or a short phrase, type what it should be, and press Return. Claude carries the change through the tables, claims and prose, as estimates you can compare with the original.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .padding(26)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct ChangeRow: View {
    let model: AppModel
    let number: Int
    let change: WhatIfChange

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            NumberDot(number: number)
            VStack(alignment: .leading, spacing: 2) {
                Text(change.label).font(.system(size: 15, weight: .medium))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 5) {
                if let a = WhatIfStyle.arrow(change) {
                    Image(systemName: a).font(.system(size: 11, weight: .bold)).foregroundStyle(WhatIfStyle.arrowColor(change))
                }
                Text("\(change.old) → \(change.new)\(change.unit.isEmpty ? "" : " " + change.unit)")
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .background(model.whatIfFocus == change.id ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            model.whatIfFocus = change.id
            if let span = change.span { model.pdf.show(span) }
        }
        .help(change.span == nil ? "Couldn't find this number on the page" : "Show it in the paper")
    }

    private var subtitle: String {
        let page = "p.\(change.span.map { $0.page + 1 } ?? change.page)"
        var parts = [change.location, page].filter { !$0.isEmpty }
        if change.span == nil { parts.append("not found on the page") }
        else if let r = model.geometry.sourceRects[change.id],
                r.maxY < 0 || r.minY > model.geometry.pdfFrame.height { parts.append("off screen") }
        return parts.joined(separator: " · ")
    }
}

/// Top bar: enters What-if, and while it's on, says how many edits and leaves it.
struct WhatIfPill: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Button { model.showingWhatIf ? model.closeWhatIf() : model.openWhatIf() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "wand.and.sparkles").font(.system(size: 13, weight: .medium))
                    Text("What-if").font(.system(size: 13, weight: .semibold))
                    if model.showingWhatIf {
                        Text(model.whatIf == nil ? "no edits" : "1 edit").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Capsule())
            }
            .help(model.showingWhatIf ? "Leave What-if" : "Change a number and see what follows")
            if model.showingWhatIf {
                Button { model.closeWhatIf() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                .help("Leave What-if")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: Capsule())
        .fixedSize()
    }
}

// MARK: What-if on the model

extension AppModel {
    func openWhatIf() {
        if showingClaims { closeClaims() }
        if showingLinks { closeLinks() }
        placeBeforeLinks = pdf.place
        switchMode { showingWhatIf = true }
        whatIfShowsEdit = true
        geometry.slipFrames = [:]
        if let sel = selection { beginWhatIf(sel) }
        if let place = placeBeforeLinks {
            pdf.hold(.place(place))
        }
    }

    func closeWhatIf() {
        switchMode { showingWhatIf = false }
        whatIf = nil
        whatIfEditing = nil
        if let place = placeBeforeLinks {
            pdf.hold(.place(place))
        }
        placeBeforeLinks = nil
    }

    /// The reader selected something in What-if mode: put a field over it to type the new value.
    func beginWhatIf(_ sel: LiveSelection) {
        guard whatIf?.isEstimating != true else { return }
        let text = sel.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 60 else { return }
        whatIf = nil
        whatIfEditing = WhatIfEdit(span: sel.span, original: text, value: text, context: pdf.sentence(around: sel.span))
    }

    func estimateWhatIf() {
        guard var edit = whatIfEditing, let index, let document, let paperKey = archiveKey else { return }
        edit.value = edit.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !edit.value.isEmpty, edit.value != edit.original else { return }
        guard let key = APIKeyStore.read() ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] else {
            showKeySheet = true
            return
        }
        whatIfEditing = nil
        selection = nil
        pdf.clearSelection()
        whatIf = WhatIf(edit: edit, isEstimating: true)
        whatIfShowsEdit = true
        var agent = PaperAgent(apiKey: key, model: answerModel.rawValue, document: document,
                               paperText: index.promptText, paperKey: paperKey)
        agent.review = { text, viewed in WhatIfPrompt.review(text, viewed: viewed, edit: edit) }
        let system = Prompts.system(paperTitle: index.title, paperText: index.promptText)
        Task {
            do {
                let raw = try await agent.run(system: system, user: WhatIfPrompt.user(edit)) { [weak self] step in
                    self?.whatIf?.step = step == "Composing the answer" ? "Writing it up" : step
                }
                guard whatIf?.edit.id == edit.id else { return }
                var result = try WhatIfPrompt.parse(raw.html)
                for i in result.changes.indices { result.changes[i].span = locate(result.changes[i]) }
                withAnimation(Motion.appear) { whatIf?.result = result }
            } catch {
                guard whatIf?.edit.id == edit.id else { return }
                whatIf?.error = (error as? ClaudeError)?.localizedDescription ?? "Couldn't reach Claude."
            }
            whatIf?.isEstimating = false
            whatIf?.step = ""
        }
    }

    /// Finds the changed number on its page: the phrase Claude quoted, narrowed to the number in it.
    private func locate(_ c: WhatIfChange) -> SpanRef? {
        guard let index, let document,
              let span = index.locate(c.quote, preferredPage: c.page - 1) ?? index.locate(c.old, preferredPage: c.page - 1),
              let raw = document.page(at: span.page)?.string as NSString?,
              NSMaxRange(span.range) <= raw.length
        else { return nil }
        let within = raw.substring(with: span.range) as NSString
        let r = within.range(of: c.old)
        guard r.location != NSNotFound else { return span }
        return SpanRef(page: span.page, location: span.location + r.location, length: r.length)
    }

    func revertWhatIf() {
        whatIf = nil
        whatIfEditing = nil
    }

    /// Keeps the what-if as an answer thread: the edit, what it moved, the verdict, and the paper's own words.
    func keepWhatIfAsBranch() {
        guard let w = whatIf, let r = w.result else { return }
        let esc = AnswerHTML.escape
        var html = "<h1>\(esc(r.title))</h1>\n"
        html += "<p>You changed “\(esc(w.edit.original))” to “\(esc(w.edit.value))”. \(esc(r.basis.isEmpty || ".!?".contains(r.basis.last!) ? r.basis : r.basis + "."))</p>\n"
        if !r.changes.isEmpty {
            html += "<table><thead><tr><th>What</th><th>Where</th><th class=\"num\">Paper</th><th class=\"num\">What-if</th></tr></thead><tbody>\n"
            for c in r.changes {
                let unit = c.unit.isEmpty ? "" : " " + esc(c.unit)
                html += "<tr><td>\(esc(c.label))</td><td>\(esc(c.location))</td><td class=\"num\">\(esc(c.old))\(unit)</td><td class=\"num\">\(esc(c.new))\(unit)</td></tr>\n"
            }
            html += "</tbody></table>\n"
        }
        if !r.verdict.isEmpty { html += "<p class=\"note\">\(esc(r.verdict))</p>\n" }
        let quoted = r.changes.filter { $0.span != nil }.prefix(3)
        if !quoted.isEmpty {
            html += "<p>Where the paper states these numbers:</p>\n"
            for c in quoted {
                html += "<paper-quote page=\"\(c.page)\" where=\"\(esc(c.location))\">\(esc(c.quote))</paper-quote>\n"
            }
        }
        let passage = Passage(span: w.edit.span, text: w.edit.context.isEmpty ? w.edit.original : w.edit.context, colorIndex: 0)
        closeWhatIf()
        mode = .compose
        finishHTML(html, code: [], mode: .compose, question: r.title, passages: [passage], threadID: nil)
    }
}
