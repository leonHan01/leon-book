import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct InfiniteCanvasView: View {
    @ObservedObject var model: NativeAppModel
    var body: some View {
        InfiniteCanvasWebView(store: model.store, onSave: { model.scheduleBackup() }) { slug in
            model.openArticleLink(slug, disposition: .currentTab)
        }
        .id(model.dataDirectoryPath)
    }
}

/// Serializes writes; a queued newer edit can never be overwritten by an older completion.
@MainActor
final class InfiniteCanvasWriter {
    let store: LocalBlogStore
    var snapshot: InfiniteCanvasSnapshot
    let originalID: String
    var latestDocument: InfiniteCanvasDocument
    var pending: InfiniteCanvasDocument?
    var failure: Error?
    var task: Task<Void, Never>?
    var onSave: ((InfiniteCanvasSnapshot, Bool) -> Void)?
    var onError: ((Error) -> Void)?

    init(store: LocalBlogStore, snapshot: InfiniteCanvasSnapshot) {
        self.store = store
        self.snapshot = snapshot
        originalID = snapshot.id
        latestDocument = snapshot.document
    }

    func enqueue(_ document: InfiniteCanvasDocument) {
        if document == latestDocument && failure == nil {
            if task == nil { onSave?(snapshot, false) }
            return
        }
        latestDocument = document
        pending = document
        failure = nil
        guard task == nil else { return }
        task = Task {
            while let document = pending {
                pending = nil
                do {
                    var forked = false
                    do {
                        snapshot = try await store.saveCanvas(id: snapshot.id, document: document, expectedRevision: snapshot.revision)
                    } catch InfiniteCanvasError.conflict {
                        var copy = document
                        copy.leonbook.title = String(copy.leonbook.title.prefix(180)) + " · 冲突副本"
                        snapshot = try await store.saveCanvas(id: UUID().uuidString.lowercased(), document: copy, expectedRevision: nil)
                        latestDocument.leonbook.title = copy.leonbook.title
                        pending?.leonbook.title = copy.leonbook.title
                        forked = true
                    }
                    onSave?(snapshot, forked)
                } catch {
                    pending = pending ?? document
                    failure = error
                    onError?(error)
                    break
                }
            }
            task = nil
        }
    }

    func flush() async throws {
        await task?.value
        if let failure { throw failure }
    }
}

