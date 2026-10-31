import AppKit
import WebKit
@testable import LeonBook

extension RichArticleTests {
    @MainActor
    func testRichArticleColumnsPointerWorkIsFrameBounded() async throws {
        try await withWebEditor { view in
            let result = try await view.callAsyncJavaScript(#"""
            const root = document.getElementById('document'), ROW = 'div[data-type=columns]';
            const wait = () => new Promise(resolve => setTimeout(resolve, 80));
            const expect = (value, message) => { if (!value) throw new Error(message); };
            const load = (html, id) => LeonArticle.load('<article data-leon-format="html-v1">' + html + '</article>', id, true, 18);
            const pointer = (node, type, x, y, id = 1) => node.dispatchEvent(new PointerEvent(type, { bubbles: true, cancelable: true, pointerId: id, button: 0, clientX: x, clientY: y }));
            const rect = Element.prototype.getBoundingClientRect, hit = document.elementFromPoint;
            let reads = 0, hits = 0, writes = 0;
            Element.prototype.getBoundingClientRect = function(...args) { reads++; return rect.apply(this, args); };
            document.elementFromPoint = function(...args) { hits++; return hit.apply(this, args); };
            const observer = new MutationObserver(records => { writes += records.length; });
            observer.observe(document.getElementById('article-block-drop'), { attributes: true });
            const measure = async work => {
              reads = hits = writes = 0; observer.takeRecords(); const start = performance.now(); work();
              const eventMS = performance.now() - start; await wait();
              return { reads, hits, writes, eventMS };
            };
            const begin = async source => {
              const bounds = source.getBoundingClientRect();
              pointer(source, 'pointermove', bounds.left + 5, bounds.top + 16); await wait();
              const handle = document.getElementById('article-block-handle'), box = handle.getBoundingClientRect();
              expect(!handle.hidden, 'block handle must be available'); pointer(handle, 'pointerdown', box.left + 8, box.top + 12);
            };
            try {
              // Smallest repro: the same destination receives a burst within one display frame.
              load('<p>Source</p><p>Target</p><p>Last</p>', 'drag-burst'); await wait();
              const source = root.firstElementChild, target = root.children[1], box = target.getBoundingClientRect();
              await begin(source);
              const burst = await measure(() => { for (let i = 0; i < 120; i++) pointer(document, 'pointermove', i ? box.right - 2 : box.left + 2, box.top + 16); });
              const marker = document.getElementById('article-block-drop'), visible = !marker.hidden;
              expect(Math.abs(parseFloat(marker.style.left) - (box.right - 2)) < 1, 'a frame must use its latest pointer position');
              const steady = await measure(() => pointer(document, 'pointermove', box.right - 2, box.top + 16));
              // A final pointerup at a new location must win over the queued move.
              pointer(document, 'pointermove', box.right - 2, box.top + 16);
              const last = root.lastElementChild, lastRect = last.getBoundingClientRect();
              pointer(document, 'pointerup', lastRect.left + lastRect.width / 2, lastRect.bottom - 2);
              expect(root.lastElementChild === source && !root.querySelector(ROW), 'release must use final coordinates');
              const committed = LeonArticle.serialize(); await wait();
              expect(LeonArticle.serialize() === committed && document.getElementById('article-block-drop').hidden, 'queued work must not run after release');
              await begin(root.firstElementChild);
              pointer(document, 'pointermove', lastRect.right - 2, lastRect.top + 16);
              document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true })); await wait();
              expect(LeonArticle.serialize() === committed && marker.hidden, 'Escape discards queued block movement');
              await begin(root.firstElementChild);
              pointer(document, 'pointermove', lastRect.right - 2, lastRect.top + 16);
              load('<p>New article</p>', 'drag-replacement'); const replacement = LeonArticle.serialize(); await wait();
              expect(LeonArticle.serialize() === replacement && marker.hidden && !document.body.classList.contains('article-layout-dragging'), 'loading a document cancels pending drag work');
              // Gutter hit-testing near the bottom of a long article must not scan every block.
              load(Array.from({length: 2000}, (_, i) => '<p>Block ' + i + '</p>').join(''), 'drag-long');
              const longSource = root.children[1988], longTarget = root.children[1990];
              longTarget.scrollIntoView({ block: 'center' }); await wait(); await begin(longSource);
              const longBox = longTarget.getBoundingClientRect(), gutterX = root.getBoundingClientRect().left + 5;
              const gutter = await measure(() => { for (let i = 0; i < 120; i++) pointer(document, 'pointermove', gutterX, longBox.top + 16); });
              pointer(document, 'pointerup', gutterX, longBox.top + 16);
              expect(longSource.closest(ROW) === longTarget.closest(ROW) && longSource.closest(ROW)?.textContent === longSource.textContent + longTarget.textContent, 'gutter drop must choose the correct block');
              window.scrollTo(0, 0);
              load('<div data-type="columns">' + Array.from({length: 10}, (_, i) => '<div data-type="column" style="width:10%"><p>Column ' + i + '</p></div>').join('') + '</div>', 'resize-burst');
              await wait();
              const row = root.querySelector(ROW), cell = row.firstElementChild.firstElementChild, cellBox = cell.getBoundingClientRect();
              pointer(cell, 'pointermove', cellBox.left + 5, cellBox.top + 16); await wait();
              const separator = document.querySelector('.article-column-separator'), edge = separator.getBoundingClientRect();
              const original = LeonArticle.serialize();
              pointer(separator, 'pointerdown', edge.left + 5, edge.top + 16);
              const resize = await measure(() => { for (let i = 0; i < 120; i++) pointer(document, 'pointermove', edge.left + 5 + i / 10, edge.top + 16); });
              pointer(document, 'pointerup', edge.left + 35, edge.top + 16);
              const finalWidth = parseFloat(row.firstElementChild.style.width);
              expect(finalWidth > 10 && row.children.length === 10, 'resize release must apply final width');
              LeonArticle.undo(-1); expect(LeonArticle.serialize() === original, 'resize remains a single undo step');
              const freshCell = root.querySelector('div[data-type=column] p');
              pointer(freshCell, 'pointermove', cellBox.left + 5, cellBox.top + 16); await wait();
              const freshSeparator = document.querySelector('.article-column-separator');
              pointer(freshSeparator, 'pointerdown', edge.left + 5, edge.top + 16);
              pointer(document, 'pointermove', edge.left + 50, edge.top + 16);
              pointer(document, 'pointercancel', edge.left + 50, edge.top + 16); await wait();
              expect(LeonArticle.serialize() === original, 'cancellation discards pending resize');
              return JSON.stringify({ burst, steady, gutter, resize, visible });
            } finally {
              Element.prototype.getBoundingClientRect = rect; document.elementFromPoint = hit; observer.disconnect();
            }
            """#, arguments: [:], in: nil, contentWorld: .page)
            print("COLUMN_DRAG_PERFORMANCE \(result as! String)")
            let json = try JSONSerialization.jsonObject(with: Data((result as! String).utf8)) as! [String: Any]
            var exceeded: [String] = []
            for scenario in ["burst", "gutter", "resize"] {
                let metrics = json[scenario] as! [String: Any]
                if (metrics["reads"] as! Int) > 80 { exceeded.append("\(scenario): more than 80 layout reads per pointer burst") }
                if (metrics["hits"] as! Int) > 2 { exceeded.append("\(scenario): hit testing not frame bounded") }
                if (metrics["writes"] as! Int) > 12 { exceeded.append("\(scenario): repeated marker mutations") }
            }
            if (json["steady"] as! [String: Any])["writes"] as! Int > 0 { exceeded.append("unchanged destination rewrites marker") }
            if !(json["visible"] as! Bool) { exceeded.append("drop indicator missing") }
            if !exceeded.isEmpty { throw NSError(domain: "ColumnDragPerformance", code: 1, userInfo: [NSLocalizedDescriptionKey: exceeded.joined(separator: "; ")]) }
        }
    }
}
