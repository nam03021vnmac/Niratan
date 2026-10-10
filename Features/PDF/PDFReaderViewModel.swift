import AppKit
import Observation
import PDFKit

@Observable @MainActor
final class PDFReaderViewModel {
    let sessionID = UUID()
    var item: PDFLibraryItem
    var document: PDFDocument?
    var isLoading = true
    var needsPassword = false
    var errorMessage: String?
    var status: String?
    var isRecognizing = false
    var popupPresentation = PopupPresentationCoordinator()
    private(set) var lookupProfileID: String?
    var highlightPage = 0
    var highlightRects: [CGRect] = []
    @ObservationIgnored weak var surface: NativePDFSurface?
    @ObservationIgnored private var worker: PDFDocumentWorker?
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var accessing = false
    @ObservationIgnored private var pages: [Int: PDFPageText] = [:]
    @ObservationIgnored private var visiblePages: [Int] = []
    @ObservationIgnored private var completedOCR = Set<Int>()
    @ObservationIgnored private var textTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var closed = false

    init(item: PDFLibraryItem) {
        self.item = item
        PDFLibraryStore.shared.claim(item.id, session: sessionID)
    }

    func open(password: String? = nil) {
        guard !closed else { return }
        PopupWebViewPool.prewarm()
        loadTask?.cancel()
        isLoading = true; errorMessage = nil; needsPassword = false
        loadTask = Task {
            do {
                if url == nil {
                    let source = try PDFLibraryStore.shared.resolve(item)
                    url = source
                    accessing = source.startAccessingSecurityScopedResource()
                    worker = PDFDocumentWorker(url: source, lineOCR: { try await PDFPaddleOCREngine.current() })
                }
                guard let worker, let url else { throw PDFSupportError.unreadable }
                let metadata = try await worker.prepare(password: password)
                try Task.checkCancellation()
                guard !closed, let pdf = PDFDocument(url: url) else { throw PDFSupportError.unreadable }
                if pdf.isLocked, !pdf.unlock(withPassword: password ?? "") { throw PDFSupportError.locked }
                item.pageCount = metadata.count
                item.pageIndex = max(0, min(item.pageIndex, max(0, metadata.count - 1)))
                item.lastOpened = Date()
                document = pdf; isLoading = false
                save()
                loadText(page: item.pageIndex)
            } catch is CancellationError { }
            catch PDFSupportError.locked {
                isLoading = false; needsPassword = true
                if password != nil { errorMessage = String(localized: "Incorrect PDF password. Try again.") }
            }
            catch { isLoading = false; errorMessage = error.localizedDescription }
        }
    }

