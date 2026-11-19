import SwiftUI
import PDFKit

// MARK: Model

/// Idea F: the paper's claims, each tied to its evidence, the assumptions it rests on, and what's missing.
/// Claims, assumptions and gaps are Claude's reading (glass); evidence is the authors' own words (paper).
struct ClaimsMap: Codable, Identifiable {
    var id = UUID()
    var scope: String                 // "the abstract", or "this passage"
    var claims: [Claim]
    var createdAt = Date()

    var evidenceCount: Int { claims.map(\.evidence.count).reduce(0, +) }
}

struct Claim: Codable, Identifiable {
    enum Strength: String, Codable { case strong, thin, notShown = "not_shown" }

    var id = UUID()
    var claim: String                 // Claude's short restatement
    var quote: String                 // where the paper makes it, in the paper's words
    var page: Int                     // 1-based, as Claude reported it
    var location: String              // "Abstract"
    var strength: Strength
    var score: Int                    // 0–5
    var why: String
    var evidence: [Evidence]
    var assumptions: [String]
    var gaps: [String]
    var span: SpanRef?

    struct Evidence: Codable, Identifiable {
        var id = UUID()
        var label: String             // "Table 4, column 1"
        var page: Int
        var quote: String             // the paper's exact words once found
        var span: SpanRef?
    }
}

extension Claim.Strength {
    var label: String {
        switch self { case .strong: "Strong"; case .thin: "Thin"; case .notShown: "Not shown" }
    }
    var symbol: String {
        switch self {
        case .strong: "checkmark.seal.fill"
        case .thin: "exclamationmark.circle.fill"
        case .notShown: "questionmark.circle"
        }
    }
    var rgb: HighlightSpec.RGB {
        switch self {
        case .strong: .init(r: 52, g: 199, b: 89)
        case .thin: .init(r: 255, g: 149, b: 0)
        case .notShown: .init(r: 142, g: 142, b: 147)
        }
    }
    var color: Color { Color(red: rgb.r / 255, green: rgb.g / 255, blue: rgb.b / 255) }
}

// MARK: Asking Claude

enum ClaimsPrompt {
    /// The task goes in the user turn so the system prompt, and its cached copy of the paper, is shared
    /// with ordinary answers.
    static func user(passage: String?, page: Int?) -> String {
        let scope: String
        if let passage {
            scope = """
            Map the claims in this passage the reader selected (page \((page ?? 0) + 1)):
            <passage>\(passage)</passage>
            """
        } else {
            scope = "Map the claims in the paper's abstract. If it has no abstract, use the summary paragraph that opens it."
        }
        return """
        <task>
        This request is not a question, and it is not answered as HTML. \(scope)

        For each distinct claim (usually 3 to 6), decide how well the rest of the paper supports it, by reading \
        the evidence the authors give. Use the tools if a figure or table needs checking.

        Reply with only this JSON object, nothing before or after it:
        {
          "scope": "the abstract" or "this passage",
          "claims": [
            {
              "claim": "The claim restated in plain words, at most 12 words, no period",
              "quote": "The exact words where the paper makes the claim, copied from the paper text",
              "page": page number of that quote,
              "where": "Abstract" or the section name,
              "strength": "strong" | "thin" | "not_shown",
              "score": 0 to 5, how well the evidence supports it (strong is 4–5, thin is 1–3, not_shown is 0),
              "why": "One sentence on why it is rated this way",
              "evidence": [
                { "label": a short name for where it is, at most 4 words: "Table 4, column 1", "Figure 3", "Section IV.A", "page": number,
                  "quote": "Exact words from the paper that show the evidence: a result sentence, a caption, or a note" }
              ],
              "assumptions": ["Something the claim takes for granted that the paper does not test"],
              "gaps": ["Something a careful reader would want shown that the paper does not show"]
            }
          ]
        }

        Rules:
        - Every "quote" is copied exactly from the paper text: same words, same order, one to three sentences.
        - "not_shown" means the paper never backs the claim; give no evidence for it and say what is missing in "gaps".
        - Give 0 to 3 pieces of evidence, 0 to 2 assumptions and 0 to 2 gaps per claim. Leave a list empty \
        rather than padding it.
        - Be fair: "thin" is for evidence that is narrow, indirect or missing a check, not for claims you disagree with.
        </task>
        """
    }

