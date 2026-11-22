import Foundation

struct Message: Codable, Identifiable, Equatable {
    let id: Int64
    let clientMessageId: String
    let deviceId: String
    let sender: String
    let platform: String
    let text: String
    let createdAt: Int64
    let conversationId: String?
    let role: String?
    let agentId: String?
    let replyTo: Int64?
    var images: [ChatImage]? = nil
    var quote: MessageQuote? = nil
    var documents:[DocumentAttachment]? = nil
    var date: Date { Date(timeIntervalSince1970: Double(createdAt) / 1000) }
}

struct ChatImage: Codable, Identifiable, Equatable {
    let id: String
    let mimeType: String
    let width: Int
    let height: Int
    let byteCount: Int
}

struct MessagePage: Codable {
    let messages: [Message]
    let hasMore: Bool
    let jobs: [AgentJob]?
    var contextOperations: [ContextOperation]? = nil
    var historyRevision: Int64? = nil
}

struct AgentInfo: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let handle: String
    let provider: String
    let model: String
    let enabled: Bool
    let avatarId: String?
    var description: String? = nil
}
struct ModelUsage: Codable, Identifiable, Equatable {
    var id: String { provider + ":" + model }
    let provider: String
    let model: String
    let inputTokens: Int64
    let outputTokens: Int64
    let totalTokens: Int64
    let reportedCalls: Int64
    let unreportedCalls: Int64
    let firstRecordedAt: String?
    let lastRecordedAt: String?
}
struct Conversation: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let kind: String
    let agentId: String?
    let agentIds: [String]
}
struct AgentJob: Codable, Identifiable, Equatable {
    var id: String { "\(messageId):\(agentId)" }
    let messageId: Int64
    let agentId: String
    let agentName: String
    let status: String
    let error: String
    let phase: String?
    var progressText: String {
        if status == "FAILED" { return error }
        if phase == "COMPRESSING" { return "上下文压缩中…" }
        return status == "RUNNING" ? "正在回复…" : "等待回复…"
    }
}

struct ContextOperation: Codable, Identifiable, Equatable {
    let id: String
    let agentId: String
    let agentName: String
    let status: String
    let error: String
    let result: String
    let createdAt: Int64
    var kind: String? = nil
    var active: Bool { status == "PENDING" || status == "RUNNING" }
    var progressText: String {
        if status == "FAILED" { return error }
        if status == "SUCCEEDED" { return result }
        if kind == "ARCHIVE" { return status == "RUNNING" ? "正在生成本轮对话总结…" : "等待生成本轮对话总结…" }
        return status == "RUNNING" ? "上下文压缩中…" : "等待压缩上下文…"
    }
}

