import Foundation
@testable import LeonChat

private final class NetworkFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String] = []
    private var inputs: [URLRequest] = []
    private var statuses: [String: Int] = [:]
    private var holdAll = true
    private var heldPaths = Set<String>()
    private var responses: [String: Data] = [:]
    private var pending: [FixtureProtocol] = []
    func record(_ request: FixtureProtocol) -> Data? {
        lock.lock(); defer { lock.unlock() }
        let path = request.request.url!.path
        requests.append(path)
        inputs.append(request.request)
        if holdAll || heldPaths.contains(path) { pending.append(request); return nil }
        return responses[path] ?? Data("{\"messages\":[],\"hasMore\":false,\"jobs\":[]}".utf8)
    }
    func setup(holding paths: Set<String>, responses: [String: Data] = [:], statuses: [String: Int] = [:]) {
        lock.lock(); defer { lock.unlock() }
        holdAll = false; heldPaths = paths; self.responses = responses; self.statuses = statuses; requests = []; inputs = []
    }
    func status(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return statuses[path] ?? 200 }
    func request(_ path: String) -> URLRequest? { lock.lock(); defer { lock.unlock() }; return inputs.last { $0.url?.path == path } }
    func paths() -> [String] { lock.lock(); defer { lock.unlock() }; return requests }
    func release(_ path: String) {
        lock.lock()
        let ready = pending.filter { $0.request.url!.path == path }
        pending.removeAll { $0.request.url!.path == path }
        heldPaths.remove(path)
        let data = responses[path] ?? Data("{}".utf8)
        lock.unlock()
        for request in ready { request.respond(data) }
    }
    func cancel(_ request: FixtureProtocol) {
        lock.lock(); defer { lock.unlock() }; pending.removeAll { $0 === request }
    }
}
private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = NetworkFixture()
    private let stateLock = NSLock()
    private var finished = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { if let data = Self.fixture.record(self) { respond(data) } }
    func respond(_ data: Data) {
        stateLock.lock()
        guard !finished else { stateLock.unlock(); return }
        finished = true; stateLock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.fixture.status(request.url!.path), httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        stateLock.lock(); finished = true; stateLock.unlock(); Self.fixture.cancel(self)
    }
}

@main
struct SwitchingChecks {
    @MainActor static func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
    @MainActor static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let api = MessageAPI(base: URL(string: "https://fixture.test")!, token: "fake-test-token", configuration: config)
        let store = ChatStore(api: api)
        store.setActive(false)
        let a = Conversation(id: "direct:a", name: "A", kind: "direct", agentId: "a", agentIds: ["a"])
        let b = Conversation(id: "direct:b", name: "B", kind: "direct", agentId: "b", agentIds: ["b"])
        let c = Conversation(id: "direct:c", name: "C", kind: "direct", agentId: "c", agentIds: ["c"])
        func agent(_ id: String, enabled: Bool = true) -> AgentInfo {
            AgentInfo(id: id, name: id.uppercased(), handle: id + id, provider: "openai", model: "test", enabled: enabled, avatarId: nil)
        }
        func message(_ id: Int64, room: Conversation) -> Message {
            Message(id: id, clientMessageId: "client-\(id)", deviceId: "device", sender: room.name, platform: "agent", text: "cached history \(id)", createdAt: 1,
                conversationId: room.id, role: "assistant", agentId: room.agentId, replyTo: nil)
        }
        var failures = 0
        func check(_ condition: Bool, _ text: String) { print("\(condition ? "PASS" : "FAIL"): \(text)"); if !condition { failures += 1 } }
        store.conversations = [a, b]
        let previous = store.selectedConversationId
        store.showAgentDetails(agent("b"))
        check(store.agentDetailId == "b" && store.selectedConversationId == previous, "Agent details do not open or create a conversation")
        check(store.agentConversations("b").map(\.id) == [b.id], "Agent history excludes other Agents")
        store.selectConversation(a.id)
        check(store.agentDetailId == nil, "Opening a history conversation exits the Agent detail page")
        var started = false
        let task = Task { @MainActor in started = true; await store.openDirect(agent("b")) }
        while !started { await Task.yield() }
        check(store.selectedConversationId == b.id, "cached Agent selection is immediate while network is blocked")
        task.cancel()
        store.selectConversation(a.id)
        let first = message(1, room: a)
        store.messages = [first]; store.draft = "A draft"
        store.showAgentDetails(agent("b")); store.agentDetailId = nil
        check(store.selectedConversationId == a.id && store.draft == "A draft" && store.messages == [first], "Returning from a message Agent profile preserves the original chat and draft")
        let picture = ChatImageDraft(id: UUID().uuidString.lowercased(), data: Data([1, 2, 3]))
        store.draftImages = [picture]
        store.selectConversation(b.id); store.draft = "B draft"; store.draftImages = []
        store.selectConversation(a.id)
        check(store.messages == [first], "loaded history appears immediately when switching back")
        check(store.draft == "A draft" && store.draftImages.map(\.id) == [picture.id], "text and image drafts stay isolated per conversation")
        check(!FixtureProtocol.fixture.paths().contains(where: { $0.hasPrefix("/api/conversations/direct/") }), "known private conversation needs no create-or-list request")

