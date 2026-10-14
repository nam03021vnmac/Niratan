import AppKit
import SwiftUI

struct PDFReaderView: View {
    @Bindable var model: PDFReaderViewModel
    @Environment(UserConfig.self) private var userConfig
    @Environment(ShortcutManager.self) private var shortcutManager
    @State private var profileRepository = ProfileRepository.shared
    @State private var password = ""
    @State private var pageNumber = ""
    @State private var registration: UUID?
    @State private var models = MangaOCRModelManager.shared
    @AppStorage(PDFOCREngineChoice.defaultsKey) private var engineRaw = PDFOCREngineChoice.automatic.rawValue

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                content
                ForEach(model.popupPresentation.popups) { popup in
                    popupView(popup, size: proxy.size)
                }
                if let status = model.status, model.popupPresentation.popups.isEmpty {
                    Text(status).font(.callout).padding(12)
                        .glassEffect(.regular, in: .rect(cornerRadius: 12))
                        .padding(12).allowsHitTesting(false)
                }
            }
        }
        .toolbar { readerToolbar }
        .task { await models.refresh() }
        .onChange(of: models.revision) { model.engineChanged() }
        .onAppear {
            pageNumber = String(model.item.pageIndex + 1)
            registration = shortcutManager.register(scope: .pdf, handlers: [
                PDFShortcutActions.previous.id: { model.navigate(-1); return true },
                PDFShortcutActions.next.id: { model.navigate(1); return true },
                PDFShortcutActions.zoomIn.id: { model.zoom(1.2); return true },
                PDFShortcutActions.zoomOut.id: { model.zoom(1 / 1.2); return true },
                PDFShortcutActions.back.id: {
                    if !model.popupPresentation.popups.isEmpty { model.dismissLookup() }
                    else if let window = model.surface?.window {
                        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
                        else { window.performClose(nil) }
                    } else { PDFWindowPresenter.shared.closeWindow() }
                    return true
                },
            ])
            model.open()
        }
        .onDisappear { shortcutManager.unregister(registration) }
        .onChange(of: model.item.pageIndex) { pageNumber = String(model.item.pageIndex + 1) }
        .onChange(of: profileRepository.index.globalActiveProfileId) { model.dismissLookup() }
        .onChange(of: model.popupPresentation.popups.count) {
            if model.popupPresentation.popups.isEmpty { model.highlightRects = []; model.surface?.highlight.needsDisplay = true }
        }
    }

    @ViewBuilder private var content: some View {
        if model.needsPassword {
            VStack(spacing: 16) {
                Text("This PDF is locked. Enter its password to read it.")
                SecureField("PDF Password", text: $password).frame(width: 280).onSubmit(unlock)
                if let error = model.errorMessage { Text(error).foregroundStyle(.red).font(.callout) }
                Button("Unlock PDF", action: unlock).buttonStyle(.glassProminent)
                Button("Cancel", role: .cancel) { PDFWindowPresenter.shared.closeWindow() }.buttonStyle(.glass)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage, model.document == nil {
            ContentUnavailableView {
                Label("Unable to Open PDF", systemImage: "exclamationmark.triangle")
            } description: { Text(error) } actions: {
                Button("Retry") { model.open() }.buttonStyle(.glass)
            }
        } else if model.isLoading {
            ProgressView("Opening PDF…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            NativePDFView(model: model, userConfig: userConfig)
        }
    }
    private func unlock() { let value = password; password = ""; model.open(password: value) }

    @ToolbarContentBuilder private var readerToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Previous Page", systemImage: "chevron.left") { model.navigate(-1) }
                .disabled(model.document == nil || model.item.pageIndex == 0)
            TextField("Page", text: $pageNumber).frame(width: 48)
                .disabled(model.document == nil)
                .onSubmit {
                    if let value = Int(pageNumber) {
                        let page = max(1, min(value, model.item.pageCount))
                        pageNumber = String(page)
                        model.surface?.go(to: page - 1)
                    } else { pageNumber = String(model.item.pageIndex + 1) }
                }
            Text("/ \(model.item.pageCount)")
            Button("Next Page", systemImage: "chevron.right") { model.navigate(1) }
                .disabled(model.document == nil || model.item.pageIndex >= model.item.pageCount - 1)
        }
        ToolbarItemGroup {
            if let scan = model.documentScan {
                ProgressView(value: Double(scan.done), total: Double(max(scan.total, 1)))
                    .progressViewStyle(.circular).controlSize(.small)
                    .help("Recognized \(scan.done) of \(scan.total) pages")
            }
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { model.zoom(1 / 1.2) }
            Button("Zoom In", systemImage: "plus.magnifyingglass") { model.zoom(1.2) }
            Menu("PDF Display", systemImage: "rectangle.expand.vertical") {
                Toggle("Continuous", isOn: $model.item.continuous).onChange(of: model.item.continuous) { model.applyLayout() }
                Button("Fit Page") { model.item.fitWidth = false; model.item.zoomScale = nil; model.applyLayout() }
                Button("Fit Width") { model.item.fitWidth = true; model.item.zoomScale = nil; model.applyLayout() }
                Button("Full Screen") { model.surface?.window?.toggleFullScreen(nil) }
            }
            Menu("Japanese OCR", systemImage: "text.viewfinder") {
                Toggle("Automatic Japanese OCR", isOn: $model.item.automaticOCR)
                    .onChange(of: model.item.automaticOCR) {
                        if model.item.automaticOCR { model.loadText(page: model.item.pageIndex) }
                        else { model.cancelRecognition() }
                        model.save()
                    }
                Picker("OCR Engine", selection: $engineRaw) {
                    Text("Automatic").tag(PDFOCREngineChoice.automatic.rawValue)
                    Text("PP-OCR (on this Mac)").tag(PDFOCREngineChoice.paddle.rawValue)
                    Text("Apple Vision").tag(PDFOCREngineChoice.vision.rawValue)
                }
                .onChange(of: engineRaw) { model.engineChanged() }
                Toggle("Read as Manga", isOn: $model.item.isManga)
                    .onChange(of: model.item.isManga) { model.engineChanged(); model.save() }
                let modelSet = model.item.lineOCRModel.modelSet
                if models.statuses[modelSet]?.isReady != true {
                    if models.isDownloading(modelSet) {
                        Button("Cancel PP-OCR Download") { models.cancel(modelSet) }
                    } else {
                        let size = ByteCountFormatter.string(fromByteCount: modelSet.totalBytes, countStyle: .file)
                        if model.item.isManga {
                            Button("Download PP-OCR Manga Models (\(size))") { models.download(modelSet) }
                        } else {
                            Button("Download PP-OCR Models (\(size))") { models.download(modelSet) }
                        }
                    }
                    if let error = models.errors[modelSet] { Text(error) }
                }
                Button("Recognize This Page") { model.loadText(page: model.item.pageIndex, forceOCR: true) }
                    .disabled(model.document == nil || model.isRecognizing)
                if let scan = model.documentScan {
                    Button("Stop Recognizing All Pages (\(scan.done)/\(scan.total))") { model.stopRecognizingAllPages() }
                } else {
                    Button("Recognize All Pages") { model.recognizeAllPages() }
                        .disabled(!model.canRecognizeAllPages)
                }
                Button("Cancel Recognition") { model.cancelRecognition() }.disabled(!model.isRecognizing)
                Divider()
                Text("Text recognition runs on this Mac. Only Japanese OCR is supported.")
                Text("For scanned text with a selectable header, choose Recognize This Page.")
                Text("Read as Manga uses the manga-tuned PP-OCR recognizer for this PDF.")
            }
        }
    }

    private func popupView(_ popup: PopupItem, size: CGSize) -> some View {
        let id = popup.id
        let profileID = model.lookupProfileID
        return PopupView(userConfig: userConfig,
                         isVisible: Binding(get: { model.popupPresentation.popups.first(where: { $0.id == id })?.showPopup ?? false },
                                            set: { model.popupPresentation.setVisibility(id: id, visible: $0) }),
                         selectionData: popup.currentSelection, lookupResults: popup.lookupResults,
                         dictionaryStyles: popup.dictionaryStyles, screenSize: size,
                         isVertical: popup.isVertical, isFullWidth: false, centersOnSelection: true,
                         coverURL: PDFLibraryStore.shared.coverURL(model.item.id), documentTitle: model.item.title,
                         profileID: profileID, clearSelection: popup.clearSelection,
                         onTextSelected: { selection in
                             guard profileRepository.activeProfile.id == profileID,
                                   model.popupPresentation.popups.contains(where: { $0.id == id }) else { return nil }
                             model.popupPresentation.closeChildren(of: id)
                             return model.popupPresentation.present(selection: selection, userConfig: userConfig)
                         }, onTapOutside: { model.popupPresentation.handleTapInsidePopup(id: id) },
                         onSwipeDismiss: { model.popupPresentation.dismiss(id: id) },
                         miningContextProvider: { sentence, _ in
                             MiningContext(sentence: sentence, documentTitle: model.item.title,
                                           coverURL: PDFLibraryStore.shared.coverURL(model.item.id), profileID: profileID)
                         })
            .id(id)
    }
}
