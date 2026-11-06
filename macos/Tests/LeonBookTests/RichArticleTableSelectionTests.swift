import AppKit
import WebKit
@testable import LeonBook

extension RichArticleTests {
    @MainActor
    func testRichArticleTableAxisSelection() async throws {
        try await withWebEditor { view in
            _ = try await view.callAsyncJavaScript(#"""
            const root = document.getElementById('document'), controls = document.getElementById('table-axis-controls');
            const tools = document.getElementById('table-tools'), highlight = document.getElementById('table-axis-selection');
            const expect = (value, message) => { if (!value) throw new Error(message); };
            const wait = (delay = 80) => new Promise(resolve => setTimeout(resolve, delay));
            const load = html => LeonArticle.load('<article data-leon-format="html-v1"><p>Before</p>' + html + '<p>After</p></article>', 'table-selection-' + Math.random(), true, 18);
            const hover = async cell => {
              const box = cell.getBoundingClientRect();
              cell.dispatchEvent(new PointerEvent('pointermove', { bubbles: true, clientX: box.left + 25, clientY: box.top + 20 })); await wait();
            };
            const handle = (axis, index) => controls.querySelector(`[data-axis="${axis}"][data-index="${index}"]`);
            const select = async (axis, index) => {
              const button = handle(axis, index), down = new MouseEvent('mousedown', { bubbles: true, cancelable: true });
              button.dispatchEvent(down); expect(down.defaultPrevented, 'handles must preserve the editor caret'); button.click(); await wait();
              expect(button.getAttribute('aria-pressed') === 'true' && !highlight.hidden, 'selected axis must stay visibly selected after selectionchange');
            };
            const key = key => {
              const event = new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true }); root.dispatchEvent(event); return event;
            };
            load('<table><colgroup><col style="width:25%"><col style="width:35%"><col style="width:40%"></colgroup><thead><tr><th>Name</th><th>Status</th><th>Notes</th></tr></thead><tbody><tr><td><strong>A</strong></td><td>A2</td><td>A3</td></tr><tr><td>B</td><td>B2</td><td>B3</td></tr></tbody></table>');
            let table = root.querySelector('table'); await hover(table.rows[1].cells[1]);
            expect(!controls.hidden && controls.children.length === 6, 'hover must expose one handle per row and column');
            const top = handle('column', 1).getBoundingClientRect(), left = handle('row', 1).getBoundingClientRect();
            expect(top.bottom <= table.getBoundingClientRect().top && Math.abs(top.left + top.width / 2 - (table.rows[0].cells[1].getBoundingClientRect().left + table.rows[0].cells[1].getBoundingClientRect().width / 2)) < 1, 'column handle must align above its column');
            expect(left.right <= table.getBoundingClientRect().left && left.top > table.rows[1].getBoundingClientRect().top && left.bottom < table.rows[1].getBoundingClientRect().bottom, 'row handle must align beside its row');
            expect(document.elementFromPoint(top.left + top.width / 2, top.top + top.height / 2) === handle('column', 1) && document.elementFromPoint(left.left + left.width / 2, left.top + left.height / 2) === handle('row', 1), 'other editor chrome must not intercept axis handle clicks');
            root.dispatchEvent(new PointerEvent('pointerleave', { relatedTarget: handle('column', 1) })); controls.dispatchEvent(new PointerEvent('pointerenter')); await wait(220);
            expect(!controls.hidden, 'handles must remain reachable from the table');
            const original = LeonArticle.serialize(); await select('column', 1);
            expect(LeonArticle.serialize() === original, 'selection chrome must not mutate saved content');
            expect(getComputedStyle(tools.querySelector('[data-table=row-delete]')).display === 'none', 'column selection must offer only column actions');
            let box = highlight.getBoundingClientRect();
            expect(Math.abs(box.height - table.getBoundingClientRect().height) < 2 && Math.abs(box.width - table.rows[0].cells[1].getBoundingClientRect().width) < 2, 'column highlight must cover every row');
            await hover(table.rows[2].cells[2]); root.dispatchEvent(new PointerEvent('pointerleave')); await wait(220);
            expect(!tools.hidden && handle('column', 1).getAttribute('aria-pressed') === 'true', 'hovering other cells and leaving must preserve the deletion target');
            expect(key('Backspace').defaultPrevented, 'Backspace must delete the selected column');
            expect([...table.rows].every(row => row.cells.length === 2) && table.rows[1].cells[0].querySelector('strong')?.textContent === 'A' && table.rows[1].cells[1].textContent === 'A3', 'column deletion must preserve adjacent content and formatting');
            const deletedColumn = LeonArticle.serialize(); LeonArticle.undo(-1); expect(LeonArticle.serialize() === original, 'one undo must restore column content and widths');
            LeonArticle.undo(1); expect(LeonArticle.serialize() === deletedColumn, 'redo must delete the same column');
            LeonArticle.load(deletedColumn, 'selected-column-reopened', true, 18); table = root.querySelector('table');
            expect(table.rows[0].cells.length === 2 && controls.hidden && highlight.hidden, 'reopening must retain the edit and discard selection chrome');
            await hover(table.rows[1].cells[0]); await select('row', 1);
            box = highlight.getBoundingClientRect(); expect(Math.abs(box.width - table.getBoundingClientRect().width) < 2 && Math.abs(box.height - table.rows[1].getBoundingClientRect().height) < 2, 'row highlight must cover every column');
            tools.querySelector('[data-table=row-delete]').click();
            expect(table.rows.length === 2 && table.rows[1].cells[0].textContent === 'B', 'toolbar must delete the selected row');
            LeonArticle.undo(-1); expect(LeonArticle.serialize() === deletedColumn, 'one undo must restore the deleted row');
            table = root.querySelector('table'); await hover(table.rows[1].cells[0]); await select('row', 1);
            tools.querySelector('[data-cell-color="#fff0bb"]').click();
            expect([...table.rows[1].cells].every(cell => cell.style.backgroundColor === 'rgb(255, 240, 187)') && !table.rows[2].cells[0].style.backgroundColor, 'color must apply to the whole selected row only');
            LeonArticle.undo(-1); expect(LeonArticle.serialize() === deletedColumn, 'axis color must be one undo step');
            table = root.querySelector('table'); await hover(table.rows[1].cells[0]); await select('column', 0); await select('row', 2);
            expect(handle('column', 0).getAttribute('aria-pressed') === 'false' && tools.dataset.axis === 'row', 'another handle must replace the previous selection');
            expect(key('Escape').defaultPrevented && highlight.hidden && !tools.dataset.axis, 'Escape must return to cell editing');
            await select('row', 1); root.lastElementChild.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }));
            expect(highlight.hidden && !key('Delete').defaultPrevented && LeonArticle.serialize() === deletedColumn, 'clicking outside must prevent a stale axis deletion');
            await hover(table.rows[1].cells[0]); await select('column', 0);
            getSelection().setPosition(table.rows[2].cells[1].firstElementChild, 0); await wait();
            expect(highlight.hidden, 'moving the native caret must clear the axis selection');
            await hover(table.rows[1].cells[0]); await select('row', 1);
            const readOnly = LeonArticle.serialize(); LeonArticle.load(readOnly, 'selection-reader', false, 18); handle('row', 1).click(); key('Backspace');
            expect(controls.hidden && highlight.hidden && LeonArticle.serialize() === readOnly, 'read mode must reject axis selection and deletion');
            load('<p>Another document</p>'); handle('row', 1).click(); key('Delete'); expect(!root.querySelector('table') && highlight.hidden, 'old controls must not affect another article');
            for (const axis of ['row', 'column']) {
              load('<table><tbody><tr><td>Only cell</td></tr></tbody></table>'); table = root.querySelector('table'); await hover(table.rows[0].cells[0]); await select(axis, 0);
              key('Delete'); expect(!root.querySelector('table') && root.children[1].tagName === 'P', 'deleting the final axis must leave an editable paragraph');
              LeonArticle.undo(-1); expect(root.querySelector('td').textContent === 'Only cell', 'undo must restore the final axis');
            }
            load('<table><tbody><tr><td>Outer<table><tbody><tr><td>Inner A</td><td>A2</td></tr><tr><td>Inner B</td><td>B2</td></tr></tbody></table></td><td>Neighbor</td></tr></tbody></table>');
            const outer = root.querySelector('table'), inner = outer.querySelector('table'); await hover(inner.rows[0].cells[0]); await select('column', 1); key('Delete');
            expect(outer.rows[0].cells.length === 2 && inner.rows[0].cells.length === 1 && inner.rows[1].cells.length === 1, 'nested table selection must delete only in its own table');
            load('<table><tr><td>A</td><td>B</td><td>C</td></tr></table>'); table = root.querySelector('table'); await hover(table.rows[0].cells[0]);
            load('<table><tr><td>A</td></tr><tr><td>B</td></tr><tr><td>C</td></tr></table>'); table = root.querySelector('table'); await hover(table.rows[0].cells[0]);
            expect(controls.querySelectorAll('[data-axis=column]').length === 1 && controls.querySelectorAll('[data-axis=row]').length === 3, 'switching table shapes must rebuild both axes even when the total handle count is unchanged');
            load('<table><tbody>' + Array.from({ length: 18 }, (_, index) => '<tr><td>Row ' + index + '</td><td>Details</td></tr>').join('') + '</tbody></table>');
            table = root.querySelector('table'); await hover(table.rows[0].cells[0]); await select('column', 1); window.scrollTo(0, 130); await wait();
            expect(!highlight.hidden && Math.abs(highlight.getBoundingClientRect().left - table.rows[0].cells[1].getBoundingClientRect().left) < 1 && handle('column', 1).hidden, 'scroll must track the highlight and hide column handles above the viewport');
            key('Escape'); window.scrollTo(0, 0); await wait();
            root.lastElementChild.dispatchEvent(new PointerEvent('pointermove', { bubbles: true }));
            for (let attempt = 0; attempt < 20 && !controls.hidden; attempt++) await wait(100);
            expect(controls.hidden, 'unselected handles must hide after leaving the table');
            return true;
            """#, arguments: [:], in: nil, contentWorld: .page)
        }
    }
}
