import AppKit
import WebKit
@testable import LeonBook

extension RichArticleTests {
    @MainActor
    func testRichArticleClearFormattingKeepsSelectionAndUndo() async throws {
        try await withWebEditor { view in
            _ = try await view.callAsyncJavaScript(#"""
            const root = document.getElementById('document'), toolbar = document.getElementById('selection-toolbar');
            const expect = (value, message) => { if (!value) throw new Error(message); };
            const load = html => LeonArticle.load('<article data-leon-format="html-v1">' + html + '</article>', 'clear-format-' + Math.random(), true, 18);
            const select = (start, startOffset, end, endOffset, backward = false) => {
              root.focus(); getSelection().setBaseAndExtent(...(backward ? [end, endOffset, start, startOffset] : [start, startOffset, end, endOffset]));
              document.dispatchEvent(new Event('selectionchange'));
            };
            const clear = () => toolbar.querySelector('[data-format=removeFormat]').click();
            load('<p><span style="color:#252827">Before <b><i><u><strike>Selected</strike></u></i></b> After</span></p>');
            select(root.firstElementChild, 0, root.firstElementChild, 1, true);
            const original = LeonArticle.serialize(), text = root.textContent;
            clear();
            expect(!root.querySelector('b,strong,i,em,u,s,strike,font,span') && root.textContent === text, 'nested color and styles must clear without leaving a synthesized FONT');
            const selection = getSelection(), range = selection.getRangeAt(0);
            expect(selection.toString() === text && selection.anchorNode === range.endContainer && selection.anchorOffset === range.endOffset, 'clearing must preserve a backwards selection');
            const cleared = LeonArticle.serialize();
            LeonArticle.undo(-1); expect(LeonArticle.serialize() === original, 'one undo must restore all cleared formatting');
            LeonArticle.undo(1); expect(LeonArticle.serialize() === cleared, 'one redo must remove all formatting again');

            load('<p><strong style="color:#4b7dce">Before Selected After</strong> <a href="https://example.com">Link</a></p>');
            const node = root.querySelector('strong').firstChild;
            select(node, 7, node, 15);
            const partialOriginal = LeonArticle.serialize(); clear();
            expect(getSelection().toString() === 'Selected' && !document.queryCommandState('bold'), 'partial clearing must keep the exact selected text and remove its bold style');
            expect([...root.querySelectorAll('b,strong')].map(item => item.textContent).join('') === 'Before  After', 'unselected text must retain its bold style');
            expect(root.querySelector('a')?.getAttribute('href') === 'https://example.com' && root.textContent === 'Before Selected After Link', 'clearing must preserve links and surrounding content');
            LeonArticle.undo(-1); expect(LeonArticle.serialize() === partialOriginal, 'partial clearing must also be one undo step');
            return true;
            """#, arguments: [:], in: nil, contentWorld: .page)
        }
    }
}
