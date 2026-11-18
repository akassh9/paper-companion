import Foundation
import PDFKit
import AppKit

/// Clean, searchable text for each page, with a map back to the PDF's own character offsets.
///
/// PDF text comes out with line-break hyphens, ligatures and odd whitespace. We normalize it once,
/// send the normalized text to Claude, and find Claude's quotes in the same normalized text. The map
/// turns a match back into a range of `PDFPage.string`, so the quote becomes a real PDF selection.
final class PaperIndex {
    struct Page {
        let normalized: NSString
        let map: [Int]        // normalized UTF-16 index -> original UTF-16 index
    }

    let pages: [Page]
    let bodyFontName: String
    let title: String

    init(document: PDFDocument, fallbackTitle: String) {
        var pages: [Page] = []
        for i in 0..<document.pageCount {
            let raw = document.page(at: i)?.string ?? ""
            pages.append(PaperIndex.normalize(raw))
        }
        self.pages = pages
        self.bodyFontName = PaperIndex.detectBodyFont(document)
        let metaTitle = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = (metaTitle?.isEmpty == false ? metaTitle! : fallbackTitle)
    }

    /// The whole paper as text with page markers, for the prompt.
    var promptText: String {
        pages.enumerated().map { "=== Page \($0.offset + 1) ===\n\($0.element.normalized as String)" }
            .joined(separator: "\n\n")
    }

    /// Normalized text of a span (for showing a selection or a found quote).
    func text(of span: SpanRef, in document: PDFDocument) -> String {
        guard let page = document.page(at: span.page),
              let sel = page.selection(for: span.range),
              let s = sel.string
        else { return "" }
        return PaperIndex.normalize(s).normalized as String
    }

    // MARK: Finding quotes

