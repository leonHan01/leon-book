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
    func testSingleLeadingMP3SticksWithoutRecreatingPlayer() async throws {
        try await RichArticleTests().withWebEditor { view in
            _ = try await view.callAsyncJavaScript(#"""
            const root = document.getElementById('document');
            const audio = '<figure data-type="audio"><audio src="/media/note/a.mp3" controls></audio><figcaption>录音</figcaption></figure>';
            const tail = '<p>' + '正文<br>'.repeat(500) + '</p>';
            const expect = (ok, reason) => { if (!ok) throw new Error(reason); };
            LeonArticle.load('<article data-leon-format="html-v1">' + audio + tail + '</article>', 'sticky-editor', true, 18);
            const player = root.querySelector('audio'), block = player.closest('figure');
            expect(root.dataset.stickyAudio === 'true' && getComputedStyle(block).position === 'sticky', 'leading MP3 should stick in editor');
            const before = LeonArticle.serialize();
            window.scrollTo(0, 600);
            expect(block.getBoundingClientRect().top >= 39 && block.getBoundingClientRect().top < 43, 'player must stay below the editor toolbar');
            expect(root.querySelector('audio') === player && LeonArticle.serialize() === before, 'scroll must keep player and saved HTML unchanged');
            LeonArticle.load('<article data-leon-format="html-v1"><p>前文</p>' + audio + tail + '</article>', 'not-first', true, 18);
            expect(!root.dataset.stickyAudio, 'audio after text must not stick');
            LeonArticle.load('<article data-leon-format="html-v1">' + audio + audio + tail + '</article>', 'two', true, 18);
            expect(!root.dataset.stickyAudio, 'multiple audio players must not stick');
            LeonArticle.load('<article data-leon-format="html-v1">' + audio.replace('a.mp3', 'a.wav') + tail + '</article>', 'other-format', true, 18);
            expect(!root.dataset.stickyAudio, 'non-MP3 audio must not stick');
            LeonArticle.load('<article data-leon-format="html-v1">' + audio + tail + '</article>', 'reader', false, 18, true);
            const readerPlayer = root.querySelector('audio'), readerBlock = readerPlayer.closest('figure');
            LeonArticle.setReaderViewport(500);
            expect(parseFloat(getComputedStyle(root).getPropertyValue('--reader-audio-offset')) > 0, 'native reader viewport must move the player');
            expect(root.querySelector('audio') === readerPlayer && readerBlock === root.firstElementChild, 'reader must retain the original player');
            """#, arguments: [:], in: nil, contentWorld: .page)
        }
    }

    @MainActor
    func testAudioDropImportsAtDropLocationThroughNativeBridge(mixedMedia: Bool = false) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("leon-audio-drop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = Bundle.module.url(forResource: "article-audio-silence", withExtension: "mp3", subdirectory: "Fixtures")!
        let files = (mixedMedia ? ["图片 & 一.PNG", "视频二.MP4", "录音三.mp3"] : ["录音 & 一.MP3", "录音二.mp3"])
            .map { directory.appendingPathComponent($0) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=")!
        let videoFixture = Bundle.module.url(forResource: "media-library-sample", withExtension: "mp4", subdirectory: "Fixtures")!
        var originalData: [Data] = []
        for file in files {
            let kind = NativeArticleMediaDrop.kind(for: file)!
            let data: Data
            if kind == .image { data = png }
            else { data = try Data(contentsOf: kind == .video ? videoFixture : fixture) }
            try data.write(to: file); originalData.append(data)
        }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects(files.map { $0 as NSURL })
        try audioExpect(NativeArticleMediaDrop.fileURLs(from: pasteboard, matching: files.map(\.lastPathComponent)) == files, "native file URLs must preserve unicode names and drop order")
        try audioExpect(NativeArticleMediaDrop.fileURLs(from: pasteboard, matching: ["missing.mp3"]) == nil, "reject mismatched drag data")
        try audioExpect(NativeArticleMediaDrop.fileURLs(from: pasteboard, matching: ["document.txt"]) == nil, "reject unsupported files")
        let store = LocalBlogStore(rootURL: directory.appendingPathComponent("workspace"))
        var html = RichArticleDocument.opening + "<p>第一段</p><p>第二段</p><p>第三段</p></article>"
        var inserted: [NativeMedia] = []
        let host = NSHostingView(rootView: RichArticleEditor(
            html: Binding(get: { html }, set: { html = $0 }), documentID: "drop-bridge", store: store,
            onImportMedia: { url in
                try await NativeMediaUpload.files([url], kind: NativeArticleMediaDrop.kind(for: url)!, destination: .inbox, store: store)[0]
            },
            onMediaInserted: { inserted.append($0) }
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
        coordinator.mediaDropPasteboard = pasteboard
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
        for (let i=0; i<names.length; i++) transfer.items.add(new File(['placeholder'], names[i], { type: kinds[i] + '/' + (kinds[i] === 'video' ? 'mp4' : kinds[i] === 'image' ? 'png' : 'mpeg') }));
        const rect = block.getBoundingClientRect(), x = rect.left + 12, y = rect.bottom - 2;
        block.dispatchEvent(new DragEvent('dragover', { bubbles:true, cancelable:true, dataTransfer:transfer, clientX:x, clientY:y }));
        if (root.dataset.audioDrop !== 'true') throw new Error('media drag hint missing');
        const drop = new DragEvent('drop', { bubbles:true, cancelable:true, dataTransfer:transfer, clientX:x, clientY:y });
        block.dispatchEvent(drop);
        if (!drop.defaultPrevented || root.dataset.audioDrop) throw new Error('native drop must consume event and clear hint');
        """#, arguments: ["names": files.map(\.lastPathComponent), "kinds": files.map { NativeArticleMediaDrop.kind(for: $0)!.rawValue }], in: nil, contentWorld: .page)
        for _ in 0..<200 { if inserted.count == files.count { break }; try await Task.sleep(nanoseconds: 25_000_000) }
        try audioExpect(inserted.count == files.count && inserted.map(\.name) == files.map(\.lastPathComponent), "drop must import every native file in order without a picker")
        try audioExpect(RichArticleDocument.audioURLs(in: html) == inserted.filter(\.isAudio).map(\.url), "drop must publish workspace audio references")
        try audioExpect(RichArticleDocument.videoURLs(in: html) == inserted.filter(\.isVideo).map(\.url), "drop must publish workspace video references")
        try audioExpect(RichArticleDocument.imageURLs(in: html) == inserted.filter(\.isImage).map(\.url), "drop must publish workspace image references")
        for (index, media) in inserted.enumerated() {
            let importedURL = await store.mediaURL(for: media.url)!
            try audioExpect(try Data(contentsOf: importedURL) == originalData[index], "native importer must copy actual media, not browser placeholder data")
        }
        _ = try await view.callAsyncJavaScript(#"""
        const root = document.getElementById('document');
        if (root.children[1].textContent !== '第二段' || kinds.some((kind, i) => !root.children[i+2].matches(`figure[data-type=${kind}]`)) || root.lastElementChild.textContent !== '第三段') throw new Error('drop used old caret instead of drop position');
        LeonArticle.undo(-1); if (root.querySelector('audio,video,img')) throw new Error('batch drop must undo in one step');
        LeonArticle.undo(1); if (root.querySelectorAll('figure').length !== kinds.length) throw new Error('batch drop must redo in one step');
        const sanitized = LeonArticle.cleanHTML('<video src="javascript:alert(1)" autoplay onerror="alert(1)"></video><video src="/media/inbox/safe.mp4" autoplay loop onplay="alert(1)"></video>');
        if (!sanitized.includes('<video') || /javascript:|autoplay|onerror|onplay|loop/.test(sanitized)) throw new Error('unsafe video attributes survived or video was stripped');
        const saved = LeonArticle.serialize(); LeonArticle.load(saved, 'read-only-drop', false, 18);
        if (root.querySelectorAll('figure').length !== kinds.length) throw new Error('reopen lost media');
        const transfer = new DataTransfer(); transfer.items.add(new File(['ignored'], 'ignored.mp3', { type:'audio/mpeg' }));
        root.dispatchEvent(new DragEvent('drop', { bubbles:true, cancelable:true, dataTransfer:transfer }));
        if (LeonArticle.serialize() !== saved || document.querySelector('[data-command=audio]').disabled) throw new Error('read-only drop changed document');
        """#, arguments: ["kinds": inserted.map(\.kind)], in: nil, contentWorld: .page)
        let saved = try await store.saveArticle(NativeSaveArticle(
            banner: nil, body: html, category: "Notes", excerpt: "", media: inserted, slug: "dropped-media",
            status: .draft, tags: [], title: "Dropped media", expectedUpdatedAt: nil
        ))
        for file in files { try FileManager.default.removeItem(at: file) }
        try await store.discardUnreferencedMedia(saved.media)
        let parsed = NativeMarkdownArticleDocument(markdown: saved.body)
        try audioExpect(Set(saved.media.map(\.url)).isSubset(of: parsed.embeddedAttachmentURLs), "embedded media must not appear twice in attachment footer")
        let record = try RichArticleFile.read(RichArticleFile.render(saved), relativePath: "media.html", modifiedAt: saved.updatedAt)
        try audioExpect(record.body == saved.body && record.media == saved.media, "HTML round-trip lost mixed media")
        await store.closeForRestore()
        let reopened = LocalBlogStore(rootURL: directory.appendingPathComponent("workspace"))
        let article = try await reopened.getArticle(slug: saved.slug)
        try audioExpect(article.body == saved.body && article.media == saved.media, "database reopen lost dropped media")
        for (index, media) in article.media.enumerated() {
            let url = await reopened.mediaURL(for: media.url)!
            try audioExpect(try Data(contentsOf: url) == originalData[index], "saved media must survive removal of source and orphan cleanup")
        }
        if mixedMedia {
            try await RichArticleTests().withWebEditor(mediaStore: reopened) { view in
                _ = try await view.callAsyncJavaScript(#"""
                LeonArticle.load(body, 'mixed-playback', false, 18);
                const root = document.getElementById('document'), video = root.querySelector('video'), image = root.querySelector('img');
                if (!video.controls || video.preload !== 'none' || !video.paused) throw new Error('video must load on demand with playback controls');
                video.muted = true; video.load();
                for (let i=0; i<160 && video.readyState<2 && !video.error; i++) await new Promise(resolve => setTimeout(resolve,25));
                if (video.error || !Number.isFinite(video.duration) || video.duration <= 0) throw new Error('dropped video failed to load: '+video.error?.message);
                await video.play();
                for (let i=0; i<80 && video.currentTime<=0; i++) await new Promise(resolve => setTimeout(resolve,25));
                if (video.currentTime <= 0) throw new Error('dropped video did not play');
                video.pause(); video.currentTime = video.duration / 2;
                for (let i=0; i<80 && video.seeking; i++) await new Promise(resolve => setTimeout(resolve,25));
                if (video.seeking || Math.abs(video.currentTime-video.duration/2)>0.1) throw new Error('dropped video could not seek');
                for (let i=0; i<80 && !image.complete; i++) await new Promise(resolve => setTimeout(resolve,25));
                if (!image.naturalWidth) throw new Error('dropped image failed to display');
                """#, arguments: ["body": article.body], in: nil, contentWorld: .page)
            }
        }
        await reopened.closeForRestore()
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
