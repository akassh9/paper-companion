import SwiftUI
import PDFKit

/// Owns the PDFView: highlights, selection tracking, and reporting where highlighted spans are on screen.
@MainActor
final class PDFController: NSObject {
    weak var model: AppModel?
    private(set) var pdfView: PDFView?
    private var applied: [HighlightSpec] = []
    /// The annotations drawn for each highlight, so a change only touches the highlights that changed.
    private var drawn: [String: Drawn] = [:]
    /// One highlight as drawn: its annotations and its shape on the page, worked out once, so scrolling
    /// only has to convert positions.
    private struct Drawn { var spec: HighlightSpec; var annotations: [PDFAnnotation]; var rects: [CGRect]; var bounds: CGRect }
    /// Line rectangles (page coordinates) of each colored highlight, for hover hit-testing.
    private var hoverRects: [(id: UUID, page: Int, rects: [CGRect])] = []
    /// Where the paper should stay while its layout changes (a mode switch narrows or widens it).
    private var holding: (target: HoldTarget, until: Date)?
    private var restoring = false
    enum HoldTarget { case place(PDFDestination), span(SpanRef) }
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
        drawn = [:]
        applied = []
        pdfView.document = doc
        DispatchQueue.main.async { [weak self] in
            self?.observeScrolling()
            self?.layoutChanged()
        }
    }

    // MARK: Highlights

    /// Shows exactly these highlights. Only the ones that changed are removed or added, so hovering in
    /// Links mode or opening a new answer never redraws the whole paper.
    func apply(_ specs: [HighlightSpec]) {
        guard specs != applied, let doc = pdfView?.document else { return }
        func key(_ s: HighlightSpec) -> String {
            "\(s.id)|\(s.span.page)|\(s.span.location)|\(s.span.length)|\(s.colorIndex)|\(s.muted)|\(s.rgb.map { "\($0.r),\($0.g),\($0.b)" } ?? "")"
        }
        let wanted = Dictionary(specs.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
        for (k, d) in drawn where wanted[k] == nil {
            for a in d.annotations { a.page?.removeAnnotation(a) }
            drawn[k] = nil
        }
        for (k, spec) in wanted where drawn[k] == nil {
            guard let page = doc.page(at: spec.span.page), let sel = page.selection(for: spec.span.range) else { continue }
            let color = spec.muted
                ? NSColor(white: 0.5, alpha: 0.16)
                : spec.rgb.map { NSColor(srgbRed: $0.r / 255, green: $0.g / 255, blue: $0.b / 255, alpha: 0.32) }
                    ?? SourcePalette.nsColor(spec.colorIndex, alpha: 0.32)
            var made: [PDFAnnotation] = []
            var rects: [CGRect] = []
            for line in sel.selectionsByLine() {
                let r = line.bounds(for: page)
                guard r.width > 0.5 else { continue }
                rects.append(r)
                let a = PDFAnnotation(bounds: r.insetBy(dx: -0.8, dy: -0.4), forType: .highlight, withProperties: nil)
                a.color = color
                a.userName = "paper-companion"
                page.addAnnotation(a)
                made.append(a)
            }
            drawn[k] = Drawn(spec: spec, annotations: made, rects: rects, bounds: sel.bounds(for: page))
        }
        hoverRects = drawn.values.filter { !$0.spec.muted }.map { ($0.spec.id, $0.spec.span.page, $0.rects) }
        applied = specs
        layoutChanged()
    }

    /// Keeps the paper at this place (or span) while its width or layout changes, instead of letting it
    /// drift and jumping back afterwards.
    func hold(_ target: HoldTarget) {
        holding = (target, Date().addingTimeInterval(0.5))
        DispatchQueue.main.async { [weak self] in self?.restoreHeld() }
    }

    private func restoreHeld() {
        guard let held = holding, !restoring, let pdfView else { return }
        guard Date() < held.until else { holding = nil; return }
        restoring = true
        switch held.target {
        case .place(let d):
            pdfView.go(to: d)
        case .span(let span):
            if let page = pdfView.document?.page(at: span.page), let sel = page.selection(for: span.range) {
                let r = sel.bounds(for: page)
                pdfView.go(to: CGRect(x: r.minX, y: r.maxY + 160, width: 1, height: 1), on: page)
            }
        }
        restoring = false
    }

    // MARK: Geometry for beams

    @objc func layoutChanged() {
        restoreHeld()
        guard let pdfView, let doc = pdfView.document, let model else { return }
        var rects: [UUID: CGRect] = [:]
        var edges: [UUID: CGFloat] = [:]
        var pages: [UUID: CGRect] = [:]
        var firstLines: [UUID: CGRect] = [:]
        let h = pdfView.bounds.height
        func flip(_ r: CGRect) -> CGRect { pdfView.isFlipped ? r : CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height) }
        for d in drawn.values where !d.spec.muted {
            guard let page = doc.page(at: d.spec.span.page) else { continue }
            let id = d.spec.id
            let pageRect = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page)
            rects[id] = flip(pdfView.convert(d.bounds, from: page))
            edges[id] = pageRect.maxX
            pages[id] = flip(pageRect)
            if model.showingLinks, let line = d.rects.first { firstLines[id] = flip(pdfView.convert(line, from: page)) }
        }
        if pages != model.geometry.sourcePageFrames { model.geometry.sourcePageFrames = pages }
        if firstLines != model.geometry.sourceFirstLines { model.geometry.sourceFirstLines = firstLines }
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
    func go(to page: PDFPage) {
        pdfView?.go(to: page)
        layoutChanged()
    }

    /// A still of the paper as it looks right now, for dissolving between layouts.
    /// PDFKit draws pages in tiles that a view capture misses (it comes out blank), so the still is drawn
    /// from the visible pages themselves, highlights included, at screen resolution.
    func snapshot() -> NSImage? {
        guard let v = pdfView, v.bounds.width > 1, v.bounds.height > 1, !v.visiblePages.isEmpty else { return nil }
        let size = v.bounds.size
        let scale = v.window?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size
        let ctx = gc.cgContext
        ctx.scaleBy(x: scale, y: scale)
        for page in v.visiblePages {
            let r = v.convert(page.bounds(for: v.displayBox), from: page)
            let rect = v.isFlipped ? CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height) : r
            let box = page.bounds(for: v.displayBox)
            guard box.width > 0, box.height > 0 else { continue }
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 6, color: NSColor.black.withAlphaComponent(0.18).cgColor)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(rect)
            ctx.restoreGState()
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.translateBy(x: rect.minX, y: rect.minY)
            ctx.scaleBy(x: rect.width / box.width, y: rect.height / box.height)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: v.displayBox, to: ctx)
            ctx.restoreGState()
        }
        gc.flushGraphics()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// Scrolls the paper to a span without selecting it.
    func show(_ span: SpanRef) {
        guard let pdfView, let page = pdfView.document?.page(at: span.page), let sel = page.selection(for: span.range) else { return }
        let r = sel.bounds(for: page)
        pdfView.go(to: CGRect(x: r.minX, y: r.maxY + 160, width: 1, height: 1), on: page)
        layoutChanged()
    }

    /// Where the reader is, so it can be restored after the paper changes width.
    var place: PDFDestination? { pdfView?.currentDestination }
    func go(to place: PDFDestination) {
        pdfView?.go(to: place)
        layoutChanged()
    }

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
        // Links mode lays pages side by side, so passages on facing pages can be joined across the gap.
        let twoUp = model.showingLinks || model.showingWhatIf
        let mode: PDFDisplayMode = twoUp ? .twoUpContinuous : .singlePageContinuous
        if view.displayMode != mode {
            view.displayMode = mode
            view.displaysAsBook = false
            view.pageBreakMargins = model.showingLinks
                ? NSEdgeInsets(top: 18, left: 64, bottom: 18, right: 64)
                : twoUp ? NSEdgeInsets(top: 18, left: 22, bottom: 18, right: 22)
                : NSEdgeInsets(top: 18, left: 0, bottom: 18, right: 0)
            view.autoScales = true
            DispatchQueue.main.async { model.pdf.layoutChanged() }
        }
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
        MainActor.assumeIsolated {
            controller?.hover(event)
            controller?.linkHover(event)
        }
    }

    // In Links mode a drag draws a link instead of selecting text.
    private var drawingLink = false
    override func mouseDown(with event: NSEvent) {
        drawingLink = MainActor.assumeIsolated { controller?.linkMouseDown(event) ?? false }
        if !drawingLink { super.mouseDown(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
        if drawingLink { MainActor.assumeIsolated { controller?.linkMouseDragged(event) } } else { super.mouseDragged(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        if drawingLink { MainActor.assumeIsolated { controller?.linkMouseUp(event) }; drawingLink = false }
        else { super.mouseUp(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        MainActor.assumeIsolated { controller?.hover(event) }
    }
}