enum TimelineItem: Identifiable {
    case message(Message), operation(ContextOperation), job(AgentJob)
    var id: String {
        switch self {
        case .message(let message): return "message:\(message.id)"
        case .operation(let operation): return "operation:\(operation.id)"
        case .job(let job): return "job:\(job.id)"
        }
    }
    static func ordered(messages: [Message], operations: [ContextOperation], jobs: [AgentJob]) -> [TimelineItem] {
        let operations = operations.enumerated().sorted {
            let left = $0.element.createdAt > 0 ? $0.element.createdAt : Int64.max
            let right = $1.element.createdAt > 0 ? $1.element.createdAt : Int64.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
        let jobs = jobs.enumerated().sorted {
            $0.element.messageId == $1.element.messageId ? $0.offset < $1.offset : $0.element.messageId < $1.element.messageId
        }.map(\.element)
        var result: [TimelineItem] = []; var operationIndex = 0; var jobIndex = 0
        for message in messages {
            while jobIndex < jobs.count && jobs[jobIndex].messageId < message.id { result.append(.job(jobs[jobIndex])); jobIndex += 1 }
            while operationIndex < operations.count && operations[operationIndex].createdAt > 0 && operations[operationIndex].createdAt <= message.createdAt {
                result.append(.operation(operations[operationIndex])); operationIndex += 1
            }
            result.append(.message(message))
            while jobIndex < jobs.count && jobs[jobIndex].messageId == message.id { result.append(.job(jobs[jobIndex])); jobIndex += 1 }
        }
        while operationIndex < operations.count { result.append(.operation(operations[operationIndex])); operationIndex += 1 }
        while jobIndex < jobs.count { result.append(.job(jobs[jobIndex])); jobIndex += 1 }
        return result
    }
}

struct ClearHistoryPreview: Codable {
    let conversationId: String
    let conversationName: String
    let messageCount: Int64
    let latestMessageId: Int64
    let historyRevision: Int64
    let hasActiveWork: Bool
}
struct ClearHistoryResult: Codable { let clearedMessages: Int64; let historyRevision: Int64 }
struct DeleteConversationResult: Codable { let conversationId: String; let deletedMessages: Int64 }

struct ChatArchive: Codable {
    let id: String
    let title: String
    let summary: String
    let conversationId: String
    let throughId: Int64
    let operation: ContextOperation
    let messages: [Message]
}

struct ConversationContext: Codable {
    let conversationId: String
    let recentRounds: Int
    let inputTokenBudget: Int
    let topicStartedAfter: Int64
    let agents: [AgentContextInfo]
    var compressionMode: String? = nil
}
struct ContextFact: Codable, Identifiable {
    var id: String { subjectId + ":" + kind + ":" + key }
    let subjectId: String; let speaker: String; let kind: String; let key: String
    let value: String; let sourceMessageId: Int64
}
struct AgentContextInfo: Codable, Identifiable {
    var id: String { agentId }
    let agentId: String
    let agentName: String
    let summary: String
    let lastCompressedAt: Int64
    let estimatedInputTokens: Int
    let retainedRounds: Int
    let phase: String
    var facts: [ContextFact]? = nil
    var retrievedRounds: Int? = nil
    var compressionFallback: Bool? = nil
}

struct Outgoing: Codable, Identifiable {
    var id: String { clientMessageId }
    let clientMessageId: String
    let deviceId: String
    let sender: String
    let platform: String
    let text: String
    var conversationId: String? = nil
    var mentionAgentIds: [String]? = nil
    var imageIds: [String]? = nil
    var quoteMessageId: Int64? = nil
    var documentIds:[String]? = nil
    var quote: MessageQuote? = nil
    var documents:[DocumentAttachment]? = nil
}

enum Endpoint {
    static func normalize(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true,
              url.path.isEmpty || url.path == "/",
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw ClientError.message("请输入 HTTPS 服务地址；本机开发可使用 http://127.0.0.1:8080。")
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = ""
        guard let normalized = components?.url else {
            throw ClientError.message("服务地址无效。")
        }
        return normalized
    }
}

enum ClientError: LocalizedError {
    case message(String)
    case archiveConflict(String)
    var errorDescription: String? {
        switch self { case .message(let value), .archiveConflict(let value): return value }
    }
}

enum HTTPFailure {
    static func message(for status: Int) -> String? {
        switch status {
        case 401: return "访问令牌未通过认证，请检查令牌后重试。"
        case 403: return "服务器拒绝访问（HTTP 403）。请检查服务端接口权限或 HTTPS 代理配置。"
        case 404: return "服务端尚未安装消息接口，请先升级服务端。"
        case 502, 503, 504: return "服务暂时不可用（HTTP \(status)），请检查服务端运行状态。"
        default: return nil
        }
    }
}

// Credentials are never forwarded through a redirect, including redirects on the same host.
final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class MessageAPI: NotificationAPI, @unchecked Sendable {
    let base: URL
    private let token: String
    private let session: URLSession
    private let avatarCache = NSCache<NSString, NSData>()
    private let imageCache = NSCache<NSString, NSData>()
    init(base: URL, token: String, configuration: URLSessionConfiguration? = nil) {
        self.base = base
        self.token = token
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        avatarCache.totalCostLimit = 8 * 1024 * 1024
        imageCache.totalCostLimit = 24 * 1024 * 1024
    }
    deinit { session.invalidateAndCancel() }

    func page(conversation: String = "shared", after: Int64? = nil, before: Int64? = nil) async throws -> MessagePage {
        var components = URLComponents(url: base.appendingPathComponent("api/device-messages"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "conversationId", value: conversation)]
        if let after { components.queryItems?.append(URLQueryItem(name: "after", value: String(after))) }
        if let before { components.queryItems?.append(URLQueryItem(name: "before", value: String(before))) }
        return try await request(URLRequest(url: components.url!))
    }

    func search(query: String, room: String?, before: Int64?) async throws -> ChatSearchPage {
        var items = [URLQueryItem(name: "q", value: query)]
        if let room { items.append(URLQueryItem(name: "conversationId", value: room)) }
        if let before { items.append(URLQueryItem(name: "before", value: String(before))) }
        return try await searchRequest("search", items: items)
    }
    func searchContext(room: String, message: Int64, direction: String) async throws -> ChatSearchContext {
        try await searchRequest("context", items: [URLQueryItem(name: "conversationId", value: room), URLQueryItem(name: "messageId", value: String(message)), URLQueryItem(name: "direction", value: direction)])
    }
    private func searchRequest<T: Decodable>(_ path: String, items: [URLQueryItem]) async throws -> T {
        var url = URLComponents(url: base.appendingPathComponent("api/device-messages/" + path), resolvingAgainstBaseURL: false)!
        url.queryItems = items
        return try await request(URLRequest(url: url.url!))
    }

    func agents() async throws -> [AgentInfo] { try await request(URLRequest(url: base.appendingPathComponent("api/agents"))) }
    func usage() async throws -> [ModelUsage] { try await request(URLRequest(url: base.appendingPathComponent("api/agents/usage"))) }
    func heartbeat(deviceId: String, name: String) async throws {
        struct Presence: Decodable { let lastSeenAt: Int64 }
        let _: Presence = try await post("api/device-messages/presence", body: ["deviceId": deviceId, "name": name, "platform": "macos"])
    }
    func avatarData(_ id: String) async throws -> Data {
        guard id.range(of: "^[a-z0-9-]{1,80}$", options: .regularExpression) != nil else { throw ClientError.message("头像标识无效") }
        if let cached = avatarCache.object(forKey: id as NSString) { return cached as Data }
        var req = URLRequest(url: base.appendingPathComponent("api/agent-avatars/\(id)"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType == "image/png", data.count <= 2 * 1024 * 1024 else { throw ClientError.message("头像暂时不可用") }
        avatarCache.setObject(data as NSData, forKey: id as NSString, cost: data.count)
        return data
    }
    func notificationStatus() async throws -> NotificationStatus {try await request(URLRequest(url:base.appendingPathComponent("api/device-messages/notifications/status")))}
    func notifications(device:String,after:Int64?,preview:Bool) async throws -> NotificationPage {
        var url=URLComponents(url:base.appendingPathComponent("api/device-messages/notifications"),resolvingAgainstBaseURL:false)!
        url.queryItems=[URLQueryItem(name:"deviceId",value:device),URLQueryItem(name:"preview",value:String(preview))]
        if let after {url.queryItems!.append(URLQueryItem(name:"after",value:String(after)))}
        return try await request(URLRequest(url:url.url!))
    }
    func registerNotifications(_ registration:PushRegistration) async throws {
        var req=URLRequest(url:base.appendingPathComponent("api/device-messages/notifications/devices"));req.httpMethod="POST";req.httpBody=try JSONEncoder().encode(registration);req.setValue("application/json",forHTTPHeaderField:"Content-Type")
        let _:[String:Bool]=try await request(req)
    }
    func removeNotifications(device:String) async throws {
        guard UUID(uuidString:device) != nil else {throw ClientError.message("设备标识无效。")}
        var req=URLRequest(url:base.appendingPathComponent("api/device-messages/notifications/devices/\(device)/remove"));req.httpMethod="POST";req.httpBody=Data("{}".utf8);req.setValue("application/json",forHTTPHeaderField:"Content-Type")
        let _:[String:Bool]=try await request(req)
    }
    func uploadDocument(_ document:DocumentAttachment,room:String,data:Data) async throws {
        guard UUID(uuidString:document.id) != nil,data.count<=10*1024*1024 else {throw ClientError.message("文档无效或超过 10 MB。")}
        var url=URLComponents(url:base.appendingPathComponent("api/device-messages/documents"),resolvingAgainstBaseURL:false)!
        url.queryItems=[URLQueryItem(name:"id",value:document.id),URLQueryItem(name:"conversationId",value:room),URLQueryItem(name:"name",value:document.name)]
        var req=URLRequest(url:url.url!);req.httpMethod="POST";req.httpBody=data;req.timeoutInterval=90;req.setValue("application/octet-stream",forHTTPHeaderField:"Content-Type")
        let _:DocumentAttachment=try await request(req)
    }
    func document(_ id:String,favorite:Int64?) async throws -> Data {
        guard UUID(uuidString:id) != nil else {throw ClientError.message("附件标识无效。")}
        let path=favorite.map {"api/device-messages/favorites/\($0)/documents/"} ?? "api/device-messages/documents/"
        var req=URLRequest(url:base.appendingPathComponent(path+id));req.timeoutInterval=60;req.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization")
        let (stream,response)=try await session.bytes(for:req)
        guard let http=response as? HTTPURLResponse,(200...299).contains(http.statusCode) else {stream.task.cancel();throw ClientError.message("附件不存在、已清空或无权访问。")}
        guard response.expectedContentLength<=10*1024*1024 else {stream.task.cancel();throw ClientError.message("附件过大。")}
        var bytes=Data();for try await byte in stream {guard bytes.count<10*1024*1024 else {stream.task.cancel();throw ClientError.message("附件过大。")};bytes.append(byte)};return bytes
    }
    func uploadImage(id: String, conversation: String, data: Data) async throws -> ChatImage {
        guard UUID(uuidString: id) != nil, data.count <= 5 * 1024 * 1024 else { throw ClientError.message("图片无效或过大") }
        var url = URLComponents(url: base.appendingPathComponent("api/device-messages/images"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "conversationId", value: conversation)]
        var req = URLRequest(url: url.url!); req.httpMethod = "POST"; req.httpBody = data
        req.timeoutInterval = 60; req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        return try await request(req)
    }
    func imageData(_ id: String) async throws -> Data {
        guard UUID(uuidString: id) != nil else { throw ClientError.message("图片标识无效") }
        if let cached = imageCache.object(forKey: id as NSString) { return cached as Data }
        var req = URLRequest(url: base.appendingPathComponent("api/device-messages/images/\(id)"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType == "image/jpeg", data.count <= 1024 * 1024 else { throw ClientError.message("图片加载失败，点击重试") }
        imageCache.setObject(data as NSData, forKey: id as NSString, cost: data.count)
        return data
    }
    func conversations() async throws -> [Conversation] { try await request(URLRequest(url: base.appendingPathComponent("api/conversations"))) }
    func direct(_ agentId: String) async throws -> Conversation { try await post("api/conversations/direct/\(agentId)", body: [String:String]()) }
    func newThread(agentId: String, name: String, requestId: String) async throws -> Conversation {
        try await post("api/conversations/direct/\(agentId)/threads", body: ["name": name, "requestId": requestId])
    }
    func branch(room:String,message:Int64,name:String,requestId:String) async throws -> Conversation {
        struct Branch:Encodable {let messageId:Int64;let name:String;let requestId:String}
        guard message>0, !room.isEmpty,room.utf8.count<=80,room.utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)||[45,58].contains($0)}) else {throw ClientError.message("分支消息标识无效")}
        var req=URLRequest(url:base.appendingPathComponent("api/conversations/\(room)/branches"));req.httpMethod="POST";req.timeoutInterval=90
        req.setValue("application/json",forHTTPHeaderField:"Content-Type");req.httpBody=try JSONEncoder().encode(Branch(messageId:message,name:name,requestId:requestId))
        return try await request(req)
    }
    func group(name: String, agentIds: [String]) async throws -> Conversation {
        struct Group: Encodable { let name: String; let agentIds: [String] }
        return try await post("api/conversations/groups", body: Group(name: name, agentIds: agentIds))
    }
    func clearHistoryPreview(conversation: String) async throws -> ClearHistoryPreview {
        var url = URLComponents(url: base.appendingPathComponent("api/conversations/context/clear-preview"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "conversationId", value: conversation)]
        return try await request(URLRequest(url: url.url!))
    }
    func clearHistory(_ preview: ClearHistoryPreview, requestId: String) async throws -> ClearHistoryResult {
        struct Clear: Encodable {
            let conversationId: String; let requestId: String; let expectedLatestMessageId: Int64; let expectedHistoryRevision: Int64; let confirm: Bool
        }
        return try await post("api/conversations/context/clear", body: Clear(conversationId: preview.conversationId, requestId: requestId,
            expectedLatestMessageId: preview.latestMessageId, expectedHistoryRevision: preview.historyRevision, confirm: true))
    }
    func clearImageCache() { imageCache.removeAllObjects() }
    func deleteConversationPreview(_ conversation: String) async throws -> ClearHistoryPreview {
        var url = URLComponents(url: base.appendingPathComponent("api/conversations/context/delete-preview"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "conversationId", value: conversation)]
        return try await request(URLRequest(url: url.url!))
    }
    func deleteConversation(_ preview: ClearHistoryPreview, requestId: String) async throws -> DeleteConversationResult {
        struct Delete: Encodable {
            let conversationId: String; let requestId: String
            let expectedLatestMessageId: Int64; let expectedHistoryRevision: Int64; let confirm: Bool
        }
        return try await post("api/conversations/context/delete", body: Delete(conversationId: preview.conversationId, requestId: requestId,
            expectedLatestMessageId: preview.latestMessageId, expectedHistoryRevision: preview.historyRevision, confirm: true))
    }
    func context(conversation: String) async throws -> ConversationContext {
        var url = URLComponents(url: base.appendingPathComponent("api/conversations/context"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "conversationId", value: conversation)]
        return try await request(URLRequest(url: url.url!))
    }
    func archiveRound(conversation: String, agentId: String, requestId: String) async throws -> ContextOperation {
        struct Archive: Encodable { let conversationId: String; let agentId: String; let requestId: String }
        return try await post("api/conversations/context/archive", body: Archive(conversationId: conversation, agentId: agentId, requestId: requestId))
    }
    func archive(_ id: String) async throws -> ChatArchive { try await request(URLRequest(url: base.appendingPathComponent("api/conversations/context/archive/" + id))) }
    func finishArchive(_ id: String) async throws -> ConversationContext {
        try await post("api/conversations/context/archive/" + id + "/finish", body: [String: String]())
    }
    func compactContext(conversation: String, agentId: String, requestId: String) async throws -> ContextOperation {
        struct Compact: Encodable { let conversationId: String; let agentId: String; let requestId: String }
        return try await post("api/conversations/context/compact", body: Compact(conversationId: conversation, agentId: agentId, requestId: requestId))
    }
    func configureContext(conversation: String, rounds: Int, reset: Bool) async throws -> ConversationContext {
        struct Settings: Encodable { let conversationId: String; let recentRounds: Int }
        return try await post("api/conversations/context/" + (reset ? "reset" : "settings"), body: Settings(conversationId: conversation, recentRounds: rounds))
    }
    func retryJob(_ job: AgentJob) async throws {
        struct Result: Decodable { let queued: Bool }
        let _: Result = try await post("api/device-messages/\(job.messageId)/agents/\(job.agentId)/retry", body: [String:String]())
    }
    private func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        var req = URLRequest(url: base.appendingPathComponent(path)); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = try JSONEncoder().encode(body)
        return try await request(req)
    }

    func addFavorite(_ message:Int64) async throws -> FavoriteItem {try await post("api/device-messages/\(message)/favorite",body:[String:String]())}
    func favorites(query:String,before:Int64?) async throws -> FavoritePage {
        var items=[URLQueryItem(name:"q",value:query)]
        if let before {items.append(URLQueryItem(name:"before",value:String(before)))}
        var url=URLComponents(url:base.appendingPathComponent("api/device-messages/favorites"),resolvingAgainstBaseURL:false)!;url.queryItems=items
        return try await request(URLRequest(url:url.url!))
    }
    func removeFavorite(_ id:Int64) async throws {struct Result:Decodable{let removed:Bool};let _:Result=try await post("api/device-messages/favorites/\(id)/remove",body:[String:String]())}
    func favoriteImage(_ favorite:Int64,image:String) async throws -> Data {
        guard UUID(uuidString:image) != nil else {throw ClientError.message("图片标识无效")}
        var req=URLRequest(url:base.appendingPathComponent("api/device-messages/favorites/\(favorite)/images/\(image)"));req.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization")
        let (bytes,response)=try await session.data(for:req)
        guard let http=response as? HTTPURLResponse,http.statusCode==200,bytes.count<=1_048_576 else {throw ClientError.message("收藏图片已不可用，请刷新后重试。")}
        return bytes
    }
    func send(_ outgoing: Outgoing) async throws -> Message {
        if outgoing.quoteMessageId != nil {
            let features:[String:Bool] = try await request(URLRequest(url:base.appendingPathComponent("api/device-messages/features")))
            guard features["quotes"] == true else {throw ClientError.message("服务端尚未支持引用回复，请先升级服务端。")}
        }
        var payload=outgoing;payload.quote=nil;payload.documents=nil
        var req = URLRequest(url: base.appendingPathComponent("api/device-messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(payload)
        return try await request(req)
    }

    private struct Failure: Decodable { let detail: String?; let message: String? }
    private func request<T: Decodable>(_ input: URLRequest) async throws -> T {
        var req = input
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ClientError.message("服务端没有返回有效响应。") }
        switch http.statusCode {
        case 200...299: return try JSONDecoder().decode(T.self, from: data)
        default:
            if http.statusCode == 409, let path = req.url?.path,
               path.hasPrefix("/api/conversations/context/archive/"), path.hasSuffix("/finish") {
                let failure = try? JSONDecoder().decode(Failure.self, from: data)
                throw ClientError.archiveConflict(failure?.detail ?? failure?.message ?? "归档尚未重置上下文，请刷新会话后重试。")
            }
            if req.url?.path.contains("/context/delete") == true {
                let failure = try? JSONDecoder().decode(Failure.self, from: data)
                throw ClientError.message(failure?.message ?? failure?.detail ?? (http.statusCode == 404
                    ? "服务端尚未支持永久删除会话，请先升级服务端。" : "删除失败（HTTP \(http.statusCode)），请重试。"))
            }
            if http.statusCode == 404, req.url?.path == "/api/device-messages/search" {
                throw ClientError.message("服务端尚未支持聊天记录搜索，请先升级服务端。")
            }
            if http.statusCode == 404, req.url?.path == "/api/agents/usage" {
                throw ClientError.message("服务端尚未支持 Token 用量，请先升级服务端。")
            }
            if http.statusCode == 404, req.url?.path.contains("/context/clear") == true {
                throw ClientError.message("服务端尚未支持 /clear，请先部署本次服务端更新。")
            }
            if http.statusCode==404,req.url?.path=="/api/device-messages/context" {
                let failure=try? JSONDecoder().decode(Failure.self,from:data)
                throw ClientError.message(failure?.detail ?? failure?.message ?? "原消息已删除或不可访问。")
            }
            if http.statusCode==404,req.url?.path.hasSuffix("/branches")==true {
                let failure=try? JSONDecoder().decode(Failure.self,from:data)
                throw ClientError.message(failure?.message ?? failure?.detail ?? "服务端尚未支持对话分支，请先升级服务端。")
            }
            if let message = HTTPFailure.message(for: http.statusCode) { throw ClientError.message(message) }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            throw ClientError.message(failure?.detail ?? failure?.message ?? "请求失败（HTTP \(http.statusCode)），请稍后重试。")
        }
    }
}


struct ChatSearchHit: Codable, Identifiable {
    let message: Message
    let conversationName: String
    var id: Int64 { message.id }
}
struct ChatSearchPage: Codable {
    let results: [ChatSearchHit]
    let hasMore: Bool
    let nextBefore: Int64?
}
struct ChatSearchContext: Codable {
    let messages: [Message]
    let hasOlder: Bool
    let hasNewer: Bool
    let historyRevision: Int64
}


struct MessageQuote: Codable, Identifiable, Equatable {
    let id: Int64
    let sender: String
    let text: String
    let images: [ChatImage]
    var documents:[DocumentAttachment]? = nil
    var preview: String { (images.isEmpty ? "" : "[图片] ") + ((documents ?? []).map {"[文件] "+$0.name}.joined(separator:" ")) + text.replacingOccurrences(of:"\n",with:" ") }
    init(message: Message) { id=message.id;sender=message.sender;text=message.text;images=message.images ?? [];documents=message.documents }
    init(id:Int64,sender:String,text:String,images:[ChatImage]) {self.id=id;self.sender=sender;self.text=text;self.images=images}
}
struct FavoriteItem: Codable, Identifiable, Equatable {
    let id: Int64
    let message: Message
    let conversationName: String
    let savedAt: Int64
}
struct FavoritePage: Codable {
    let results: [FavoriteItem]
    let hasMore: Bool
    let nextBefore: Int64?
}
