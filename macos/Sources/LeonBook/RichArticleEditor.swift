import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct RichArticleEditor: NSViewRepresentable {
    @Binding var html: String
    let documentID: String
    var isEditable = true
    var fontSize: CGFloat = 18
    var store: LocalBlogStore? = nil
    var sourceRelativePath: String? = nil
    var onHeightChange: ((CGFloat) -> Void)? = nil
    var onOpenLink: ((URL) -> Void)? = nil
    var onSelectText: ((String) -> Void)? = nil
    var onOutlinePositions: (([CGFloat]) -> Void)? = nil

    static var pageHTML: String {
        guard let url = Bundle.module.url(forResource: "RichArticleEditor", withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return html
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "richArticle")
        let media = RichArticleMediaHandler(store: store, sourceRelativePath: sourceRelativePath)
        configuration.setURLSchemeHandler(media, forURLScheme: "leonmedia")
        context.coordinator.mediaHandler = media
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(Self.pageHTML, baseURL: nil)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.mediaHandler?.sourceRelativePath = sourceRelativePath
        context.coordinator.synchronize(view)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "richArticle")
        view.navigationDelegate = nil
        view.stopLoading()
        coordinator.mediaHandler?.cancelAll()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: RichArticleEditor
        var mediaHandler: RichArticleMediaHandler?
        private var isReady = false
        private var lastBody: String?
        private var lastID: String?
        private var lastEditable: Bool?
        private var lastFontSize: CGFloat?

        init(parent: RichArticleEditor) { self.parent = parent }

        func synchronize(_ webView: WKWebView) {
            guard isReady else { return }
            let html = RichArticleDocument.convertingLegacyBody(parent.html)
            guard lastBody != html || lastID != parent.documentID
                || lastEditable != parent.isEditable || lastFontSize != parent.fontSize else { return }
            lastBody = html
            lastID = parent.documentID
            lastEditable = parent.isEditable
            lastFontSize = parent.fontSize
            webView.callAsyncJavaScript(
                "return window.LeonArticle.load(body, id, editable, size)",
                arguments: ["body": html, "id": parent.documentID, "editable": parent.isEditable, "size": parent.fontSize],
                in: nil, in: .page
            ) { _ in }
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
            case "change":
                guard parent.isEditable, let html = payload["body"] as? String,
                      RichArticleDocument.isHTML(html) else { return }
                lastBody = html
                if parent.html != html { parent.html = html }
            case "height":
                if let height = payload["height"] as? Double { parent.onHeightChange?(max(24, height)) }
            case "selection":
                if !parent.isEditable, let text = payload["text"] as? String { parent.onSelectText?(text) }
            case "outline":
                if let offsets = payload["offsets"] as? [Double] { parent.onOutlinePositions?(offsets.map { CGFloat($0) }) }
            case "link":
                if let raw = payload["url"] as? String, let url = URL(string: raw) { open(url) }
            case "pasteImage":
                guard parent.isEditable, let requestID = payload["requestID"] as? String,
                      let view = message.webView else { return }
                let sources = RichArticleClipboard.imageDataURL(from: .general).map { [$0] } ?? []
                view.callAsyncJavaScript(
                    "return window.LeonArticle.insertPastedImages(requestID, sources)",
                    arguments: ["requestID": requestID, "sources": sources], in: nil, in: .page
                ) { _ in }
            case "requestLink":
                guard parent.isEditable, let view = message.webView else { return }
                let alert = NSAlert()
                alert.messageText = "添加链接"
                let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
                field.placeholderString = "https://example.com"
                alert.accessoryView = field
                alert.addButton(withTitle: "插入")
                alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                view.callAsyncJavaScript("window.LeonArticle.insertLink(url)", arguments: ["url": field.stringValue], in: nil, in: .page) { _ in }
            default: break
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
    static func imageDataURL(from pasteboard: NSPasteboard) -> String? {
        let types: [NSPasteboard.PasteboardType] = [.png, .tiff, .init("public.jpeg"), .init("com.compuserve.gif"), .init("org.webmproject.webp"), .init("com.microsoft.bmp")]
        for type in types {
            guard let data = pasteboard.data(forType: type),
                  let bitmap = NSBitmapImageRep(data: data),
                  let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            return "data:image/png;base64," + png.base64EncodedString()
        }
        return nil
    }
}

final class RichArticleMediaHandler: NSObject, WKURLSchemeHandler {
    let store: LocalBlogStore?
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
