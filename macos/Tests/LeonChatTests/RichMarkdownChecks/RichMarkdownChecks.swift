@testable import LeonChat
import AppKit
import SwiftUI
import WebKit

private final class MarkdownScrollDocument: NSView {
    override var isFlipped: Bool { true }
}

@main
struct RichMarkdownChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "RichMarkdownChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func wait(_ condition: () -> Bool, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }
    static func findWeb(_ view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for child in view.subviews { if let web = findWeb(child) { return web } }
        return nil
    }
    static func evaluate(_ web: WKWebView, _ script: String) throws -> Any? {
        var finished = false, result: Any?, failure: Error?
        web.evaluateJavaScript(script) { value, error in result = value; failure = error; finished = true }
        guard wait({ finished }, timeout: 15) else { throw NSError(domain: "JavaScript timed out", code: 1) }
        if let failure { throw failure }
        return result
    }

    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        for source in ["- [ ] 待办", "正文[^1]", "术语\n: 定义", "![图](https://example.com/a.png)", "```java\nclass A {}\n```",
                       "> [!NOTE]\n提示", "==高亮==", "H~2~O", "x^2^", ":smile:", "[[标题]]", "<details><summary>折叠</summary>正文</details>"] {
            try check(RichMarkdown.isRequired(source), "Extension did not select shared renderer: \(source)")
        }
        for source in ["你好", "**粗体** 和 *斜体*", "[网站](https://example.com)", "$x_i^2$", "\\[x^2\\]"] {
            try check(!RichMarkdown.isRequired(source), "Basic message unnecessarily loaded a browser: \(source)")
        }
        guard let runtime = RichMarkdown.runtimeURL else { throw NSError(domain: "Missing runtime", code: 1) }
        for file in ["markdown.html", "renderer.js", "diagrams.js", "katex.min.css", "fonts/KaTeX_Main-Regular.woff2", "THIRD-PARTY-LICENSES.txt"] {
            try check(FileManager.default.fileExists(atPath: runtime.appendingPathComponent(file).path), "Missing bundled file: \(file)")
        }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/showcase.md")
        let source = try String(contentsOf: fixture, encoding: .utf8)
        func message(fontSize: CGFloat) -> some View {
            MarkdownMessageView(source, mine: false).frame(width: 580).padding(20)
                .background(Color.white).environment(\.colorScheme, .light)
                .environment(\.chatBodyFontSize, fontSize)
        }
        let host = NSHostingView(rootView: message(fontSize: 14))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 620, height: 1800), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host; window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        var web: WKWebView?
        try check(wait { web = findWeb(host); return web != nil }, "SwiftUI did not create the rich message view")
        guard let web else { return }
        var rendered = false
        let deadline = Date().addingTimeInterval(30)
        while !rendered && Date() < deadline {
            rendered = (try? evaluate(web, "document.querySelectorAll('.diagram svg').length === 2 && document.querySelectorAll('.katex').length === 3")) as? Bool == true
            if !rendered { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        }
        try check(rendered, "WKWebView failed to render bundled scripts, math or Mermaid")
        let taskCount = try evaluate(web, "document.querySelectorAll('input[type=checkbox]').length") as? Int
        let hasLabels = try evaluate(web, "document.querySelector('.diagram').textContent.includes('解析消息')") as? Bool
        let colspan = try evaluate(web, "document.querySelector('th').colSpan") as? Int
        try check(taskCount == 2, "Native task list missing")
        try check(hasLabels == true, "Native diagram lost labels")
        try check(colspan == 2, "Native merged table missing")
        let oldHeight = web.frame.height
        _ = try evaluate(web, "document.querySelector('details').open=true")
        try check(wait({ host.layoutSubtreeIfNeeded(); return web.frame.height > oldHeight }, timeout: 5), "Native message height did not follow expanded details")
        var image: NSImage?, snapshotError: Error?, complete = false
        web.takeSnapshot(with: nil) { value, error in image = value; snapshotError = error; complete = true }
        try check(wait { complete }, "WKWebView snapshot timed out")
        if let snapshotError { throw snapshotError }
        guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw NSError(domain: "No native preview", code: 1) }
        try png.write(to: URL(fileURLWithPath: ".build/rich-markdown-preview.png"))
        let bitmap = NSBitmapImageRep(cgImage: cg)
        try check((bitmap.colorAt(x: bitmap.pixelsWide - 1, y: bitmap.pixelsHigh - 1)?.alphaComponent ?? 1) < 0.1,
                  "Web content must stay transparent over outgoing and dark chat bubbles")
        let standardHeight = web.frame.height
        host.rootView = message(fontSize: 23)
        try check(wait({
            host.layoutSubtreeIfNeeded()
            return web.frame.height > standardHeight && findWeb(host) === web
        }, timeout: 5), "Changing body size must remeasure the open rich message in place")
        let fontSizes = try evaluate(web, "[document.body, document.querySelector('pre code')].map(node => getComputedStyle(node).fontSize)") as? [String]
        try check(fontSizes == ["23px", "22px"], "Rich text and code must follow the chat body size")
        let plainText = String(repeating: "聊天消息正文 ", count: 20)
        func plainHeight(fontSize: CGFloat) -> CGFloat {
            NSHostingView(rootView: MarkdownMessageView(plainText, mine: false).frame(width: 250)
                .environment(\.chatBodyFontSize, fontSize)).fittingSize.height
        }
        try check(plainHeight(fontSize: 23) > plainHeight(fontSize: 14), "Native message text must follow the chat body size")
        try checkWebViewReuse()
        print("PASS: native routing and packaged local runtime/font resources")
        print("PASS: real WKWebView task lists, math, Mermaid labels, merged tables, dynamic disclosure height and snapshot")
    }

    @MainActor private static func checkWebViewReuse() throws {
        let rect = NSRect(x: -10_000, y: -10_000, width: 520, height: 260)
        let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: rect.size))
        let document = MarkdownScrollDocument(frame: NSRect(x: 0, y: 0, width: 520, height: 1500))
        let first = NSHostingView(rootView: MarkdownMessageView("```swift\nlet firstFixture = 1\n```", mine: false).frame(width: 500))
        let second = NSHostingView(rootView: MarkdownMessageView("```swift\nlet secondFixture = 2\n```", mine: false).frame(width: 500))
        first.frame = NSRect(x: 0, y: 0, width: 520, height: 160)
        second.frame = NSRect(x: 0, y: 950, width: 520, height: 160)
        document.addSubview(first); document.addSubview(second)
        scroll.documentView = document
        window.contentView = scroll; window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        func scrollTo(_ y: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        func verifyCode(in view: WKWebView, contains text: String, excluding oldText: String) -> Bool {
            let value = try? evaluate(view, """
                document.querySelector('.hljs-keyword') !== null && document.querySelector('.code-toolbar button') !== null &&
                document.getElementById('message').textContent.includes('\(text)') &&
                !document.getElementById('message').textContent.includes('\(oldText)')
                """)
            return value as? Bool == true
        }

        scrollTo(0)
        try check(wait { findWeb(first) != nil } && findWeb(second) == nil, "Only the nearby rich message should borrow a WebView")
        let web = findWeb(first)!
        try check(wait { verifyCode(in: web, contains: "firstFixture", excluding: "secondFixture") }, "First code message did not render")
        scrollTo(460)
        try check(wait { findWeb(first) == nil && findWeb(second) == nil }, "Scrolling away must release the WebView")
        scrollTo(920)
        try check(wait { findWeb(second) === web }, "Second rich message must reuse the warm WebView")
        try check(wait { !web.isHidden && verifyCode(in: web, contains: "secondFixture", excluding: "firstFixture") },
                  "Recycled renderer must replace old content and retain syntax highlighting and copy controls")
        print("PASS: scrolling releases offscreen WebViews and reuses the renderer for a different highlighted message")
    }
}