struct InfiniteCanvasWebView: NSViewRepresentable {
    let store: LocalBlogStore
    var onSave: () -> Void = {}
    var onOpenArticle: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(store: store, onSave: onSave, onOpenArticle: onOpenArticle) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(InfiniteCanvasResources(store: store), forURLScheme: "leoncanvas")
        configuration.userContentController.add(context.coordinator, name: "canvas")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        view.load(URLRequest(url: URL(string: "leoncanvas://app/InfiniteCanvas.html")!))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        // Every committed interaction has already reached the writer, which finishes
        // independently of the view. Do not cancel pending disk writes on navigation.
        coordinator.webView = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "canvas")
        view.navigationDelegate = nil
        view.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let store: LocalBlogStore
        let onSave: () -> Void
        let onOpenArticle: (String) -> Void
        weak var webView: WKWebView?
        var writer: InfiniteCanvasWriter?
        private var generation = 0

        init(store: LocalBlogStore, onSave: @escaping () -> Void = {}, onOpenArticle: @escaping (String) -> Void) {
            self.store = store
            self.onSave = onSave
            self.onOpenArticle = onOpenArticle
        }

        func send(_ action: String, _ payload: [String: Any] = [:]) {
            webView?.callAsyncJavaScript("window.LeonCanvas.receive(action, payload)", arguments: ["action": action, "payload": payload], in: nil, in: .page) { _ in }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.host == "app",
                  message.frameInfo.request.url?.scheme == "leoncanvas",
                  let payload = message.body as? [String: Any], let type = payload["type"] as? String else { return }
            if type == "save", let raw = payload["document"] as? String, let writer {
                do {
                    guard let id = payload["id"] as? String, [writer.originalID, writer.snapshot.id].contains(id) else { return }
                    writer.enqueue(try .decode(Data(raw.utf8)))
                } catch { send("error", ["message": error.localizedDescription]) }
                return
            }
            Task {
                do { try await handle(type, payload) }
                catch { send("error", ["message": error.localizedDescription]) }
            }
        }

        private func handle(_ type: String, _ payload: [String: Any]) async throws {
            switch type {
            case "ready":
                let list = try await store.listCanvases()
                send("catalog", ["items": list])
                let root = store.rootURL.path
                let recent = UserDefaults.standard.string(forKey: "canvas.last.\(root)")
                if let id = list.first(where: { $0["id"] == recent })?["id"] ?? list.first?["id"] { try await open(id) }
            case "open":
                if let id = payload["id"] as? String { try await open(id) }
            case "create":
                try await writer?.flush()
                let snapshot = try await store.saveCanvas(id: UUID().uuidString.lowercased(), document: InfiniteCanvasDocument(), expectedRevision: nil)
                bind(snapshot)
                try await catalog()
            case "library":
                let query = payload["query"] as? String ?? ""
                let kind = payload["kind"] as? String ?? "article"
                var items: [[String: String]] = []
                if kind == "moment" {
                    let page = try await store.listMomentPage(matching: NativeMomentFilter(searchText: query), limit: 100)
                    items = page.moments.map { ["id": $0.id, "title": String($0.text.prefix(80)), "subtitle": $0.createdAt, "kind": "moment"] }
                } else {
                    let articles: [NativeArticleSummary]
                    if query.isEmpty { articles = Array(try await store.listArticles().prefix(100)) }
                    else {
                        let results = try await store.search(query, restrictingTo: [.article], limit: 100)
                        articles = try await store.listArticleSummaries(slugs: results.map(\.documentID))
                    }
                    items = articles.map { ["id": $0.slug, "title": $0.title, "subtitle": $0.excerpt, "kind": "article", "file": "articles/" + $0.sourceRelativePath] }
                }
                send("library", ["items": items, "query": query, "kind": kind])
            case "content":
                guard let nodeID = payload["nodeID"] as? String, let writer,
                      payload["id"] as? String == writer.snapshot.id,
                      let node = writer.latestDocument.nodes.first(where: { $0.id == nodeID }) else { return }
                let boardID = writer.snapshot.id
                do {
                    var result = try await content(node)
                    result["id"] = boardID; result["nodeID"] = nodeID
                    send("content", result)
                } catch {
                    send("content", ["id": boardID, "nodeID": nodeID, "error": "原内容已移动、删除或暂时不可用。"])
                }
            case "openArticle":
                if let slug = payload["slug"] as? String {
                    try await writer?.flush()
                    onOpenArticle(slug)
                }
            case "external":
                if let raw = payload["url"] as? String, let url = InfiniteCanvasDocument.webURL(raw) { NSWorkspace.shared.open(url) }
            case "attachment": try await addAttachment()
            case "openFile":
                if let path = payload["path"] as? String, let file = await store.canvasResourceURL(path: path) {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                }
            case "export":
                try await writer?.flush()
                guard let writer else { return }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [UTType(filenameExtension: "canvas") ?? .json]
                panel.nameFieldStringValue = writer.snapshot.document.leonbook.title + ".canvas"
                if panel.runModal() == .OK, let url = panel.url { try writer.snapshot.document.encoded().write(to: url, options: .atomic) }
            case "import":
                try await writer?.flush()
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [UTType(filenameExtension: "canvas") ?? .json, .json]
                panel.canChooseDirectories = false
                if panel.runModal() == .OK, let url = panel.url {
                    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max) <= InfiniteCanvasDocument.maximumBytes else { throw InfiniteCanvasError.invalid("画布超过 8 MB。") }
                    var document = try InfiniteCanvasDocument.decode(Data(contentsOf: url))
                    if document.leonbook.title == "未命名画布" { document.leonbook.title = String(url.deletingPathExtension().lastPathComponent.prefix(200)) }
                    let snapshot = try await store.saveCanvas(id: UUID().uuidString.lowercased(), document: document, expectedRevision: nil)
                    bind(snapshot)
                    try await catalog()
                }
            case "delete":
                try await writer?.flush()
                guard let writer else { return }
                let alert = NSAlert()
                alert.messageText = "删除“\(writer.snapshot.document.leonbook.title)”？"
                alert.informativeText = "不会删除引用的文章和素材。画布文件会移入 canvases/.trash。"
                alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "删除画布")
                if alert.runModal() == .alertSecondButtonReturn {
                    try await store.deleteCanvas(id: writer.snapshot.id, expectedRevision: writer.snapshot.revision)
                    onSave()
                    self.writer = nil
                    send("empty")
                    try await catalog()
                }
            case "retry": if let writer, let pending = writer.pending { writer.enqueue(pending) }
            default: break
            }
        }

        private func catalog() async throws { send("catalog", ["items": try await store.listCanvases()]) }

        private func open(_ id: String) async throws {
            generation += 1
            let token = generation
            try await writer?.flush()
            let snapshot = try await store.loadCanvas(id: id)
            guard token == generation else { return }
            bind(snapshot)
        }

        private func bind(_ snapshot: InfiniteCanvasSnapshot) {
            let writer = InfiniteCanvasWriter(store: store, snapshot: snapshot)
            self.writer = writer
            writer.onSave = { [weak self, weak writer] snapshot, forked in
                guard let self, self.writer === writer else { return }
                self.onSave()
                self.send("saved", ["id": snapshot.id, "title": snapshot.document.leonbook.title, "forked": forked, "pending": writer?.pending != nil])
                if forked { Task { try? await self.catalog() } }
            }
            writer.onError = { [weak self] error in self?.send("error", ["message": "保存失败：\(error.localizedDescription)"]) }
            if let data = try? snapshot.document.encoded(), let raw = String(data: data, encoding: .utf8) {
                send("load", ["id": snapshot.id, "document": raw])
            }
            UserDefaults.standard.set(snapshot.id, forKey: "canvas.last.\(store.rootURL.path)")
        }

        private func addAttachment() async throws {
            guard let writer else { return }
            let boardID = writer.snapshot.id
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = true
            guard panel.runModal() == .OK else { return }
            for url in panel.urls {
                let type = UTType(filenameExtension: url.pathExtension)
                let kind = type?.conforms(to: .image) == true ? "image" : type?.conforms(to: .movie) == true ? "video" : type?.conforms(to: .audio) == true ? "audio" : "file"
                let media = try await store.uploadMedia(fileURL: url, kind: kind, slug: "canvases")
                guard self.writer === writer else { return }
                send("addFile", ["id": boardID, "file": String(media.url.dropFirst()), "title": media.name])
            }
        }

        private func content(_ node: InfiniteCanvasDocument.Node) async throws -> [String: Any] {
            if let reference = node.leonbook, reference.kind == "article" {
                let article = try await store.getArticle(slug: reference.id)
                return ["kind": "article", "title": article.title, "html": RichArticleDocument.convertingLegacyBody(article.body), "source": article.sourceRelativePath]
            }
            if let reference = node.leonbook, reference.kind == "moment" {
                let moment = try await store.getMoment(id: reference.id)
                return ["kind": "moment", "title": "微博 · \(moment.createdAt.prefix(10))", "text": moment.text,
                        "media": moment.images.map { ["path": $0.url, "kind": $0.kind, "name": $0.name] }]
            }
            guard let path = node.file, let url = await store.canvasResourceURL(path: path) else { throw NativeStoreError.notFound }
            let type = UTType(filenameExtension: url.pathExtension)
            let kind = type?.conforms(to: .image) == true ? "image" : type?.conforms(to: .movie) == true ? "video" : type?.conforms(to: .audio) == true ? "audio" : url.pathExtension.lowercased() == "pdf" ? "pdf" : "file"
            if ["md", "txt", "html"].contains(url.pathExtension.lowercased()) {
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max) <= 2 * 1024 * 1024 else { throw InfiniteCanvasError.invalid("文件过大，请在外部打开。") }
                let body = try String(contentsOf: url, encoding: .utf8)
                return ["kind": "article", "title": node.leonbook?.title ?? url.lastPathComponent,
                        "html": url.pathExtension.lowercased() == "html" ? body : RichArticleDocument.convertingLegacyBody(body),
                        "source": path.hasPrefix("articles/") ? String(path.dropFirst(9)) : path]
            }
            return ["kind": kind, "title": node.leonbook?.title ?? url.lastPathComponent, "path": path]
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = action.request.url
            if action.targetFrame?.isMainFrame != false {
                decisionHandler(url?.scheme == "leoncanvas" && url?.host == "app" ? .allow : .cancel)
            } else {
                decisionHandler(url?.scheme == "https" || url?.scheme == "http" || url?.scheme == "about" || (url?.scheme == "leoncanvas" && url?.host == "media") ? .allow : .cancel)
            }
        }
    }
}

