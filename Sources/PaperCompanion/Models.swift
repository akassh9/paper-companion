import Foundation
import SwiftUI

/// A run of characters on one PDF page, in the page's own text (`PDFPage.string`, UTF-16 offsets).
struct SpanRef: Codable, Hashable {
    var page: Int          // zero-based page index
    var location: Int
    var length: Int

    var range: NSRange { NSRange(location: location, length: length) }

    func overlaps(_ other: SpanRef) -> Bool {
        page == other.page && NSIntersectionRange(range, other.range).length > 0
    }
}

/// A passage the reader highlighted to start or grow a thread.
struct Passage: Codable, Identifiable, Hashable {
    var id = UUID()
    var span: SpanRef
    var text: String
    var colorIndex: Int
}

/// One series in an instrument chart.
struct InstrumentSeries: Codable, Hashable {
    var name: String
    var unit: String
    var values: [Double]
}

/// A small live chart the AI builds when prose is the wrong shape.
struct Instrument: Codable, Hashable {
    var xLabel: String
    var xValues: [String]
    var series: [InstrumentSeries]
    var startIndex: Int
}

/// A chart Claude draws for the question: a scatter, lines, or bars, built from the paper or computed from it.
struct FigureSpec: Codable, Hashable {
    enum Basis: String, Codable { case paper, computed, readOffFigure = "read_off_figure" }
    struct Point: Codable, Hashable { var x: Double; var y: Double; var label: String }
    struct Series: Codable, Hashable {
        enum Style: String, Codable { case points, line, dashed, bars }
        var name: String
        var style: Style
        var points: [Point]
    }
    var xLabel: String
    var yLabel: String
    var xCategories: [String]
    var series: [Series]
    var basis: Basis
    var source: String
    /// The code Claude ran for a computed figure, shown on request.
    var code: String?
}

/// One block of a composed answer.
struct AnswerBlock: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case prose, heading, quote, instrument, figure }

    var id = UUID()
    var kind: Kind
    var text: String = ""
    var subtitle: String? = nil
    // Quotes
    var span: SpanRef? = nil          // nil when the quote couldn't be found in the paper
    var location: String? = nil       // "Scaling With Context Length", "Figure 1 caption"
    var colorIndex: Int? = nil
    // Instruments
    var instrument: Instrument? = nil
    // Figures
    var figure: FigureSpec? = nil

    var isLinkedQuote: Bool { kind == .quote && span != nil }
}

enum ComposeMode: String, Codable, CaseIterable, Identifiable {
    case compose, extend, rewrite, branch
    var id: String { rawValue }

    var label: String {
        switch self {
        case .compose: "Compose"
        case .extend: "Extend"
        case .rewrite: "Rewrite"
        case .branch: "Branch"
        }
    }

    /// Plain-words explanation, shown as a tooltip.
    var help: String {
        switch self {
        case .compose: "Start a new answer about the selected passage"
        case .extend: "Add to the end of this answer"
        case .rewrite: "Write a new version of this answer"
        case .branch: "Add the selected passage to this answer and recompose it"
        }
    }
}

/// One version of an answer. Rewrites and branches add versions; earlier ones stack behind.
struct AnswerVersion: Codable, Identifiable, Hashable {
    var id = UUID()
    var question: String
    var mode: ComposeMode
    var title: String
    var blocks: [AnswerBlock]
    var createdAt = Date()
    /// Answers Claude writes as HTML. `blocks` then holds only its quotes, for beams and highlights.
    var html: String? = nil

    var quoteBlocks: [AnswerBlock] { blocks.filter(\.isLinkedQuote) }
    var sourceCount: Int { Set(quoteBlocks.compactMap(\.span)).count }
}

/// A thread: passages the reader gathered, plus the stack of answer versions.
struct PaperThread: Codable, Identifiable, Hashable {
    var id = UUID()
    var createdAt = Date()
    var passages: [Passage]
    var versions: [AnswerVersion]
    var currentVersion: Int

    var current: AnswerVersion? {
        versions.indices.contains(currentVersion) ? versions[currentVersion] : versions.last
    }
    var title: String { versions.first?.title ?? "Untitled" }
}

/// Everything saved for one PDF.
struct PaperArchive: Codable {
    var pdfPath: String
    var threads: [PaperThread]
    var openThreadID: UUID?
    var claims: ClaimsMap? = nil
    var links: [PaperLink]? = nil
}

/// Which Claude model answers (View ▸ Model).
enum AnswerModel: String, CaseIterable, Identifiable {
    /// Haiku answers; if it reaches for code, the question restarts on Sonnet.
    case automatic = "auto"
    case haiku = "claude-haiku-5-5"
    case sonnet = "claude-sonnet-5-5"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: "Automatic (Haiku, Sonnet for Analysis)"
        case .haiku: "Claude Haiku 5.5 (Fast)"
        case .sonnet: "Claude Sonnet 5.5 (Thorough)"
        }
    }
}

/// What sits behind the paper and the glass (View ▸ Backdrop).
enum Backdrop: String, CaseIterable, Identifiable {
    case frosted, dimmed, clear
    var id: String { rawValue }
    var label: String {
        switch self {
        case .frosted: "Frosted"
        case .dimmed: "Dimmed"
        case .clear: "Clear"
        }
    }
}

/// One hue per source. Matches the Figma palette (purple, yellow, teal, pink, ...).
enum SourcePalette {
    static let rgb: [(Double, Double, Double)] = [
        (175, 82, 222),   // purple
        (255, 204, 0),    // yellow
        (48, 176, 199),   // teal
        (255, 45, 85),    // pink
        (10, 132, 255),   // blue
        (52, 199, 89),    // green
        (255, 149, 0),    // orange
    ]

    static func color(_ index: Int) -> Color {
        let c = rgb[((index % rgb.count) + rgb.count) % rgb.count]
        return Color(red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255)
    }

    static func nsColor(_ index: Int, alpha: CGFloat) -> NSColor {
        let c = rgb[((index % rgb.count) + rgb.count) % rgb.count]
        return NSColor(srgbRed: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: alpha)
    }
}
