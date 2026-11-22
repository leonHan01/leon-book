import Foundation
@testable import LeonChat
import Darwin

private final class ArchiveFixture: @unchecked Sendable {
    private let lock = NSLock()
    var message: Message!
    var files: [String: Data] = [:]
    var failDownloads = false
    var finishFailures = 0
    var finishFailureStatus = 500
    var topicStartedAfter: Int64 = 0
    var newerMessages: [Message] = []
    private(set) var archiveIDs: [String] = []
    private(set) var finishIDs: [String] = []
    private(set) var downloads: [String] = []
    func reset(message: Message, files: [String: Data] = [:], finishFailures: Int = 0, failDownloads: Bool = false,
               finishFailureStatus: Int = 500, topicStartedAfter: Int64 = 0, newerMessages: [Message] = []) {
        lock.lock(); defer { lock.unlock() }
        self.message = message; self.files = files; self.finishFailures = finishFailures; self.failDownloads = failDownloads
        self.finishFailureStatus = finishFailureStatus; self.topicStartedAfter = topicStartedAfter; self.newerMessages = newerMessages
        archiveIDs = []; finishIDs = []; downloads = []
    }
    func stopDownloads() { lock.lock(); defer { lock.unlock() }; failDownloads = true }
    func snapshot() -> (archives: [String], finishes: [String], downloads: [String]) {
        lock.lock(); defer { lock.unlock() }; return (archiveIDs, finishIDs, downloads)
    }
    func response(_ request: URLRequest) throws -> (Int, String, Data) {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path
        func json<T: Encodable>(_ value: T, status: Int = 200) throws -> (Int, String, Data) {
            (status, "application/json", try JSONEncoder().encode(value))
        }
        func operation(_ id: String) -> ContextOperation {
            ContextOperation(id: id, agentId: "archive-test-agent", agentName: "Test", status: "SUCCEEDED", error: "", result: "ok", createdAt: 1, kind: "ARCHIVE")
        }
        if path == "/api/conversations/context/archive", request.httpMethod == "POST" {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count))
                }
            }
            let params = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            let id = params["requestId"] as! String; archiveIDs.append(id)
            return try json(operation(id))
        }
        if path.hasSuffix("/finish") {
            finishIDs.append(request.url!.deletingLastPathComponent().lastPathComponent)
            if finishFailures > 0 { finishFailures -= 1; return try json(["detail": "temporary finish failure"], status: finishFailureStatus) }
            return try json(ConversationContext(conversationId: message.conversationId!, recentRounds: 4, inputTokenBudget: 10000, topicStartedAfter: 1, agents: []))
        }
        if path.hasPrefix("/api/conversations/context/archive/") {
            let id = request.url!.lastPathComponent
            let messages = archiveIDs.first == id || newerMessages.isEmpty ? [message!] : newerMessages
            return try json(ChatArchive(id: id, title: "本轮讨论的关键结论与行动计划", summary: "归档总结", conversationId: message.conversationId!, throughId: messages.last!.id, operation: operation(id), messages: messages))
        }
        if path == "/api/conversations/context" { return try json(ConversationContext(conversationId: message.conversationId!, recentRounds: 4, inputTokenBudget: 10000, topicStartedAfter: topicStartedAfter, agents: [])) }
        if path == "/api/device-messages" { return try json(MessagePage(messages: newerMessages, hasMore: false, jobs: [], contextOperations: [])) }
        if path.hasPrefix("/api/device-messages/images/") || path.hasPrefix("/api/device-messages/documents/") {
            let id = request.url!.lastPathComponent; downloads.append(id)
            if !failDownloads, let data = files[id] { return (200, path.contains("/images/") ? "image/jpeg" : "application/octet-stream", data) }
            return try json(["detail": "missing attachment"], status: 404)
        }
        return try json(["detail": "unexpected fixture request: " + path], status: 500)
    }
}
private final class ArchiveProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = ArchiveFixture()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, type, data) = try Self.fixture.response(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": type, "Content-Length": String(data.count)])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct ArchiveFlowChecks {
    static func cli(_ method: String, _ destination: LeonBlogExporter.Destination, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let process = Process(); process.executableURL = try LeonBlogExporter.executable()
        process.arguments = [method, "--root", destination.root, "--user", destination.user, "--json", String(data: try JSONSerialization.data(withJSONObject: params), encoding: .utf8)!]
        let pipe = Pipe(); process.standardOutput = pipe; try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        guard process.terminationStatus == 0, let result = envelope["result"] as? [String: Any] else {
            throw ClientError.message("Test CLI: " + String(data: data, encoding: .utf8)!)
        }
        return result
    }
    static func contents(_ media: [String: Any], _ destination: LeonBlogExporter.Destination) throws -> Data {
        let workspace = URL(fileURLWithPath: destination.root).appendingPathComponent("workspaces/" + destination.user)
        return try Data(contentsOf: workspace.appendingPathComponent(String((media["url"] as! String).dropFirst())))
    }
    @MainActor static func main() async {
        do { try await run() }
        catch { print("FAIL: " + error.localizedDescription); exit(EXIT_FAILURE) }
    }
    @MainActor static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("leon-archive-flow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousRoot = getenv("LEON_BOOK_WORKDIR").map { String(cString: $0) }
        let originalDevice = ChatPreferences.defaults.object(forKey: "deviceId")
        var rooms: [String] = [], failures = 0
        defer {
            if let previousRoot { setenv("LEON_BOOK_WORKDIR", previousRoot, 1) } else { unsetenv("LEON_BOOK_WORKDIR") }
            for key in ChatPreferences.defaults.dictionaryRepresentation().keys where rooms.contains(where: { key.contains($0) }) { ChatPreferences.defaults.removeObject(forKey: key) }
            if originalDevice == nil { ChatPreferences.defaults.removeObject(forKey: "deviceId") }
            try? FileManager.default.removeItem(at: directory)
        }
        func check(_ success: Bool, _ text: String) { print("\(success ? "PASS" : "FAIL"): \(text)"); if !success { failures += 1 } }
        func library(_ name: String) throws -> LeonBlogExporter.Destination { try LeonBlogExporter.destination(root: directory.appendingPathComponent(name).path) }
        func message() -> Message {
            let room = "archive-flow-" + UUID().uuidString.lowercased(); rooms.append(room)
            return Message(id: 1, clientMessageId: "client", deviceId: "device", sender: "用户", platform: "macos", text: "当前原文", createdAt: 1700000000123,
                           conversationId: room, role: "user", agentId: nil, replyTo: nil)
        }
        func store(_ message: Message) -> ChatStore {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ArchiveProtocol.self]
            let store = ChatStore(api: MessageAPI(base: URL(string: "https://archive-fixture.invalid")!, token: "fake-test-token", configuration: config))
            store.setActive(false)
            store.agents = [AgentInfo(id: "archive-test-agent", name: "Test", handle: "test", provider: "test", model: "test", enabled: true, avatarId: nil)]
            store.conversations = [Conversation(id: message.conversationId!, name: "Test", kind: "direct", agentId: "archive-test-agent", agentIds: ["archive-test-agent"])]
            store.selectConversation(message.conversationId!, refresh: false)
            return store
        }
        func prepare(_ store: ChatStore) async throws -> ChatStore.PreparedArchive {
            let root = ProcessInfo.processInfo.environment["LEON_BOOK_WORKDIR"]!
            let library = try LeonBlogExporter.destination(root: root)
            return try await store.prepareArchive(.init(scope: store.conversationScope, agentID: "archive-test-agent", library: library))
        }


        // Only referenced quote attachments must also be copied, without duplicate uploads.
        let attachments = try library("attachments"); setenv("LEON_BOOK_WORKDIR", attachments.root, 1)
        var original = message()
        let image = ChatImage(id: UUID().uuidString.lowercased(), mimeType: "image/jpeg", width: 1, height: 1, byteCount: 4)
        let quotedImage = ChatImage(id: UUID().uuidString.lowercased(), mimeType: "image/jpeg", width: 1, height: 1, byteCount: 4)
        let document = DocumentAttachment(id: UUID().uuidString.lowercased(), name: "计划 [v1] & 说明.txt", mimeType: "text/plain", byteCount: 4, characterCount: 4, truncated: false)
        let quotedDocument = DocumentAttachment(id: UUID().uuidString.lowercased(), name: "引用附件.txt", mimeType: "text/plain", byteCount: 4, characterCount: 4, truncated: false)
        original.images = [image]; original.documents = [document]
        var quote = MessageQuote(id: 42, sender: "引用者 <测试>", text: "引用原文 <script>不能执行</script>\n引用第二行", images: [image, quotedImage])
        quote.documents = [document, quotedDocument]; original.quote = quote
        let files = [image.id: Data([1, 2, 3, 4]), quotedImage.id: Data([5, 6, 7, 8]), document.id: Data("document-original".utf8), quotedDocument.id: Data("quoted-document-original".utf8)]
        ArchiveProtocol.fixture.reset(message: original, files: files)
        let attachmentStore = store(original); let attachmentStorePrepared = try await prepare(attachmentStore)
        _ = await attachmentStore.exportCurrentRound(attachmentStorePrepared, startNew: false)
        check(attachmentStore.exportError == nil, "attachment export succeeds")
        let attachmentID = ArchiveProtocol.fixture.snapshot().archives.first!
        let article = try cli("articles.get", attachments, ["slug": "leon-chat-" + attachmentID])
        let media = article["media"] as! [[String: Any]], body = article["body"] as! String
        let rawMedia = media.first { $0["name"] as? String == "原始对话.md" }!
        let raw = String(data: try contents(rawMedia, attachments), encoding: .utf8)!
        check(article["title"] as? String == "本轮讨论的关键结论与行动计划" && raw.hasPrefix("# 本轮讨论的关键结论与行动计划\n"), "LeonBook article and original attachment use the AI title returned by the server")
        check(media.count == 5, "normal and quoted images/documents copied once, plus original Markdown")
        check(raw.contains("引用原文 <script>不能执行</script>") && raw.contains("引用第二行") && body.contains("引用原文 &lt;script&gt;") && !body.contains("<script>不能执行"), "quote text survives in Markdown and escaped HTML")
        check(raw.contains("42") && raw.contains("引用附件.txt") && body.contains("引用附件.txt") && body.contains("计划 [v1] &amp; 说明.txt"), "quote identity and document links appear in both original formats")
        for doc in [document, quotedDocument] {
            if let saved = media.first(where: { $0["name"] as? String == doc.name }) {
                check(try contents(saved, attachments) == files[doc.id], "copied bytes match " + doc.name)
            } else { check(false, "copied document exists: " + doc.name) }
        }
        check(Set(ArchiveProtocol.fixture.snapshot().downloads) == Set(files.keys) && ArchiveProtocol.fixture.snapshot().downloads.count == files.count, "all attachments downloaded exactly once")

        // A missing file must block success and keep the original archive recoverable.
        let missing = try library("missing-file"); setenv("LEON_BOOK_WORKDIR", missing.root, 1)
        var missingMessage = message(); missingMessage.documents = [document]
        ArchiveProtocol.fixture.reset(message: missingMessage, failDownloads: true)
        let missingStore = store(missingMessage); let missingStorePrepared = try await prepare(missingStore)
        _ = await missingStore.exportCurrentRound(missingStorePrepared, startNew: true)
        check(missingStore.exportError != nil && ArchiveProtocol.fixture.snapshot().finishes.isEmpty, "missing document prevents successful archive and context reset")
        check(try cli("articles.list", missing)["total"] as? Int == 0, "missing document never leaves a falsely complete draft")

        // A retry after restart must finish the existing saved archive, even if originals disappear.
        let retry = try library("retry"), other = try library("other"); setenv("LEON_BOOK_WORKDIR", retry.root, 1)
        var retryMessage = message(); retryMessage.documents = [document]
        ArchiveProtocol.fixture.reset(message: retryMessage, files: files, finishFailures: 1)
        let firstStore = store(retryMessage); let firstStorePrepared = try await prepare(firstStore)
        _ = await firstStore.exportCurrentRound(firstStorePrepared, startNew: true)
        let first = ArchiveProtocol.fixture.snapshot()
        check(firstStore.exportError != nil && firstStore.exportProgress.contains("已保存") && first.finishes.count == 1, "failed finish reports saved draft without claiming a new context")
        setenv("LEON_BOOK_WORKDIR", other.root, 1); ArchiveProtocol.fixture.stopDownloads()
        let restartedStore = store(retryMessage); let restartedStorePrepared = try await prepare(restartedStore)
        check(restartedStorePrepared.destination.root == retry.root, "reopened retry previews persisted library and user")
        _ = await restartedStore.exportCurrentRound(restartedStorePrepared, startNew: true)
        let resumed = ArchiveProtocol.fixture.snapshot()
        check(restartedStore.exportError == nil, "saved archive can resume finish without original attachments")
        check(resumed.archives.count == 1 && resumed.finishes.count == 2 && Set(resumed.finishes) == Set(first.archives), "retry reuses saved archive without another summary request")
        check(resumed.downloads == first.downloads, "retry does not redownload already saved attachments")
        check(try cli("articles.list", retry)["total"] as? Int == 1 && cli("articles.list", other)["total"] as? Int == 0, "retry creates exactly one draft in the original destination")

        // Changing LeonBook defaults after the preview must not redirect the write.
        let pinned = try library("pinned"); setenv("LEON_BOOK_WORKDIR", pinned.root, 1)
        let pinnedMessage = message(); ArchiveProtocol.fixture.reset(message: pinnedMessage)
        let pinnedStore = store(pinnedMessage); let pinnedStorePrepared = try await prepare(pinnedStore)
        let switchedUser = try cli("users.create", pinned, ["name": "临时另一个用户"])["user"] as! [String: Any]
        let switchedDestination = LeonBlogExporter.Destination(root: pinned.root, user: switchedUser["id"] as! String)
        setenv("LEON_BOOK_WORKDIR", other.root, 1)
        _ = await pinnedStore.exportCurrentRound(pinnedStorePrepared, startNew: false)
        check(pinnedStore.exportError == nil && pinnedStorePrepared.destination.root == pinned.root, "export keeps the destination displayed before defaults changed")
        check(try cli("articles.list", pinned)["total"] as? Int == 1 && cli("articles.list", other)["total"] as? Int == 0, "changed defaults receive no exported content")
        check(try cli("articles.list", switchedDestination)["total"] as? Int == 0, "switching LeonBook users after preview cannot redirect the export")

        // Busy conflicts preserve the snapshot; new messages or a new topic require a fresh one.
        for mode in ["busy", "new-message", "new-topic"] {
            let conflict = try library(mode); setenv("LEON_BOOK_WORKDIR", conflict.root, 1)
            let source = message()
            let newer = Message(id: 2, clientMessageId: "newer", deviceId: "device", sender: "用户", platform: "macos", text: "归档后到达的新消息", createdAt: 1700000001123,
                                conversationId: source.conversationId, role: "user", agentId: nil, replyTo: nil)
            let changed = mode != "busy"
            ArchiveProtocol.fixture.reset(message: source, finishFailures: 1, finishFailureStatus: 409,
                                          topicStartedAfter: mode == "new-topic" ? 1 : 0, newerMessages: changed ? [newer] : [])
            let conflictStore = store(source); let conflictStorePrepared = try await prepare(conflictStore)
            _ = await conflictStore.exportCurrentRound(conflictStorePrepared, startNew: true)
            let initial = ArchiveProtocol.fixture.snapshot()
            check(conflictStore.exportError != nil && conflictStore.exportProgress.contains("尚未开始新对话"), mode + ": server conflict never claims a reset")
            let refreshed = try await prepare(conflictStore)
            _ = await conflictStore.exportCurrentRound(refreshed, startNew: true)
            let final = ArchiveProtocol.fixture.snapshot()
            check(conflictStore.exportError == nil && final.archives.count == (changed ? 2 : 1), mode + ": retry uses the appropriate snapshot")
            check(changed ? final.finishes.first != final.finishes.last : final.finishes == [initial.archives[0], initial.archives[0]], mode + ": reset targets the correct archive ID")
            check(try cli("articles.list", conflict)["total"] as? Int == (changed ? 2 : 1), mode + ": saved archive is preserved")
        }

        let guardedMessage = message(); ArchiveProtocol.fixture.reset(message: guardedMessage)
        let guardedStore = store(guardedMessage)
        let guardedStorePrepared = try await prepare(guardedStore)
        guardedStore.selectConversation("another-room", refresh: false)
        _ = await guardedStore.exportCurrentRound(guardedStorePrepared, startNew: false)
        check(guardedStore.exportError != nil && ArchiveProtocol.fixture.snapshot().archives.isEmpty, "prepared destination cannot be reused for another conversation")

        // The single-Agent slash command must still support one-step export.
        setenv("LEON_BOOK_WORKDIR", pinned.root, 1)
        let commandMessage = message(); ArchiveProtocol.fixture.reset(message: commandMessage)
        let commandStore = store(commandMessage)
        await commandStore.performCommand(.exportRound, library: pinned)
        check(commandStore.exportError == nil && commandStore.exportProgress.contains("已保存"), "single-Agent /export prepares and pins its destination automatically")
        if failures > 0 { throw ClientError.message("\(failures) archive flow checks failed") }
        print("PASS: temporary libraries only; no production models or chat services used")
    }
}
