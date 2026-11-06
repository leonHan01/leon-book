import AppKit
import WebKit
@testable import LeonBook

extension RichArticleTests {
    @MainActor
    func testRichArticleDeletesAllHighlightedBlocks() async throws {
        try await withWebEditor { view in
            _ = try await view.callAsyncJavaScript(#"""
            const root = document.getElementById('document');
            const expect = (value, message) => { if (!value) throw new Error(message); };
            const load = (html, editable = true) => LeonArticle.load('<article data-leon-format="html-v1">' + html + '</article>', 'block-delete-' + Math.random(), editable, 18);
            const texts = (container = root) => [...container.children].map(block => block.textContent).join('|');
            const select = (start, startOffset, end, endOffset, backward = false) => {
              root.focus();
              getSelection().setBaseAndExtent(...(backward ? [end, endOffset, start, startOffset] : [start, startOffset, end, endOffset]));
              document.dispatchEvent(new Event('selectionchange'));
            };
            const key = (name, options = {}) => {
              const event = new KeyboardEvent('keydown', { key: name, bubbles: true, cancelable: true, ...options });
              root.dispatchEvent(event); return event;
            };
            const fixture = '<p>Before</p><p>Selected first</p><p>Selected last</p><p>After</p>';
            load(fixture);
            select(root.children[1].firstChild, 0, root.children[2].firstChild, 13);
            expect(root.querySelectorAll('.article-multiselected').length === 2, 'two whole blocks must be visibly selected');
            const original = LeonArticle.serialize();
            // A synthetic key has no native default: reproduce WebKit's deletion when unhandled.
            if (!key('Backspace').defaultPrevented) document.execCommand('delete');
            expect(texts() === 'Before|After', 'deleting highlighted blocks must not leave an empty first row');
            expect(getSelection().isCollapsed && root.lastElementChild.contains(getSelection().anchorNode), 'caret must move to the next surviving block');
            const deleted = LeonArticle.serialize(); LeonArticle.undo(-1);
            expect(LeonArticle.serialize() === original && !getSelection().isCollapsed, 'one undo must restore all blocks and their selection');
            LeonArticle.undo(1); expect(LeonArticle.serialize() === deleted, 'redo must delete the complete blocks again');

            load(fixture);
            select(root.children[1].firstChild, 4, root.children[2].firstChild, 5, true);
            expect(key('Delete').defaultPrevented && texts() === 'Before|After', 'reverse partial text ranges shown as whole blocks must delete both complete blocks');
            expect(!root.querySelector('.article-multiselected') && !root.classList.contains('article-multiselect'), 'deletion must immediately clear block selection');

            load(fixture);
            select(root.children[0].firstChild, 6, root.children[3].firstChild, 0);
            expect(root.querySelectorAll('.article-multiselected').length === 2, 'touching a previous end or next start must not select those blocks');
            const input = new InputEvent('beforeinput', { inputType: 'deleteContentForward', bubbles: true, cancelable: true }); root.dispatchEvent(input);
            expect(input.defaultPrevented && texts() === 'Before|After', 'native input deletion must use the same exact block range');

            load('<p>One</p><p>Two</p>');
            select(root, 0, root, 2);
            expect(key('Backspace').defaultPrevented && root.children.length === 1 && root.firstElementChild.matches('p') && !root.textContent, 'deleting all content must leave exactly one writable paragraph');
            expect(getSelection().isCollapsed && root.firstElementChild.contains(getSelection().anchorNode), 'empty document must retain a writable caret');
            load('<p>Before</p><p>One</p><p>Two</p>'); select(root, 1, root, 3); key('Delete');
            expect(texts() === 'Before' && root.firstElementChild.contains(getSelection().anchorNode), 'deleting the tail must focus the preceding block');

            load('<p>Before</p><h2>Heading</h2><hr><p><br></p><p>After</p>'); select(root, 1, root, 4); key('Backspace');
            expect(texts() === 'Before|After', 'selected headings, dividers and real empty blocks must all be removed');
            load('<div data-type="columns"><div data-type="column"><p>One</p><p>Two</p></div><div data-type="column"><p>Keep</p></div></div>');
            let column = root.querySelector('[data-type=column]'); select(column, 0, column, 2); key('Backspace');
            expect(root.querySelectorAll('[data-type=column]').length === 2 && !column.textContent && root.textContent === 'Keep', 'deleting blocks inside one column must preserve the other column and an editable placeholder');
            expect(column.firstElementChild.contains(getSelection().anchorNode), 'caret must stay in the emptied column');
            load('<p>Before</p><div data-type="columns"><div data-type="column"><p>One</p></div><div data-type="column"><p>Two</p></div></div><p>After</p>');
            select(root, 1, root, 2); key('Delete'); expect(texts() === 'Before|After', 'fully selected column layouts must not leave empty rows');

            load(fixture); select(root.children[1].firstChild, 2, root.children[1].firstChild, 5);
            const single = LeonArticle.serialize(); expect(!key('Backspace').defaultPrevented && LeonArticle.serialize() === single, 'single-block text deletion must stay native');
            load(fixture, false); select(root.children[1].firstChild, 0, root.children[2].firstChild, 13);
            const reader = LeonArticle.serialize(); expect(!key('Delete').defaultPrevented && LeonArticle.serialize() === reader, 'read-only selection must never delete blocks');
            load(fixture); select(root.children[1].firstChild, 0, root.children[2].firstChild, 13);
            const composing = LeonArticle.serialize(); expect(!key('Backspace', { isComposing: true }).defaultPrevented && LeonArticle.serialize() === composing, 'IME composition must not trigger block deletion');
            return true;
            """#, arguments: [:], in: nil, contentWorld: .page)
        }
    }
}
