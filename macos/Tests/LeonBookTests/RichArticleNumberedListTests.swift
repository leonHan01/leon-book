import AppKit
import WebKit
@testable import LeonBook

extension RichArticleTests {
    @MainActor
    func testRichArticleNumberingRestartsAtEachIndent() async throws {
        try await withWebEditor { view in
            _ = try await view.callAsyncJavaScript(#"""
            const root = document.getElementById('document');
            const expect = (value, message) => { if (!value) throw new Error(message); };
            const load = (html, editable = true) => LeonArticle.load('<article data-leon-format="html-v1">' + html + '</article>', 'numbering-' + Math.random(), editable, 18);
            const number = (text, depth = 0) => `<p data-type="number" data-depth="${depth}">${text}</p>`;
            const values = (container = root) => [...container.querySelectorAll('[data-type=number]')].map(block => +block.dataset.number).join(',');
            const focus = block => { root.focus(); const range = document.createRange(); range.selectNodeContents(block); range.collapse(false); getSelection().removeAllRanges(); getSelection().addRange(range); };
            const tab = (index, shiftKey = false) => {
              focus(root.children[index]); const selection = getSelection(), node = selection.anchorNode, offset = selection.anchorOffset;
              const event = new KeyboardEvent('keydown', { key: 'Tab', shiftKey, bubbles: true, cancelable: true }); root.dispatchEvent(event);
              expect(event.defaultPrevented && getSelection().anchorNode === node && getSelection().anchorOffset === offset, 'Tab must indent the current block without moving the caret');
            };
            load(number('A') + number('B'));
            const original = LeonArticle.serialize(); tab(1);
            expect(values() === '1,1', 'Tab must restart a new child list at 1');
            const indented = LeonArticle.serialize(); LeonArticle.undo(-1); expect(LeonArticle.serialize() === original && values() === '1,2', 'one undo must restore the parent numbering');
            LeonArticle.undo(1); expect(LeonArticle.serialize() === indented && values() === '1,1', 'redo must restore child numbering');
            load(number('A') + number('B') + number('C') + number('D'));
            tab(1); tab(2); tab(2); tab(3); tab(3);
            expect(values() === '1,1,1,2', 'each nested level must restart, while siblings at the deepest level continue');
            tab(3, true); expect(values() === '1,1,1,2' && root.children[3].dataset.depth === '1', 'Shift+Tab must continue the prior level');
            tab(3, true); expect(values() === '1,1,1,2' && root.children[3].dataset.depth === '0', 'returning to the root must resume its own counter');
            // Enter continues the same level; indenting that new item starts a new child list.
            root.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertParagraph', bubbles: true, cancelable: true }));
            expect(values() === '1,1,1,2,3', 'Enter must continue the current list level');
            tab(4); expect(values() === '1,1,1,2,1', 'a different parent must start a fresh child list');
            const saved = LeonArticle.serialize(); LeonArticle.load(saved, 'numbering-reopened', true, 18);
            expect(values() === '1,1,1,2,1', 'numbering must survive saving and reopening');
            LeonArticle.load(saved, 'numbering-reader', false, 18);
            expect(values() === '1,1,1,2,1', 'reading mode must use the same numbering');
            load(number('A') + number('B', 1) + number('C', 2) + number('D', 1) + number('E') + number('F', 1) + number('G', 1));
            expect(values() === '1,1,1,2,2,1,2', 'returning from deeper children must preserve sibling counters and reset only deeper branches');
            load(number('A', 3) + number('B', 3) + '<p>Paragraph break</p>' + number('C', 3));
            expect(values() === '1,2,1', 'a standalone indented list starts at 1 and normal prose separates lists');
            load('<table><tr><td>' + number('A') + number('B', 1) + number('C', 1) + '</td><td>' + number('D') + number('E', 1) + '</td></tr></table>');
            expect(values(root.querySelectorAll('td')[0]) === '1,1,2' && values(root.querySelectorAll('td')[1]) === '1,1', 'each table cell must have independent counters');
            load('<div data-type="columns"><div data-type="column">' + number('A') + number('B', 1) + '</div><div data-type="column">' + number('C') + number('D', 1) + '</div></div>');
            expect(values() === '1,1,1,1', 'each document column must have independent counters');
            return true;
            """#, arguments: [:], in: nil, contentWorld: .page)
        }
    }
}
