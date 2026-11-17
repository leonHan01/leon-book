import AppKit
import WebKit
@testable import LeonBook

extension RichArticleTests {
    @MainActor
    func testRichArticleSelectionWorkStaysWithinSelectedBlocks() async throws {
        try await withWebEditor { view in
            let result = try await view.callAsyncJavaScript(#"""
            const root = document.getElementById('document');
            const expect = (value, message) => { if (!value) throw new Error(message); };
            LeonArticle.load('<article data-leon-format="html-v1">' + Array.from({ length: 2500 }, (_, index) => '<p>Paragraph ' + index + '</p>').join('\n') + '</article>', 'bounded-selection', true, 18);
            root.focus();
            const intersects = Range.prototype.intersectsNode, matches = Element.prototype.matches;
            let intersections = 0, blockChecks = 0;
            Range.prototype.intersectsNode = function(...args) { intersections++; return intersects.apply(this, args); };
            Element.prototype.matches = function(...args) { if (this.parentElement === root) blockChecks++; return matches.apply(this, args); };
            const select = (start, startOffset, end, endOffset) => {
              getSelection().setBaseAndExtent(start, startOffset, end, endOffset);
              document.dispatchEvent(new Event('selectionchange'));
            };
            try {
              const first = root.children[2400], second = root.children[2401];
              select(first.firstChild, 2, first.firstChild, 5);
              expect(!root.querySelector('.article-multiselected'), 'one paragraph must retain native text selection');
              for (let index = 0; index < 20; index++) select(first.firstChild, 2, second.firstChild, 5);
              expect(root.querySelectorAll('.article-multiselected').length === 2, 'a short range near the document end must select exactly its two blocks');
              expect(intersections < 100 && blockChecks < 300, 'short selections must not inspect every block in the document');
              const metrics = { intersections, blockChecks };
              const original = LeonArticle.serialize();
              const deletion = new InputEvent('beforeinput', { inputType: 'deleteContentBackward', bubbles: true, cancelable: true });
              root.dispatchEvent(deletion);
              expect(deletion.defaultPrevented && root.children.length === 2498, 'bounded selection must still delete both complete blocks');
              LeonArticle.undo(-1); expect(LeonArticle.serialize() === original, 'undo must restore the exact document');
              // Root offsets count whitespace text nodes as well as element children.
              select(root, 4800, root, 4803);
              expect(root.querySelectorAll('.article-multiselected').length === 2, 'element boundary selection must respect inter-block whitespace');
              return JSON.stringify(metrics);
            } finally {
              Range.prototype.intersectsNode = intersects; Element.prototype.matches = matches;
            }
            """#, arguments: [:], in: nil, contentWorld: .page)
            print("BOUNDED_SELECTION_PERFORMANCE \(result as! String)")
        }
    }

    @MainActor
    func testRichArticleTableAxisWorkTracksVisibleRows() async throws {
        try await withWebEditor { view in
            let result = try await view.callAsyncJavaScript(#"""
            const root = document.getElementById('document'), controls = document.getElementById('table-axis-controls');
            const expect = (value, message) => { if (!value) throw new Error(message); };
            const wait = () => new Promise(resolve => setTimeout(resolve, 100));
            LeonArticle.load('<article data-leon-format="html-v1"><p>Before</p><table><tbody>' + Array.from({ length: 600 }, (_, index) => '<tr><td><p>Row ' + index + '</p></td><td><p>Value</p></td><td><p>Notes</p></td></tr>').join('') + '</tbody></table></article>', 'visible-table-axes', true, 18);
            const table = root.querySelector('table');
            root.focus(); getSelection().setPosition(table.rows[0].cells[0].firstElementChild, 0); await wait();
            const originalRect = Element.prototype.getBoundingClientRect;
            let reads = 0;
            Element.prototype.getBoundingClientRect = function(...args) { reads++; return originalRect.apply(this, args); };
            const hover = async cell => {
              const box = cell.getBoundingClientRect();
              cell.dispatchEvent(new PointerEvent('pointermove', { bubbles: true, clientX: box.left + 20, clientY: box.top + 18 })); await wait();
            };
            try {
              reads = 0; await hover(table.rows[0].cells[0]); const initialReads = reads;
              expect(initialReads < 100, 'first hover must binary-search visible rows instead of measuring the complete table');
              expect(controls.querySelectorAll('[data-axis=row]').length < 30, 'row handle DOM must be bounded by the viewport');
              const column = controls.querySelector('[data-axis=column][data-index="1"]');
              column.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true })); column.click(); await wait();
              const destination = table.rows[500].getBoundingClientRect().top + scrollY - 120;
              reads = 0; window.scrollTo(0, destination); await wait(); const scrollReads = reads;
              expect(scrollReads < 100, 'scrolling a selected column must reuse its complete cached bounds');
              expect(controls.querySelectorAll('[data-axis=row]').length < 30 && controls.querySelector('[data-axis=row][data-index="500"]'), 'scroll must replace row handles with the visible interval');
              expect(!document.getElementById('table-axis-selection').hidden && column.hidden, 'selected-column highlight must follow the viewport while its top handle is offscreen');
              root.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }));
              const inserted = table.insertRow(500);
              for (let index = 0; index < 3; index++) inserted.insertCell().innerHTML = '<p>Inserted</p>';
              root.dispatchEvent(new Event('input', { bubbles: true })); await wait(); await hover(inserted.cells[0]);
              const handle = controls.querySelector('[data-axis=row][data-index="500"]');
              expect(handle && Math.abs(handle.getBoundingClientRect().top - (inserted.getBoundingClientRect().top + 6)) < 1, 'row insertion must invalidate cached indices and geometry');
              inserted.cells[0].firstElementChild.append(document.createElement('br'), 'Taller', document.createElement('br'), 'Row');
              root.dispatchEvent(new Event('input', { bubbles: true })); await wait();
              expect(Math.abs(handle.getBoundingClientRect().height - (inserted.getBoundingClientRect().height - 12)) < 1, 'content reflow must invalidate cached row sizes');
              return JSON.stringify({ initialReads, scrollReads, rowHandles: controls.querySelectorAll('[data-axis=row]').length });
            } finally {
              Element.prototype.getBoundingClientRect = originalRect; window.scrollTo(0, 0);
            }
            """#, arguments: [:], in: nil, contentWorld: .page)
            print("VISIBLE_TABLE_AXES_PERFORMANCE \(result as! String)")
        }
    }
}