    /// Pulls the JSON object out of Claude's reply, tolerating a code fence or a stray sentence.
    static func parse(_ text: String) throws -> ClaimsMap {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { throw ClaudeError.unreadable }
        let data = Data(text[start...end].utf8)
        struct Raw: Decodable {
            struct C: Decodable {
                var claim: String; var quote: String?; var page: Int?; var `where`: String?
                var strength: String?; var score: Int?; var why: String?
                var evidence: [E]?; var assumptions: [String]?; var gaps: [String]?
            }
            struct E: Decodable { var label: String?; var page: Int?; var quote: String? }
            var scope: String?
            var claims: [C]
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data), !raw.claims.isEmpty else {
            throw ClaudeError.unreadable
        }
        return ClaimsMap(scope: raw.scope ?? "the abstract", claims: raw.claims.map { c in
            let strength = Claim.Strength(rawValue: c.strength ?? "") ?? .thin
            return Claim(claim: c.claim, quote: c.quote ?? "", page: c.page ?? 1, location: c.where ?? "",
                         strength: strength, score: min(max(c.score ?? 0, 0), 5), why: c.why ?? "",
                         evidence: strength == .notShown ? [] : (c.evidence ?? []).compactMap { e in
                             guard let q = e.quote, !q.isEmpty else { return nil }
                             return Claim.Evidence(label: e.label ?? "", page: e.page ?? 1, quote: q)
                         },
                         assumptions: c.assumptions ?? [], gaps: c.gaps ?? [])
        })
    }
}

// MARK: The panel

/// The claims map: claims on the left as glass cards with a strength meter, and what bears on each to their
/// right: the paper's evidence as white slips, assumptions and gaps as glass. Thin lines join them.
struct ClaimsPanel: View {
    @Bindable var model: AppModel
    let map: ClaimsMap?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 14)
            if let map {
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        ForEach(map.claims) { claim in
                            ClaimRow(model: model, claim: claim)
                        }
                    }
                    .padding(.horizontal, 28).padding(.top, 6).padding(.bottom, 30)
                }
                .scrollIndicators(.never)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("space")) } action: {
                    model.geometry.sheetViewport = $0
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text((model.claimsStep.isEmpty ? "Reading the paper's claims" : model.claimsStep) + "…")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    if let error = model.claimsError {
                        Text(error).font(.system(size: 13)).foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 28)
                Spacer()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 13, weight: .medium))
            Text("Claims in \(map?.scope ?? model.claimsScope)")
                .font(.system(size: 15, weight: .semibold))
            if let map {
                Text("\(map.claims.count) claims · \(map.evidenceCount) pieces of evidence")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 14) {
                ForEach([Claim.Strength.strong, .thin, .notShown], id: \.self) { s in
                    HStack(spacing: 5) {
                        Circle().fill(s.color).frame(width: 7, height: 7)
                        Text(s.label)
                    }
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            Menu {
                Button("Map Again") { model.mapClaims(force: true) }
                Button("Close Claims") { model.closeClaims() }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuIndicator(.hidden)
                .menuStyle(.button)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}

/// One claim and everything that bears on it, joined by thin lines (solid to evidence, dashed otherwise).
struct ClaimRow: View {
    let model: AppModel
    let claim: Claim
    @State private var claimFrame: CGRect = .zero
    @State private var itemFrames: [Int: CGRect] = [:]
    @State private var rowFrame: CGRect = .zero

    private enum Item { case evidence(Claim.Evidence), assumption(String), gap(String) }
    private var items: [Item] {
        claim.evidence.map(Item.evidence) + claim.assumptions.map(Item.assumption) + claim.gaps.map(Item.gap)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 56) {
            ClaimCard(model: model, claim: claim)
                .frame(width: 300)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("space")) } action: { claimFrame = $0 }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    Group {
                        switch item {
                        case .evidence(let e): EvidenceSlip(model: model, evidence: e)
                        case .assumption(let a): ReadingCard(label: "Assumes", text: a, tint: nil, dashed: true)
                        case .gap(let g): ReadingCard(label: "Gap", text: g,
                                                      tint: claim.strength == .thin ? Claim.Strength.thin.color : nil,
                                                      dashed: false)
                        }
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("space")) } action: { itemFrames[i] = $0 }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(alignment: .topLeading) { connectors }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("space")) } action: { rowFrame = $0 }
    }

    /// Lines from the claim card's right edge, near its top, to each item's left edge.
    private var connectors: some View {
        Canvas { ctx, _ in
            guard claimFrame.width > 0, rowFrame.width > 0 else { return }
            let o = rowFrame.origin
            let start = CGPoint(x: claimFrame.maxX - o.x, y: claimFrame.minY - o.y + 26)
            for (i, item) in items.enumerated() {
                guard let g = itemFrames[i] else { continue }
                let f = g.offsetBy(dx: -o.x, dy: -o.y)
                let end = CGPoint(x: f.minX, y: f.minY + min(26, f.height / 2))
                var p = Path()
                p.move(to: start)
                let dx = (end.x - start.x) * 0.55
                p.addCurve(to: end, control1: CGPoint(x: start.x + dx, y: start.y), control2: CGPoint(x: end.x - dx, y: end.y))
                let dashed: Bool = { if case .evidence = item { return false } else { return true } }()
                ctx.stroke(p, with: .color(.primary.opacity(dashed ? 0.28 : 0.35)),
                           style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: dashed ? [3, 3] : []))
                ctx.fill(Path(ellipseIn: CGRect(x: end.x - 2.5, y: end.y - 2.5, width: 5, height: 5)),
                         with: .color(.primary.opacity(0.45)))
            }
        }
        .allowsHitTesting(false)
    }
}

