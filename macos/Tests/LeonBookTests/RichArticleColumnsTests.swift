import AppKit
import WebKit
@testable import LeonBook

extension RichArticleTests {
    @MainActor
    func testRichArticleColumnsHandleRemainsReachable() async throws {
        try await withWebEditor { view in
            _ = try await view.callAsyncJavaScript(#"""
            const root = document.getElementById('document');
            const handle = document.getElementById('article-block-handle');
            const wait = () => new Promise(resolve => setTimeout(resolve, 65));
            const expect = (value, message) => { if (!value) throw new Error(message); };
            const point = (type, x, y) => {
              const target = document.elementFromPoint(x, y);
              expect(target, 'pointer must hit the editor');
              target.dispatchEvent(new PointerEvent(type, { bubbles: true, cancelable: true, pointerId: 1, button: 0, clientX: x, clientY: y }));
            };
            LeonArticle.load('<article data-leon-format="html-v1"><p>First block</p><p>Second block</p></article>', 'handle-reachability', true, 18);
            await wait();
            const grab = async block => {
              const box = block.getBoundingClientRect(), content = LeonArticle.serialize();
              point('pointermove', box.left + 8, box.top + 14); await wait();
              expect(!handle.hidden, 'hover must expose the block handle');
              point('pointermove', box.left - 1, box.top + 14); await wait();
              expect(!handle.hidden, 'block handle disappears while crossing from text to its button');
              const button = handle.getBoundingClientRect();
              expect(button.width >= 28 && button.height >= 32, 'handle needs a generous hit area');
              // Approach diagonally through the blank space below the button.
              point('pointermove', box.left - 1, button.bottom + 2); await wait();
              expect(!handle.hidden, 'diagonal approach must not dismiss the handle');
              const x = button.left + button.width / 2, y = button.bottom - 2;
              point('pointermove', x, y); await wait();
              expect(!handle.hidden && handle.contains(document.elementFromPoint(x, y)), 'expanded handle edge must be clickable');
              point('pointerdown', x, y);
              expect(document.body.classList.contains('article-layout-dragging'), 'pointer must be able to grab the handle');
              point('pointerup', x, y); await wait();
              expect(LeonArticle.serialize() === content, 'a click without movement must not rearrange content');
              expect(block.contains(document.elementFromPoint(box.left + 2, box.top + 14)), 'handle must not cover its block text');
              point('pointermove', innerWidth - 2, 2); await wait();
              expect(handle.hidden, 'leaving the block and its gutter must hide the handle');
            };
            await grab(root.firstElementChild);
            // Check both a roomy layout and the maximum supported column count.
            for (const count of [2, 10]) {
              LeonArticle.load('<article data-leon-format="html-v1"><div data-type="columns">' + Array.from({length: count}, (_, i) => '<div data-type="column"><p>' + i + '</p></div>').join('') + '</div></article>', 'handle-columns-' + count, true, 18);
              await wait();
              const row = root.firstElementChild;
              await grab(row.firstElementChild.firstElementChild);
              await grab(row.lastElementChild.firstElementChild);
            }
            LeonArticle.load(LeonArticle.serialize(), 'handle-reader', false, 18); await wait();
            expect(handle.hidden, 'read-only mode must hide editing controls');
            return true;
            """#, arguments: [:], in: nil, contentWorld: .page)
        }
    }

    @MainActor
    func testRichArticleColumnsDragResizeAndPersistence() async throws {
        try await withWebEditor { view in
            _ = try await view.callAsyncJavaScript(#"""
            const root = document.getElementById('document'), ROW = 'div[data-type=columns]', COL = 'div[data-type=column]';
            const expect = (value, message) => { if (!value) throw new Error(message); };
            const wait = () => new Promise(resolve => setTimeout(resolve, 65));
            const load = (content, id = 'columns') => LeonArticle.load('<article data-leon-format="html-v1">' + content + '</article>', id, true, 18);
            const pointer = (node, type, x, y) => node.dispatchEvent(new PointerEvent(type, { bubbles: true, cancelable: true, pointerId: 1, button: 0, clientX: x, clientY: y }));
            const drag = async (source, target, side, cancel = false) => {
              const sourceRect = source.getBoundingClientRect();
              pointer(source, 'pointermove', sourceRect.left + 5, sourceRect.top + 16); await wait();
              const handle = document.getElementById('article-block-handle'); expect(!handle.hidden, 'hover exposes block handle');
              const bounds = handle.getBoundingClientRect(); pointer(handle, 'pointerdown', bounds.left + 8, bounds.top + 12);
              const rect = target.getBoundingClientRect();
              const x = side === 'left' ? rect.left + 2 : side === 'right' ? rect.right - 2 : rect.left + rect.width / 2;
              const y = side === 'before' ? rect.top + 1 : side === 'after' ? rect.bottom - 1 : rect.top + Math.min(16, rect.height / 2);
              pointer(document, 'pointermove', x, y);
              pointer(document, cancel ? 'pointercancel' : 'pointerup', x, y); await wait();
            };
            load('<p>A</p><p>B</p><p>C</p>');
            const original = LeonArticle.serialize();
            await drag(root.children[1], root.children[0], 'right');
            let row = root.querySelector(ROW);
            expect(row && row.children.length === 2 && row.textContent === 'AB', 'side drop must create two columns without copying blocks');
            expect(root.children.length === 2 && root.lastElementChild.textContent === 'C', 'other blocks stay in place');
            let saved = LeonArticle.serialize();
            expect(!saved.includes('article-block-handle') && saved.includes('data-type="columns"'), 'save only layout/content');
            LeonArticle.undo(-1); expect(LeonArticle.serialize() === original, 'one undo restores original order');
            LeonArticle.undo(1); expect(LeonArticle.serialize() === saved, 'redo restores columns');
            row = root.querySelector(ROW);
            pointer(row.firstElementChild.firstElementChild, 'pointermove', 40, row.getBoundingClientRect().top + 16); await wait();
            let separator = document.querySelector('.article-column-separator'); expect(separator, 'columns expose resize divider');
            let rect = separator.getBoundingClientRect();
            pointer(separator, 'pointerdown', rect.left + 5, rect.top + 15);
            pointer(document, 'pointermove', rect.left + 65, rect.top + 15);
            pointer(document, 'pointerup', rect.left + 65, rect.top + 15);
            expect(parseFloat(row.children[0].style.width) > 50, 'drag divider grows left column');
            const resized = LeonArticle.serialize();
            LeonArticle.undo(-1); expect(LeonArticle.serialize() === saved, 'resize is one undo step');
            LeonArticle.undo(1); expect(LeonArticle.serialize() === resized, 'resize redo');
            LeonArticle.load(resized, 'reopened', true, 18);
            expect(LeonArticle.serialize() === resized, 'reopening retains widths and block IDs');
            row = root.querySelector(ROW);
            pointer(row.firstElementChild.firstElementChild, 'pointermove', 40, row.getBoundingClientRect().top + 16); await wait();
            separator = document.querySelector('.article-column-separator'); rect = separator.getBoundingClientRect();
            pointer(separator, 'pointerdown', rect.left + 5, rect.top + 15);
            pointer(document, 'pointermove', rect.left - 80, rect.top + 15);
            pointer(document, 'pointercancel', rect.left - 80, rect.top + 15);
            expect(LeonArticle.serialize() === resized, 'cancel restores exact widths');
            separator.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true, cancelable: true }));
            expect(LeonArticle.serialize() !== resized, 'divider supports keyboard adjustment');
            // Block editing must remain scoped to its column.
            const paragraph = row.children[0].firstElementChild; root.focus(); getSelection().setPosition(paragraph.firstChild, 1);
            root.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertParagraph', bubbles: true, cancelable: true }));
            expect(row.children[0].children.length === 2 && row.children[1].textContent === 'B', 'Enter stays inside current column');
            const next = row.children[0].lastElementChild; getSelection().setPosition(next, 0);
            LeonArticle.execute('h2'); expect(row.children[0].lastElementChild.tagName === 'H2', 'commands target the inner block');
            getSelection().setPosition(paragraph.firstChild, 0);
            const backspace = new InputEvent('beforeinput', { inputType: 'deleteContentBackward', bubbles: true, cancelable: true });
            root.dispatchEvent(backspace); expect(backspace.defaultPrevented, 'backspace cannot join different columns');
            load('<h2>Title</h2><table><tr><td><p>Cell</p></td></tr></table><figure><img src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7" alt="sample"></figure>', 'rich-columns');
            await drag(root.children[1], root.children[0], 'right');
            await drag(root.children[1], root.querySelector('table'), 'right');
            row = root.querySelector(ROW);
            expect(row.children.length === 3 && row.querySelector('h2') && row.querySelector('table') && row.querySelector('img'), 'headings, tables and image blocks can share a row');
            const cellText = row.querySelector('td p').firstChild; root.focus(); getSelection().setPosition(cellText, 2);
            root.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertParagraph', bubbles: true, cancelable: true }));
            expect(row.querySelector('td').children.length === 2 && row.children.length === 3, 'table editing inside columns preserves layout');
            const rich = LeonArticle.serialize(); LeonArticle.load(rich, 'rich-reopened', true, 18);
            expect(LeonArticle.serialize() === rich && root.querySelector('img').alt === 'sample', 'rich column content round-trips');
            // A row accepts ten columns, rejects the eleventh, and still allows reordering.
            load('<p>A</p><p>B</p><p>C</p><p>D</p><p>E</p><p>F</p><p>G</p><p>H</p><p>I</p><p>J</p><p>K</p>', 'limit');
            await drag(root.children[1], root.children[0], 'right');
            for (let count = 2; count < 10; count++) await drag(root.children[1], root.querySelector(COL).firstElementChild, 'left');
            row = root.querySelector(ROW); expect(row.children.length === 10, 'support ten columns');
            const ten = LeonArticle.serialize();
            await drag(root.lastElementChild, row.lastElementChild.firstElementChild, 'right');
            expect(LeonArticle.serialize() === ten && document.getElementById('article-column-status').hidden, 'reject eleventh without losing content');
            const moved = row.firstElementChild.firstElementChild;
            await drag(moved, row.lastElementChild.firstElementChild, 'right');
            expect(row.children.length === 10 && row.lastElementChild.firstElementChild === moved, 'full row supports reordering');
            const stable = LeonArticle.serialize();
            await drag(root.lastElementChild, row, 'before', true); expect(LeonArticle.serialize() === stable, 'cancel leaves content unchanged');
            await drag(moved, row, 'after');
            expect(root.children[1] === moved && row.children.length === 9, 'drag to row bottom extracts block');
            load('<p>A</p><p>B</p>', 'collapse'); await drag(root.children[1], root.children[0], 'right');
            row = root.querySelector(ROW); await drag(row.children[1].firstElementChild, row, 'after');
            expect(!root.querySelector(ROW) && root.textContent === 'AB', 'single remaining column unwraps');
            // Import repair retains all content while enforcing the limit.
            load('<div data-type="columns">' + Array.from({length: 12}, (_, i) => '<div data-type="column"><p>' + i + '</p></div>').join('') + '</div>', 'import');
            expect(root.querySelector(ROW).children.length === 10 && root.querySelector(ROW).lastElementChild.textContent === '91011', 'repair imported oversized rows without data loss');
            load('<div data-type="columns"><div data-type="column" style="width:2%"><p>A</p></div><div data-type="column" style="width:2%"><p>B</p></div><div data-type="column" style="width:96%"><p>C</p></div></div>', 'minimum');
            row = root.querySelector(ROW); pointer(row.firstElementChild.firstElementChild, 'pointermove', 30, row.getBoundingClientRect().top + 16); await wait();
            separator = document.querySelector('.article-column-separator');
            separator.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true, cancelable: true }));
            expect(parseFloat(row.children[0].style.width) >= 2, 'narrow columns respect the serialization width floor');
            const minimum = LeonArticle.serialize(); LeonArticle.load(minimum, 'minimum-reopened', true, 18);
            expect(LeonArticle.serialize() === minimum, 'minimum widths round-trip exactly');
            load('<div data-type="columns">' + Array.from({length: 10}, (_, i) => '<div data-type="column" style="width:' + (i ? 2 : 100) + '%"><p>' + i + '</p></div>').join('') + '</div>', 'weights');
            expect([...root.querySelectorAll(COL)].every(column => parseFloat(column.style.width) >= 2), 'normalization retains minimum width');
            const reader = LeonArticle.serialize(); LeonArticle.load(reader, 'reader', false, 18); await wait();
            expect(root.querySelector(ROW).children.length === 10 && getComputedStyle(root.querySelector(ROW)).display === 'flex', 'read mode preserves layout');
            expect(document.getElementById('article-block-handle').hidden && !document.querySelector('.article-column-separator'), 'read mode has no editing controls');
            return true;
            """#, arguments: [:], in: nil, contentWorld: .page)
        }
    }
}
