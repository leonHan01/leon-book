import AppKit
import WebKit
@testable import LeonBook

private struct WhiteboardTestFailure: Error, CustomStringConvertible { let description: String }
private func boardExpect(_ condition: Bool, _ message: String) throws {
    if !condition { throw WhiteboardTestFailure(description: message) }
}

final class ArticleWhiteboardTests {
    private let png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII="
    private let empty = ##"{"type":"excalidraw","version":2,"elements":[],"appState":{"viewBackgroundColor":"#ffffff"},"files":{}}"##

    func testWhiteboardImmutableStorageAndValidation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leon-whiteboard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let first = try await store.saveWhiteboard(scene: empty, preview: png)
        let duplicate = try await store.saveWhiteboard(scene: empty, preview: png)
        try boardExpect(first == duplicate, "identical saves must reuse immutable files")
        let nextScene = empty.replacingOccurrences(of: "#ffffff", with: "#abcdef")
        let second = try await store.saveWhiteboard(scene: nextScene, preview: png)
        try boardExpect(first != second, "edits must create a new version")
        try boardExpect(try await store.loadWhiteboard(source: first.source) == empty, "previous source must survive editing")
        try boardExpect(try await store.loadWhiteboard(source: second.source) == nextScene, "current source must reopen")
        let article = try await store.saveArticle(NativeSaveArticle(
            banner: nil, body: RichArticleDocument.opening + "<figure data-type=\"whiteboard\" data-whiteboard-source=\"\(first.source)\"><img src=\"\(first.preview)\"></figure></article>",
            category: "Notes", excerpt: "", media: [], slug: "drawing-test", status: .draft, tags: [], title: "Drawing", expectedUpdatedAt: nil
        ))
        let read = try await store.getArticle(slug: article.slug)
        try boardExpect(read.body.contains(first.source), "HTML save and reopen must preserve editable scene reference")
        try boardExpect(await store.mediaURL(for: first.preview) != nil, "preview must use the existing media resolver")
        for path in ["/media/whiteboards/../../secret.excalidraw", "https://example.com/board.excalidraw", first.source.replacingOccurrences(of: ".excalidraw", with: ".png")] {
            do { _ = try ArticleWhiteboardData.filename(for: path); throw WhiteboardTestFailure(description: "unsafe source accepted") }
            catch is NativeStoreError {}
        }
        for scene in ["{}", empty.replacingOccurrences(of: "\"elements\":[]", with: "\"elements\":[{\"type\":\"image\",\"fileId\":\"missing\"}]")] {
            do { _ = try await store.saveWhiteboard(scene: scene, preview: png); throw WhiteboardTestFailure(description: "invalid scene accepted") }
            catch is NativeStoreError {}
        }
        do { _ = try await store.saveWhiteboard(scene: empty, preview: "data:image/png;base64,AAAA"); throw WhiteboardTestFailure(description: "invalid PNG accepted") }
        catch is NativeStoreError {}
        let vault = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        _ = try await store.configureMarkdownWorkspaceSource(mode: .readOnlyMount, directoryURL: vault)
        do { _ = try await store.saveWhiteboard(scene: empty, preview: png); throw WhiteboardTestFailure(description: "read-only source accepted a write") }
        catch is NativeStoreError {}
        await store.closeForRestore()
    }

    @MainActor
    func testWhiteboardArticleRoundTripUndoAndStaleRequests() async throws {
        let messages = WhiteboardRequestRecorder()
        try await RichArticleTests().withWebEditor(messageHandler: messages) { view in
            let setup = #"""
            const root = document.getElementById('document');
            LeonArticle.load('<article data-leon-format="html-v1"><p>前文</p><p>/画板</p></article>', 'board-article', true, 18);
            root.focus(); getSelection().setPosition(root.lastElementChild.firstChild, 3);
            document.dispatchEvent(new Event('selectionchange'));
            if (!LeonArticle.execute('whiteboard')) throw new Error('whiteboard command missing');
            """#
            _ = try await view.callAsyncJavaScript(setup, arguments: [:], in: nil, contentWorld: .page)
            for _ in 0..<40 { if !messages.requests.isEmpty { break }; try await Task.sleep(nanoseconds: 25_000_000) }
            guard let request = messages.requests.last else { throw WhiteboardTestFailure(description: "native open request missing") }
            let result = try await view.callAsyncJavaScript(#"""
            const expect = (value, message) => { if (!value) throw new Error(message); };
            const source = '/media/whiteboards/' + 'a'.repeat(64) + '.excalidraw', preview = source.replace('.excalidraw', '.png');
            expect(LeonArticle.completeWhiteboard(requestID, source, preview), 'saved board must be inserted');
            const saved = LeonArticle.serialize();
            expect(saved.includes(source) && saved.includes(preview) && !saved.includes('/画板'), 'source and preview must survive serialization');
            expect(!saved.includes('contenteditable'), 'runtime editing attributes must not leak into saved HTML');
            expect(document.querySelector('figure').contentEditable === 'false', 'board must be an atomic content block');
            expect(LeonArticle.cleanHTML(saved).includes(source), 'sanitizer must preserve known source metadata');
            expect(!LeonArticle.cleanHTML('<figure data-type="whiteboard" data-whiteboard-source="../../secret"><img src="x"></figure>').includes('data-whiteboard-source'), 'sanitizer must reject unsafe source paths');
            LeonArticle.undo(-1); expect(!LeonArticle.serialize().includes(source), 'undo must remove the complete inserted board');
            LeonArticle.undo(1); expect(LeonArticle.serialize().includes(source), 'redo must restore source and preview');
            LeonArticle.load(saved, 'board-reopened', true, 18);
            expect(LeonArticle.serialize().includes(source), 'reload must retain editable source');
            document.querySelector('figure img').dispatchEvent(new MouseEvent('click', {bubbles:true}));
            expect(!document.getElementById('whiteboard-tools').hidden, 'board operations must be discoverable');
            expect(document.getElementById('image-tools').hidden, 'ordinary replace-image UI must not corrupt board preview');
            document.querySelector('[data-board-action="delete"]').click();
            expect(!LeonArticle.serialize().includes(source), 'delete must remove the entire board');
            LeonArticle.undo(-1); expect(LeonArticle.serialize().includes(source), 'delete undo must restore editable board');
            document.querySelector('figure').dispatchEvent(new MouseEvent('dblclick', {bubbles:true}));
            return saved;
            """#, arguments: ["requestID": request], in: nil, contentWorld: .page)
            for _ in 0..<40 { if messages.requests.count > 1 { break }; try await Task.sleep(nanoseconds: 25_000_000) }
            guard let second = messages.requests.last, second != request else { throw WhiteboardTestFailure(description: "re-edit request missing") }
            _ = try await view.callAsyncJavaScript(#"""
            LeonArticle.load(saved, 'another-document', false, 18);
            if (LeonArticle.completeWhiteboard(requestID, '/media/whiteboards/' + 'b'.repeat(64) + '.excalidraw', '/media/whiteboards/' + 'b'.repeat(64) + '.png')) throw new Error('stale request changed another document');
            if (!document.getElementById('whiteboard-tools').hidden) throw new Error('reader exposed editing controls');
            """#, arguments: ["requestID": second, "saved": result as! String], in: nil, contentWorld: .page)
        }
    }

    @MainActor
    func testWhiteboardBundledRuntimeExportsAndReopensOffline() async throws {
        _ = NSApplication.shared
        let configuration = ArticleWhiteboardWindow.configuration()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { view.stopLoading(); window.close() }
        view.load(URLRequest(url: URL(string: "leonboard://app/index.html")!))
        var ready = false
        for _ in 0..<400 {
            try await Task.sleep(nanoseconds: 25_000_000)
            if (try? await view.evaluateJavaScript("typeof window.LeonWhiteboard === 'object'")) as? Bool == true { ready = true; break }
        }
        try boardExpect(ready, "bundled Excalidraw must initialize without HTTP or CDN")
        let result = try await view.callAsyncJavaScript(#"""
        const scene = {
          type:'excalidraw', version:2, source:'LeonBook', appState:{viewBackgroundColor:'#ffffff'},
          elements:[{id:'image-1',type:'image',x:20,y:20,width:180,height:120,angle:0,strokeColor:'transparent',backgroundColor:'transparent',fillStyle:'solid',strokeWidth:1,strokeStyle:'solid',roughness:0,opacity:100,groupIds:[],frameId:null,roundness:null,seed:1,version:1,versionNonce:1,isDeleted:false,boundElements:null,updated:1,link:null,locked:false,fileId:'image-file',status:'saved',scale:[1,1],crop:null}],
          files:{'image-file':{id:'image-file',mimeType:'image/png',dataURL:png,created:1,lastRetrieved:1}}
        };
        LeonWhiteboard.load(JSON.stringify(scene));
        for (let i=0;i<200 && (!LeonWhiteboard.getAPI() || !LeonWhiteboard.getAPI().getSceneElements().length);i++) await new Promise(resolve=>setTimeout(resolve,25));
        const api = LeonWhiteboard.getAPI();
        if (!api || !api.getSceneElements().length) throw new Error('initialData did not restore the image');
        const result = await LeonWhiteboard.snapshot();
        const saved = JSON.parse(result.scene);
        if (!saved.files['image-file']?.dataURL || !result.preview.startsWith('data:image/png;base64,')) throw new Error('image source or PNG export missing');
        const resources = performance.getEntriesByType('resource').map(entry=>entry.name);
        if (resources.some(url=>/^https?:/.test(url))) throw new Error('runtime requested a network resource: '+resources.join(', '));
        if (document.querySelector('#status').textContent.includes('失败')) throw new Error(document.querySelector('#status').textContent);
        return result;
        """#, arguments: ["png": png], in: nil, contentWorld: .page)
        guard let object = result as? [String: String], let scene = object["scene"], let preview = object["preview"] else {
            throw WhiteboardTestFailure(description: "runtime did not produce a savable snapshot")
        }
        _ = try ArticleWhiteboardData.sceneData(scene)
        _ = try ArticleWhiteboardData.previewData(preview)
    }
}

private final class WhiteboardRequestRecorder: NSObject, WKScriptMessageHandler {
    var requests: [String] = []
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let payload = message.body as? [String: Any], payload["type"] as? String == "editWhiteboard", let id = payload["requestID"] as? String { requests.append(id) }
    }
}