/// A claim: Claude's reading, so glass. A bar of its strength's color down the left, where its beam arrives.
struct ClaimCard: View {
    let model: AppModel
    let claim: Claim

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: claim.strength.symbol)
                Text(claim.strength.label)
                Spacer()
                HStack(spacing: 3) {
                    ForEach(0..<5, id: \.self) { i in
                        Capsule()
                            .fill(i < claim.score ? claim.strength.color : Color.primary.opacity(0.15))
                            .frame(width: 11, height: 3)
                    }
                }
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(claim.strength.color)

            Text(claim.claim)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text([claim.location, "p.\(claim.span.map { $0.page + 1 } ?? claim.page)"].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 20).padding(.trailing, 16).padding(.vertical, 14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .leading) {
            Capsule().fill(claim.strength.color).frame(width: 4).padding(.vertical, 10).padding(.leading, 5)
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("space")) } action: {
            model.geometry.slipFrames[claim.id] = $0
        }
        .onHover { inside in
            if inside { model.geometry.hoveredSource = claim.id }
            else if model.geometry.hoveredSource == claim.id { model.geometry.hoveredSource = nil }
        }
        .onTapGesture { if let span = claim.span { model.pdf.reveal(span) } }
        .help(claim.why)
    }
}

/// Evidence: the authors' words, on paper, with where they are. Click to see them in the paper.
struct EvidenceSlip: View {
    let model: AppModel
    let evidence: Claim.Evidence

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text([evidence.label, "p.\(evidence.span.map { $0.page + 1 } ?? evidence.page)"]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                if evidence.span == nil {
                    Text("· not found in the paper").foregroundStyle(.orange)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.black.opacity(0.5))
            Text(evidence.quote)
                .font(.custom(model.paperFontName, size: 15))
                .lineSpacing(2)
                .foregroundStyle(Color.black.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
        .contentShape(Rectangle())
        .onTapGesture { if let span = evidence.span { model.pdf.reveal(span) } }
        .help(evidence.span == nil ? "Claude's copy didn't match the paper's text exactly" : "Show in the paper")
    }

    private var icon: String {
        let l = evidence.label.lowercased()
        if l.hasPrefix("table") { return "tablecells" }
        if l.hasPrefix("fig") { return "chart.bar" }
        return "doc.text"
    }
}

/// An assumption or a gap: Claude's reading, so glass, never paper.
struct ReadingCard: View {
    let label: String
    let text: String
    let tint: Color?
    let dashed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint ?? Color.secondary)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((tint ?? .primary).opacity(tint == nil ? 0.03 : 0.08),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder((tint ?? .primary).opacity(tint == nil ? 0.22 : 0.5),
                              style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : []))
        )
    }
}
