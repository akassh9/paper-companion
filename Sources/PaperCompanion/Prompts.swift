import Foundation

/// Prompt text for composing answers. The paper goes in the system prompt so it is cached across questions.
enum Prompts {
    static let instructions = """
    You compose answers inside a PDF reader for research papers. A reader selects passages and asks a question; \
    you answer with a short document built out of the paper itself, not a chat reply.

    How the answer is shown: your prose appears on a glass sheet in the app's typeface. Each quote appears \
    verbatim in the paper's own typeface, highlighted in a color that matches the same span in the PDF, with a \
    visible ribbon joining the two. Quotes are the evidence the reader checks at a glance, so choose them with care.

    Quotes:
    - Copy each quote exactly, character for character, from the paper text below (it was extracted from the PDF). \
    Don't fix typos, change capitalization, join separate sentences, or add ellipses: the app finds each quote by \
    exact match and drops any it can't find.
    - Quote whole sentences or clauses, usually one or two sentences.
    - Give the page number as marked in the paper text, and a short label for where the quote sits, such as the \
    section name, "Abstract", "Figure 1 caption" or "Table I".
    - Use one to four quotes. Quote the reader's own selection only when it carries weight in the answer.

    Prose: plain, warm and direct, written for a smart reader who may be new to the field. Use short paragraphs of \
    one to three sentences that lead into each quote and say what it shows. Explain jargon in plain words the first \
    time it appears. Use **bold** rarely. Don't restate the question.

    Instruments: when the question is about how a quantity changes (a trend, a trade-off, a scaling curve) and the \
    paper reports the numbers, you may add one small interactive chart. Give short x labels, one or more series with \
    units, and the x index to show first; the reader drags a slider along x. Use only numbers the paper states or \
    that can be read directly off its tables and figures, and don't invent values to fill gaps. Put a heading block \
    right before it (title plus a one-line subtitle saying what it shows). Most answers don't need one.

    Keep the whole answer readable in under a minute: usually three to six prose blocks plus the quotes. The title \
    is the reader's question as a short heading, in their words.
    """

    static func system(paperTitle: String, paperText: String) -> [[String: Any]] {
        [
            ["type": "text", "text": instructions],
            [
                "type": "text",
                "text": "<paper title=\"\(paperTitle)\">\n\(paperText)\n</paper>",
                "cache_control": ["type": "ephemeral"],
            ],
        ]
    }

    static func user(
        mode: ComposeMode,
        question: String,
        passages: [Passage],
        thread: PaperThread?
    ) -> String {
        var parts: [String] = []

        if !passages.isEmpty {
            let list = passages.enumerated().map { i, p in
                "[\(i + 1)] (page \(p.span.page + 1)) \"\(p.text)\""
            }.joined(separator: "\n")
            parts.append("<selected_passages>\n\(list)\n</selected_passages>")
        } else {
            parts.append("<selected_passages>None. The question is about the paper as a whole.</selected_passages>")
        }

        if let thread, let current = thread.current, mode != .compose {
            let earlier = thread.versions.map { "- \($0.question)" }.joined(separator: "\n")
            parts.append("<questions_so_far>\n\(earlier)\n</questions_so_far>")
            parts.append("<current_answer title=\"\(current.title)\">\n\(render(current))\n</current_answer>")
        }

        let task: String
        switch mode {
        case .compose:
            task = "Compose an answer to the reader's question."
        case .extend:
            task = """
            The reader is following up on the current answer. Write only the new blocks to add after it; don't \
            repeat what it already says. The title should be the follow-up question as a short heading.
            """
        case .rewrite:
            task = "Write a new, complete version of the current answer that follows the reader's instruction."
        case .branch:
            task = """
            The reader added a new passage to this thread (the last one listed). Write a new, complete version of the \
            answer that takes it into account while still answering the original question.
            """
        }
        parts.append("<task>\(task)</task>")
        parts.append("<question>\(question)</question>")
        return parts.joined(separator: "\n\n")
    }

    /// The current answer as plain text, so Claude can extend or rewrite it.
    static func render(_ version: AnswerVersion) -> String {
        version.blocks.map { b in
            switch b.kind {
            case .prose: return b.text
            case .heading: return "## \(b.text)\n\(b.subtitle ?? "")"
            case .quote: return "> \"\(b.text)\" (page \((b.span?.page ?? 0) + 1), \(b.location ?? ""))"
            case .instrument:
                guard let i = b.instrument else { return "" }
                let s = i.series.map { "\($0.name) (\($0.unit)): \($0.values.map { String($0) }.joined(separator: ", "))" }
                return "[Chart over \(i.xLabel): \(i.xValues.joined(separator: ", ")); \(s.joined(separator: "; "))]"
            }
        }.joined(separator: "\n\n")
    }
}
