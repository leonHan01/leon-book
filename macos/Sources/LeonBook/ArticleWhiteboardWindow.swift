import AppKit
import Combine
import UniformTypeIdentifiers
import WebKit

/// One lazily created editor. Reading an article only loads its PNG preview.
@MainActor
final class ArticleWhiteboardWindow: NSWindowController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let webView: WKWebView
    private let scene: String
    private let onSave: (String, String) async throws -> Void
    private var onClose: (() -> Void)?
    private var dirty = false
    private var saving = false
    private var finished = false
    private var languageObserver: AnyCancellable?

    init(scene: String, onSave: @escaping (String, String) async throws -> Void, onClose: @escaping () -> Void) {
        self.scene = scene
        self.onSave = onSave
        self.onClose = onClose
        let configuration = Self.configuration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: configuration)
        let panel = NSPanel(contentRect: webView.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = NativeLocalization.text("文章画板 · Excalidraw")
        panel.minSize = NSSize(width: 700, height: 500)
        panel.isReleasedWhenClosed = false
        panel.contentView = webView
        super.init(window: panel)
        panel.delegate = self
        configuration.userContentController.add(self, name: "whiteboard")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        languageObserver = NativeLanguagePreferences.shared.$language.removeDuplicates().sink { [weak self] language in
            guard let self else { return }
            window?.title = NativeLocalization.string("文章画板 · Excalidraw", language: language)
            NativeWebLocalization.apply(language, to: webView)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        NativeWebLocalization.install(on: configuration, language: NativeLocalization.currentLanguage)
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(ArticleWhiteboardResources(), forURLScheme: "leonboard")
        return configuration
    }

    func present(on parent: NSWindow?) {
        guard let window else { return }
        if let parent, parent.attachedSheet == nil { parent.beginSheet(window) }
        else { window.center(); showWindow(nil) }
        webView.load(URLRequest(url: URL(string: "leonboard://app/index.html")!))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !finished, message.frameInfo.isMainFrame, message.frameInfo.request.url?.scheme == "leonboard",
              let payload = message.body as? [String: Any], let type = payload["type"] as? String else { return }
        switch type {
        case "ready":
            NativeWebLocalization.apply(NativeLocalization.currentLanguage, to: webView)
            webView.callAsyncJavaScript("window.LeonWhiteboard.load(scene)", arguments: ["scene": scene], in: nil, in: .page) { [weak self] result in
                if case .failure(let error) = result { self?.showError(error.localizedDescription) }
            }
        case "dirty": dirty = payload["value"] as? Bool ?? true
        case "cancel": requestClose()
        case "save":
            guard !saving, let source = payload["scene"] as? String, let preview = payload["preview"] as? String else { return }
            saving = true
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await onSave(source, preview)
                    finish()
                } catch {
                    saving = false
                    showError(error.localizedDescription)
                }
            }
        default: break
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { requestClose(); return false }

    private func requestClose() {
        guard !saving else { return }
        if dirty, let window {
            let alert = NSAlert()
            alert.messageText = NativeLocalization.text("放弃画板修改？")
            alert.informativeText = NativeLocalization.text("尚未保存到文章的修改将被丢弃。")
            alert.addButton(withTitle: NativeLocalization.text("继续编辑"))
            alert.addButton(withTitle: NativeLocalization.text("放弃修改"))
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertSecondButtonReturn { self?.finish() }
            }
        } else { finish() }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        languageObserver = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "whiteboard")
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        if let window {
            window.delegate = nil
            window.sheetParent?.endSheet(window)
            window.orderOut(nil)
            window.close()
        }
        let callback = onClose
        onClose = nil
        callback?()
    }

    private func showError(_ message: String) {
        webView.callAsyncJavaScript("window.LeonWhiteboard?.showError(message)", arguments: ["message": message], in: nil, in: .page) { _ in }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = NativeLocalization.text("无法加载画板")
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window) { [weak self] _ in self?.finish() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        decisionHandler(url?.scheme == "leonboard" && url?.host == "app" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard let window else { completionHandler(nil); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.beginSheetModal(for: window) { result in completionHandler(result == .OK ? panel.urls : nil) }
    }
}

/// Serves only the bundled editor assets; it never exposes workspace files.
final class ArticleWhiteboardResources: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "app",
              let root = Bundle.leonBookResources.url(forResource: "Whiteboard", withExtension: nil) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let file = root.appendingPathComponent(url.path).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path + "/"),
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let mime: String
        switch file.pathExtension {
        case "js": mime = "text/javascript"
        case "css": mime = "text/css"
        case "html": mime = "text/html"
        case "woff2": mime = "font/woff2"
        default: mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": mime, "Access-Control-Allow-Origin": "*", "Content-Length": String(data.count)
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
