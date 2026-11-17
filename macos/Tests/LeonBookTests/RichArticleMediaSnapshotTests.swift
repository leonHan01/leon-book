import WebKit
@testable import LeonBook

private struct MediaSnapshotFailure: Error, CustomStringConvertible { let description: String }

@MainActor private final class MediaSnapshotRecorder: NSObject, WKScriptMessageHandler {
    var requests: [String] = []
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any],
              let type = payload["type"] as? String, ["editWhiteboard", "chooseAudio"].contains(type),
              let id = payload["requestID"] as? String else { return }
        requests.append(id)
    }
}

final class RichArticleMediaSnapshotTests {
    @MainActor
    func testWhiteboardCompletionIgnoresImagePresentationChanges() async throws {
        let messages = MediaSnapshotRecorder()
        try await RichArticleTests().withWebEditor(messageHandler: messages) { view in
            _ = try await view.evaluateJavaScript(#"""
            const root = document.getElementById('document');
            const boardSource = '/media/whiteboards/' + 'a'.repeat(64) + '.excalidraw';
            LeonArticle.load('<article data-leon-format="html-v1"><figure data-type="whiteboard" data-whiteboard-source="' + boardSource + '"><img src="' + boardSource.replace('.excalidraw', '.png') + '"><figcaption>原画板</figcaption></figure><p>后文</p></article>', 'board-image-state', true, 18);
            const board = root.querySelector('figure'), image = board.querySelector('img');
            image.classList.add('article-image-pending');
            board.dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
            image.dispatchEvent(new Event('load'));
            if (image.classList.contains('article-image-pending')) throw new Error('load did not remove the runtime placeholder');
            """#)
            let first = try await self.request(0, in: messages)
            _ = try await view.callAsyncJavaScript(#"""
            const next = '/media/whiteboards/' + 'b'.repeat(64) + '.excalidraw';
            if (!LeonArticle.completeWhiteboard(requestID, next, next.replace('.excalidraw', '.png'))) throw new Error('image load discarded the completed whiteboard');
            if (!LeonArticle.serialize().includes(next)) throw new Error('completed board was not published');
            root.querySelector('figure').dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
            root.querySelector('figcaption').textContent = '用户在等待时编辑了说明';
            """#, arguments: ["requestID": first], in: nil, contentWorld: .page)
            let second = try await self.request(1, in: messages)
            _ = try await view.callAsyncJavaScript(#"""
            const next = '/media/whiteboards/' + 'c'.repeat(64) + '.excalidraw';
            if (LeonArticle.completeWhiteboard(requestID, next, next.replace('.excalidraw', '.png'))) throw new Error('a genuine caption edit must still reject a stale completion');
            if (!LeonArticle.serialize().includes('用户在等待时编辑了说明')) throw new Error('newer user text was lost');
            """#, arguments: ["requestID": second], in: nil, contentWorld: .page)
        }
    }

    @MainActor
    func testAudioCompletionIgnoresImagePresentationChanges() async throws {
        let messages = MediaSnapshotRecorder()
        try await RichArticleTests().withWebEditor(messageHandler: messages) { view in
            _ = try await view.evaluateJavaScript(#"""
            const root = document.getElementById('document');
            LeonArticle.load('<article data-leon-format="html-v1"><p><img src="/media/note/image.png"><span>图片说明</span></p><p>后文</p></article>', 'audio-image-state', true, 18);
            const block = root.firstElementChild, image = block.querySelector('img');
            image.classList.add('article-image-pending');
            root.focus(); getSelection().setPosition(block, block.childNodes.length);
            if (!LeonArticle.execute('audio')) throw new Error('audio request missing');
            image.dispatchEvent(new Event('load'));
            if (image.classList.contains('article-image-pending')) throw new Error('load did not remove the runtime placeholder');
            """#)
            let first = try await self.request(0, in: messages)
            _ = try await view.callAsyncJavaScript(#"""
            if (!LeonArticle.completeAudio(requestID, '/media/inbox/first.mp3', '录音')) throw new Error('image load discarded the imported recording');
            if (!LeonArticle.serialize().includes('/media/inbox/first.mp3')) throw new Error('recording was not published');
            root.focus(); getSelection().setPosition(block, block.childNodes.length);
            if (!LeonArticle.execute('audio')) throw new Error('second audio request missing');
            block.lastChild.textContent = '用户在等待时修改了正文';
            """#, arguments: ["requestID": first], in: nil, contentWorld: .page)
            let second = try await self.request(1, in: messages)
            _ = try await view.callAsyncJavaScript(#"""
            if (LeonArticle.completeAudio(requestID, '/media/inbox/stale.mp3', '过期录音')) throw new Error('a genuine text edit must still reject a stale completion');
            const body = LeonArticle.serialize();
            if (body.includes('/media/inbox/stale.mp3') || !body.includes('用户在等待时修改了正文')) throw new Error('stale import altered newer text');
            """#, arguments: ["requestID": second], in: nil, contentWorld: .page)
        }
    }

    @MainActor private func request(_ index: Int, in recorder: MediaSnapshotRecorder) async throws -> String {
        for _ in 0..<100 {
            if recorder.requests.count > index { return recorder.requests[index] }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw MediaSnapshotFailure(description: "native media request was not delivered")
    }
}
