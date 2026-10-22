import AppKit
import WebKit
@testable import LeonBook

extension RichArticleTests {
    @MainActor
    func testRichArticleCaretMatchesTextAndPreservesEditing() async throws {
        try await withWebEditor { view in
            let result = try await view.callAsyncJavaScript(#"""
            const root = document.getElementById('document');
            const wait = () => new Promise(resolve => setTimeout(resolve, 70));
            const expect = (value, message) => { if (!value) throw new Error(message); };
            const caret = () => document.getElementById('article-caret');
            const visible = () => caret() && !caret().hidden;
            const select = async (node, offset) => {
              root.focus(); getSelection().setPosition(node, offset);
              document.dispatchEvent(new Event('selectionchange')); await wait();
            };
            const checkText = async (element, offset = element.firstChild.length) => {
              await select(element.firstChild, offset);
              const text = getSelection().getRangeAt(0).getBoundingClientRect();
              expect(visible(), 'a collapsed text selection needs a visible font-sized caret');
              const actual = caret().getBoundingClientRect();
              expect(Math.abs(actual.height - text.height) < 1, `caret height ${actual.height} must match text ${text.height}`);
              expect(Math.abs(actual.top - text.top) < 1 && Math.abs(actual.left - text.left) < 1, 'caret must follow the insertion position');
              expect(getComputedStyle(element).caretColor === 'rgba(0, 0, 0, 0)', 'native caret must be hidden only while its replacement is visible');
            };
            LeonArticle.load('<article data-leon-format="html-v1"><p>一边经营琴行，一边业余写歌弹琴。' + '个人经历与日常记录。'.repeat(8) + '</p><h2>个人经历</h2><p>正文<strong>粗体文字</strong><code>code</code></p><p><br></p><table><tr><td><p>表格正文</p></td><td><p><br></p></td></tr></table><pre><code>let value = 1\nprint(value)</code></pre></article>', 'caret', true, 18);
            root.style.width = '340px';
            const saved = LeonArticle.serialize(), originalMarkup = root.innerHTML;
            const paragraph = root.firstElementChild;
            expect(paragraph.getBoundingClientRect().height > 60, 'fixture must wrap');
            const lineHeight = getComputedStyle(paragraph).lineHeight;
            await checkText(paragraph);
            expect(caret().getBoundingClientRect().height < parseFloat(lineHeight) - 5, 'wrapped-line caret must exclude the extra line spacing');
            await checkText(paragraph, 0);
            await checkText(root.querySelector('h2'));
            await checkText(root.querySelector('strong'));
            await checkText(root.querySelector('p code'));
            await checkText(root.querySelector('td p'));
            await checkText(root.querySelector('pre code'));
            for (const empty of [root.children[3], root.querySelectorAll('td p')[1]]) {
              await select(empty, 0);
              expect(visible() && caret().getBoundingClientRect().height < 25, 'empty paragraph needs a font-sized caret');
              const bounds = empty.getBoundingClientRect(), actual = caret().getBoundingClientRect();
              expect(actual.top >= bounds.top && actual.bottom <= bounds.bottom + 1, 'empty-line caret must stay inside its paragraph');
            }
            await select(paragraph, paragraph.childNodes.length);
            expect(visible(), 'element-boundary selection needs a caret');
            expect(LeonArticle.serialize() === saved && root.innerHTML === originalMarkup, 'caret measurement must not mutate document content');
            expect(getComputedStyle(paragraph).lineHeight === lineHeight, 'caret must preserve paragraph line spacing');
            await checkText(paragraph);
            root.dispatchEvent(new CompositionEvent('compositionstart', {bubbles: true}));
            expect(!visible() && getComputedStyle(paragraph).caretColor !== 'rgba(0, 0, 0, 0)', 'IME composition must retain the native caret');
            root.dispatchEvent(new CompositionEvent('compositionend', {bubbles: true})); await wait();
            expect(visible(), 'font-sized caret must return after composition');
            getSelection().setBaseAndExtent(paragraph.firstChild, 0, paragraph.firstChild, 4);
            document.dispatchEvent(new Event('selectionchange')); await wait();
            expect(!visible(), 'text selection must hide the caret');
            await select(paragraph.firstChild, 4);
            window.dispatchEvent(new Event('blur')); await wait(); expect(!visible(), 'window blur must hide the caret');
            window.dispatchEvent(new Event('focus')); await wait(); expect(visible(), 'window focus must restore the caret');
            document.querySelector('#toolbar button').focus(); await wait(); expect(!visible(), 'editor blur must hide the caret');
            await checkText(paragraph);
            window.scrollTo(0, 70); await wait();
            const position = getSelection().getRangeAt(0).getBoundingClientRect();
            expect(Math.abs(caret().getBoundingClientRect().top - position.top) < 1, 'scrolling must keep the caret aligned');
            window.scrollTo(0, 0);
            LeonArticle.load(LeonArticle.serialize(), 'caret', true, 24); await wait();
            await checkText(root.firstElementChild);
            expect(caret().getBoundingClientRect().height > 25, 'caret must track changed font size');
            document.execCommand('insertText', false, '新增'); await wait();
            expect(LeonArticle.serialize().includes('新增'), 'typing must still use native editing');
            LeonArticle.undo(-1); await wait(); expect(!LeonArticle.serialize().includes('新增'), 'undo must still restore the document');
            LeonArticle.load(LeonArticle.serialize(), 'caret', false, 18); await wait();
            expect(!visible() && !root.classList.contains('article-caret-visible'), 'reader mode must restore native selection styling');
            LeonArticle.load('<article data-leon-format="html-v1"><p></p><p>换行之前<br><br></p><p>末尾</p></article>', 'caret-empty', true, 18);
            const empty = root.firstElementChild;
            empty.replaceChildren();
            await select(empty, 0);
            expect(visible() && caret().getBoundingClientRect().height < 25, 'a block without a BR must also have a text-sized caret');
            const emptySaved = LeonArticle.serialize();
            await select(root.children[1], 2);
            const lineBreak = root.children[1].lastChild.getBoundingClientRect();
            expect(visible() && Math.abs(caret().getBoundingClientRect().top - lineBreak.top) < 1, 'soft line break must place the caret on the empty line');
            root.dispatchEvent(new PointerEvent('pointerdown', {bubbles: true})); await wait();
            expect(!visible(), 'pointer selection must hide the caret while dragging');
            window.dispatchEvent(new PointerEvent('pointerup')); await wait();
            expect(visible(), 'pointer release must restore the caret');
            expect(LeonArticle.serialize() === emptySaved, 'empty-line measurement must not add document markers');
            return 'wrapped text, headings, formatting, empty lines, tables, code, IME, focus, scrolling, font size, typing and undo';
            """#, arguments: [:], in: nil, contentWorld: .page)
            print("Caret checks: \(result ?? "")")
            if let preview = ProcessInfo.processInfo.environment["LEON_RICH_CARET_PREVIEW_PATH"] {
                _ = try await view.callAsyncJavaScript(#"""
                LeonArticle.load('<article data-leon-format="html-v1"><h2>个人经历</h2><p>曾在工地工作，后来经营琴行，一边业余写歌弹琴。坚持创作，记录生活中的故事与感受。</p><p>2011年在豆瓣音乐人发布第一首作品。</p></article>', 'caret-preview', true, 18);
                const root = document.getElementById('document'); root.style.width = '500px';
                root.focus(); const text = root.querySelector('p').firstChild;
                getSelection().setPosition(text, text.length);
                await new Promise(resolve => setTimeout(resolve, 80));
                document.getElementById('article-caret').style.animation = 'none';
                return true;
                """#, arguments: [:], in: nil, contentWorld: .page)
                let image = try await view.takeSnapshot(configuration: nil)
                if let tiff = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: URL(fileURLWithPath: preview))
                }
            }
        }
    }
}