    func visiblePage(_ index: Int, position: CGPoint, visibleIndices: [Int]) {
        guard !closed, document != nil, index >= 0, index < item.pageCount else { return }
        let changed = item.pageIndex != index
        item.pageIndex = index; item.position = position
        let plan = PDFPageTextSchedulingPolicy.plan(currentPage: index, visiblePages: visibleIndices, pageCount: item.pageCount)
        let viewportChanged = plan != visiblePages
        visiblePages = plan
        if changed || viewportChanged { dismissLookup(); loadText(page: index) }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    func captureFinalPosition(_ index: Int, position: CGPoint) {
        guard !closed, document != nil, index >= 0, index < item.pageCount else { return }
        item.pageIndex = index
        item.position = position
    }

    func loadText(page: Int, forceOCR: Bool = false) {
        guard let worker, !closed else { return }
        let plan = PDFPageTextSchedulingPolicy.plan(currentPage: page, visiblePages: visiblePages, pageCount: item.pageCount)
        let pending = plan.filter { pages[$0] == nil || (item.automaticOCR && PDFTextGeometry.needsOCR(pages[$0]?.native ?? []) && !completedOCR.contains($0)) || (forceOCR && $0 == page) }
        let old = textTask
        old?.cancel()
        isRecognizing = false
        requestID = UUID()
        let request = requestID
        guard !pending.isEmpty else {
            textTask = nil
            return
        }
        textTask = Task {
            // A cancelled Vision call may still run internally. Wait for it
            // before starting another raster/request, keeping memory bounded.
            await old?.value
            guard !Task.isCancelled else { return }
            do {
                try await Task.sleep(for: .milliseconds(200))
                let retained = Set(plan)
                pages = pages.filter { retained.contains($0.key) }
                completedOCR.formIntersection(retained)
                var finalStatus: String?
                for index in pending {
                    let native: [PDFTextBlock]
                    if let ready = pages[index] { native = ready.native }
                    else { native = try await worker.embeddedText(page: index) }
                    try Task.checkCancellation()
                    guard requestID == request, !closed else { return }
                    var text = pages[index] ?? PDFPageText()
                    text.native = native
                    pages[index] = text
                    let manual = forceOCR && index == page
                    if manual || (item.automaticOCR && PDFTextGeometry.needsOCR(native) && !completedOCR.contains(index)) {
                        isRecognizing = true
                        status = String(localized: "Recognizing Japanese text…")
                        let recognized = try await worker.recognize(page: index, useCache: !manual)
                        try Task.checkCancellation()
                        guard requestID == request, !closed else { return }
                        pages[index]?.recognized = recognized
                        completedOCR.insert(index)
                        if index == page {
                            finalStatus = recognized.isEmpty ? String(localized: "No text found.") : String(localized: "Japanese text is ready. Click a word to look it up.")
                        }
                    }
                }
                isRecognizing = false
                status = finalStatus
            } catch is CancellationError { }
            catch {
                guard requestID == request, !closed else { return }
                isRecognizing = false; status = error.localizedDescription
            }
        }
    }

    /// The OCR engine or its models changed: drop recognized text so visible
    /// pages are read again with the current engine.
    func engineChanged() {
        guard !closed, document != nil else { return }
        for key in pages.keys { pages[key]?.recognized = [] }
        completedOCR.removeAll()
        loadText(page: item.pageIndex)
    }

    func cancelRecognition() {
        requestID = UUID(); textTask?.cancel(); isRecognizing = false
        status = String(localized: "Text recognition cancelled.")
    }

    func lookup(page: Int, point: CGPoint, anchor: (CGRect) -> CGRect, userConfig: UserConfig) {
        guard !closed else { return }
        dismissLookup()
        if pages[page] == nil {
            loadText(page: page)
            status = String(localized: "Preparing PDF text… Click the word again when ready.")
            return
        }
        guard let hit = pages[page]?.hit(at: point) else { return }
        guard LookupEngine.shared.isReadyForLookup, DictionaryManager.shared.termDictionaries.contains(where: \.isEnabled) else {
            status = String(localized: "The dictionary is not ready. Enable a dictionary in Settings.")
            return
        }
        let profile = ProfileRepository.shared.activeProfile
        guard let candidate = PDFLookupSelectionResolver.candidate(block: hit.block, span: hit.span,
                                                                  scanLength: userConfig.scanLength, language: profile.language) else { return }
        let selection = SelectionData(text: candidate.text, sentence: hit.block.text, rect: anchor(hit.span.rect),
                                      normalizedOffset: candidate.utf16Start,
                                      miningContext: .text(hit.block.text, targetUTF16Location: candidate.utf16Start))
        lookupProfileID = profile.id
        if let count = popupPresentation.present(selection: selection, userConfig: userConfig, replacingExisting: true, isVertical: hit.block.vertical) {
            if let range = PDFLookupSelectionResolver.matchRange(candidate: candidate, characterCount: count) {
                highlightPage = page; highlightRects = hit.block.rectangles(for: range)
            }
            status = nil
        } else {
            status = String(localized: "No dictionary result found.")
        }
    }

    func recognizedText(page: Int, point: CGPoint) -> String? {
        pages[page]?.recognized.first(where: { $0.hit(at: point) != nil })?.text
    }

    func dismissLookup() {
        popupPresentation.popups.removeAll()
        highlightRects = []; lookupProfileID = nil
        surface?.highlight.setNeedsDisplay(surface?.highlight.bounds ?? .zero)
    }

    func navigate(_ delta: Int) { surface?.go(to: item.pageIndex + delta) }
    func zoom(_ factor: Double) { surface?.zoom(factor); save() }
    func applyLayout() { dismissLookup(); surface?.applySettings(); save() }
    func save() {
        do { try PDFLibraryStore.shared.save(item, session: sessionID) }
        catch { errorMessage = error.localizedDescription; status = error.localizedDescription }
    }
    func flushAndSave() { surface?.flushProgress(); save() }

    func close() {
        guard !closed else { return }
        flushAndSave(); closed = true
        loadTask?.cancel(); textTask?.cancel(); saveTask?.cancel(); requestID = UUID()
        dismissLookup(); surface = nil; document = nil
        // The worker retains its own read lease until its last task finishes.
        worker = nil
        if accessing, let url { url.stopAccessingSecurityScopedResource() }
        accessing = false; url = nil
    }
}