/// Small bundled runtime plus bounded, streamed reads from the current workspace.
final class InfiniteCanvasResources: NSObject, WKURLSchemeHandler {
    let store: LocalBlogStore
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    init(store: LocalBlogStore) { self.store = store }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { task.didFailWithError(URLError(.badURL)); return }
        if url.host == "app" {
            let name = url.lastPathComponent
            guard ["InfiniteCanvas.html", "InfiniteCanvas.css", "InfiniteCanvas.js"].contains(name),
                  let file = Bundle.module.url(forResource: (name as NSString).deletingPathExtension, withExtension: (name as NSString).pathExtension),
                  let data = try? Data(contentsOf: file) else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
            let mime = name.hasSuffix(".html") ? "text/html" : name.hasSuffix(".css") ? "text/css" : "text/javascript"
            task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data); task.didFinish()
            return
        }
        guard url.host == "media", let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = parts.queryItems?.first(where: { $0.name == "path" })?.value else { task.didFailWithError(URLError(.badURL)); return }
        let source = parts.queryItems?.first(where: { $0.name == "source" })?.value
        let key = ObjectIdentifier(task)
        tasks[key] = Task { @MainActor [weak self, store] in
            defer { self?.tasks.removeValue(forKey: key) }
            do {
                guard let file = await store.canvasResourceURL(path: path, source: source), !Task.isCancelled else { throw URLError(.fileDoesNotExist) }
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                var start: UInt64 = 0, end = size
                let range = task.request.value(forHTTPHeaderField: "Range")
                if let range, range.hasPrefix("bytes=") {
                    let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                    if parts.count == 2 {
                        if parts[0].isEmpty, let suffix = UInt64(parts[1]) { start = size - min(size, suffix) }
                        else { start = UInt64(parts[0]) ?? 0; end = min(size, (UInt64(parts[1]) ?? (size > 0 ? size - 1 : 0)) &+ 1) }
                    }
                }
                guard start <= end, start < size || size == 0 else { throw URLError(.badServerResponse) }
                try handle.seek(toOffset: start)
                let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                var headers = ["Content-Type": mime, "Content-Length": String(end - start), "Accept-Ranges": "bytes", "Access-Control-Allow-Origin": "*"]
                if range != nil { headers["Content-Range"] = "bytes \(start)-\(end > 0 ? end - 1 : 0)/\(size)" }
                task.didReceive(HTTPURLResponse(url: url, statusCode: range == nil ? 200 : 206, httpVersion: "HTTP/1.1", headerFields: headers)!)
                var remaining = end - start
                while remaining > 0 && !Task.isCancelled {
                    let count = Int(min(remaining, 256 * 1024))
                    let data = try await Task.detached(priority: .utility) { try handle.read(upToCount: count) ?? Data() }.value
                    guard !Task.isCancelled else { return }
                    guard !data.isEmpty else { throw URLError(.cannotDecodeContentData) }
                    task.didReceive(data); remaining -= UInt64(data.count)
                }
                if !Task.isCancelled { task.didFinish() }
            } catch { if !Task.isCancelled { task.didFailWithError(error) } }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { tasks.removeValue(forKey: ObjectIdentifier(task))?.cancel() }
}
