import AppKit
import WebKit
@testable import LeonBook

extension RichArticleTests {
    @MainActor
    func testRichArticleTableInsertBetweenRows() async throws {
        try await withWebEditor { view in
            _ = try await view.callAsyncJavaScript(#"""
            const root = document.getElementById('document'), insert = document.getElementById('table-insert-row'), append = document.getElementById('table-add-row');
            const expect = (value, message) => { if (!value) throw new Error(message); };
            const wait = (delay = 80) => new Promise(resolve => setTimeout(resolve, delay));
            const load = html => LeonArticle.load('<article data-leon-format="html-v1">' + html + '</article>', 'row-insert-' + Math.random(), true, 18);
            const hover = async (cell, side) => {
              root.focus(); const range = document.createRange(); range.selectNodeContents(cell); range.collapse(true);
              getSelection().removeAllRanges(); getSelection().addRange(range);
              const box = cell.getBoundingClientRect();
              cell.dispatchEvent(new PointerEvent('pointermove', { bubbles: true, clientX: box.left + 25, clientY: side === 'top' ? box.top + 2 : box.bottom - 2 }));
              await wait();
            };
            load('<table><colgroup><col style="width:35%"><col style="width:65%"></colgroup><thead><tr><th>Title</th><th>Details</th></tr></thead><tbody><tr><td><strong>A</strong></td><td>A2</td></tr><tr><td>B</td><td>B2</td></tr><tr><td>C</td><td>C2</td></tr></tbody></table>');
            let table = root.querySelector('table');
            await hover(table.rows[1].cells[1], 'bottom');
            expect(!insert.hidden && !append.hidden, 'middle and bottom row actions must coexist');
            const boundary = table.rows[1].getBoundingClientRect().bottom, button = insert.getBoundingClientRect();
            expect(Math.abs(button.top + button.height / 2 - boundary) < 1 && Math.abs(button.left + button.width / 2 - table.getBoundingClientRect().left) < 1, 'plus must align with the hovered row boundary on the left');
            await hover(table.rows[2].cells[0], 'top');
            expect(!insert.hidden && Math.abs(insert.getBoundingClientRect().top + 11 - boundary) < 1, 'approaching the same boundary from below must select the same insertion point');
            root.dispatchEvent(new PointerEvent('pointerleave', { relatedTarget: insert })); insert.dispatchEvent(new PointerEvent('pointerenter'));
            await wait(220); expect(!insert.hidden, 'row action must stay reachable after leaving the cell');
            const original = LeonArticle.serialize(), down = new MouseEvent('mousedown', { bubbles: true, cancelable: true }); insert.dispatchEvent(down);
            expect(down.defaultPrevented, 'pressing the row action must preserve the selection'); insert.click();
            expect(table.rows.length === 5 && table.rows[2].cells.length === 2 && !table.rows[2].textContent.trim(), 'insert one empty row at the selected boundary');
            expect(table.rows[1].cells[0].querySelector('strong')?.textContent === 'A' && table.rows[3].cells[0].textContent === 'B', 'adjacent content and formatting must remain intact');
            expect(table.querySelector('col').style.width === '35%', 'column widths must remain unchanged');
            expect(getSelection().anchorNode.parentElement.closest('td') === table.rows[2].cells[0], 'caret must enter the inserted row');
            const saved = LeonArticle.serialize(); expect(!saved.includes('table-insert-row'), 'editor buttons must not be saved into the article');
            LeonArticle.undo(-1); expect(LeonArticle.serialize() === original, 'one undo must restore the original table');
            LeonArticle.undo(1); expect(LeonArticle.serialize() === saved, 'redo must restore the insertion');
            LeonArticle.load(saved, 'row-reopened', true, 18); expect(root.querySelector('table').rows.length === 5, 'inserted row must survive reopening');
            // Keep header rows in the header; the last header boundary inserts a body row.
            load('<table><thead><tr><th>H1</th><th>H2</th></tr><tr><th>Sub1</th><th>Sub2</th></tr></thead><tbody><tr><td>A</td><td>B</td></tr></tbody></table>');
            table = root.querySelector('table'); await hover(table.rows[0].cells[0], 'bottom'); insert.click();
            expect(table.tHead.rows.length === 3 && table.tHead.rows[1].cells[0].tagName === 'TH', 'insertion between header rows must stay in the header');
            await hover(table.tHead.rows[2].cells[0], 'bottom'); insert.click();
            expect(table.tHead.rows.length === 3 && table.tBodies[0].rows.length === 2 && table.tBodies[0].rows[0].cells[0].tagName === 'TD', 'header/body boundary must insert a body row');
            const readOnly = LeonArticle.serialize(); LeonArticle.load(readOnly, 'row-readonly', false, 18); insert.click();
            expect(insert.hidden && LeonArticle.serialize() === readOnly, 'read-only mode must reject insertion');
            load('<p>Another article</p>'); insert.click(); expect(insert.hidden && !root.querySelector('table'), 'document changes must invalidate old insertion targets');
            load('<table><tbody><tr><td>Outer<table><tbody><tr><td>Inner A</td><td>A2</td></tr><tr><td>Inner B</td><td>B2</td></tr></tbody></table></td></tr></tbody></table>');
            const outer = root.querySelector('table'), inner = outer.querySelector('table');
            await hover(inner.rows[0].cells[1], 'bottom'); insert.click();
            expect(outer.rows.length === 1 && inner.rows.length === 3 && inner.rows[1].cells.length === 2, 'nested tables must insert only in the hovered table');
            return true;
            """#, arguments: [:], in: nil, contentWorld: .page)
        }
    }
}