        // Hold all directory/presence calls; the message response must still be displayed.
        let directoryPaths: Set<String> = ["/api/agents", "/api/conversations", "/api/device-messages/presence"]
        let second = message(2, room: a)
        let page = MessagePage(messages: [second], hasMore: false, jobs: [], contextOperations: [])
        FixtureProtocol.fixture.setup(holding: directoryPaths, responses: ["/api/device-messages": try JSONEncoder().encode(page)])
        store.setActive(true)
        let delivered = await waitFor { store.messages.contains { $0.id == 2 } }
        check(delivered, "message loading does not wait for directory requests or heartbeat")
        let clock = ContinuousClock(), start = ContinuousClock.now
        for _ in 0..<100 { store.selectConversation(b.id); store.selectConversation(a.id) }
        print("MEASURE: 200 cached conversation switches took \(start.duration(to: clock.now))")
        _ = await waitFor { FixtureProtocol.fixture.paths().contains("/api/agents") }
        check(FixtureProtocol.fixture.paths().filter { $0 == "/api/agents" }.count == 1, "rapid switching shares one background directory refresh")
        store.setActive(false)

        // A slow first-time creation must not override a newer click on an existing Agent.
        FixtureProtocol.fixture.setup(holding: ["/api/conversations/direct/c"], responses: ["/api/conversations/direct/c": try JSONEncoder().encode(c)])
        let creation = Task { @MainActor in await store.openDirect(agent("c")) }
        _ = await waitFor { FixtureProtocol.fixture.paths().contains("/api/conversations/direct/c") }
        check(store.selectedConversationId == c.id && store.loadingMessages, "first-time Agent click selects its room and shows loading before the network responds")
        await store.openDirect(agent("b"))
        FixtureProtocol.fixture.release("/api/conversations/direct/c")
        await creation.value
        check(store.selectedConversationId == b.id, "late private-conversation creation cannot override the latest selection")
        check(!FixtureProtocol.fixture.paths().contains("/api/conversations"), "first-time creation does not re-download the conversation directory")

        let d = Conversation(id: "direct:d", name: "D", kind: "direct", agentId: "d", agentIds: ["d"])
        FixtureProtocol.fixture.setup(holding: ["/api/conversations/direct/d"], responses: ["/api/conversations/direct/d": try JSONEncoder().encode(d)])
        store.selectAgent(agent("d"))
        check(store.selectedConversationId == d.id && store.loadingMessages, "sidebar action selects a new Agent synchronously before starting its request")
        store.draft = "wait for room creation"
        check(!store.canSend, "sending stays disabled until private-conversation creation succeeds")
        _ = await waitFor { FixtureProtocol.fixture.paths().contains("/api/conversations/direct/d") }
        store.selectAgent(agent("d"))
        await Task.yield()
        check(FixtureProtocol.fixture.paths().filter { $0 == "/api/conversations/direct/d" }.count == 1, "repeat clicks share the in-flight private-conversation request")
        store.setActive(true)
        await Task.yield()
        check(!FixtureProtocol.fixture.paths().contains("/api/device-messages"), "foreground refresh does not request history before the room exists")
        store.setActive(false)
        FixtureProtocol.fixture.release("/api/conversations/direct/d")
        _ = await waitFor { !store.openingDirectConversation }
        check(store.canSend, "successful room creation enables sending")

