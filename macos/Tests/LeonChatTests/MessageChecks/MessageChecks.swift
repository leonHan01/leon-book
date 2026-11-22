import Foundation
@testable import LeonChat

private final class UsageProtocol: URLProtocol, @unchecked Sendable {
    static var status = 200
    static var response = "[]"
    static var authorized = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.authorized = request.url?.path == "/api/agents/usage" && request.value(forHTTPHeaderField: "Authorization") == "Bearer usage-test-token"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.response.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// Standalone checks compile the real network/model source and also run with Command Line
// Tools alone, without requiring the XCTest framework from a full Xcode installation.
@main
struct MessageChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ClientError.message(message) }
    }
    static func main() async throws {
        try commandChecks()
        try endpointChecks()
        try decodingChecks()
        try timelineChecks()
        try await usageChecks()
        try mentionChecks()
        try check(HTTPFailure.message(for: 401)?.contains("令牌") == true, "401 must explain authentication failure")
        try check(HTTPFailure.message(for: 403)?.contains("令牌") == false, "Proxy 403 must not blame the token")
        try check(HTTPFailure.message(for: 403)?.contains("代理") == true, "403 must explain server permissions/proxy")
        try check(HTTPFailure.message(for: 502)?.contains("运行状态") == true, "502 must explain service failure")
        print("PASS: authentication, proxy denial and upstream failures stay distinct")
        print("PASS: endpoint validation and Unicode/Unix-millisecond protocol decoding")
        print("PASS: @ mention caret replacement, Unicode names, email boundaries and selections")
        if let address = ProcessInfo.processInfo.environment["LEONAPP_TEST_SERVER"],
           let token = ProcessInfo.processInfo.environment["LEONAPP_TEST_TOKEN"] {
            try await networkChecks(address, token)
            print("PASS: real HTTP send, idempotent retry, incremental receive and second-device reply")
            if let agentId = ProcessInfo.processInfo.environment["LEONAPP_TEST_AGENT"] {
                try await agentChecks(address, token, agentId)
                print("PASS: Agent directory, private conversation isolation, group creation and mention job protocol")
            }
        } else { print("SKIP: isolated HTTP checks (set LEONAPP_TEST_SERVER and LEONAPP_TEST_TOKEN)") }
    }
    static func timelineChecks() throws {
        let data = Data(#"{"messages":[{"id":1,"clientMessageId":"a","deviceId":"d","sender":"me","platform":"macos","text":"first","createdAt":1000},{"id":2,"clientMessageId":"b","deviceId":"d","sender":"me","platform":"macos","text":"later","createdAt":3000}],"hasMore":false}"#.utf8)
        let messages = try JSONDecoder().decode(MessagePage.self, from: data).messages
        let job = AgentJob(messageId: 1, agentId: "sol", agentName: "Sol", status: "FAILED", error: "failed", phase: nil)
        let operation = ContextOperation(id: "compact", agentId: "sol", agentName: "Sol", status: "FAILED", error: "failed", result: "", createdAt: 2000)
        let items = TimelineItem.ordered(messages: messages, operations: [operation], jobs: [job])
        try check(items.map(\.id) == ["message:1", "job:1:sol", "operation:compact", "message:2"], "Failures and context notices must remain in the conversation timeline")
        try check(TimelineItem.ordered(messages: messages, operations: [], jobs: [job]).map(\.id) == ["message:1", "job:1:sol", "message:2"], "A failed reply must remain after its triggering message")
    }
    static func commandChecks() throws {
        try check(ChatCommand.query(in: "/", selection: NSRange(location: 1, length: 0)) == "", "Slash did not open commands")
        try check(ChatCommand.matching("").count == 5, "Commands missing")
        try check(ChatCommand.matching("clear") == [.clear] && ChatCommand.exact("/clear") == .clear, "Clear command missing")
        try check(ChatCommand.matching("comp") == [.compact], "Command prefix matching failed")
        try check(ChatCommand.exact(" /new ") == .newRound && ChatCommand.exact("/export") == .exportRound, "Round commands missing")
        try check(ChatCommand.exact("/compress") == .compact, "Compression alias failed")
        for text in ["https://example.com/", "请看 /", "/usr/local/bin", "/compact with args"] {
            try check(ChatCommand.query(in: text, selection: NSRange(location: (text as NSString).length, length: 0)) == nil, "Unrelated text opened commands")
        }
        try check(ChatCommand.isAttempt("/compact with args"), "Malformed commands must not be sent as chat")
        try check(ChatCommand.query(in: "/compact", selection: NSRange(location: 0, length: 8)) == nil, "Selected text triggered commands")
        print("PASS: slash menu, command prefixes/aliases, new/export commands and ordinary paths")
    }
    static func usageChecks() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UsageProtocol.self]
        let api = MessageAPI(base: URL(string: "https://usage.test")!, token: "usage-test-token", configuration: config)
        UsageProtocol.response = #"[{"provider":"openai","model":"test-model","inputTokens":3000000000,"outputTokens":20,"totalTokens":3000000020,"reportedCalls":2,"unreportedCalls":1,"firstRecordedAt":"2026-11-19T00:00:00Z","lastRecordedAt":"2026-11-19T01:00:00Z"}]"#
        let rows = try await api.usage()
        try check(UsageProtocol.authorized, "Usage request must use the authenticated read-only endpoint")
        try check(UsagePricing.estimate(rows[0]) == nil, "Unknown models must not be priced")
        let priced = ModelUsage(provider: "deepseek", model: "deepseek-flash", inputTokens: 1_000_000, outputTokens: 1_000_000, totalTokens: 2_000_000, reportedCalls: 1, unreportedCalls: 0, firstRecordedAt: nil, lastRecordedAt: nil)
        let estimate = UsagePricing.estimate(priced)!
        try check(abs(estimate.low - 0.603) < 0.000001 && abs(estimate.high - 1.5) < 0.000001, "Cache and peak pricing ranges must be applied")
        try check(rows[0].totalTokens == 3_000_000_020 && rows[0].unreportedCalls == 1, "Usage counts must retain 64-bit totals and missing reports")
        UsageProtocol.response = "[]"
        let empty = try await api.usage()
        try check(empty.isEmpty, "Empty usage must be distinct from request failure")
        for (status, hint) in [(404, "Token 用量"), (401, "令牌"), (403, "权限")] {
            UsageProtocol.status = status
            var message = ""
            do { _ = try await api.usage() } catch { message = error.localizedDescription }
            try check(message.contains(hint), "Missing usage endpoint and authorization errors must stay distinct")
        }
        print("PASS: authenticated usage request, 64-bit counts, empty data and upgrade/auth errors")
    }
    static func endpointChecks() throws {
        let remote = try Endpoint.normalize(" https://121.40.254.112/ ")
        try check(remote.absoluteString == "https://121.40.254.112", "HTTPS normalization failed")
        let loopback = try Endpoint.normalize("http://127.0.0.1:8080")
        try check(loopback.absoluteString == "http://127.0.0.1:8080", "Loopback normalization failed")
        for value in ["http://example.com", "https://token@example.com", "https://example.com?token=x", "https://example.com/api", "https://example.com#x", "ftp://example.com", "https://example.com:99999"] {
            var rejected = false
            do { _ = try Endpoint.normalize(value) } catch { rejected = true }
            try check(rejected, "Accepted unsafe endpoint: \(value)")
        }
    }
    static func decodingChecks() throws {
        let oldAgent = Data(#"{"id":"writer","name":"写作助手","handle":"writer","provider":"openai","model":"test-model","enabled":true}"#.utf8)
        let legacy = try JSONDecoder().decode(AgentInfo.self, from: oldAgent)
        try check(legacy.description == nil, "Old Agent responses must remain compatible")
        let newAgent = Data(#"{"id":"writer","name":"写作助手","handle":"writer","provider":"openai","model":"test-model","enabled":true,"description":"梳理思路与润色文字"}"#.utf8)
        let profile = try JSONDecoder().decode(AgentInfo.self, from: newAgent)
        try check(profile.description == "梳理思路与润色文字" && profile.model == "test-model", "Agent profile metadata was lost")
        let data = Data(#"{"messages":[{"id":1,"clientMessageId":"client","deviceId":"device","sender":"手机","platform":"android","text":"你好 🚀\n第二行","createdAt":1700000000123}],"hasMore":false}"#.utf8)
        let page = try JSONDecoder().decode(MessagePage.self, from: data)
        try check(page.messages[0].text == "你好 🚀\n第二行", "Unicode/newline decoding failed")
        try check(abs(page.messages[0].date.timeIntervalSince1970 - 1700000000.123) < 0.001, "Millisecond date decoding failed")
        let jobData = Data(#"{"messageId":1,"agentId":"agent","agentName":"Sol","status":"RUNNING","error":"","phase":"COMPRESSING"}"#.utf8)
        let job = try JSONDecoder().decode(AgentJob.self, from: jobData)
        try check(job.progressText == "上下文压缩中…", "Compression must be shown separately from replying")
        let oldData = Data(#"{"messageId":1,"agentId":"agent","agentName":"Sol","status":"RUNNING","error":""}"#.utf8)
        let oldJob = try JSONDecoder().decode(AgentJob.self, from: oldData)
        try check(oldJob.progressText == "正在回复…", "Old servers must remain compatible")
        let contextData = Data(#"{"conversationId":"direct:agent","recentRounds":10,"inputTokenBudget":12000,"topicStartedAfter":0,"agents":[{"agentId":"agent","agentName":"Sol","summary":"记住偏好","lastCompressedAt":1700000000123,"estimatedInputTokens":1234,"retainedRounds":10,"phase":""}]}"#.utf8)
        let context = try JSONDecoder().decode(ConversationContext.self, from: contextData)
        try check(context.recentRounds == 10 && context.agents[0].summary == "记住偏好", "Server context metadata decoding failed")

    }
    static func mentionChecks() throws {
        let bare = MentionCompletion.token(in: "你好 @", selection: NSRange(location: 4, length: 0))
        try check(bare?.query == "", "Bare @ did not open candidates")
        try check(MentionCompletion.matches(name: "写作助手", handle: "writer", query: "写作"), "Chinese name did not match")
        try check(MentionCompletion.matches(name: "写作助手", handle: "writer", query: "WRI"), "Handle filtering is not case insensitive")
        guard let adjacent = MentionCompletion.token(in: "你好@写", selection: NSRange(location: 4, length: 0)) else { throw ClientError.message("@ after Chinese text did not match") }
        try check(MentionCompletion.replacing(adjacent, in: "你好@写", with: "writer").text == "你好 @writer ", "Mention after Chinese text missed the routing delimiter")
        for text in ["me@example.com", "@writer ", "@a."] {
            try check(MentionCompletion.token(in: text, selection: NSRange(location: (text as NSString).length, length: 0)) == nil, "Unexpected mention candidate for \(text)")
        }
        try check(MentionCompletion.token(in: "@w", selection: NSRange(location: 0, length: 2)) == nil, "Selected text must not trigger candidates")
        guard let token = MentionCompletion.token(in: "😀 @wriXYZ 保留", selection: NSRange(location: 7, length: 0)) else { throw ClientError.message("Caret token missing") }
        try check(token.query == "wri", "Wrong caret query")
        let result = MentionCompletion.replacing(token, in: "😀 @wriXYZ 保留", with: "writer")
        try check(result.text == "😀 @writer 保留" && result.caret == 11, "Replacement lost text or moved caret incorrectly")
        try check(MentionCompletion.token(in: result.text, selection: NSRange(location: result.caret, length: 0)) == nil, "Selected mention reopened candidates")
    }
    static func networkChecks(_ address: String, _ token: String) async throws {
        let api = MessageAPI(base: try Endpoint.normalize(address), token: token)
        let before = try await api.page()
        let cursor = before.messages.last?.id ?? 0
        let outgoing = Outgoing(clientMessageId: UUID().uuidString.lowercased(), deviceId: UUID().uuidString.lowercased(), sender: "Mac 集成测试", platform: "macos", text: "来自 Mac 的真实请求 🚀\n第二行")
        try await api.heartbeat(deviceId: outgoing.deviceId, name: outgoing.sender)
        let sent = try await api.send(outgoing)
        try check(sent.text == outgoing.text, "HTTP send changed text")
        let retried = try await api.send(outgoing)
        try check(sent.id == retried.id, "Retry duplicated the message")
        let received = try await api.page(after: cursor)
        try check(received.messages.filter { $0.id == sent.id }.count == 1, "Incremental receive lost/duplicated the message")
        let android = Outgoing(clientMessageId: UUID().uuidString.lowercased(), deviceId: UUID().uuidString.lowercased(), sender: "Android 集成测试", platform: "android", text: "收到 Mac，来自 Android 的回复")
        _ = try await api.send(android)
        let response = try await api.page(after: sent.id)
        try check(response.messages.last?.text == android.text, "Second-device reply not received")
    }
    static func agentChecks(_ address: String, _ token: String, _ agentId: String) async throws {
        let api = MessageAPI(base: try Endpoint.normalize(address), token: token)
        let agents = try await api.agents()
        try check(agents.contains { $0.id == agentId }, "Configured Agent not listed")
        let avatarId = agents.first { $0.id == agentId }?.avatarId ?? "alfred"
        let avatar = try await api.avatarData(avatarId)
        try check(avatar.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), "Authenticated avatar did not return PNG data")
        let cachedAvatar = try await api.avatarData(avatarId)
        try check(avatar == cachedAvatar, "Cached avatar data changed")
        let direct = try await api.direct(agentId)
        let group = try await api.group(name: "Mac 协议测试群", agentIds: [agentId])
        let rooms = try await api.conversations()
        try check(rooms.contains { $0.id == direct.id } && rooms.contains { $0.id == group.id }, "Conversation directory incomplete")
        let outgoing = Outgoing(clientMessageId: UUID().uuidString.lowercased(), deviceId: UUID().uuidString.lowercased(), sender: "Mac", platform: "macos", text: "独立私聊问题", conversationId: direct.id, mentionAgentIds: [])
        let sent = try await api.send(outgoing)
        let privatePage = try await api.page(conversation: direct.id)
        try check(privatePage.messages.contains { $0.id == sent.id }, "Private message not in private history")
        let shared = try await api.page()
        try check(!shared.messages.contains { $0.id == sent.id }, "Private message leaked into shared history")
        let mention = Outgoing(clientMessageId: UUID().uuidString.lowercased(), deviceId: UUID().uuidString.lowercased(), sender: "Mac", platform: "macos", text: "请回答", conversationId: group.id, mentionAgentIds: [agentId])
        let groupMessage = try await api.send(mention)
        let groupPage = try await api.page(conversation: group.id)
        try check(groupPage.jobs?.contains { $0.messageId == groupMessage.id && $0.agentId == agentId } == true, "Mention did not create the targeted reply job")
    }
}
