import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct RichArticleEditor: NSViewRepresentable {
    @Environment(\.locale) private var locale
    @Environment(\.nativeAppPalette) private var appPalette
    @Environment(\.colorScheme) private var colorScheme
    private var webPalette: NativeAppPalette { NativeAppPalette(theme: appPalette.theme, colorScheme: colorScheme) }
    private var language: NativeAppLanguage { locale.identifier.hasPrefix("en") ? .english : .simplifiedChinese }

    @Binding var html: String
    let documentID: String
    var isEditable = true
    var fontSize: CGFloat = 18
    var store: LocalBlogStore? = nil
    var sourceRelativePath: String? = nil
    var onImportMedia: ((URL) async throws -> NativeMedia)? = nil
    var onMediaInserted: ((NativeMedia) -> Void)? = nil
    var onHeightChange: ((CGFloat) -> Void)? = nil
    var onOpenLink: ((URL) -> Void)? = nil
    var onSelectText: ((String) -> Void)? = nil
    var onOutlinePositions: (([CGFloat]) -> Void)? = nil

    static let pageHTML: String = {
        guard let url = Bundle.leonBookResources.url(forResource: "RichArticleEditor", withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        guard let scriptURL = Bundle.leonBookResources.url(forResource: "RichArticleInteractions", withExtension: "js"),
              let styleURL = Bundle.leonBookResources.url(forResource: "RichArticleInteractions", withExtension: "css"),
              let script = try? String(contentsOf: scriptURL, encoding: .utf8),
              let style = try? String(contentsOf: styleURL, encoding: .utf8) else { return "" }
        guard let caretScriptURL = Bundle.leonBookResources.url(forResource: "RichArticleCaret", withExtension: "js"),
              let caretStyleURL = Bundle.leonBookResources.url(forResource: "RichArticleCaret", withExtension: "css"),
              let caretScript = try? String(contentsOf: caretScriptURL, encoding: .utf8),
              let caretStyle = try? String(contentsOf: caretStyleURL, encoding: .utf8) else { return "" }
        guard let boardURL = Bundle.leonBookResources.url(forResource: "RichArticleWhiteboards", withExtension: "js"),
              let boardScript = try? String(contentsOf: boardURL, encoding: .utf8) else { return "" }
        guard let audioURL = Bundle.leonBookResources.url(forResource: "RichArticleAudio", withExtension: "js"),
              let audioScript = try? String(contentsOf: audioURL, encoding: .utf8) else { return "" }
        guard let columnsURL = Bundle.leonBookResources.url(forResource: "RichArticleColumns", withExtension: "js"),
              let columnsStyleURL = Bundle.leonBookResources.url(forResource: "RichArticleColumns", withExtension: "css"),
              let columnsScript = try? String(contentsOf: columnsURL, encoding: .utf8),
              let columnsStyle = try? String(contentsOf: columnsStyleURL, encoding: .utf8) else { return "" }
        return html.replacingOccurrences(of: "/* editor-interactions-script */", with: script)
            .replacingOccurrences(of: "/* editor-interactions-style */", with: style)
            .replacingOccurrences(of: "/* editor-columns-script */", with: columnsScript)
            .replacingOccurrences(of: "/* editor-columns-style */", with: columnsStyle)
            .replacingOccurrences(of: "/* editor-caret-script */", with: caretScript)
            .replacingOccurrences(of: "/* editor-caret-style */", with: caretStyle)
            .replacingOccurrences(of: "/* editor-whiteboards-script */", with: boardScript)
            .replacingOccurrences(of: "/* editor-audio-script */", with: audioScript)
    }()

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        NativeWebLocalization.install(on: configuration, language: language)
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "richArticle")
        let media = RichArticleMediaHandler(store: store, sourceRelativePath: sourceRelativePath)
        configuration.setURLSchemeHandler(media, forURLScheme: "leonmedia")
        context.coordinator.mediaHandler = media
        let view = NativeLoadingWebView(frame: .zero, configuration: configuration)
        view.waitsForContent = true
        view.beginContentLoading()
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(Self.pageHTML, baseURL: nil)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.mediaHandler?.store !== store {
            context.coordinator.mediaHandler?.cancelAll()
            context.coordinator.mediaHandler?.store = store
        }
        context.coordinator.mediaHandler?.sourceRelativePath = sourceRelativePath
        context.coordinator.observeReaderScroll(in: view)
        context.coordinator.synchronize(view)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "richArticle")
        view.navigationDelegate = nil
        view.stopLoading()
        (view as? NativeLoadingWebView)?.cancelLoadingFeedback()
        coordinator.mediaHandler?.cancelAll()
        coordinator.cancelImageRequests()
        coordinator.stopObservingReaderScroll()
        coordinator.closeWhiteboard()
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: RichArticleEditor {
            didSet {
                if parent.documentID != oldValue.documentID || parent.store !== oldValue.store
                    || !parent.isEditable {
                    cancelImageRequests()
                }
            }
        }
        var mediaHandler: RichArticleMediaHandler?
        var mediaDropPasteboard = NSPasteboard(name: .drag)
        var imagePasteboard = NSPasteboard.general
        var imageLoader = RichArticleImageLoader.shared
        private var imageTasks: [UUID: Task<Void, Never>] = [:]
        private var imageGeneration = UUID()
        private var isReady = false
        private var lastBody: String?
        private var lastID: String?
        private var lastEditable: Bool?
        private var lastFontSize: CGFloat?
        private var lastPalette: NativeAppPalette?
        private var lastLanguage: NativeAppLanguage?
        private var whiteboard: ArticleWhiteboardWindow?
        private var whiteboardRequestID: String?
        private weak var readerClipView: NSClipView?
        private var readerScrollObserver: NSObjectProtocol?
        private var readerViewportUpdatePending = false

        init(parent: RichArticleEditor) { self.parent = parent }

        deinit { imageTasks.values.forEach { $0.cancel() } }

        func stopObservingReaderScroll() {
            if let readerScrollObserver { NotificationCenter.default.removeObserver(readerScrollObserver) }
            readerScrollObserver = nil
            readerClipView = nil
        }

        func observeReaderScroll(in webView: WKWebView) {
            guard parent.onHeightChange != nil, let clip = webView.enclosingScrollView?.contentView else {
                stopObservingReaderScroll()
                return
            }
            if readerClipView !== clip {
                stopObservingReaderScroll()
                readerClipView = clip
                clip.postsBoundsChangedNotifications = true
                readerScrollObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
                ) { [weak self, weak webView] _ in
                    guard let self, let webView else { return }
                    MainActor.assumeIsolated { self.scheduleReaderViewportUpdate(webView) }
                }
            }
            scheduleReaderViewportUpdate(webView)
        }

        private func scheduleReaderViewportUpdate(_ webView: WKWebView) {
            guard isReady, !readerViewportUpdatePending else { return }
            readerViewportUpdatePending = true
            DispatchQueue.main.async { [weak self, weak webView] in
                guard let self else { return }
                self.readerViewportUpdatePending = false
                guard let webView, self.parent.onHeightChange != nil else { return }
                let visible = webView.visibleRect
                let top = webView.isFlipped ? visible.minY : webView.bounds.height - visible.maxY
                webView.callAsyncJavaScript("window.LeonArticle.setReaderViewport(top)",
                    arguments: ["top": max(0, top)], in: nil, in: .page) { _ in }
            }
        }

        func synchronize(_ webView: WKWebView) {
            guard isReady else { return }
            if lastLanguage != parent.language {
                lastLanguage = parent.language
                NativeWebLocalization.apply(parent.language, to: webView)
            }
            if lastPalette != parent.webPalette {
                lastPalette = parent.webPalette
                NativeWebTheme.apply(parent.webPalette, to: webView)
            }
            if lastID != parent.documentID || !parent.isEditable { closeWhiteboard() }
            let html = RichArticleDocument.convertingLegacyBody(parent.html)
            guard lastBody != html || lastID != parent.documentID
                || lastEditable != parent.isEditable || lastFontSize != parent.fontSize else { return }
            let changesDocument = lastID != parent.documentID
            let loadingView = webView as? NativeLoadingWebView
            let loadingID = changesDocument ? loadingView?.beginContentLoading() : loadingView?.loadingRequestID
            lastBody = html
            lastID = parent.documentID
            lastEditable = parent.isEditable
            lastFontSize = parent.fontSize
            webView.callAsyncJavaScript(
                "return window.LeonArticle.load(body, id, editable, size, embeddedReader)",
                arguments: ["body": html, "id": parent.documentID, "editable": parent.isEditable,
                            "size": parent.fontSize, "embeddedReader": parent.onHeightChange != nil],
                in: nil, in: .page
            ) { [weak self, weak webView, weak loadingView] result in
                guard let loadingView, loadingView.loadingRequestID == loadingID else { return }
                switch result {
                case .success:
                    loadingView.finishContentLoading(loadingID)
                    if let webView { self?.observeReaderScroll(in: webView) }
                case .failure: loadingView.showLoadingFailure(NativeLocalization.text("内容加载失败，请重新打开。"))
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  let payload = message.body as? [String: Any], let type = payload["type"] as? String else { return }
            if type == "ready", let view = message.webView {
                isReady = true
                synchronize(view)
                return
            }
            guard payload["documentID"] as? String == parent.documentID else { return }
            switch type {
            case "chooseAudio":
                guard parent.isEditable, let requestID = payload["requestID"] as? String,
                      let view = message.webView else { return }
                chooseAudio(requestID: requestID, in: view)
            case "dropMedia":
                guard parent.isEditable, let requestID = payload["requestID"] as? String,
                      let names = payload["names"] as? [String], let view = message.webView else { return }
                guard let urls = NativeArticleMediaDrop.fileURLs(from: mediaDropPasteboard, matching: names) else {
                    cancelAudio(requestID: requestID, in: view)
                    showMediaError(NativeLocalization.text("无法读取拖入的媒体文件，请从访达重新拖入。"), in: view)
                    return
                }
                insertMedia(urls: urls, requestID: requestID, in: view)
            case "editWhiteboard":
                guard parent.isEditable, let requestID = payload["requestID"] as? String,
                      let source = payload["source"] as? String, let view = message.webView else { return }
                openWhiteboard(requestID: requestID, source: source, in: view)
            case "change":
                guard parent.isEditable, let html = payload["body"] as? String,
                      RichArticleDocument.isHTML(html) else { return }
                lastBody = html
                if parent.html != html { parent.html = html }
            case "height":
                if let height = payload["height"] as? Double { parent.onHeightChange?(max(24, height)) }
            case "readerWheel":
                guard !parent.isEditable, parent.onHeightChange != nil, let delta = payload["deltaY"] as? Double,
                      delta.isFinite, let scrollView = message.webView?.enclosingScrollView,
                      let document = scrollView.documentView else { return }
                let clip = scrollView.contentView
                let minimum = document.bounds.minY
                let maximum = max(minimum, document.bounds.maxY - clip.bounds.height)
                let direction: CGFloat = document.isFlipped ? 1 : -1
                let y = min(maximum, max(minimum, clip.bounds.origin.y + CGFloat(delta) * direction))
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                scrollView.reflectScrolledClipView(clip)
            case "selection":
                if !parent.isEditable, let text = payload["text"] as? String { parent.onSelectText?(text) }
            case "outline":
                if let offsets = payload["offsets"] as? [Double] { parent.onOutlinePositions?(offsets.map { CGFloat($0) }) }
            case "link":
                if let raw = payload["url"] as? String, let url = URL(string: raw) { open(url) }
            case "pasteImage":
                guard parent.isEditable, let requestID = payload["requestID"] as? String,
                      let view = message.webView else { return }
                insertImage(from: .clipboard(RichArticleClipboard.imageData(from: imagePasteboard)),
                            requestID: requestID, replacing: false, in: view)
            case "chooseImage":
                guard parent.isEditable, let requestID = payload["requestID"] as? String,
                      let view = message.webView else { return }
                let panel = NSOpenPanel()
                panel.title = NativeLocalization.text("替换图片")
                panel.allowedContentTypes = [.png, .jpeg, .gif, .tiff, .webP, .bmp]
                panel.allowsMultipleSelection = false
                let generation = imageGeneration
                let response = panel.runModal()
                guard generation == imageGeneration else { return }
                let source: RichArticleImageLoader.Source
                if response == .OK, let url = panel.url { source = .file(url) }
                else { source = .clipboard([]) }
                insertImage(from: source, requestID: requestID, replacing: true, in: view)
            case "requestLink":
                guard parent.isEditable, let view = message.webView else { return }
                let alert = NSAlert()
                alert.messageText = NativeLocalization.text("添加链接")
                let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
                field.placeholderString = "https://example.com"
                alert.accessoryView = field
                alert.addButton(withTitle: NativeLocalization.text("插入"))
                alert.addButton(withTitle: NativeLocalization.text("取消"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                view.callAsyncJavaScript("window.LeonArticle.insertLink(url)", arguments: ["url": field.stringValue], in: nil, in: .page) { _ in }
            default: break
            }
        }

        func cancelImageRequests() {
            imageGeneration = UUID()
            imageTasks.values.forEach { $0.cancel() }
            imageTasks.removeAll()
        }

        @discardableResult
        func insertImage(from source: RichArticleImageLoader.Source, requestID: String, replacing: Bool,
                         in view: WKWebView) -> Task<Void, Never> {
            let token = UUID(), generation = imageGeneration
            let documentID = parent.documentID, store = parent.store, loader = imageLoader
            let task = Task(priority: .userInitiated) { [weak self, weak view] in
                let image = try? await loader.imageDataURL(from: source)
                guard let self else { return }
                defer { self.imageTasks.removeValue(forKey: token) }
                guard !Task.isCancelled, let view, self.imageGeneration == generation,
                      self.parent.documentID == documentID, self.parent.isEditable,
                      self.parent.store === store, view.navigationDelegate === self else { return }
                if replacing {
                    view.callAsyncJavaScript(
                        "return window.LeonArticle.completeImageReplacement(requestID, source)",
                        arguments: ["requestID": requestID, "source": image ?? ""], in: nil, in: .page
                    ) { _ in }
                } else {
                    view.callAsyncJavaScript(
                        "return window.LeonArticle.insertPastedImages(requestID, sources)",
                        arguments: ["requestID": requestID, "sources": image.map { [$0] } ?? []], in: nil, in: .page
                    ) { _ in }
                }
            }
            imageTasks[token] = task
            return task
        }

        func closeWhiteboard() {
            whiteboardRequestID = nil
            whiteboard?.finish()
            whiteboard = nil
        }

        private func chooseAudio(requestID: String, in view: WKWebView) {
            guard parent.store != nil, parent.onImportMedia != nil else { cancelAudio(requestID: requestID, in: view); return }
            let panel = NSOpenPanel()
            panel.title = NativeLocalization.text("插入音频")
            panel.message = NativeLocalization.text("选择一个 MP3 音频，插入文章后可直接播放。")
            panel.allowedContentTypes = [.mp3]
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { cancelAudio(requestID: requestID, in: view); return }
            insertMedia(urls: [url], requestID: requestID, in: view)
        }

        private func cancelAudio(requestID: String, in view: WKWebView) {
            view.callAsyncJavaScript("window.LeonArticle.cancelAudio(requestID)", arguments: ["requestID": requestID], in: nil, in: .page) { _ in }
        }

        private func showMediaError(_ message: String, in view: WKWebView) {
            let alert = NSAlert()
            alert.messageText = NativeLocalization.text("无法插入媒体")
            alert.informativeText = message
            if let window = view.window { alert.beginSheetModal(for: window) { _ in } }
        }

        private func insertMedia(urls: [URL], requestID: String, in view: WKWebView) {
            guard let store = parent.store, let importMedia = parent.onImportMedia else { cancelAudio(requestID: requestID, in: view); return }
            let documentID = parent.documentID
            Task { [weak self, weak view] in
                guard let self, let view else { return }
                @MainActor func isCurrent() -> Bool {
                    self.parent.documentID == documentID && self.parent.isEditable
                        && self.parent.store === store && view.navigationDelegate === self
                }
                guard isCurrent() else { return }
                var imported: [NativeMedia] = []
                do {
                    for url in urls {
                        guard isCurrent() else { throw CancellationError() }
                        imported.append(try await importMedia(url))
                    }
                    guard isCurrent() else { throw CancellationError() }
                    let result = try await view.callAsyncJavaScript(
                        "return window.LeonArticle.completeMedia(requestID, items) ? window.LeonArticle.serialize() : null",
                        arguments: ["requestID": requestID, "items": imported.map { ["source": $0.url, "title": $0.name, "kind": $0.kind] }], in: nil, contentWorld: .page
                    )
                    guard isCurrent(), let body = result as? String, RichArticleDocument.isHTML(body) else {
                        throw NativeStoreError.fileSystem(NativeLocalization.text("文章中的插入位置已改变，请重新插入媒体。"))
                    }
                    lastBody = body
                    parent.html = body
                    for media in imported { parent.onMediaInserted?(media) }
                } catch {
                    try? await store.discardUnreferencedMedia(imported)
                    guard isCurrent() else { return }
                    cancelAudio(requestID: requestID, in: view)
                    showMediaError(error.localizedDescription, in: view)
                }
            }
        }

        private func openWhiteboard(requestID: String, source: String, in view: WKWebView) {
            guard whiteboardRequestID == nil else { return }
            guard let store = parent.store else {
                view.callAsyncJavaScript("window.LeonArticle.cancelWhiteboard(requestID)", arguments: ["requestID": requestID], in: nil, in: .page) { _ in }
                return
            }
            whiteboardRequestID = requestID
            let documentID = parent.documentID
            Task { [weak self, weak view] in
                guard let self, let view else { return }
                do {
                    let scene = source.isEmpty ? "" : try await store.loadWhiteboard(source: source)
                    guard parent.documentID == documentID, parent.isEditable,
                          parent.store === store, whiteboardRequestID == requestID else { return }
                    let controller = ArticleWhiteboardWindow(scene: scene, onSave: { [weak self, weak view] scene, preview in
                        guard let self, let view, self.parent.documentID == documentID, self.parent.isEditable,
                              self.parent.store === store, self.whiteboardRequestID == requestID else {
                            throw NativeStoreError.fileSystem(NativeLocalization.text("当前文章已改变，画板未写入文章。"))
                        }
                        let asset = try await store.saveWhiteboard(scene: scene, preview: preview)
                        guard self.parent.documentID == documentID, self.parent.isEditable,
                              self.parent.store === store, self.whiteboardRequestID == requestID else {
                            throw NativeStoreError.fileSystem(NativeLocalization.text("当前文章已改变，画板未写入文章。"))
                        }
                        let applied = try await view.callAsyncJavaScript(
                            "return window.LeonArticle.completeWhiteboard(requestID, source, preview)",
                            arguments: ["requestID": requestID, "source": asset.source, "preview": asset.preview], in: nil, contentWorld: .page
                        )
                        guard applied as? Bool == true else {
                            throw NativeStoreError.fileSystem(NativeLocalization.text("文章中的原位置已改变，请取消后重新插入画板。"))
                        }
                    }, onClose: { [weak self, weak view] in
                        guard let self, self.whiteboardRequestID == requestID else { return }
                        self.whiteboardRequestID = nil
                        self.whiteboard = nil
                        view?.callAsyncJavaScript("window.LeonArticle.cancelWhiteboard(requestID)", arguments: ["requestID": requestID], in: nil, in: .page) { _ in }
                    })
                    whiteboard = controller
                    controller.present(on: view.window)
                } catch {
                    guard whiteboardRequestID == requestID else { return }
                    whiteboardRequestID = nil
                    view.callAsyncJavaScript("window.LeonArticle.cancelWhiteboard(requestID)", arguments: ["requestID": requestID], in: nil, in: .page) { _ in }
                    let alert = NSAlert()
                    alert.messageText = NativeLocalization.text("无法打开画板")
                    alert.informativeText = error.localizedDescription
                    if let window = view.window { alert.beginSheetModal(for: window) { _ in } }
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(action.request.url?.scheme == "about" ? .allow : .cancel)
            }
        }

        private func open(_ url: URL) {
            guard ["https", "http", "mailto", "leonbook"].contains(url.scheme?.lowercased() ?? "") else { return }
            if let callback = parent.onOpenLink { callback(url) }
            else { NSWorkspace.shared.open(url) }
        }
    }
}

enum RichArticleClipboard {
    /// WebKit exposes most clipboard images as PNG files. macOS screenshots and
    /// copied images can also arrive as TIFF without a browser-readable file.
    @MainActor static func imageData(from pasteboard: NSPasteboard) -> [Data] {
        let types: [NSPasteboard.PasteboardType] = [.png, .tiff, .init("public.jpeg"), .init("com.compuserve.gif"), .init("org.webmproject.webp"), .init("com.microsoft.bmp")]
        return types.compactMap { pasteboard.data(forType: $0) }
    }

    static func imageDataURL(from data: Data) -> String? {
        guard let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}

final class RichArticleMediaHandler: NSObject, WKURLSchemeHandler {
    var store: LocalBlogStore?
    var sourceRelativePath: String?
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(store: LocalBlogStore?, sourceRelativePath: String?) {
        self.store = store
        self.sourceRelativePath = sourceRelativePath
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        guard let url = urlSchemeTask.request.url,
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value,
              let store else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let relativePath = sourceRelativePath
        tasks[key] = Task { @MainActor [weak self] in
            guard let fileURL = await store.mediaURL(for: path, relativeToMarkdownSource: relativePath),
                  !Task.isCancelled else {
                if !Task.isCancelled { urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)) }
                self?.tasks.removeValue(forKey: key)
                return
            }
            do {
                let data = try await Task.detached(priority: .utility) { try Data(contentsOf: fileURL) }.value
                guard !Task.isCancelled else { return }
                let mime = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch { if !Task.isCancelled { urlSchemeTask.didFailWithError(error) } }
            self?.tasks.removeValue(forKey: key)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    func cancelAll() { tasks.values.forEach { $0.cancel() }; tasks.removeAll() }
}

struct RichArticleReader: View {
    let bodyHTML: String
    let store: LocalBlogStore
    let sourceRelativePath: String
    var fontSize: CGFloat = 18
    var onOpenLink: ((URL) -> Void)? = nil
    var onSelectText: ((String) -> Void)? = nil
    @State private var contentHeight: CGFloat = 100
    @State private var headingOffsets: [CGFloat] = []

    var body: some View {
        RichArticleEditor(
            html: .constant(bodyHTML), documentID: "reader-\(sourceRelativePath)",
            isEditable: false, fontSize: fontSize, store: store, sourceRelativePath: sourceRelativePath,
            onHeightChange: { if abs(contentHeight - $0) > 1 { contentHeight = $0 } },
            onOpenLink: onOpenLink, onSelectText: onSelectText,
            onOutlinePositions: { if headingOffsets != $0 { headingOffsets = $0 } }
        )
        .frame(height: contentHeight)
        .overlay(alignment: .topLeading) {
            ForEach(headingOffsets.indices, id: \.self) { index in
                Color.clear.frame(width: 1, height: 1)
                    .id(MarkdownOutline.anchorID(for: index))
                    .offset(y: headingOffsets[index])
                    .allowsHitTesting(false)
            }
        }
    }
}