        FixtureProtocol.fixture.setup(holding: ["/api/conversations/direct/e"])
        store.selectAgent(agent("e"))
        store.draft = "retry after creation failure"
        _ = await waitFor { FixtureProtocol.fixture.paths().contains("/api/conversations/direct/e") }
        FixtureProtocol.fixture.release("/api/conversations/direct/e")
        _ = await waitFor { !store.loadingMessages }
        check(store.error != nil && store.openingDirectConversation, "failed first-time creation exits loading and stays retryable")
        let e = Conversation(id: "direct:e", name: "E", kind: "direct", agentId: "e", agentIds: ["e"])
        FixtureProtocol.fixture.setup(holding: [], responses: ["/api/conversations/direct/e": try JSONEncoder().encode(e)])
        store.selectAgent(agent("e"))
        _ = await waitFor { !store.openingDirectConversation }
        check(!store.openingDirectConversation && store.canSend, "clicking after creation failure retries instead of selecting an unusable placeholder")
        store.selectAgent(agent("b"))

        let group = Conversation(id: "group", name: "Group", kind: "group", agentId: nil, agentIds: ["a", "b"])
        let orphan = Conversation(id: "direct:unknown", name: "Old history", kind: "direct", agentId: "unknown", agentIds: ["unknown"])
        store.agents = [agent("a"), agent("b"), agent("c", enabled: false)]
        store.conversations = [a, b, c, group, orphan]
        check(store.sidebarConversations.map(\.id) == [group.id, orphan.id], "sidebar removes duplicate known Agent rooms and keeps group/orphan history")
        check(store.sidebarAgents.map(\.id) == ["a", "b", "c"], "disabled Agent history remains accessible through its single entry")
        check(store.isSelected(agent("b")), "selected Agent is highlighted on its remaining entry")

        let thread = Conversation(id: "thread:a:1", name: "New topic", kind: "direct", agentId: "a", agentIds: ["a"])
        FixtureProtocol.fixture.setup(holding: [], responses: ["/api/conversations/direct/a/threads": try JSONEncoder().encode(thread)])
        store.selectConversation(a.id)
        await store.createAgentConversation(agent("a"), name: "New topic", requestId: UUID().uuidString, fromHistory: true)
        check(store.selectedConversationId == thread.id && store.agentConversations("a").contains(thread), "creating from Agent history opens a separate conversation")
        let later = Conversation(id: "thread:a:2", name: "Later", kind: "direct", agentId: "a", agentIds: ["a"])
        FixtureProtocol.fixture.setup(holding: ["/api/conversations/direct/a/threads"], responses: ["/api/conversations/direct/a/threads": try JSONEncoder().encode(later)])
        let newThread = Task { @MainActor in await store.createAgentConversation(agent("a"), name: "Later", requestId: UUID().uuidString, fromHistory: true) }
        _ = await waitFor { FixtureProtocol.fixture.paths().contains("/api/conversations/direct/a/threads") }
        store.selectConversation(b.id)
        FixtureProtocol.fixture.release("/api/conversations/direct/a/threads")
        await newThread.value
        check(store.selectedConversationId == b.id && store.agentConversations("a").contains(later), "late creation preserves the newer selection and keeps the new conversation")

