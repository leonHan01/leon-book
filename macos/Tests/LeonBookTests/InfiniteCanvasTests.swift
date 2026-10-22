import AppKit
import WebKit
@testable import LeonBook

private struct CanvasCheckFailure: Error, CustomStringConvertible { let description: String }
private func canvasExpect(_ condition: Bool, _ message: String) throws {
    if !condition { throw CanvasCheckFailure(description: message) }
}

final class InfiniteCanvasTests {
    private func fixture() throws -> InfiniteCanvasDocument {
        try .decode(Data(#"{"nodes":[{"id":"note","type":"text","text":"知识地图","x":0,"y":0,"width":360,"height":260},{"id":"web","type":"link","url":"https://example.com","x":460,"y":50,"width":380,"height":300}],"edges":[{"id":"edge","fromNode":"note","toNode":"web","label":"参考"}]}"#.utf8))
    }

    func testCanvasStorageValidationIsolationAndRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root.appendingPathComponent("one"))
        let other = LocalBlogStore(rootURL: root.appendingPathComponent("two"))
        let id = UUID().uuidString.lowercased()
        let initial = try await store.saveCanvas(id: id, document: fixture(), expectedRevision: nil)
        var changed = initial.document
        changed.nodes[0].text = "最新内容"; changed.leonbook.title = "研究空间"
        changed.leonbook.viewport = .init(x: -400, y: 80, zoom: 0.6)
        let saved = try await store.saveCanvas(id: id, document: changed, expectedRevision: initial.revision)
        try canvasExpect(try await store.loadCanvas(id: id).document == changed, "positions, viewport, content and edges must survive reopening")
        try canvasExpect(try await other.listCanvases().isEmpty, "canvases must be workspace isolated")
        do { _ = try await store.saveCanvas(id: id, document: initial.document, expectedRevision: initial.revision); throw CanvasCheckFailure(description: "stale write accepted") }
        catch InfiniteCanvasError.conflict {}
        do { try await store.deleteCanvas(id: id, expectedRevision: initial.revision); throw CanvasCheckFailure(description: "stale delete accepted") }
        catch InfiniteCanvasError.conflict {}
        for invalid in ["../secret", "/tmp/secret", "file:///tmp/secret", "articles/%2e%2e/secret"] {
            var document = changed
            document.nodes[0].type = "file"; document.nodes[0].file = invalid
            do { _ = try document.encoded(); throw CanvasCheckFailure(description: "unsafe file reference accepted: \(invalid)") }
            catch InfiniteCanvasError.invalid {}
        }
        var invalid = changed
        invalid.nodes[1].url = "javascript:alert(1)"
        do { _ = try invalid.encoded(); throw CanvasCheckFailure(description: "script URL accepted") }
        catch InfiniteCanvasError.invalid {}
        invalid = changed; invalid.edges[0].toNode = "missing"
        do { _ = try invalid.encoded(); throw CanvasCheckFailure(description: "dangling edge accepted") }
        catch InfiniteCanvasError.invalid {}
        try await store.deleteCanvas(id: id, expectedRevision: saved.revision)
        try canvasExpect(try await store.listCanvases().isEmpty, "deleted board must leave catalog")
        let recovery = root.appendingPathComponent("one/canvases/.trash")
        try canvasExpect(try FileManager.default.contentsOfDirectory(atPath: recovery.path).count == 1, "deleted canvas must remain recoverable")
        await store.closeForRestore(); await other.closeForRestore()
    }

