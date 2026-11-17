import WebKit
@testable import LeonBook

extension RichArticleTests {
    @MainActor
    func testReaderImagesFollowNativeViewportAndPreserveSources() async throws {
        try await withWebEditor { view in
            _ = try await view.callAsyncJavaScript(#"""
            const root = document.getElementById('document');
            const expect = (value, message) => { if (!value) throw new Error(message); };
            const wait = () => new Promise(resolve => setTimeout(resolve, 120));
            const opening = '<article data-leon-format="html-v1">';
            const source = opening + Array.from({length: 40}, (_, index) =>
              Array.from({length: 20}, () => '<p>段落正文用于保持每张图片之间的距离。</p>').join('') + '<p><img src="/media/viewport-' + index + '.png" alt="图片"></p>'
            ).join('') + '</article>';
            LeonArticle.load(source, 'reader-image-viewport', false, 18, true);
            LeonArticle.setReaderViewport(0, 600); await wait();
            const images = [...root.querySelectorAll('img')];
            const initial = images.filter(image => image.hasAttribute('src')).length;
            expect(initial < 4, 'native first viewport must not request all article images');
            const last = images.at(-1);
            expect(!last.hasAttribute('src'), 'offscreen last image must remain deferred');
            LeonArticle.setReaderViewport(last.getBoundingClientRect().top + scrollY, 600); await wait();
            expect(last.getAttribute('src')?.includes('maxPixelSize=2400'), 'scrolling must load a bounded thumbnail near the native viewport');
            const saved = LeonArticle.serialize();
            expect(saved.includes('/media/viewport-0.png') && saved.includes('/media/viewport-39.png'), 'deferred and loaded images must retain original sources');
            expect(!saved.includes('maxPixelSize') && !saved.includes('article-image-pending'), 'rendering details must not leak into saved HTML');
            LeonArticle.load(saved, 'reader-image-viewport', true, 18);
            expect([...root.querySelectorAll('img')].every(image => image.hasAttribute('src')), 'entering edit mode must activate remaining image previews');
            """#, arguments: [:], in: nil, contentWorld: .page)
        }
    }
}