    /// Find `quote` in the paper, trying `preferredPage` (zero-based) first.
    func locate(_ quote: String, preferredPage: Int?) -> SpanRef? {
        let needle = PaperIndex.normalize(quote).normalized
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”'‘’…")))
        guard needle.count >= 4 else { return nil }

        var order = Array(pages.indices)
        if let p = preferredPage, pages.indices.contains(p) {
            order.removeAll { $0 == p }
            order.insert(p, at: 0)
        }
        // 1. Exact (case- and accent-insensitive) match.
        for i in order {
            let r = pages[i].normalized.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
            if r.location != NSNotFound { return span(page: i, normalizedRange: r) }
        }
        // 2. Without trailing punctuation.
        let trimmed = needle.trimmingCharacters(in: CharacterSet(charactersIn: ".,;: "))
        if trimmed != needle, trimmed.count >= 4 {
            for i in order {
                let r = pages[i].normalized.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive])
                if r.location != NSNotFound { return span(page: i, normalizedRange: r) }
            }
        }
        // 3. Anchor on the first and last few words (handles small differences in the middle).
        let words = needle.split(separator: " ")
        guard words.count >= 10 else { return nil }
        let head = words.prefix(6).joined(separator: " ")
        let tail = words.suffix(6).joined(separator: " ")
        for i in order {
            let text = pages[i].normalized
            let h = text.range(of: head, options: [.caseInsensitive, .diacriticInsensitive])
            guard h.location != NSNotFound else { continue }
            let searchFrom = NSRange(location: h.location, length: text.length - h.location)
            let t = text.range(of: tail, options: [.caseInsensitive, .diacriticInsensitive], range: searchFrom)
            guard t.location != NSNotFound else { continue }
            let length = NSMaxRange(t) - h.location
            if Double(length) < Double(needle.count) * 1.4 {
                return span(page: i, normalizedRange: NSRange(location: h.location, length: length))
            }
        }
        return nil
    }

    private func span(page: Int, normalizedRange r: NSRange) -> SpanRef {
        let map = pages[page].map
        let start = map[r.location]
        let end = map[NSMaxRange(r) - 1] + 1
        return SpanRef(page: page, location: start, length: max(1, end - start))
    }

    // MARK: Normalization

    static func normalize(_ raw: String) -> Page {
        let src = raw as NSString
        var out: [unichar] = []
        var map: [Int] = []
        out.reserveCapacity(src.length)
        map.reserveCapacity(src.length)

        let ligatures: [unichar: String] = [
            0xFB00: "ff", 0xFB01: "fi", 0xFB02: "fl", 0xFB03: "ffi", 0xFB04: "ffl", 0xFB05: "st", 0xFB06: "st",
        ]
        let replacements: [unichar: unichar] = [
            0x2018: 0x27, 0x2019: 0x27, 0x201C: 0x22, 0x201D: 0x22,   // curly quotes
            0x2013: 0x2D, 0x2014: 0x2D, 0x2212: 0x2D,                 // dashes, minus
            0x00A0: 0x20, 0x2009: 0x20, 0x202F: 0x20,                 // odd spaces
        ]

        func isSpace(_ c: unichar) -> Bool {
            c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0x00A0 || c == 0x2009 || c == 0x202F
        }
        func isLower(_ c: unichar) -> Bool { (0x61...0x7A).contains(c) }

        var i = 0
        let n = src.length
        while i < n {
            var c = src.character(at: i)

            // Soft hyphen: drop.
            if c == 0x00AD { i += 1; continue }

            // Line-break hyphenation: "exam-\nple" -> "example".
            if c == 0x2D, i + 1 < n {
                var j = i + 1
                var sawBreak = false
                while j < n, isSpace(src.character(at: j)) {
                    if src.character(at: j) == 0x0A || src.character(at: j) == 0x0D { sawBreak = true }
                    j += 1
                }
                if sawBreak, j < n, isLower(src.character(at: j)), let prev = out.last, (0x61...0x7A).contains(prev) {
                    i = j
                    continue
                }
            }

            if let lig = ligatures[c] {
                for u in lig.utf16 { out.append(u); map.append(i) }
                i += 1
                continue
            }
            if let r = replacements[c] { c = r }

            if isSpace(c) {
                if let last = out.last, last != 0x20 { out.append(0x20); map.append(i) }
                i += 1
                continue
            }
            out.append(c)
            map.append(i)
            i += 1
        }
        while out.last == 0x20 { out.removeLast(); map.removeLast() }
        let s = NSString(characters: out, length: out.count)
        return Page(normalized: s, map: map)
    }

    // MARK: Paper typeface

    /// The paper's typeface, read from the font names embedded in the PDF and mapped to a face installed on
    /// this Mac. Quotes are set in it so they read as the paper's own words.
    static func detectBodyFont(_ doc: PDFDocument) -> String {
        var names: [String] = []
        for i in 0..<min(doc.pageCount, 2) {
            guard let page = doc.page(at: i)?.pageRef, let dict = page.dictionary else { continue }
            var resources: CGPDFDictionaryRef?
            var fonts: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources,
                  CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fonts else { continue }
            CGPDFDictionaryApplyBlock(fonts, { _, value, _ in
                var fontDict: CGPDFDictionaryRef?
                var base: UnsafePointer<CChar>?
                if CGPDFObjectGetValue(value, .dictionary, &fontDict), let fontDict,
                   CGPDFDictionaryGetName(fontDict, "BaseFont", &base), let base {
                    var name = String(cString: base)
                    if let plus = name.firstIndex(of: "+") { name = String(name[name.index(after: plus)...]) }
                    names.append(name.lowercased())
                }
                return true
            }, nil)
        }
        let families: [(keys: [String], face: String)] = [
            (["times", "termes", "newtx", "nimbusrom", "stix", "tinos", "liberationserif"], "Times New Roman"),
            (["palatino", "pagella", "palladio", "mathpazo", "pplr"], "Palatino"),
            (["charter", "bitstreamcharter", "xcharter"], "Charter"),
            (["garamond", "ebgaramond"], "Garamond"),
            (["baskerville"], "Baskerville"),
            (["georgia"], "Georgia"),
            (["cmr", "lmroman", "computermodern", "sfrm", "cmu"], "Latin Modern Roman"),
            (["minion"], "Minion Pro"),
            (["helvetica", "arial", "nimbussans", "texgyreheros"], "Helvetica Neue"),
        ]
        for name in names {
            for f in families where f.keys.contains(where: { name.contains($0) }) {
                if NSFont(name: f.face, size: 12) != nil { return f.face }
                // Computer Modern isn't installed by default; New York is the closest built-in serif.
                if f.face == "Latin Modern Roman" { return "New York" }
            }
        }
        // Most papers are set in a Times-like face.
        return "Times New Roman"
    }
}
