import AppKit
import SwiftUI
import WebKit
@testable import LeonBook

extension RichArticleTests {
    @MainActor
    func testRichArticleOutlineNativeBridge() async throws {
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "RichArticleOutlineTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        _ = NSApplication.shared
        let controller = RichArticleOutlineController()
        let html = "<article data-leon-format=\"html-v1\"><h1>Overview</h1>"
            + String(repeating: "<p>Paragraph</p>", count: 24) + "<h2>Details</h2>"
            + String(repeating: "<p>Tail</p>", count: 16) + "</article>"
        let host = NSHostingView(rootView: RichArticleEditor(html: .constant(html), documentID: "outline-native", outlineController: controller))
        host.frame = NSRect(x: 0, y: 0, width: 1040, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        func webView(in view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap { webView(in: $0) }.first
        }
        guard let view = webView(in: host) else { try require(false, "expected native editor web view"); return }
        for _ in 0..<200 where controller.snapshot.items.count != 2 { try await Task.sleep(nanoseconds: 25_000_000) }
        try require(controller.snapshot.items.map(\.title) == ["Overview", "Details"], "native directory must receive the editor headings")
        guard let target = controller.snapshot.items.last else { return }
        controller.navigate(to: target, documentID: "outline-native")
        for _ in 0..<100 where controller.snapshot.activeID != target.id { try await Task.sleep(nanoseconds: 25_000_000) }
        try require(controller.snapshot.activeID == target.id, "native directory must highlight the destination")
        try require((try await view.evaluateJavaScript("scrollY > 100")) as? Bool == true, "native directory must scroll the editor")
        host.rootView = RichArticleEditor(html: .constant("<article data-leon-format=\"html-v1\"><h3>Another document</h3></article>"), documentID: "outline-next", outlineController: controller)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<200 where controller.snapshot.documentID != "outline-next" { try await Task.sleep(nanoseconds: 25_000_000) }
        try require(controller.snapshot.items.map(\.title) == ["Another document"], "native directory must follow document switches")
        controller.receive(items: [["id": target.id, "level": 2, "title": "Stale"]], documentID: "outline-native")
        controller.navigate(to: target, documentID: "outline-native")
        try require(controller.snapshot.items.map(\.title) == ["Another document"], "late callbacks from the old editor must not replace its successor's directory")
    }

    @MainActor
    func testRichArticleOutlineNavigationAndUpdates() async throws {
        try await withWebEditor { view in
            _ = try await view.callAsyncJavaScript(#"""
            const root = document.getElementById('document'), messages = [];
            const descriptor = Object.getOwnPropertyDescriptor(window, 'webkit');
            Object.defineProperty(window, 'webkit', { configurable: true, value: { messageHandlers: { richArticle: { postMessage: payload => messages.push(payload) } } } });
            const expect = (value, message) => { if (!value) throw new Error(message); };
            const wait = () => new Promise(resolve => setTimeout(resolve, 90));
            let step = 0;
            const until = async predicate => { const current = ++step; for (let i = 0; i < 30 && !predicate(); i++) await wait(); expect(predicate(), 'outline update timed out at step ' + current + ': ' + JSON.stringify({ scrollY, outline: latest('editorOutline'), active: latest('editorOutlineActive') })); };
            const latest = type => messages.filter(message => message.type === type).at(-1);
            const items = () => latest('editorOutline')?.items || [];
            const load = (html, id = 'outline-edit', editable = true) => LeonArticle.load('<article data-leon-format="html-v1">' + html + '</article>', id, editable, 18);
            const filler = '<p>Paragraph content</p>'.repeat(16);
            try {
              LeonArticle.setOutlineEnabled(true);
              load('<h1>Overview</h1>' + filler + '<h2>Details</h2>' + filler + '<h3>Details</h3><h4><br></h4><table><tr><td><h2>In a cell</h2></td></tr></table>' + filler);
              await until(() => items().length === 5);
              expect(items().map(item => item.level).join() === '1,2,3,4,2', 'include all supported heading levels and nested cell headings in document order');
              expect(items().map(item => item.title).join('|') === 'Overview|Details|Details||In a cell', 'preserve duplicate and empty titles');
              expect(new Set(items().map(item => item.id)).size === 5, 'duplicate titles must have distinct navigation targets');
              const original = LeonArticle.serialize(), targets = items().map(item => item.id), heading = root.querySelector('h2');
              root.focus(); getSelection().setPosition(root.querySelector('p').firstChild, 3);
              const anchor = getSelection().anchorNode, offset = getSelection().anchorOffset;
              expect(LeonArticle.navigateOutline(targets[1], 'outline-edit'), 'directory click must navigate to an existing heading');
              await until(() => Math.abs(heading.getBoundingClientRect().top - document.getElementById('toolbar').getBoundingClientRect().bottom - 12) < 2);
              await until(() => latest('editorOutlineActive')?.id === targets[1]);
              expect(getSelection().anchorNode === anchor && getSelection().anchorOffset === offset && LeonArticle.serialize() === original, 'navigation must preserve caret, content and undo history');
              window.scrollTo(0, 0); await until(() => latest('editorOutlineActive')?.id === targets[0]);
              const published = messages.filter(message => message.type === 'editorOutline').length;
              for (let i = 0; i < 100; i++) window.dispatchEvent(new Event('scroll'));
              await wait(); expect(messages.filter(message => message.type === 'editorOutline').length === published, 'scrolling must not republish the unchanged heading list');
              heading.firstElementChild ? heading.firstElementChild.textContent = 'Updated' : heading.textContent = 'Updated';
              root.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: 'd' }));
              await until(() => items()[1]?.title === 'Updated');
              expect(items()[1].id === targets[1], 'renaming must preserve the navigation identity');
              LeonArticle.undo(-1); await until(() => items()[1]?.title === 'Details');
              LeonArticle.undo(1); await until(() => items()[1]?.title === 'Updated');
              const removedID = items()[2].id; root.querySelector('h3').remove(); root.dispatchEvent(new Event('input'));
              await until(() => items().length === 4);
              expect(!LeonArticle.navigateOutline(removedID, 'outline-edit'), 'deleted headings must reject stale clicks');
              const currentID = items()[1].id;
              load('<p>No headings in this document</p>', 'outline-other'); await until(() => latest('editorOutline')?.documentID === 'outline-other' && !items().length);
              expect(!LeonArticle.navigateOutline(currentID, 'outline-edit'), 'switching documents must reject the previous directory');
              load('<h2>Read only</h2>' + filler, 'outline-reader', false); await until(() => items()[0]?.title === 'Read only');
              const reader = LeonArticle.serialize(); expect(LeonArticle.navigateOutline(items()[0].id, 'outline-reader') && LeonArticle.serialize() === reader, 'directory navigation must also work without editing the document');
              LeonArticle.setOutlineEnabled(false); const disabledCount = messages.length;
              root.querySelector('h2').textContent = 'Disabled'; window.dispatchEvent(new Event('scroll')); await wait();
              expect(messages.length === disabledCount, 'disabled directory must stop publishing and observing changes');
              LeonArticle.setOutlineEnabled(true); await until(() => items()[0]?.title === 'Disabled');
              return true;
            } finally {
              LeonArticle.setOutlineEnabled(false);
              if (descriptor) Object.defineProperty(window, 'webkit', descriptor); else delete window.webkit;
            }
            """#, arguments: [:], in: nil, contentWorld: .page)
        }
    }
}
