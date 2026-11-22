import AppKit
import WebKit
@testable import LeonBook

@MainActor private final class ReaderHeightRecorder: NSObject, WKScriptMessageHandler {
    var height: CGFloat?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any], payload["type"] as? String == "height",
              let height = payload["height"] as? Double else { return }
        self.height = height
    }
}

extension RichArticleTests {
    @MainActor
    func testReaderReportedHeightContainsHeadingMarginsWithoutInnerScroll() async throws {
        let recorder = ReaderHeightRecorder()
        try await withWebEditor(messageHandler: recorder) { view in
            let fixtures = [
                "<h2>对话总结</h2><p>正文</p>",
                "<h1>文章标题</h1><p>正文</p><h2>原始对话</h2>" + String(repeating: "<h3>AI 回复</h3><pre>对话正文\n第二行</pre>", count: 30),
                "<h3>小标题</h3><p>末尾段落</p>",
                "<h4>引用标题</h4><blockquote><p>引用正文</p></blockquote>",
                "<p>没有标题的普通正文</p>"
            ]
            for width: CGFloat in [320, 800] {
                for size in [14, 18, 24] {
                    for (index, fixture) in fixtures.enumerated() {
                        view.setFrameSize(NSSize(width: width, height: 600))
                        recorder.height = nil
                        _ = try await view.callAsyncJavaScript("LeonArticle.load(body, id, false, size, true);", arguments: [
                            "body": RichArticleDocument.opening + fixture + "</article>",
                            "id": "reader-height-\(width)-\(size)-\(index)", "size": size
                        ], in: nil, contentWorld: .page)
                        for _ in 0..<40 {
                            if recorder.height != nil { break }
                            try await Task.sleep(nanoseconds: 10_000_000)
                        }
                        guard let height = recorder.height else { throw ReaderHeightFailure.missingHeight }
                        // Mirror RichArticleReader's frame(height: contentHeight).
                        view.setFrameSize(NSSize(width: width, height: height))
                        _ = try await view.callAsyncJavaScript(#"""
                        await new Promise(resolve => setTimeout(resolve, 80));
                        const scrolling = document.scrollingElement;
                        if (scrolling.scrollHeight > innerHeight + 1) {
                          throw new Error(`Reader height ${innerHeight} leaves ${scrolling.scrollHeight - innerHeight}px of overflow, creating a second scrollbar`);
                        }
                        const last = document.getElementById('document').lastElementChild;
                        if (last && last.getBoundingClientRect().bottom > innerHeight + 1) {
                          throw new Error('Last article block is clipped by the reported reader height');
                        }
                        """#, arguments: [:], in: nil, contentWorld: .page)
                    }
                }
            }
        }
    }
}

private enum ReaderHeightFailure: Error { case missingHeight }
