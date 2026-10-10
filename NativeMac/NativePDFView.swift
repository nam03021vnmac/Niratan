import AppKit
import PDFKit
import SwiftUI

struct NativePDFView: NSViewRepresentable {
    let model: PDFReaderViewModel
    let userConfig: UserConfig
    func makeNSView(context: Context) -> NativePDFSurface {
        let view = NativePDFSurface(model: model, userConfig: userConfig)
        model.surface = view
        return view
    }
    func updateNSView(_ view: NativePDFSurface, context: Context) {
        if view.pdf.document !== model.document { view.installDocument() }
        view.highlight.needsDisplay = true
    }
    static func dismantleNSView(_ view: NativePDFSurface, coordinator: ()) { view.detach() }
}

@MainActor
final class NativePDFSurface: NSView, NSGestureRecognizerDelegate {
    let pdf = PDFView()
    let highlight = PDFLookupHighlightView()
    weak var model: PDFReaderViewModel?
    private let userConfig: UserConfig
    private var observers: [NSObjectProtocol] = []
    private var clipObservers: [NSObjectProtocol] = []
    private var clipIdentities: [ObjectIdentifier] = []
    private var restoring = false
    private var layoutGeneration = UUID()
    private var lastGeometry: (page: Int, position: CGPoint, scale: CGFloat, size: CGSize, visible: [Int])?
    private var applyingSettings = false
    private var expectedFitScale: CGFloat?
    // Sample inside the visible page rather than the inter-page gap. Restore
    // this same sample point; it is not padding added to PDF content.
    private let progressAnchorInset: CGFloat = 40
    override var isFlipped: Bool { true }

