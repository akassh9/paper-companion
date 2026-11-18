import SwiftUI
import PDFKit

/// Owns the PDFView: highlights, selection tracking, and reporting where highlighted spans are on screen.
@MainActor
final class PDFController: NSObject {
    weak var model: AppModel?
    private(set) var pdfView: PDFView?
    private var applied: [HighlightSpec] = []
    private var annotations: [PDFAnnotation] = []
    private var ignoreSelection = false

    func attach(_ view: PDFView) {
        pdfView = view
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(selectionChanged), name: .PDFViewSelectionChanged, object: view)
        nc.addObserver(self, selector: #selector(layoutChanged), name: .PDFViewScaleChanged, object: view)
        nc.addObserver(self, selector: #selector(layoutChanged), name: .PDFViewPageChanged, object: view)
        nc.addObserver(self, selector: #selector(layoutChanged), name: .PDFViewDisplayModeChanged, object: view)
        view.postsFrameChangedNotifications = true
        nc.addObserver(self, selector: #selector(layoutChanged), name: NSView.frameDidChangeNotification, object: view)
    }

    /// Watch the scroll view once PDFKit has built it.
    func observeScrolling() {
        guard let clip = pdfView?.documentView?.enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(layoutChanged),
                                               name: NSView.boundsDidChangeNotification, object: clip)
        pdfView?.documentView?.enclosingScrollView?.drawsBackground = false
    }

    func setDocument(_ doc: PDFDocument?) {
        guard let pdfView, pdfView.document !== doc else { return }
        annotations = []
        applied = []
        pdfView.document = doc
        DispatchQueue.main.async { [weak self] in
            self?.observeScrolling()
            self?.layoutChanged()
        }
    }

    // MARK: Highlights

    func apply(_ specs: [HighlightSpec]) {
        guard specs != applied, let doc = pdfView?.document else { return }
        for a in annotations { a.page?.removeAnnotation(a) }
        annotations = []
        for spec in specs {
            guard let page = doc.page(at: spec.span.page), let sel = page.selection(for: spec.span.range) else { continue }
            let color = spec.muted
                ? NSColor(white: 0.5, alpha: 0.16)
                : SourcePalette.nsColor(spec.colorIndex, alpha: 0.32)
            for line in sel.selectionsByLine() {
                let r = line.bounds(for: page)
                guard r.width > 0.5 else { continue }
                let a = PDFAnnotation(bounds: r.insetBy(dx: -0.8, dy: -0.4), forType: .highlight, withProperties: nil)
                a.color = color
                a.userName = "paper-companion"
                page.addAnnotation(a)
                annotations.append(a)
            }
        }
        applied = specs
        layoutChanged()
    }

    // MARK: Geometry for beams

    @objc func layoutChanged() {
        guard let pdfView, let doc = pdfView.document, let model else { return }
        var rects: [UUID: CGRect] = [:]
        var edges: [UUID: CGFloat] = [:]
        let h = pdfView.bounds.height
        for spec in applied where !spec.muted {
            guard let page = doc.page(at: spec.span.page), let sel = page.selection(for: spec.span.range) else { continue }
            let r = pdfView.convert(sel.bounds(for: page), from: page)
            let pageRect = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page)
            let flipped = pdfView.isFlipped ? r : CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
            rects[spec.id] = flipped
            edges[spec.id] = pageRect.maxX
        }
        if rects != model.geometry.sourceRects { model.geometry.sourceRects = rects }
        if edges != model.geometry.sourcePageEdge { model.geometry.sourcePageEdge = edges }
    }

    // MARK: Selection

    @objc func selectionChanged() {
        guard !ignoreSelection, let pdfView, let model else { return }
        guard let sel = pdfView.currentSelection,
              let page = sel.pages.first,
              let doc = pdfView.document,
              let text = sel.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.count >= 3
        else {
            model.selectionChanged(nil)
            return
        }
        let range = sel.range(at: 0, on: page)
        guard range.location != NSNotFound, range.length > 0 else { model.selectionChanged(nil); return }
        let span = SpanRef(page: doc.index(for: page), location: range.location, length: range.length)
        let clean = PaperIndex.normalize(page.selection(for: range)?.string ?? text).normalized as String
        model.selectionChanged(LiveSelection(span: span, text: clean))
    }

    func clearSelection() {
        ignoreSelection = true
        pdfView?.clearSelection()
        ignoreSelection = false
    }

    /// Select text the way a reader would (used by the `--select` test flag).
    func select(text: String) {
        guard let pdfView, let doc = pdfView.document, let model, let index = model.index,
              let span = index.locate(text, preferredPage: nil),
              let page = doc.page(at: span.page), let sel = page.selection(for: span.range) else { return }
        pdfView.setCurrentSelection(sel, animate: false)
        selectionChanged()
    }

    /// Scroll the paper to a span and flash it.
    func reveal(_ span: SpanRef) {
        guard let pdfView, let page = pdfView.document?.page(at: span.page), let sel = page.selection(for: span.range) else { return }
        let r = sel.bounds(for: page)
        pdfView.go(to: CGRect(x: r.minX, y: r.maxY + 120, width: 1, height: 1), on: page)
        ignoreSelection = true
        pdfView.setCurrentSelection(sel, animate: true)
        ignoreSelection = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.clearSelection()
            self?.layoutChanged()
        }
    }
}

/// SwiftUI wrapper for the PDFView. Pages float as paper on the dark space.
struct PDFPane: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.backgroundColor = .clear
        view.pageShadowsEnabled = true
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 18, left: 0, bottom: 18, right: 0)
        model.pdf.attach(view)
        model.pdf.setDocument(model.document)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        model.pdf.setDocument(model.document)
        model.pdf.apply(model.highlightSpecs)
    }
}
