import Foundation

enum LeonBlogExporter {
    struct Destination: Codable, Sendable, Equatable { let root: String; let user: String }
    struct Saved: Sendable { let slug: String; let title: String }
    private static let messageDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
    static func messageTime(_ date: Date) -> String { messageDateFormatter.string(from: date) }
    static func executable() throws -> URL {
        if let bundled = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("LeonBookCLI"),
           FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        if Bundle.main.bundleIdentifier == "com.leon-book.macos" {
            throw ClientError.message("应用缺少内置归档工具，请重新构建或安装 LeonBook。当前上下文已保留。")
        }
        if let override = ProcessInfo.processInfo.environment["LEON_CHAT_CLI_PATH"],
           FileManager.default.isExecutableFile(atPath: override) { return URL(fileURLWithPath: override) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".local/bin/leonbook").path] + (ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin").split(separator: ":").map { String($0) + "/leonbook" }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw ClientError.message("未找到 leonbook CLI，请先安装或配置 LeonBook。当前上下文已保留。") }
        return URL(fileURLWithPath: path)
    }
    static func destination(root: String? = nil, user: String? = nil) throws -> Destination {
        let value = try call("workspace.info", params: [:], destination: root.map { Destination(root: $0, user: user ?? "") })
        guard let root = value["root"] as? String, let user = (value["user"] as? [String: Any])?["id"] as? String,
              FileManager.default.fileExists(atPath: root), !user.isEmpty else { throw ClientError.message("无法读取 LeonBook 资料库，请确认磁盘已连接。") }
        return Destination(root: root, user: user)
    }
    private static func call(_ method: String, params: [String: Any], destination: Destination?, missingAllowed: Bool = false) throws -> [String: Any] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("leonbook-cli-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = directory.appendingPathComponent("request.json"), output = directory.appendingPathComponent("output.json"), errors = directory.appendingPathComponent("error.txt")
        let data = try JSONSerialization.data(withJSONObject: params)
        guard data.count < 8 * 1024 * 1024 else { throw ClientError.message("归档请求超过 CLI 限制，当前上下文已保留。") }
        try data.write(to: request, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: request.path)
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: errors.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let out = try FileHandle(forWritingTo: output), err = try FileHandle(forWritingTo: errors)
        defer { try? out.close(); try? err.close() }
        let process = Process(); process.executableURL = try executable()
        var arguments = [method]
        if let destination { arguments += ["--root", destination.root]; if !destination.user.isEmpty { arguments += ["--user", destination.user] } }
        process.arguments = arguments + ["--json", "@" + request.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = out; process.standardError = err
        try process.run()
        let deadline = Date().addingTimeInterval(45)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); throw ClientError.message("LeonBook CLI 响应超时，请重试核验归档；当前上下文已保留。") }
        let response = try Data(contentsOf: output)
        guard let envelope = try JSONSerialization.jsonObject(with: response) as? [String: Any] else { throw ClientError.message("LeonBook CLI 返回格式无效，当前上下文已保留。") }
        if let failure = envelope["error"] as? [String: Any] {
            if missingAllowed, failure["code"] as? String == "not_found" { return [:] }
            throw ClientError.message("LeonBook：" + (failure["message"] as? String ?? "写入未完成"))
        }
        guard process.terminationStatus == 0, let result = envelope["result"] as? [String: Any] else { throw ClientError.message("LeonBook 未确认操作成功，当前上下文已保留。") }
        return result
    }
    private static func inlineMarkdown(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        for character in ["\\", "`", "*", "_", "[", "]", "<", ">", "#", "~", "|"] {
            result = result.replacingOccurrences(of: character, with: "\\" + character)
        }
        return result
    }
    static func images(in archive: ChatArchive) -> [ChatImage] {
        var seen = Set<String>()
        return archive.messages.flatMap { ($0.images ?? []) + ($0.quote?.images ?? []) }.filter { seen.insert($0.id).inserted }
    }
    static func documents(in archive: ChatArchive) -> [DocumentAttachment] {
        var seen = Set<String>()
        return archive.messages.flatMap { ($0.documents ?? []) + ($0.quote?.documents ?? []) }.filter { seen.insert($0.id).inserted }
    }
    private static func verify(_ article: [String: Any], id: String) throws -> Saved {
        let slug = "leon-chat-" + id.lowercased()
        let properties = article["properties"] as? [String: Any]
        guard article["slug"] as? String == slug,
              (properties?["leonChatArchiveId"] as? [String: Any])?["value"] as? String == id else {
            throw ClientError.message("LeonBook 已存在同名文章，归档标识不一致；未覆盖文章，当前上下文保留。")
        }
        return Saved(slug: slug, title: article["title"] as? String ?? "对话归档")
    }
    static func highlightingSpeakers(in body: String) -> String {
        let expression = try! NSRegularExpression(pattern: #"<h3\b([^>]*)>([^<]+ · (?:AI|用户))</h3>(?=\s*<p\b[^>]*>\d{4}-\d{2}-\d{2}[T ])"#)
        return expression.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body),
            withTemplate: "<h3$1><span style=\"color: #2563eb;\">$2</span></h3>")
    }
    static func localizingMessageTimes(in body: String) -> String {
        let expression = try! NSRegularExpression(pattern: #"(<h3\b[^>]*>[^<]*(?:<span\b[^>]*>)?[^<]* · (?:AI|用户)(?:</span>)?</h3>\s*<p\b[^>]*>)(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2}))(</p>)"#)
        let parser = ISO8601DateFormatter()
        let fractionalParser = ISO8601DateFormatter()
        fractionalParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let source = body as NSString, result = NSMutableString(string: body)
        for match in expression.matches(in: body, range: NSRange(location: 0, length: source.length)).reversed() {
            let timestamp = source.substring(with: match.range(at: 2))
            if let date = parser.date(from: timestamp) ?? fractionalParser.date(from: timestamp) {
                result.replaceCharacters(in: match.range(at: 2), with: messageTime(date))
            }
        }
        return result as String
    }
    static func savedArchive(id: String, destination: Destination) throws -> Saved? {
        let slug = "leon-chat-" + id.lowercased()
        let existing = try call("articles.get", params: ["slug": slug], destination: destination, missingAllowed: true)
        guard !existing.isEmpty else { return nil }
        let saved = try verify(existing, id: id)
        guard let body = existing["body"] as? String, let updatedAt = existing["updatedAt"] as? String else {
            throw ClientError.message("LeonBook 归档正文或版本信息缺失，当前上下文已保留。")
        }
        // Apply speaker colors and UTC+8 timestamps after Markdown conversion.
        // Retrying finishes this step before any context reset.
        let formatted = highlightingSpeakers(in: localizingMessageTimes(in: body))
        guard formatted != body else { return saved }
        _ = try call("articles.update", params: ["slug": slug, "body": formatted, "format": "html", "expectedUpdatedAt": updatedAt], destination: destination)
        let updated = try call("articles.get", params: ["slug": slug], destination: destination)
        guard updated["body"] as? String == formatted else { throw ClientError.message("LeonBook 未确认归档显示格式已保存，当前上下文已保留。") }
        return try verify(updated, id: id)
    }
    static func export(_ archive: ChatArchive, destination: Destination, imageFiles: [String: URL], documentFiles: [String: URL] = [:]) throws -> Saved {
        if let existing = try savedArchive(id: archive.id, destination: destination) { return existing }
        let slug = "leon-chat-" + archive.id.lowercased()
        // Recover staged files left by an interrupted attempt. Cleanup on errors
        // keeps repeated saves from collecting copies of the original conversation.
        try discardUncommittedMedia(archiveID: archive.id, destination: destination)
        var committed = false
        defer {
            if !committed { try? discardUncommittedMedia(archiveID: archive.id, destination: destination) }
        }
        var media: [[String: Any]] = [], imageURLs: [String: String] = [:], documentURLs: [String: String] = [:]
        for id in images(in: archive).map(\.id).sorted() {
            guard let file = imageFiles[id] else { throw ClientError.message("原对话图片未准备完整，当前上下文已保留。") }
            let item = try call("media.upload", params: ["path": file.path, "kind": "image", "slug": slug], destination: destination)
            guard let url = item["url"] as? String else { throw ClientError.message("LeonBook 未返回图片地址。") }
            imageURLs[id] = url
            media.append(["kind": "image", "name": item["name"] as? String ?? id + ".jpg", "size": item["size"] as? Int ?? 0, "url": url])
        }
        for document in documents(in: archive) {
            guard let file = documentFiles[document.id] else { throw ClientError.message("原对话文档未准备完整，当前上下文已保留。") }
            let item = try call("media.upload", params: ["path": file.path, "kind": "file", "slug": slug], destination: destination)
            guard let url = item["url"] as? String else { throw ClientError.message("LeonBook 未返回文档地址。") }
            documentURLs[document.id] = url
            media.append(["kind": "file", "name": document.name, "size": item["size"] as? Int ?? document.byteCount, "url": url])
        }
        func attachments(_ images: [ChatImage], _ documents: [DocumentAttachment]) throws -> String {
            var raw = ""
            for image in images {
                guard let url = imageURLs[image.id] else { throw ClientError.message("原对话图片未保存完整，当前上下文已保留。") }
                raw += "\n![对话图片](" + url + ")\n"
            }
            for document in documents {
                guard let url = documentURLs[document.id] else { throw ClientError.message("原对话文档未保存完整，当前上下文已保留。") }
                let label = document.name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
                raw += "\n[文件：" + label + "](" + url + ")\n"
            }
            return raw
        }
        var raw = "# " + archive.title + "\n\n", markdown = "## 原始对话\n\n"
        for message in archive.messages {
            let identity = message.sender + (message.role == "assistant" ? " · AI" : " · 用户")
            let date = messageTime(message.date)
            raw += "\n## " + identity + " · " + date + "\n\n" + message.text + "\n"
            markdown += "### " + inlineMarkdown(identity) + "\n\n" + date + "\n\n" + message.text + "\n\n"
            let own = try attachments(message.images ?? [], message.documents ?? [])
            raw += own; markdown += own + "\n"
            if let quote = message.quote {
                let heading = "引用消息 #\(quote.id) · " + quote.sender
                let quoted = try attachments(quote.images, quote.documents ?? [])
                raw += "\n### " + heading + "\n\n" + quote.text + "\n" + quoted
                let quotedMarkdown = "**" + inlineMarkdown(heading) + "**\n\n" + quote.text + "\n" + quoted
                markdown += quotedMarkdown.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n") + "\n\n"
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("leon-chat-export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("原始对话.md"); try Data(raw.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let attachment = try call("media.upload", params: ["path": file.path, "kind": "file", "slug": slug], destination: destination)
        guard let originalURL = attachment["url"] as? String else { throw ClientError.message("原始对话附件未保存成功。") }
        media.append(["kind": "file", "name": "原始对话.md", "size": attachment["size"] as? Int ?? 0, "url": originalURL])
        let summary = "## 对话总结\n\n" + archive.summary + "\n\n"
        let download = "[下载完整原始对话（Markdown）](" + originalURL + ")\n\n"
        let properties: [String: Any] = ["leonChatArchiveId": ["kind": "text", "value": archive.id]]
        var params: [String: Any] = ["slug": slug, "title": archive.title, "body": summary + download + "---\n\n" + markdown,
            "format": "markdown", "status": "draft", "category": "AI 对话", "tags": ["AI对话", "Leon聊天归档"], "properties": properties, "media": media]
        if try JSONSerialization.data(withJSONObject: params).count > 6 * 1024 * 1024 {
            params["body"] = summary + "## 原始对话\n\n本轮内容较长，完整原文及引用已保存在附件中，所有图片和文档均已复制到资料库。\n\n" + download
        }
        _ = try call("articles.create", params: params, destination: destination)
        guard let saved = try savedArchive(id: archive.id, destination: destination) else { throw ClientError.message("LeonBook 未确认归档已保存，当前上下文已保留。") }
        committed = true
        return saved
    }

    private static func discardUncommittedMedia(archiveID: String, destination: Destination) throws {
        _ = try call("media.discardChatArchive", params: ["archiveId": archiveID], destination: destination)
    }
}
