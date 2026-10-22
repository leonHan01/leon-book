import AppKit
import SwiftUI
import WebKit
@testable import LeonBook

private struct AudioTestFailure: Error, CustomStringConvertible { let description: String }
private func audioExpect(_ condition: Bool, _ message: String) throws {
    if !condition { throw AudioTestFailure(description: message) }
}

final class ArticleAudioTests {
    @MainActor
    func testAudioDropImportsAtDropLocationThroughNativeBridge() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("leon-audio-drop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = Bundle.module.url(forResource: "article-audio-silence", withExtension: "mp3", subdirectory: "Fixtures")!
        let files = [directory.appendingPathComponent("录音 & 一.MP3"), directory.appendingPathComponent("录音二.mp3")]
        for file in files { try FileManager.default.copyItem(at: fixture, to: file) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects(files.map { $0 as NSURL })
        try audioExpect(NativeArticleAudioDrop.fileURLs(from: pasteboard, matching: files.map(\.lastPathComponent)) == files, "native file URLs must preserve unicode names and drop order")
        try audioExpect(NativeArticleAudioDrop.fileURLs(from: pasteboard, matching: ["missing.mp3"]) == nil, "reject mismatched drag data")
        try audioExpect(NativeArticleAudioDrop.fileURLs(from: pasteboard, matching: ["image.png"]) == nil, "reject non-MP3 files")
        let store = LocalBlogStore(rootURL: directory.appendingPathComponent("workspace"))
        var html = RichArticleDocument.opening + "<p>第一段</p><p>第二段</p><p>第三段</p></article>"
        var inserted: [NativeMedia] = []
        let host = NSHostingView(rootView: RichArticleEditor(
            html: Binding(get: { html }, set: { html = $0 }), documentID: "drop-bridge", store: store,
            onImportAudio: { url in
                try await NativeMediaUpload.files([url], kind: .audio, destination: .inbox, store: store)[0]
            },
            onAudioInserted: { inserted.append($0) }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        func findWebView(_ view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap(findWebView).first
        }
        guard let view = findWebView(host), let coordinator = view.navigationDelegate as? RichArticleEditor.Coordinator else {
            throw AudioTestFailure(description: "native audio editor missing")
        }
        coordinator.audioDropPasteboard = pasteboard
        var ready = false
        for _ in 0..<200 {
            try await Task.sleep(nanoseconds: 25_000_000)
            if (try? await view.evaluateJavaScript("document.getElementById('document')?.contentEditable === 'true'")) as? Bool == true { ready = true; break }
        }
        try audioExpect(ready, "native editor must load")
        _ = try await view.callAsyncJavaScript(#"""
        const root = document.getElementById('document'), block = root.children[1];
        root.focus(); getSelection().setPosition(root.firstElementChild.firstChild, 0);
        const transfer = new DataTransfer();
        for (const name of names) transfer.items.add(new File(['placeholder'], name, { type:'audio/mpeg' }));
        const rect = block.getBoundingClientRect(), x = rect.left + 12, y = rect.bottom - 2;
        block.dispatchEvent(new DragEvent('dragover', { bubbles:true, cancelable:true, dataTransfer:transfer, clientX:x, clientY:y }));
        if (root.dataset.audioDrop !== 'true') throw new Error('MP3 drag hint missing');
        const drop = new DragEvent('drop', { bubbles:true, cancelable:true, dataTransfer:transfer, clientX:x, clientY:y });
        block.dispatchEvent(drop);
        if (!drop.defaultPrevented || root.dataset.audioDrop) throw new Error('native drop must consume event and clear hint');
        """#, arguments: ["names": files.map(\.lastPathComponent)], in: nil, contentWorld: .page)
        for _ in 0..<200 { if inserted.count == 2 { break }; try await Task.sleep(nanoseconds: 25_000_000) }
        try audioExpect(inserted.count == 2 && inserted.map(\.name) == files.map(\.lastPathComponent), "drop must import both native files in order without a picker")
        try audioExpect(RichArticleDocument.audioURLs(in: html) == inserted.map(\.url), "drop must publish workspace references into the native document")
        for media in inserted {
            let importedURL = await store.mediaURL(for: media.url)!
            try audioExpect(try Data(contentsOf: importedURL) == Data(contentsOf: fixture), "native importer must copy the actual MP3, not browser placeholder data")
        }
        _ = try await view.callAsyncJavaScript(#"""
        const root = document.getElementById('document');
        if (root.children[1].textContent !== '第二段' || !root.children[2].matches('figure[data-type=audio]') || !root.children[3].matches('figure[data-type=audio]') || root.lastElementChild.textContent !== '第三段') throw new Error('drop used old caret instead of drop position');
        LeonArticle.undo(-1); if (root.querySelector('audio')) throw new Error('batch drop must undo in one step');
        LeonArticle.undo(1); if (root.querySelectorAll('audio').length !== 2) throw new Error('batch drop must redo in one step');
        const saved = LeonArticle.serialize(); LeonArticle.load(saved, 'read-only-drop', false, 18);
        const transfer = new DataTransfer(); transfer.items.add(new File(['ignored'], 'ignored.mp3', { type:'audio/mpeg' }));
        root.dispatchEvent(new DragEvent('drop', { bubbles:true, cancelable:true, dataTransfer:transfer }));
        if (LeonArticle.serialize() !== saved || document.querySelector('[data-command=audio]').disabled) throw new Error('read-only drop changed document');
        """#, arguments: [:], in: nil, contentWorld: .page)
        await store.closeForRestore()
    }

    @MainActor
    func testAudioInsertionUndoCancellationAndSanitization() async throws {
        let messages = AudioRequestRecorder()
        try await RichArticleTests().withWebEditor(messageHandler: messages) { view in
            _ = try await view.callAsyncJavaScript(#"""
            const root = document.getElementById('document');
            LeonArticle.load('<article data-leon-format="html-v1"><p>前文</p><p>后文</p></article>', 'audio-note', true, 18);
            root.focus(); getSelection().setPosition(root.firstElementChild.firstChild, 2);
            document.querySelector('[data-command=audio]').dispatchEvent(new MouseEvent('mousedown', { bubbles:true }));
            """#, arguments: [:], in: nil, contentWorld: .page)
            for _ in 0..<40 { if !messages.requests.isEmpty { break }; try await Task.sleep(nanoseconds: 25_000_000) }
            guard let request = messages.requests.last else { throw AudioTestFailure(description: "toolbar must request a native MP3 picker") }
            _ = try await view.callAsyncJavaScript(#"""
            const expect = (value, message) => { if (!value) throw new Error(message); };
            const root = document.getElementById('document'), source = '/media/inbox/recording.mp3';
            expect(LeonArticle.completeAudio(requestID, source, '录音 <一> & 二.mp3'), 'insert failed');
            expect(root.children[1].matches('figure[data-type=audio]'), 'audio belongs after current paragraph');
            expect(root.firstElementChild.textContent === '前文' && root.lastElementChild.textContent === '后文', 'surrounding text changed');
            const audio = root.querySelector('audio'), saved = LeonArticle.serialize();
            expect(audio.controls && audio.preload === 'none' && audio.paused, 'player must be user controlled and load on demand');
            expect(saved.includes(source) && !saved.includes('leonmedia:') && !saved.includes('data-original-src'), 'persist workspace path, not runtime URL');
            expect(saved.includes('录音 &lt;一&gt; &amp; 二.mp3') && !saved.includes('contenteditable'), 'caption must be escaped; runtime state must not be saved');
            expect(LeonArticle.cleanHTML(saved).includes('<audio'), 'sanitizer lost player');
            const unsafe = LeonArticle.cleanHTML('<audio src="javascript:alert(1)" autoplay onerror="alert(1)"></audio><audio src="/media/inbox/safe.mp3" autoplay loop onplay="alert(1)"></audio>');
            expect(!/javascript:|autoplay|onerror|onplay|loop/.test(unsafe), 'unsafe attributes survived');
            LeonArticle.undo(-1); expect(!root.querySelector('audio'), 'undo insertion');
            LeonArticle.undo(1); expect(root.querySelector('audio'), 'redo insertion');
            LeonArticle.load(saved, 'reopened', true, 18);
            const figure = root.querySelector('figure'); figure.focus();
            figure.dispatchEvent(new KeyboardEvent('keydown', { key:'Delete', bubbles:true }));
            expect(!root.querySelector('audio'), 'delete entire audio block');
            LeonArticle.undo(-1); expect(root.querySelector('audio'), 'undo deletion');
            LeonArticle.load(saved, 'reader', false, 18);
            expect(root.querySelector('audio').controls && getComputedStyle(document.getElementById('toolbar')).display === 'none', 'reader should expose playback only');
            expect(!LeonArticle.execute('audio'), 'read-only insertion must fail');
            LeonArticle.load('<article data-leon-format="html-v1"><p>/audio</p></article>', 'cancel-note', true, 18);
            root.focus(); getSelection().setPosition(root.firstElementChild.firstChild, 6);
            document.dispatchEvent(new Event('selectionchange')); LeonArticle.execute('audio');
            """#, arguments: ["requestID": request], in: nil, contentWorld: .page)
            for _ in 0..<40 { if messages.requests.count > 1 { break }; try await Task.sleep(nanoseconds: 25_000_000) }
            guard let cancelRequest = messages.requests.last, cancelRequest != request else { throw AudioTestFailure(description: "slash command must request MP3") }
            _ = try await view.callAsyncJavaScript(#"""
            const before = LeonArticle.serialize(); LeonArticle.cancelAudio(requestID);
            if (before !== LeonArticle.serialize()) throw new Error('cancel changed article');
            if (document.querySelector('[data-command=audio]').disabled) throw new Error('cancel left button disabled');
            LeonArticle.execute('audio');
            """#, arguments: ["requestID": cancelRequest], in: nil, contentWorld: .page)
            for _ in 0..<40 { if messages.requests.count > 2 { break }; try await Task.sleep(nanoseconds: 25_000_000) }
            guard let staleRequest = messages.requests.last, staleRequest != cancelRequest else { throw AudioTestFailure(description: "retry must work after cancellation") }
            _ = try await view.callAsyncJavaScript(#"""
            LeonArticle.load('<article data-leon-format="html-v1"><p>另一篇文章</p></article>', 'other', true, 18);
            if (LeonArticle.completeAudio(requestID, '/media/inbox/stale.mp3', 'stale')) throw new Error('stale upload changed new article');
            """#, arguments: ["requestID": staleRequest], in: nil, contentWorld: .page)
        }
    }

    @MainActor
    func testAudioPersistsAndPlaysFromWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leon-audio-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = Bundle.module.url(forResource: "article-audio-silence", withExtension: "mp3", subdirectory: "Fixtures")!
        let source = root.appendingPathComponent("录音 & 测试.MP3")
        try FileManager.default.copyItem(at: fixture, to: source)
        let store = LocalBlogStore(rootURL: root.appendingPathComponent("workspace"))
        let uploaded = try await NativeMediaUpload.files([source], kind: .audio, destination: .inbox, store: store)
        let media = uploaded[0]
        try FileManager.default.removeItem(at: source)
        let body = RichArticleDocument.opening + "<p>音频正文</p><figure data-type=\"audio\"><audio src=\"\(media.url)\" controls preload=\"none\"></audio><figcaption>录音</figcaption></figure></article>"
        let saved = try await store.saveArticle(NativeSaveArticle(
            banner: nil, body: body, category: "Notes", excerpt: "", media: uploaded, slug: "audio-test",
            status: .draft, tags: [], title: "Audio", expectedUpdatedAt: nil
        ))
        try audioExpect(saved.media[0].url.hasPrefix("/media/audio-test/"), "new article save must relocate inbox audio")
        try await store.discardUnreferencedMedia(saved.media)
        let mediaURL = await store.mediaURL(for: saved.media[0].url)!
        try audioExpect(FileManager.default.fileExists(atPath: mediaURL.path), "saved audio must survive removal of source and orphan cleanup")
        let parsed = NativeMarkdownArticleDocument(markdown: saved.body)
        try audioExpect(parsed.embeddedAttachmentURLs.contains(saved.media[0].url) && parsed.imageURLs.isEmpty, "embedded audio must not appear again in attachment footer")
        let sourceFile = try RichArticleFile.render(saved)
        let record = try RichArticleFile.read(sourceFile, relativePath: "audio.html", modifiedAt: saved.updatedAt)
        try audioExpect(record.body == saved.body && record.media == saved.media, "HTML round-trip lost audio")
        await store.closeForRestore()
        let reopened = LocalBlogStore(rootURL: root.appendingPathComponent("workspace"))
        let article = try await reopened.getArticle(slug: saved.slug)
        try audioExpect(article.body == saved.body && article.media == saved.media, "database reopen lost audio")
        try await RichArticleTests().withWebEditor(mediaStore: reopened) { view in
            _ = try await view.callAsyncJavaScript(#"""
            LeonArticle.load(body, 'playback', false, 18);
            const player = document.querySelector('audio'); player.muted = true;
            player.load();
            for (let i=0;i<160 && player.readyState<2 && !player.error;i++) await new Promise(resolve=>setTimeout(resolve,25));
            if (player.error || !Number.isFinite(player.duration) || player.duration < 2) throw new Error('local MP3 failed to load: '+player.error?.code+' '+player.error?.message);
            await player.play();
            for (let i=0;i<80 && player.currentTime<=0 && !player.error;i++) await new Promise(resolve=>setTimeout(resolve,25));
            if (player.paused || player.currentTime <= 0) throw new Error('local MP3 did not play: paused='+player.paused+' readyState='+player.readyState+' error='+player.error?.code);
            player.pause(); player.currentTime = 1.5;
            for (let i=0;i<80 && player.seeking;i++) await new Promise(resolve=>setTimeout(resolve,25));
            if (player.seeking || Math.abs(player.currentTime-1.5)>0.1) throw new Error('local MP3 seek failed');
            """#, arguments: ["body": article.body], in: nil, contentWorld: .page)
        }
        await reopened.closeForRestore()
    }
}

private final class AudioRequestRecorder: NSObject, WKScriptMessageHandler {
    var requests: [String] = []
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let payload = message.body as? [String: Any], payload["type"] as? String == "chooseAudio", let id = payload["requestID"] as? String { requests.append(id) }
    }
}