        store.selectConversation(a.id)
        store.messages = (1...350).map { message(Int64($0), room: a) }
        store.selectConversation(b.id); store.selectConversation(a.id)
        check(store.messages.count == 300 && store.messages.first?.id == 51 && store.hasOlder, "cached history is bounded and older messages remain pageable")
        store.setActive(false)
        store.selectConversation(a.id)
        store.messages = [message(700, room: a)]
        store.draft = "/clear"
        let clearPreview = ClearHistoryPreview(conversationId: a.id, conversationName: a.name, messageCount: 1, latestMessageId: 700, historyRevision: 0, hasActiveWork: false)
        FixtureProtocol.fixture.setup(holding: [], responses: [
            "/api/conversations/context/clear-preview": try JSONEncoder().encode(clearPreview),
            "/api/conversations/context/clear": try JSONEncoder().encode(ClearHistoryResult(clearedMessages: 1, historyRevision: 1))
        ])
        await store.performCommand(.clear)
        check(store.showClearHistory && store.messages.count == 1, "/clear opens confirmation without deleting history")
        check(!FixtureProtocol.fixture.paths().contains("/api/conversations/context/clear"), "no deletion request before confirmation")
        await store.prepareClearHistory()
        check(store.clearPreview?.messageCount == 1, "confirmation reads current server history count")
        store.pending = [Outgoing(clientMessageId: UUID().uuidString, deviceId: "test", sender: "test", platform: "macos", text: "discard confirmed", conversationId: a.id)]
        store.draftImages = [picture]
        await store.clearCurrentHistory()
        check(store.messages.isEmpty && store.jobs.isEmpty && store.contextOperations.isEmpty && store.currentPending.isEmpty && store.draftImages.isEmpty, "confirmed clear drops selected history, context, pending messages and images")
        store.selectConversation(b.id); store.selectConversation(a.id)
        check(store.messages.isEmpty, "switching back cannot restore cleared history from cache")
        let newer = message(900, room: a)
        store.messages = [message(800, room: a)]
        let clearedElsewhere = MessagePage(messages: [newer], hasMore: false, jobs: [], contextOperations: [], historyRevision: 2)
        FixtureProtocol.fixture.setup(holding: directoryPaths, responses: ["/api/device-messages": try JSONEncoder().encode(clearedElsewhere)])
        store.setActive(true)
        _ = await waitFor { store.messages.contains { $0.id == 900 } }
        check(store.messages == [newer], "another device clearing history removes stale cached messages on next poll")
        store.setActive(false)
        store.selectConversation(a.id,refresh:false);store.draft="source draft"
        let branch=Conversation(id:"branch:copy",name:"分支",kind:"direct",agentId:"a",agentIds:["a"])
        let branchPath="/api/conversations/\(a.id)/branches"
        FixtureProtocol.fixture.setup(holding:directoryPaths,responses:[branchPath:try JSONEncoder().encode(branch)])
        store.beginBranch(message(901,room:a))
        let created=try await store.createBranch(message(901,room:a),name:"分支",requestId:"request")
        check(created.id==branch.id && store.conversations.contains(where:{$0.id==branch.id}),"branch appears in the conversation directory")
        check(store.selectedConversationId==a.id && store.draft=="source draft","branch creation preserves source navigation and draft")
        store.selectConversation(branch.id,refresh:false);check(store.draft.isEmpty,"branch starts without the unsent source draft")
        store.selectConversation(a.id,refresh:false);check(store.draft=="source draft","returning from branch restores source draft")
        let late=Conversation(id:"branch:late",name:"迟到",kind:"direct",agentId:"a",agentIds:["a"])
        FixtureProtocol.fixture.setup(holding:[branchPath],responses:[branchPath:try JSONEncoder().encode(late)])
        let branchTask=Task {try await store.createBranch(message(901,room:a),name:"迟到",requestId:"late-request")}
        _ = await waitFor {FixtureProtocol.fixture.paths().contains(branchPath)}
        branchTask.cancel();FixtureProtocol.fixture.release(branchPath)
        do {_ = try await branchTask.value;check(false,"cancelled branch must fail")} catch {}
        check(!store.conversations.contains(where:{$0.id==late.id}),"cancelled branch response cannot modify navigation state")
        // Permanent deletion must wait for the server, then purge every local route back to the old room.
        let deletion = ChatStore(api: api)
        deletion.setActive(false); deletion.conversations = [a, b, c]; deletion.agents = [agent("a"), agent("b"), agent("c")]
        deletion.selectConversation(b.id); deletion.messages = [message(2000, room: b)]; deletion.draft = "keep B"
        deletion.selectConversation(a.id); deletion.messages = [message(2001, room: a)]; deletion.draft = "delete A"
        deletion.draftImages = [picture]; deletion.quoteMessage(message(2001, room: a))
        deletion.scrollPositions[a.id] = ConversationScrollPosition(offset: 15, messageID: 2001, messageTop: 0)
        deletion.pending = [Outgoing(clientMessageId: UUID().uuidString, deviceId: "test", sender: "test", platform: "macos", text: "old pending", conversationId: a.id),
            Outgoing(clientMessageId: UUID().uuidString, deviceId: "test", sender: "test", platform: "macos", text: "keep pending", conversationId: b.id)]
        let deletePreview = ClearHistoryPreview(conversationId: a.id, conversationName: a.name, messageCount: 1, latestMessageId: 2001, historyRevision: 3, hasActiveWork: false)
        let deletePath = "/api/conversations/context/delete", previewPath = "/api/conversations/context/delete-preview"
        let deleteResult = DeleteConversationResult(conversationId: a.id, deletedMessages: 1)
        FixtureProtocol.fixture.setup(holding: [deletePath], responses: [previewPath: try JSONEncoder().encode(deletePreview), deletePath: try JSONEncoder().encode(deleteResult)])
        let confirmedPreview = try await deletion.previewConversationDeletion(a)
        check(confirmedPreview.messageCount == 1 && !FixtureProtocol.fixture.paths().contains(deletePath), "preview and cancel never issue permanent deletion")
        let deletionTask = Task { @MainActor in try await deletion.deleteConversation(confirmedPreview, requestId: "deletion-request") }
        _ = await waitFor { FixtureProtocol.fixture.paths().contains(deletePath) }
        check(deletion.conversations.contains(a) && deletion.messages.count == 1 && !deletion.canSend, "in-flight deletion keeps history visible and disables new sending")
        let sentRequest = FixtureProtocol.fixture.request(deletePath)!
        var requestBody = sentRequest.httpBody ?? Data()
        if requestBody.isEmpty, let stream = sentRequest.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; requestBody.append(contentsOf: buffer.prefix(count))
            }
        }
        let sentBody = try JSONSerialization.jsonObject(with: requestBody) as! [String: Any]
        check(sentRequest.httpMethod == "POST" && sentBody["conversationId"] as? String == a.id && sentBody["confirm"] as? Bool == true
            && sentBody["expectedLatestMessageId"] as? Int == 2001 && sentBody["expectedHistoryRevision"] as? Int == 3,
            "delete request carries explicit confirmation and both history concurrency guards")
        FixtureProtocol.fixture.release(deletePath); try await deletionTask.value
        check(!deletion.conversations.contains(a) && deletion.selectedConversationId != a.id && !deletion.pending.contains(where: { $0.conversationId == a.id }), "successful deletion removes the room and its outbox")
        check(deletion.scrollPositions[a.id] == nil, "deletion clears the removed conversation reading position")
        deletion.selectConversation(b.id)
        check(deletion.draft == "keep B" && deletion.messages == [message(2000, room: b)] && deletion.currentPending.count == 1, "other conversation history, draft and outbox survive deletion")
        deletion.selectConversation(a.id)
        check(deletion.selectedConversationId == b.id, "stale navigation cannot reopen deleted cached history")

        // A failed server transaction must leave the source conversation untouched.
        let failedPreview = ClearHistoryPreview(conversationId: b.id, conversationName: b.name, messageCount: 1, latestMessageId: 2000, historyRevision: 0, hasActiveWork: false)
        FixtureProtocol.fixture.setup(holding: [], responses: [deletePath: Data("{\"message\":\"会话已有新消息，请刷新后重新确认\"}".utf8)], statuses: [deletePath: 409])
        do { try await deletion.deleteConversation(failedPreview, requestId: "failed-request"); check(false, "failed deletion must throw") }
        catch { check(error.localizedDescription.contains("新消息"), "deletion preserves the server concurrency error") }
        check(deletion.conversations.contains(b) && deletion.draft == "keep B" && deletion.currentPending.count == 1 && !deletion.deletingConversation, "failed deletion preserves history and drafts and exits busy state")

        // A late response must not pull the user away from a newer selection.
        FixtureProtocol.fixture.setup(holding: [deletePath], responses: [deletePath: try JSONEncoder().encode(DeleteConversationResult(conversationId: b.id, deletedMessages: 1))])
        let backgroundDelete = Task { @MainActor in try await deletion.deleteConversation(failedPreview, requestId: "background-delete") }
        _ = await waitFor { FixtureProtocol.fixture.paths().contains(deletePath) }
        deletion.selectConversation(c.id); deletion.draft = "newer C draft"
        FixtureProtocol.fixture.release(deletePath); try await backgroundDelete.value
        check(deletion.selectedConversationId == c.id && deletion.draft == "newer C draft", "late deletion preserves newer navigation and draft")

        // Reopening an Agent creates a fresh room rather than selecting its deleted default ID.
        let freshA = Conversation(id: "thread:fresh-a", name: "A", kind: "direct", agentId: "a", agentIds: ["a"])
        FixtureProtocol.fixture.setup(holding: [], responses: ["/api/conversations/direct/a": try JSONEncoder().encode(freshA)])
        await deletion.openDirect(agent("a"))
        check(deletion.selectedConversationId == freshA.id && deletion.messages.isEmpty && deletion.draft.isEmpty && deletion.draftImages.isEmpty && deletion.quotedMessage == nil,
            "reopening a deleted Agent chat starts with fresh history and no old draft, quote or attachments")

        let remote = ChatStore(api: api)
        remote.setActive(false); remote.conversations = [a, b]; remote.selectConversation(a.id); remote.messages = [message(3000, room: a)]
        remote.draft = "removed on another device"
        remote.pending = [Outgoing(clientMessageId: UUID().uuidString, deviceId: "test", sender: "test", platform: "macos", text: "stale", conversationId: a.id)]
        FixtureProtocol.fixture.setup(holding: [], responses: ["/api/conversations": try JSONEncoder().encode([b]), "/api/agents": try JSONEncoder().encode([agent("a"), agent("b")])])
        remote.setActive(true)
        _ = await waitFor { !remote.conversations.contains(a) }
        remote.setActive(false)
        check(!remote.conversations.contains(a) && remote.selectedConversationId == b.id && remote.pending.isEmpty,
            "directory sync removes chats deleted on another device and purges their stale outbox")

        let race = ChatStore(api: api)
        race.setActive(false); race.conversations = [a, b]; race.selectConversation(a.id)
        FixtureProtocol.fixture.setup(holding: ["/api/conversations"], responses: ["/api/conversations": try JSONEncoder().encode([a, b]),
            "/api/agents": try JSONEncoder().encode([agent("a"), agent("b")]), deletePath: try JSONEncoder().encode(deleteResult)])
        race.setActive(true)
        _ = await waitFor { FixtureProtocol.fixture.paths().contains("/api/conversations") }
        try await race.deleteConversation(deletePreview, requestId: "directory-race")
        FixtureProtocol.fixture.release("/api/conversations")
        try? await Task.sleep(nanoseconds: 50_000_000)
        race.setActive(false)
        check(!race.conversations.contains(a), "late directory response cannot restore a permanently deleted conversation")

        if failures > 0 { exit(1) }
    }
}
