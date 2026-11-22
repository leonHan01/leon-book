import Foundation
@testable import LeonChat

@main
struct ArchiveChecks {
    static func article(_ slug: String, destination: LeonBlogExporter.Destination) throws -> [String: Any] {
        let process = Process(); process.executableURL = try LeonBlogExporter.executable()
        let params = String(data: try JSONSerialization.data(withJSONObject: ["slug": slug]), encoding: .utf8)!
        process.arguments = ["articles.get", "--root", destination.root, "--user", destination.user, "--json", params]
        let output = Pipe(); process.standardOutput = output; try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        guard process.terminationStatus == 0, let result = envelope["result"] as? [String: Any] else { throw ClientError.message("Test article readback failed") }
        return result
    }
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("leon-archive-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = try LeonBlogExporter.destination(root: directory.appendingPathComponent("library").path)
        let id = UUID().uuidString.lowercased(), imageId = UUID().uuidString.lowercased()
        let image = directory.appendingPathComponent("image.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j4ZkAAAAASUVORK5CYII=")!.write(to: image)
        let operation = ContextOperation(id: id, agentId: "agent", agentName: "Sol", status: "SUCCEEDED", error: "", result: "ok", createdAt: 1, kind: "ARCHIVE")
        var message = Message(id: 1, clientMessageId: "client", deviceId: "device", sender: "用户", platform: "macos", text: "原始对话 <script>不能执行</script>\n第二行", createdAt: 1700000000123, conversationId: "room", role: "user", agentId: nil, replyTo: nil)
        message.images = [ChatImage(id: imageId, mimeType: "image/png", width: 1, height: 1, byteCount: 68)]
        var formatted = Message(id: 2, clientMessageId: "markdown-client", deviceId: "device", sender: "Sol", platform: "macos", text: "### 渲染标题\n\n- **强调条目**\n- 普通条目\n\n> 引用段落\n\n| 列一 | 列二 |\n| --- | --- |\n| 内容一 | 内容二 |\n\n```swift\nlet value = \"<tag>\"\n```", createdAt: 1700000001123, conversationId: "room", role: "assistant", agentId: "agent", replyTo: nil)
        formatted.quote = MessageQuote(id: 1, sender: "用户", text: "**引用重点**\n\n- 引用列表", images: [])
        let archive = ChatArchive(id: id, title: "临时对话归档验收", summary: "首先展示的 **AI 总结**\n\n- 摘要条目", conversationId: "room", throughId: 2, operation: operation, messages: [message, formatted])
        let first = try LeonBlogExporter.export(archive, destination: destination, imageFiles: [imageId: image])
        let second = try LeonBlogExporter.export(archive, destination: destination, imageFiles: [:])
        precondition(first.slug == second.slug)
        let saved = try article(first.slug, destination: destination)
        let body = saved["body"] as! String
        precondition(saved["status"] as? String == "draft")
        precondition(body.range(of: "对话总结")!.lowerBound < body.range(of: "原始对话")!.lowerBound)
        precondition(body.contains("第二行") && body.contains("&lt;script&gt;") && !body.contains("<script>不能执行"))
        precondition((saved["media"] as! [Any]).count == 2)
        precondition(body.contains("2023-11-15 06:13:20") && !body.contains("2023-11-14T22:13:20"), "message timestamps must use UTC+8 with date and seconds")
        print("PASS: real LeonBook CLI exports summary-first draft, exact text, copied image and original attachment; repeat export reuses saved article")
        precondition(body.contains("<strong>AI 总结</strong>") && body.contains("<strong>强调条目</strong>"), "summary and message emphasis must render as Markdown")
        precondition(body.contains(">渲染标题</h3>") && body.contains("data-type=\"bullet\"") && body.contains("<table"), "message headings, lists and tables must render")
        precondition(body.contains("<blockquote") && body.contains("<strong>引用重点</strong>"), "quoted messages must render Markdown too")
        precondition(body.components(separatedBy: "<pre").count == 2 && body.contains("let value = &quot;&lt;tag&gt;&quot;"), "only fenced code is a code block")
        print("PASS: summary, messages and quotes render Markdown headings, emphasis, lists and tables; fenced code remains literal")

        let longText = "BEGIN-LONG-ORIGINAL\n" + String(repeating: "a", count: 6 * 1024 * 1024 + 65536) + "\nEND-LONG-ORIGINAL"
        let longID = UUID().uuidString.lowercased()
        var longMessage = Message(id: 2, clientMessageId: "long-client", deviceId: "device", sender: "用户", platform: "macos", text: longText, createdAt: 1700000000123, conversationId: "room", role: "user", agentId: nil, replyTo: nil)
        longMessage.quote = MessageQuote(id: 1, sender: "原始作者", text: "长对话中的引用原文", images: message.images!)
        let longArchive = ChatArchive(id: longID, title: "长对话归档验收", summary: "长对话总结", conversationId: "room", throughId: 2, operation: operation, messages: [longMessage])
        let longSaved = try LeonBlogExporter.export(longArchive, destination: destination, imageFiles: [imageId: image])
        let longArticle = try article(longSaved.slug, destination: destination)
        let longMedia = longArticle["media"] as! [[String: Any]]
        let originalURL = longMedia.first { $0["name"] as? String == "原始对话.md" }!["url"] as! String
        let originalFile = URL(fileURLWithPath: destination.root).appendingPathComponent("workspaces/" + destination.user).appendingPathComponent(String(originalURL.dropFirst()))
        let originalText = try String(contentsOf: originalFile, encoding: .utf8)
        precondition((longArticle["body"] as! String).contains("本轮内容较长") && originalText.contains(longText))
        precondition(originalText.contains("长对话中的引用原文") && longMedia.count == 2 && originalText.contains("![对话图片]"))
        print("PASS: >6 MiB conversation keeps its complete original, quoted text and copied quote image")
        print("PASS: isolated temporary library only; real user library unchanged")
    }
}