    init(model: PDFReaderViewModel, userConfig: UserConfig) {
        self.model = model; self.userConfig = userConfig
        super.init(frame: .zero)
        addSubview(pdf); addSubview(highlight)
        highlight.surface = self
        pdf.backgroundColor = .windowBackgroundColor
        pdf.displayDirection = .vertical
        let click = PDFLookupClickRecognizer(target: self, action: #selector(clicked(_:)))
        click.onPointerDown = { [weak self] in self?.model?.dismissLookup() }
        click.hasNativeSelection = { [weak self] in !(self?.pdf.currentSelection?.string ?? "").isEmpty }
        click.delaysPrimaryMouseButtonEvents = false
        click.delegate = self
        pdf.addGestureRecognizer(click)
        let secondary = NSClickGestureRecognizer(target: self, action: #selector(secondaryClick(_:)))
        secondary.buttonMask = 0x2
        secondary.delaysSecondaryMouseButtonEvents = false
        secondary.delegate = self
        pdf.addGestureRecognizer(secondary)
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged, .PDFViewDisplayModeChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: pdf, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.geometryChanged() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: pdf, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.restoring, !self.applyingSettings, !self.pdf.autoScales else { return }
                if let expected = self.expectedFitScale, self.model?.item.zoomScale == nil,
                   Swift.abs(expected - self.pdf.scaleFactor) < 0.00001 { return }
                self.expectedFitScale = nil
                self.model?.item.zoomScale = Double(self.pdf.scaleFactor)
            }
        })
        installDocument()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let resized = pdf.frame != bounds
        pdf.frame = bounds; highlight.frame = bounds
        if resized {
            // PDFKit's clip bounds otherwise still describe the previous
            // window/toolbar size while the parent is in its layout pass.
            pdf.layoutSubtreeIfNeeded()
            if model?.item.zoomScale == nil { applySettings() }
            geometryChanged()
        }
        installClipObservers()
    }

    func installDocument() {
        guard let model else { return }
        restoring = true
        layoutGeneration = UUID()
        lastGeometry = nil
        let generation = layoutGeneration
        pdf.document = model.document
        applySettings()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.layoutGeneration == generation, let model = self.model,
                  let page = self.pdf.document?.page(at: model.item.pageIndex) else { return }
            let crop = page.bounds(for: .cropBox)
            let point = CGPoint(x: crop.minX + model.item.position.x * crop.width, y: crop.minY + model.item.position.y * crop.height)
            self.pdf.go(to: page)
            if let documentView = self.pdf.documentView, let scroll = documentView.enclosingScrollView {
                // PDFDestination scrolling can retain an old clip origin when
                // PDFKit auto-scales an image page. Convert the stored point
                // through PDFKit and restore the actual native clip instead.
                let target = documentView.convert(self.pdf.convert(point, from: page), from: self.pdf)
                let visible = scroll.contentView.bounds
                let origin = PDFTextGeometry.clipOrigin(target: target, viewport: visible.size,
                                                       flipped: documentView.isFlipped, anchorInset: self.progressAnchorInset)
                let constrained = scroll.contentView.constrainBoundsRect(CGRect(origin: origin, size: visible.size))
                scroll.contentView.scroll(to: constrained.origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            self.restoring = false
            self.installClipObservers()
            self.geometryChanged()
        }
    }

    func applySettings() {
        guard let model else { return }
        applyingSettings = true
        defer { applyingSettings = false }
        pdf.displayMode = model.item.continuous ? .singlePageContinuous : .singlePage
        pdf.autoScales = false
        if let scale = model.item.zoomScale, scale.isFinite {
            expectedFitScale = nil
            pdf.scaleFactor = max(0.1, min(8, scale))
        } else if let page = pdf.currentPage ?? pdf.document?.page(at: model.item.pageIndex) {
            let crop = page.bounds(for: .cropBox)
            let rotated = abs(page.rotation % 180) == 90
            let size = CGSize(width: rotated ? crop.height : crop.width, height: rotated ? crop.width : crop.height)
            let viewport = pdf.documentView?.enclosingScrollView?.contentView.bounds.size ?? bounds.size
            let margins = pdf.pageBreakMargins
            let available = CGSize(width: viewport.width - margins.left - margins.right,
                                   height: viewport.height - margins.top - margins.bottom)
            if let scale = PDFTextGeometry.fittedScale(pageSize: size, viewport: available, fitWidth: model.item.fitWidth) {
                expectedFitScale = CGFloat(scale)
                pdf.scaleFactor = scale
                expectedFitScale = pdf.scaleFactor
            }
        }
    }
    func go(to index: Int) {
        guard let page = pdf.document?.page(at: max(0, min(index, (pdf.document?.pageCount ?? 1) - 1))) else { return }
        model?.dismissLookup(); pdf.go(to: page); geometryChanged()
    }
    func zoom(_ factor: Double) {
        expectedFitScale = nil
        model?.dismissLookup(); pdf.autoScales = false
        let scale = max(0.1, min(8, pdf.scaleFactor * factor))
        model?.item.zoomScale = Double(scale)
        pdf.scaleFactor = scale
    }

    private func installClipObservers() {
        func clips(_ view: NSView) -> [NSClipView] { (view as? NSClipView).map { [$0] } ?? view.subviews.flatMap(clips) }
        let current = clips(pdf)
        let identities = current.map(ObjectIdentifier.init)
        guard identities != clipIdentities else { return }
        for observer in clipObservers { NotificationCenter.default.removeObserver(observer) }
        clipObservers = []; clipIdentities = identities
        for clip in current {
            clip.postsBoundsChangedNotifications = true
            clipObservers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.geometryChanged() }
            })
        }
    }

    private func viewportState() -> (index: Int, position: CGPoint, visible: [Int])? {
        guard !restoring, let document = pdf.document else { return nil }
        let inset = min(progressAnchorInset, pdf.bounds.height / 2)
        let viewPoint = CGPoint(x: pdf.bounds.midX, y: pdf.isFlipped ? pdf.bounds.minY + inset : pdf.bounds.maxY - inset)
        guard let page = pdf.page(for: viewPoint, nearest: true) ?? pdf.currentPage else { return nil }
        let point = pdf.convert(viewPoint, to: page)
        let crop = page.bounds(for: .cropBox)
        guard crop.width > 0, crop.height > 0 else { return nil }
        let normalized = CGPoint(x: max(0, min(1, (point.x - crop.minX) / crop.width)), y: max(0, min(1, (point.y - crop.minY) / crop.height)))
        let index = document.index(for: page)
        let visibleIndices = pdf.visiblePages.map { document.index(for: $0) }
        return (index, normalized, visibleIndices)
    }

    /// Closing/termination can precede the queued SwiftUI geometry callback.
    /// Persist the live native viewport synchronously, without starting OCR.
    func flushProgress() {
        guard let state = viewportState() else { return }
        model?.captureFinalPosition(state.index, position: state.position)
        if model?.item.zoomScale != nil { model?.item.zoomScale = Double(pdf.scaleFactor) }
    }

    private func geometryChanged() {
        guard let model, let state = viewportState() else { return }
        highlight.needsDisplay = true
        let index = state.index, normalized = state.position, visibleIndices = state.visible
        if let previous = lastGeometry, previous.page == index,
           Swift.abs(previous.position.x - normalized.x) < 0.00001,
           Swift.abs(previous.position.y - normalized.y) < 0.00001,
           previous.scale == pdf.scaleFactor, previous.size == bounds.size, previous.visible == visibleIndices { return }
        lastGeometry = (index, normalized, pdf.scaleFactor, bounds.size, visibleIndices)
        // PDFKit notifications can happen while SwiftUI updates the bridge.
        DispatchQueue.main.async { [weak self, weak model] in
            guard self?.model === model, self?.restoring == false else { return }
            model?.dismissLookup()
            model?.visiblePage(index, position: normalized, visibleIndices: visibleIndices)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool { true }

    /// Look up on mouse-up without waiting out the double-click interval. The
    /// popup opens beside the word, so a second click still reaches PDFKit;
    /// its mouse-down dismisses the popup and native word/line selection
    /// proceeds as usual.
    @objc private func clicked(_ gesture: PDFLookupClickRecognizer) {
        guard window?.isKeyWindow == true else { return }
        performLookup(at: pdf.convert(gesture.clickLocationInWindow, from: nil))
    }

    private func performLookup(at point: CGPoint) {
        guard let model, (pdf.currentSelection?.string ?? "").isEmpty else { return }
        guard let page = pdf.page(for: point, nearest: false), let document = pdf.document else { model.dismissLookup(); return }
        let local = pdf.convert(point, to: page)
        // Leave links and interactive annotations to PDFKit.
        if page.annotations.contains(where: { $0.bounds.contains(local) && ($0.type == "Link" || $0.type == "Widget") }) { return }
        pdf.clearSelection()
        model.lookup(page: document.index(for: page), point: local, anchor: { [self] rect in convert(pdf.convert(rect, from: page), from: pdf) }, userConfig: userConfig)
        highlight.needsDisplay = true
    }

    @objc private func secondaryClick(_ gesture: NSClickGestureRecognizer) {
        guard let model, let page = pdf.page(for: gesture.location(in: pdf), nearest: false), let document = pdf.document,
              let text = model.recognizedText(page: document.index(for: page), point: pdf.convert(gesture.location(in: pdf), to: page)) else { return }
        let menu = NSMenu()
        let item = NSMenuItem(title: String(localized: "Copy Recognized Text"), action: #selector(copyRecognized(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = text; menu.addItem(item)
        menu.popUp(positioning: nil, at: gesture.location(in: self), in: self)
    }
    @objc private func copyRecognized(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    func detach() {
        for token in observers + clipObservers { NotificationCenter.default.removeObserver(token) }
        observers = []; clipObservers = []; clipIdentities = []; pdf.document = nil; model = nil
    }
}

@MainActor
final class PDFLookupHighlightView: NSView {
    weak var surface: NativePDFSurface?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let surface, let model = surface.model, let page = surface.pdf.document?.page(at: model.highlightPage) else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
        for rect in model.highlightRects {
            let converted = convert(surface.pdf.convert(rect, from: page), from: surface.pdf)
            NSBezierPath(rect: converted).fill()
        }
    }
}