    @MainActor
    func testCanvasWriterOrdersEditsAndPreservesConflictCopies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-writer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let initial = try await store.saveCanvas(id: UUID().uuidString.lowercased(), document: fixture(), expectedRevision: nil)
        let writer = InfiniteCanvasWriter(store: store, snapshot: initial)
        for index in 0..<30 {
            var document = initial.document; document.nodes[0].text = "edit \(index)"; writer.enqueue(document)
            if index == 3 { await Task.yield() }
        }
        try await writer.flush()
        try canvasExpect(try await store.loadCanvas(id: initial.id).document.nodes[0].text == "edit 29", "last edit must win")
        var remote = writer.snapshot.document; remote.nodes[0].text = "另一窗口的修改"
        _ = try await store.saveCanvas(id: initial.id, document: remote, expectedRevision: writer.snapshot.revision)
        var local = remote; local.nodes[0].text = "本窗口的修改"
        writer.enqueue(local); try await writer.flush()
        try canvasExpect(writer.snapshot.id != initial.id, "conflict must create another canvas")
        try canvasExpect(try await store.loadCanvas(id: initial.id).document.nodes[0].text == remote.nodes[0].text, "remote content must survive")
        try canvasExpect(try await store.loadCanvas(id: writer.snapshot.id).document.nodes[0].text == local.nodes[0].text, "local edits must survive in conflict copy")
        await store.closeForRestore()
    }

    func testCanvasResourcesStayInsideWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-paths-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root.appendingPathComponent("workspace"))
        _ = try await store.listCanvases()
        let media = root.appendingPathComponent("workspace/media/canvases")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Data("safe".utf8).write(to: media.appendingPathComponent("example.txt"))
        let outside = root.appendingPathComponent("secret.txt")
        try Data("private".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: media.appendingPathComponent("escape.txt"), withDestinationURL: outside)
        try canvasExpect(await store.canvasResourceURL(path: "media/canvases/example.txt") != nil, "workspace attachment must resolve")
        for path in ["media/canvases/escape.txt", "../secret.txt", "/tmp/secret.txt", "media/../../secret.txt"] {
            try canvasExpect(await store.canvasResourceURL(path: path) == nil, "outside file must not resolve: \(path)")
        }
        await store.closeForRestore()
    }

    @MainActor
    func testCanvasNativeBridgeLoadsAndRefreshesArticleReferences() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-bridge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let article = try await store.saveArticle(NativeSaveArticle(
            banner: nil, body: RichArticleDocument.opening + "<h2>原文章</h2><p>第一版正文</p></article>",
            category: "Notes", excerpt: "", media: [], slug: "canvas-reference", status: .draft,
            tags: [], title: "引用测试", expectedUpdatedAt: nil
        ))
        var document = try fixture()
        document.nodes.append(.init(id: "article", type: "file", x: 100, y: 360, width: 400, height: 300,
                                   file: "articles/" + article.sourceRelativePath,
                                   leonbook: .init(kind: "article", id: article.slug, title: article.title)))
        document.nodes.append(.init(id: "missing", type: "file", x: 550, y: 360, width: 320, height: 300, file: "articles/no-such-file.txt"))
        let snapshot = try await store.saveCanvas(id: UUID().uuidString.lowercased(), document: document, expectedRevision: nil)
        var openedSlug: String?
        let coordinator = InfiniteCanvasWebView.Coordinator(store: store) { openedSlug = $0 }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(InfiniteCanvasResources(store: store), forURLScheme: "leoncanvas")
        configuration.userContentController.add(coordinator, name: "canvas")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1180, height: 820), configuration: configuration)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        coordinator.webView = view; view.navigationDelegate = coordinator
        defer { coordinator.webView = nil; view.stopLoading(); configuration.userContentController.removeScriptMessageHandler(forName: "canvas"); window.close() }
        view.load(URLRequest(url: URL(string: "leoncanvas://app/InfiniteCanvas.html")!))
        func waitFor(_ expression: String) async throws {
            for _ in 0..<200 {
                if (try? await view.evaluateJavaScript(expression)) as? Bool == true { return }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            throw CanvasCheckFailure(description: "native bridge did not reach: \(expression)")
        }
        try await waitFor("document.body.innerText.includes('第一版正文') && document.body.innerText.includes('内容暂不可用')")
        _ = try await store.saveArticle(NativeSaveArticle(
            banner: nil, body: RichArticleDocument.opening + "<p>第二版正文</p></article>", category: "Notes", excerpt: "", media: [],
            slug: article.slug, status: .draft, tags: [], title: "更新后的标题", expectedUpdatedAt: article.updatedAt
        ))
        _ = try await view.evaluateJavaScript("document.querySelector('[data-id=article] button[title=刷新原内容]').click()")
        try await waitFor("document.body.innerText.includes('第二版正文') && document.body.innerText.includes('更新后的标题')")
        _ = try await view.evaluateJavaScript("const field=document.querySelector('textarea'); field.value='通过原生桥保存'; field.dispatchEvent(new Event('input',{bubbles:true}));")
        try await Task.sleep(nanoseconds: 100_000_000)
        try await coordinator.writer?.flush()
        try canvasExpect(try await store.loadCanvas(id: snapshot.id).document.nodes[0].text == "通过原生桥保存", "editing must reach the actual store")
        _ = try await view.evaluateJavaScript("document.querySelector('[data-id=article] button[title=打开原文]').click()")
        for _ in 0..<40 { if openedSlug != nil { break }; try await Task.sleep(nanoseconds: 25_000_000) }
        try canvasExpect(openedSlug == article.slug, "open-original action must navigate to the referenced article")
        await store.closeForRestore()
    }

    @MainActor
    func testCanvasRuntimeEditingConnectionsAndCulling() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-runtime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(InfiniteCanvasResources(store: store), forURLScheme: "leoncanvas")
        let recorder = CanvasMessageRecorder()
        configuration.userContentController.add(recorder, name: "canvas")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1180, height: 780), configuration: configuration)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { view.stopLoading(); configuration.userContentController.removeScriptMessageHandler(forName: "canvas"); window.close() }
        view.load(URLRequest(url: URL(string: "leoncanvas://app/InfiniteCanvas.html")!))
        for _ in 0..<200 {
            if recorder.ready { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try canvasExpect(recorder.ready, "bundled canvas must load offline")
        let document = String(data: try fixture().encoded(), encoding: .utf8)!
        _ = try await view.callAsyncJavaScript(#"""
        const expect = (value, message) => { if (!value) throw new Error(message); };
        LeonCanvas.receive('load', {id:'board',document});
        expect(LeonCanvas.snapshot().nodes.length === 2, 'must load JSON Canvas');
        const field = window.document.querySelector('textarea');
        field.focus(); field.value = '便签编辑后立即保存'; field.dispatchEvent(new Event('input',{bubbles:true})); field.blur();
        expect(LeonCanvas.snapshot().nodes[0].text === field.value, 'note edits must persist');
        const added = LeonCanvas.addNode({type:'text',text:'新的想法'}, {x:530,y:580});
        LeonCanvas.connect('note', added.id);
        expect(LeonCanvas.snapshot().edges.length === 2, 'connecting cards must add edge');
        window.document.getElementById('remove').click();
        expect(!LeonCanvas.snapshot().nodes.some(n=>n.id===added.id), 'remove selected card');
        expect(LeonCanvas.snapshot().edges.length===1, 'removing card must remove incident edges');
        window.document.getElementById('undo').click();
        expect(LeonCanvas.snapshot().nodes.some(n=>n.id===added.id) && LeonCanvas.snapshot().edges.length===2, 'undo must restore card and edges together');
        const article = LeonCanvas.addNode({type:'file',file:'articles/demo.html',leonbook:{kind:'article',id:'demo',title:'文章内容'},width:400,height:390},{x:300,y:420});
        LeonCanvas.receive('content',{id:'board',nodeID:article.id,kind:'article',title:'文章内容',html:'<h2>研究与创作</h2><p>让博客、资料与灵感在画布上自由连接。</p><script>window.canvasInjected=true</script><img src="x" onerror="window.canvasInjected=true"><a href="javascript:alert(1)">unsafe</a>'});
        const card = window.document.querySelector('[data-id="'+article.id+'"]');
        expect(card.textContent.includes('研究与创作'), 'article body must render');
        expect(!card.querySelector('script,[onerror],a[href^="javascript:"]') && !window.canvasInjected, 'article HTML must not execute');
        for (let i=0;i<20;i++) LeonCanvas.addNode({type:'text',text:'远处内容 '+i},{x:100000+i*500,y:100000});
        expect(LeonCanvas.state().visibleCards<8,'offscreen cards must not remain mounted');
        expect(!window.document.querySelector('iframe'),'websites must not load before activation');
        const snapshot = LeonCanvas.snapshot();
        snapshot.nodes = snapshot.nodes.filter(n=>n.x<10000); snapshot.leonbook.title = '创作与知识地图';
        LeonCanvas.receive('load',{id:'board',document:JSON.stringify(snapshot)});
        LeonCanvas.receive('content',{id:'board',nodeID:article.id,kind:'article',title:'研究与创作',html:'<h2>让想法建立联系</h2><p>博客、文章和资料，不再散落各处。</p><blockquote>在无限空间里整理灵感。</blockquote><ul><li>阅读与收集</li><li>连接与思考</li><li>写作与分享</li></ul>'});
        return true;
        """#, arguments: ["document": document], in: nil, contentWorld: .page)
        try canvasExpect(recorder.savedDocuments > 0, "editing must reach native persistence bridge")
        // Optional artifact for visual inspection; this window is never shown.
        if let path = ProcessInfo.processInfo.environment["LEON_CANVAS_SCREENSHOT"] {
            try await Task.sleep(nanoseconds: 150_000_000)
            let image = try await view.takeSnapshot(configuration: nil)
            if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}

private final class CanvasMessageRecorder: NSObject, WKScriptMessageHandler {
    var ready = false
    var savedDocuments = 0
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any] else { return }
        if payload["type"] as? String == "ready" { ready = true }
        if payload["type"] as? String == "save" { savedDocuments += 1 }
    }
}
