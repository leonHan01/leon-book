import AppKit
import WebKit
@testable import LeonBook

extension RichArticleTests {
    @MainActor
    func testRichArticleColumnsDragBlocksIntoTableCells() async throws {
        try await withWebEditor { view in
            _ = try await view.callAsyncJavaScript(#"""
            const root = document.getElementById('document'), marker = document.getElementById('article-block-drop');
            const expect = (value, message) => { if (!value) throw new Error(message); };
            const wait = () => new Promise(resolve => setTimeout(resolve, 70));
            let documentIndex = 0;
            const load = html => LeonArticle.load('<article data-leon-format="html-v1">' + html + '</article>', 'table-blocks-' + ++documentIndex, true, 18);
            const pointer = (node, type, x, y) => node.dispatchEvent(new PointerEvent(type, { bubbles: true, cancelable: true, pointerId: 1, button: 0, clientX: x, clientY: y }));
            const begin = async source => {
              const box = source.getBoundingClientRect(); pointer(source, 'pointermove', box.left + 8, box.top + Math.min(16, box.height / 2)); await wait();
              const handle = document.getElementById('article-block-handle'); expect(!handle.hidden, 'source block must expose a drag handle');
              const grip = handle.getBoundingClientRect(); pointer(handle, 'pointerdown', grip.left + 14, grip.top + 16);
            };
            const drop = async (source, target, side = 'middle', cancel = false) => {
              await begin(source);
              const box = target.getBoundingClientRect(), x = box.left + box.width / 2;
              const y = side === 'before' ? box.top + 2 : side === 'after' ? box.bottom - 2 : box.top + box.height / 2;
              pointer(document, 'pointermove', x, y); await wait();
              pointer(document, cancel ? 'pointercancel' : 'pointerup', x, y); await wait();
            };
            load('<p><strong>Source</strong></p><table><colgroup><col style="width:35%"><col style="width:65%"></colgroup><thead><tr><th>Heading</th><th>Other</th></tr></thead><tbody><tr><td><p><br></p></td><td><p>A</p><p>B</p></td></tr></tbody></table><p>Tail</p>');
            let table = root.querySelector('table'), source = root.firstElementChild, cell = table.tBodies[0].rows[0].cells[0];
            const original = LeonArticle.serialize();
            await begin(source);
            const box = cell.getBoundingClientRect(), x = box.left + box.width / 2, y = box.top + box.height / 2;
            const rect = Element.prototype.getBoundingClientRect; let reads = 0;
            Element.prototype.getBoundingClientRect = function(...args) { reads++; return rect.apply(this, args); };
            try { for (let i = 0; i < 120; i++) pointer(document, 'pointermove', x, y); await wait(); }
            finally { Element.prototype.getBoundingClientRect = rect; }
            expect(reads < 80, 'cell drop hit testing must stay frame bounded');
            const line = marker.getBoundingClientRect();
            expect(!marker.hidden && line.left > box.left && line.right < box.right && line.top > box.top && line.bottom < box.bottom, 'drop indicator must sit inside the selected cell');
            pointer(document, 'pointerup', x, y); await wait();
            expect(cell.children.length === 1 && cell.firstElementChild === source && source.querySelector('strong').textContent === 'Source', 'move the original formatted block into the empty cell without an extra blank paragraph');
            expect(table.rows.length === 2 && table.rows[1].cells.length === 2 && table.querySelector('col').style.width === '35%', 'dragging content must preserve table shape and widths');
            const saved = LeonArticle.serialize(); LeonArticle.undo(-1); expect(LeonArticle.serialize() === original, 'one undo restores the block and empty cell');
            LeonArticle.undo(1); expect(LeonArticle.serialize() === saved, 'redo restores the cell drop');
            LeonArticle.load(saved, 'table-blocks-reopened', true, 18); expect(LeonArticle.serialize() === saved, 'cell blocks must survive save/reopen');
            table = root.querySelector('table'); const left = table.rows[1].cells[0], right = table.rows[1].cells[1]; source = left.firstElementChild;
            await drop(source, right.children[1], 'before');
            expect([...right.children].map(node => node.textContent).join('|') === 'A|Source|B', 'insert between existing blocks in the chosen cell');
            expect(left.children.length === 1 && left.querySelector('p > br'), 'moving the last cell block must retain an editable empty cell');
            await drop(source, right.lastElementChild, 'after'); expect(right.lastElementChild === source, 'reorder blocks inside a cell');
            await drop(source, root.lastElementChild, 'after'); expect(root.lastElementChild === source && right.textContent === 'AB', 'drag cell blocks back into the article');
            const stable = LeonArticle.serialize(); await drop(table, left);
            expect(LeonArticle.serialize() === stable && marker.hidden, 'a table must not be moved into its own descendant cell');
            await drop(source, left, 'middle', true); expect(LeonArticle.serialize() === stable, 'cancel must leave table and source untouched');
            // A source column can collapse after its only block moves into a cell.
            load('<div data-type="columns"><div data-type="column"><h2>Column heading</h2></div><div data-type="column"><table><tbody><tr><td><p><br></p></td></tr></tbody></table></div></div>');
            source = root.querySelector('h2'); cell = root.querySelector('td'); await drop(source, cell);
            expect(cell.firstElementChild === source && !root.querySelector('div[data-type=columns]'), 'column cleanup must preserve the target table and moved heading');
            // Media remain complete blocks, including their captions and local references.
            load('<figure><img src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7" alt="sample"><figcaption>Caption</figcaption></figure><figure data-type="audio"><audio src="/media/example.mp3"></audio></figure><table><thead><tr><th><p><br></p></th></tr></thead><tbody><tr><td><p><br></p></td></tr></tbody></table>');
            source = root.querySelector('figure'); cell = root.querySelector('th'); await drop(source, cell);
            expect(cell.firstElementChild === source && cell.querySelector('figcaption').textContent === 'Caption', 'image and caption must move together into header cells');
            source = root.querySelector('figure[data-type=audio]'); cell = root.querySelector('td'); await drop(source, cell);
            expect(cell.firstElementChild === source && LeonArticle.serialize().includes('/media/example.mp3'), 'audio block references must survive moving into cells');
            // Moving another whole table is legal; nesting a table inside itself is not.
            load('<table><tbody><tr><td>Small table</td></tr></tbody></table><table><tbody><tr><td><p><br></p></td><td>Neighbor</td></tr></tbody></table>');
            const inner = root.firstElementChild, outer = root.lastElementChild; await drop(inner, outer.rows[0].cells[0]);
            expect(outer.rows.length === 1 && outer.rows[0].cells.length === 2 && outer.querySelector('table') === inner && inner.rows[0].cells[0].textContent === 'Small table', 'whole-table drop must retain both table structures');
            const reader = LeonArticle.serialize(); LeonArticle.load(reader, 'table-blocks-reader', false, 18);
            expect(document.getElementById('article-block-handle').hidden && marker.hidden && LeonArticle.serialize() === reader, 'read mode must preserve nested content and hide editing controls');
            return true;
            """#, arguments: [:], in: nil, contentWorld: .page)
        }
    }
}
