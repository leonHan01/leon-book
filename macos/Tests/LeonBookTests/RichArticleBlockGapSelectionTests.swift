import AppKit
import WebKit
@testable import LeonBook

extension RichArticleTests {
    @MainActor
    func testRichArticleBlockGapSelectionPreservesContent() async throws {
        try await withWebEditor { view in
            _ = try await view.callAsyncJavaScript(#"""
            const root = document.getElementById('document'), selection = getSelection();
            const expect = (value, message) => { if (!value) throw new Error(message); };
            const load = (html, editable = true) => LeonArticle.load('<article data-leon-format="html-v1">' + html + '</article>', 'gap-' + Math.random(), editable, 18);
            const select = (startNode, startOffset, endNode, endOffset, pointer = true) => {
              root.focus();
              if (pointer) root.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, button: 0 }));
              selection.setBaseAndExtent(startNode, startOffset, endNode, endOffset);
              document.dispatchEvent(new Event('selectionchange'));
              document.dispatchEvent(new PointerEvent('pointerup', { bubbles: true, button: 0 }));
            };
            for (const html of ['<p>A</p><p>B</p>', '<h1>A</h1><h2>B</h2>', '<p><strong>A</strong></p><p><em>B</em></p>', '<p>A</p><p><br></p>', '<table><tr><td><p>A</p><p>B</p></td></tr></table>', '<div data-type="columns"><div data-type="column"><p>A</p><p>B</p></div><div data-type="column"><p>C</p></div></div>']) {
              load(html); const saved = LeonArticle.serialize(), first = root.querySelector('p,h1'), second = first.nextElementSibling;
              const start = first.querySelector('strong')?.firstChild || first.firstChild;
              const end = second.querySelector('em')?.firstChild || second;
              select(start, start.length, end, 0);
              expect(selection.isCollapsed && selection.focusNode === end && selection.focusOffset === 0, 'a forward pointer selection of only a block boundary must collapse at its focus');
              select(end, 0, start, start.length);
              expect(selection.isCollapsed && selection.focusNode === start && selection.focusOffset === start.length, 'a backward boundary selection must keep its focus direction');
              expect(LeonArticle.serialize() === saved, 'normalizing a gap must not modify blocks or saved content');
              LeonArticle.undo(-1); expect(LeonArticle.serialize() === saved, 'normalizing a gap must not create an undo entry');
            }
            load('<p>A</p><p>B</p>'); let first = root.firstElementChild, second = root.lastElementChild;
            select(first.firstChild, 0, second.firstChild, 1); expect(!selection.isCollapsed && selection.toString().includes('A') && selection.toString().includes('B'), 'ordinary cross-block text selection must remain intact');
            select(first.firstChild, 1, second.firstChild, 0, false); expect(!selection.isCollapsed, 'keyboard/programmatic selection of a paragraph break must remain editable');
            select(root, 1, second, 0); expect(selection.isCollapsed, 'container-boundary endpoints must also discard pure block spacing');
            load('<p>A  B</p>'); first = root.firstElementChild;
            select(first.firstChild, 1, first.firstChild, 3); expect(!selection.isCollapsed && selection.getRangeAt(0).toString() === '  ', 'literal spaces must remain selectable');
            load('<p>A</p><p><br></p><p>B</p>'); first = root.firstElementChild; second = root.lastElementChild;
            select(first.firstChild, 1, second.firstChild, 0); expect(!selection.isCollapsed, 'an explicitly empty paragraph between blocks must remain selectable and deletable');
            const empty = root.children[1]; select(empty, 0, empty, 1); expect(!selection.isCollapsed, 'an empty paragraph placeholder must remain selectable');
            load('<p>A<br>B</p>'); first = root.firstElementChild;
            select(first, 1, first, 2); expect(!selection.isCollapsed, 'soft line breaks inside a block must remain selectable');
            load('<p>A<br></p><p>B</p>'); first = root.firstElementChild; second = root.lastElementChild;
            select(first.firstChild, 1, second, 0); expect(!selection.isCollapsed, 'a trailing soft line break is content, not block spacing');
            load('<table><tr><td><p>A</p></td><td><p>B</p></td></tr></table>');
            const paragraphs = root.querySelectorAll('p'); select(paragraphs[0].firstChild, 1, paragraphs[1].firstChild, 0);
            expect(!selection.isCollapsed, 'table cell boundaries must keep their own selection behavior');
            load('<p>A</p><p>B</p>', false); first = root.firstElementChild; second = root.lastElementChild;
            select(first.firstChild, 1, second.firstChild, 0); expect(!selection.isCollapsed, 'reading mode must preserve native selection');
            return true;
            """#, arguments: [:], in: nil, contentWorld: .page)
        }
    }
}
