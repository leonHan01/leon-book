@testable import LeonChat
import AppKit
import SwiftUI
import WebKit

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
        let host = NSHostingView(rootView: MarkdownMessageView(source, mine: false).frame(width: 580).padding(20).background(Color.white).environment(\.colorScheme, .light))
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
        print("PASS: native routing and packaged local runtime/font resources")
        print("PASS: real WKWebView task lists, math, Mermaid labels, merged tables, dynamic disclosure height and snapshot")
    }
}
