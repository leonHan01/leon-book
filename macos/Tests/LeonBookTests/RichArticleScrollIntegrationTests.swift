import AppKit
import SwiftUI
import WebKit
@testable import LeonBook

private struct ReaderScrollFailure: Error, CustomStringConvertible { let description: String }

extension RichArticleTests {
    @MainActor
    func testEmbeddedReaderSuppressesPageScrollbarsUntilNativeHeightCatchesUp() async throws {
        try await withWebEditor { view in
            _ = try await view.callAsyncJavaScript(#"""
            const source = '<article data-leon-format="html-v1">' + '<p>滚动正文</p>'.repeat(100) + '</article>';
            const expect = (value, message) => { if (!value) throw new Error(message); };
            const suppressesScrollbars = () => ['hidden', 'clip'].includes(getComputedStyle(document.documentElement).overflowY);
            LeonArticle.load(source, 'embedded-scroll-owner', false, 18, true);
            expect(document.scrollingElement.scrollHeight > innerHeight, 'fixture must cover pending native height updates');
            expect(suppressesScrollbars(), 'Embedded article exposes a second page scrollbar before the native frame catches up');
            const wheel = new WheelEvent('wheel', {bubbles:true, cancelable:true, deltaY:120});
            document.getElementById('document').dispatchEvent(wheel);
            expect(wheel.defaultPrevented, 'embedded wheel events must be forwarded to native scrolling');
            LeonArticle.load(source, 'standalone-scroll-owner', false, 18, false);
            expect(!suppressesScrollbars(), 'standalone reader must retain its page scrolling');
            LeonArticle.load(source, 'editor-scroll-owner', true, 18, true);
            expect(!suppressesScrollbars(), 'editor must retain its page scrolling');
            """#, arguments: [:], in: nil, contentWorld: .page)
        }
    }

    @MainActor
    func testReaderUsesOnlyNativeScrollViewWhileScrollingAndResizing() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reader-scroll-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalBlogStore(rootURL: directory)
        let fixture: String
        if let path = ProcessInfo.processInfo.environment["LEON_READER_ARTICLE_FIXTURE"] {
            let envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
            fixture = (envelope["result"] as! [String: Any])["body"] as! String
        } else {
            fixture = RichArticleDocument.opening + "<h2>对话总结</h2>" + (0..<75).map {
                "<h3>第\($0)段</h3><p>" + String(repeating: "这是用于验证原生阅读器滚动和窗口缩放的正文。", count: 8) + "</p>"
            }.joined() + "<p>LAST ARTICLE PARAGRAPH</p></article>"
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let suiteName = "ReaderScroll.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let layout = NativeWorkspaceLayoutState(defaults: defaults)
        layout.isReaderInspectorVisible = false
        let preferences = NativeReadingPreferences(defaults: defaults)
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false, store: store)
        model.storageReady = true; model.isLoading = false
        model.selectedArticle = NativeArticle(banner: nil, body: fixture, category: "AI 对话", excerpt: "",
            media: [NativeMedia(kind: "file", name: "原始对话.md", size: 1, url: "/media/original.md")],
            slug: "scroll-fixture", status: .draft, tags: ["AI对话"], title: "滚动回归文章",
            updatedAt: "2026-11-21T14:00:00Z", publishedAt: nil, wordCount: 8300)
        let host = NSHostingView(rootView: ArticleReaderView(model: model, workspaceLayout: layout, readingPreferences: preferences)
            .environment(\.locale, Locale(identifier: "zh-Hans")).environment(\.colorScheme, .light))
        window.contentView = host
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func settle() async throws {
            for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 30_000_000) }
        }
        var loaded: WKWebView?
        for _ in 0..<200 {
            try await Task.sleep(nanoseconds: 25_000_000); host.layoutSubtreeIfNeeded()
            if let web = descendants(host).compactMap({ $0 as? WKWebView }).first,
               (try? await web.evaluateJavaScript("typeof LeonArticle === 'object' && document.getElementById('document').getBoundingClientRect().height > 100")) as? Bool == true {
                loaded = web; break
            }
        }
        guard let web = loaded, let scroll = web.enclosingScrollView, let document = scroll.documentView else {
            throw ReaderScrollFailure(description: "Native reader did not load inside its scroll view")
        }
        scroll.scrollerStyle = .legacy; scroll.autohidesScrollers = false
        for size in [NSSize(width: 1000, height: 800), NSSize(width: 700, height: 1100), NSSize(width: 1200, height: 700)] {
            window.setContentSize(size); try await settle()
            var stableHeight: CGFloat?
            for fraction in [0.0, 0.5, 1.0] {
                let clip = scroll.contentView
                let minimum = document.bounds.minY
                let maximum = max(minimum, document.bounds.maxY - clip.bounds.height)
                let y = minimum + (maximum - minimum) * fraction
                clip.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(clip)
                try await settle()
                if let prefix = ProcessInfo.processInfo.environment["LEON_READER_SCROLL_PREVIEW"], fraction == 0.5 {
                    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-\(Int(size.width)).png"))
                    }
                }
                let documentHeight = document.bounds.height
                if let stableHeight, abs(documentHeight - stableHeight) > 1 {
                    throw ReaderScrollFailure(description: "Scroll range changed from \(stableHeight) to \(documentHeight) without article changes at fraction \(fraction)")
                }
                stableHeight = documentHeight
                let state = try await web.evaluateJavaScript("JSON.stringify({viewport:innerHeight,scrollHeight:document.scrollingElement.scrollHeight,scrollTop:document.scrollingElement.scrollTop,rootHeight:document.getElementById('document').getBoundingClientRect().height,rootTop:document.getElementById('document').getBoundingClientRect().top})") as! String
                print("READER_SCROLL size=\(size) fraction=\(fraction) webFrame=\(web.frame) outer=\(clip.bounds) state=\(state)")
                let metrics = try JSONSerialization.jsonObject(with: Data(state.utf8)) as! [String: Double]
                guard metrics["scrollHeight"]! <= metrics["viewport"]!, metrics["scrollTop"]! == 0 else {
                    throw ReaderScrollFailure(description: "Second scrollbar inside native reader: \(state)")
                }
            }
        }
    }
}
