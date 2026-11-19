import SwiftUI
import PDFKit

/// Owns the PDFView: highlights, selection tracking, and reporting where highlighted spans are on screen.
@MainActor
final class PDFController: NSObject {
    weak var model: AppModel?
    private(set) var pdfView: PDFView?
    private var applied: [HighlightSpec] = []
    private var annotations: [PDFAnnotation] = []
    /// Line rectangles (page coordinates) of each colored highlight, for hover hit-testing.
    private var hoverRects: [(id: UUID, page: Int, rects: [CGRect])] = []
    private var hoverFromPaper = false
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
        hoverRects = []
        for spec in specs {
            guard let page = doc.page(at: spec.span.page), let sel = page.selection(for: spec.span.range) else { continue }
            if !spec.muted {
                hoverRects.append((spec.id, spec.span.page, sel.selectionsByLine().map { $0.bounds(for: page) }))
            }
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

    /// The pointer moved over the paper: emphasize the beam of the highlight under it.
    func hover(_ event: NSEvent) {
        guard let pdfView, let model, let doc = pdfView.document else { return }
        let p = pdfView.convert(event.locationInWindow, from: nil)
        var found: UUID?
        if let page = pdfView.page(for: p, nearest: false) {
            let pp = pdfView.convert(p, to: page)
            let index = doc.index(for: page)
            found = hoverRects.first { $0.page == index && $0.rects.contains { $0.insetBy(dx: -2, dy: -2).contains(pp) } }?.id
        }
        if let found {
            if model.geometry.hoveredSource != found { model.geometry.hoveredSource = found }
            hoverFromPaper = true
        } else if hoverFromPaper {
            model.geometry.hoveredSource = nil
            hoverFromPaper = false
        }
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
        let view = HoverPDFView()
        view.controller = model.pdf
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

/// A PDFView that reports pointer movement, so hovering a highlight can light up its beam.
final class HoverPDFView: PDFView {
    weak var controller: PDFController?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        MainActor.assumeIsolated { controller?.hover(event) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        MainActor.assumeIsolated { controller?.hover(event) }
    }
}
