import AppKit
import SwiftUI
import CryptoKit

@MainActor
final class ChatDraft: ObservableObject {
    @Published var text = ""
}

@MainActor
final class ChatStore: ObservableObject {
    var scrollPositions:[String:ConversationScrollPosition]=[:]
    func openQuotedRoom(_ id:String) {selectConversation(id)}
    func createBranch(_ message:Message,name:String,requestId:String) async throws -> Conversation {
        guard message.id>0,let room=message.conversationId,let api else {throw ClientError.message("请先连接服务器并选择已发送成功的消息。")}
        let connection=connectionId
        do {
            let result=try await api.branch(room:room,message:message.id,name:name,requestId:requestId)
            guard connection==connectionId,!Task.isCancelled,!deletedConversationIDs.contains(result.id) else {throw CancellationError()}
            if !conversations.contains(where:{$0.id==result.id}) {conversations.append(result)}
            return result
        } catch {
            throw error
        }
    }
    @Published var quotedMessage: MessageQuote?
    private var quoteDrafts: [String:MessageQuote] = [:]
    @Published var collectionNotice = ""
    private var favoriteRequests = Set<Int64>()
    func quoteMessage(_ message:Message) {
        guard message.id>0, message.conversationId == selectedConversationId else {return}
        quotedMessage=MessageQuote(message:message)
    }
    func cancelQuote(){quotedMessage=nil}
    func favoriteMessage(_ message:Message) async {
        guard message.id>0,let api,!favoriteRequests.contains(message.id) else {return}
        let connection=connectionId;favoriteRequests.insert(message.id)
        defer {if connection==connectionId {favoriteRequests.remove(message.id)}}
        do {_ = try await api.addFavorite(message.id);guard connection==connectionId else {return};collectionNotice="已收藏";Task {try? await Task.sleep(nanoseconds:2_000_000_000);if connection==self.connectionId {self.collectionNotice=""}}}
        catch {if connection==connectionId {self.error=error.localizedDescription}}
    }
    func favoritePage(query:String,before:Int64?) async throws -> FavoritePage {
        guard let api else {throw ClientError.message("请先连接服务器。")}
        let result=try await api.favorites(query:query,before:before)
        guard self.api === api else {throw CancellationError()};return result
    }
    func deleteFavorite(_ id:Int64) async throws {
        guard let api else {throw ClientError.message("请先连接服务器。")};try await api.removeFavorite(id)
        guard self.api === api else {throw CancellationError()}
    }
    func favoriteImage(_ favorite:Int64,image:String) async throws -> Data {
        guard let api else {throw ClientError.message("请先连接服务器。")};let data=try await api.favoriteImage(favorite,image:image)
        guard self.api === api else {throw CancellationError()};return data
    }
    var searchConnectionID: ObjectIdentifier? { api.map { ObjectIdentifier($0) } }
    func searchMessages(query: String, room: String?, before: Int64?) async throws -> ChatSearchPage {
        guard let api else { throw ClientError.message("请先连接服务器。") }
        let result = try await api.search(query:query,room:room,before:before)
        guard self.api === api else { throw CancellationError() }
        return result
    }
    func searchHistory(room: String, message: Int64, direction: String) async throws -> ChatSearchContext {
        guard let api else { throw ClientError.message("请先连接服务器。") }
        let result = try await api.searchContext(room:room,message:message,direction:direction)
        guard self.api === api else { throw CancellationError() }
        return result
    }
    @Published var messages: [Message] = [] {
        didSet {
            cachedMessageIDs = nil
            cachedTimelineItems = nil
        }
    }
    private var cachedMessageIDs: [Int64]?
    private var cachedTimelineItems: [TimelineItem]?

    var messageIDs: [Int64] {
        if let cachedMessageIDs { return cachedMessageIDs }
        let ids = messages.map(\.id)
        cachedMessageIDs = ids
        return ids
    }

    var timelineItems: [TimelineItem] {
        if let cachedTimelineItems { return cachedTimelineItems }
        let items = TimelineItem.ordered(messages: messages, operations: contextOperations, jobs: visibleJobs)
        cachedTimelineItems = items
        return items
    }

    @Published var pending: [Outgoing] = []
    let composerDraft = ChatDraft()
    var draft: String {
        get { composerDraft.text }
        set { composerDraft.text = newValue }
    }
    @Published var draftDocuments:[DraftDocument]=[]
    @Published var importingDocuments=false
    private var documentDrafts:[String:[DraftDocument]]=[:]
    private var documentGeneration=UUID()
    var notificationAPI:(any NotificationAPI)? {api as? any NotificationAPI}
    var notificationDevice:String {deviceId}
    var documentRoom:String {selectedConversationId}
    func addDocuments(_ urls:[URL],room:String,connection:ObjectIdentifier?){
        guard hasConnection,!importingDocuments,!clearBusy,searchConnectionID==connection else {return}
        let count=room==selectedConversationId ? draftDocuments.count : documentDrafts[room]?.count ?? 0
        guard count+urls.count<=4 else {error="每条消息最多发送 4 个文档。";return}
        let stamp=documentGeneration;importingDocuments=true
        Task {
            do {
                let docs=try await Task.detached(priority:.userInitiated){try urls.map {try DraftDocument.read($0)}}.value
                guard stamp==documentGeneration,searchConnectionID==connection,!deletedConversationIDs.contains(room) else {return}
                if room==selectedConversationId {draftDocuments+=docs}else{documentDrafts[room,default:[]]+=docs}
            }catch {if stamp==documentGeneration {self.error=error.localizedDescription}}
            if stamp==documentGeneration {importingDocuments=false}
        }
    }
    func removeDocument(_ id:String){draftDocuments.removeAll {$0.id==id}}
    func documentData(_ id:String,favorite:Int64?=nil) async throws -> Data {
        guard let api else {throw ClientError.message("请先连接服务器。")};let data=try await api.document(id,favorite:favorite)
        guard self.api === api else {throw CancellationError()};return data
    }
    @Published var draftImages: [ChatImageDraft] = []
    @Published var preparingImages = false
    private var imageDrafts: [String: [ChatImageDraft]] = [:]
    var canSend: Bool { !openingDirectConversation && !deletingConversation && !deletedConversationIDs.contains(selectedConversationId) && !clearBusy && !exportBusy && hasConnection && !configuring && !preparingImages && !importingDocuments && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftImages.isEmpty || !draftDocuments.isEmpty) && draft.utf16.count <= 8000 }
    func addImages(_ sources: [Data]) async {
        guard hasConnection, !configuring, !preparingImages else { return }
        let room = selectedConversationId, connection = connectionId
        let available = 4 - draftImages.count
        guard available > 0 else { error = "每条消息最多发送 4 张图片"; return }
        preparingImages = true
        let result = await Task.detached { () -> Result<[ChatImageDraft], Error> in
            Result { try sources.prefix(available).map(ChatImageDraft.prepare) }
        }.value
        preparingImages = false
        guard connection == connectionId, !deletedConversationIDs.contains(room) else { return }
        switch result {
        case .success(let images):
            if selectedConversationId == room { draftImages += images }
            else { imageDrafts[room, default: []] += images }
            if sources.count > available { error = "每条最多 4 张图片，超出部分未添加。" }
        case .failure(let failure): error = friendly(failure)
        }
    }
    @Published private(set) var imageCacheRevision = UUID()
    private var imageLoader = ChatImageLoader()

    private func imageSource(_ id: String) -> ChatImageLoader.Source {
        let scope = pendingKey, api = api
        return {
            if let local = ChatImageFiles.read(id, scope: scope) { return local }
            guard let api else { throw ClientError.message("请先连接服务器") }
            return try await api.imageData(id)
        }
    }

    func imageData(_ id: String) async throws -> Data {
        try await imageLoader.data(id, source: imageSource(id))
    }

    func imageThumbnail(_ id: String, pixels: Int) async throws -> NSImage {
        try await imageLoader.thumbnail(id, pixels: pixels, source: imageSource(id))
    }

    func fullSizeImage(_ id: String) async throws -> NSImage {
        try await imageLoader.fullSize(id, source: imageSource(id))
    }

    private func clearChatImages() {
        imageLoader.cancel()
        api?.clearImageCache()
        imageLoader = ChatImageLoader()
        imageCacheRevision = UUID()
    }
    @Published var agents: [AgentInfo] = []
    @Published var agentDetailId: String?
    @Published var creatingAgentConversation = false
    func showAgentDetails(_ agent: AgentInfo) {
        navigationRequest = UUID()
        agentDetailId = agent.id
    }
    func agentConversations(_ agentId: String) -> [Conversation] {
        conversations.filter { $0.kind == "direct" && $0.agentId == agentId }
    }
    func createAgentConversation(_ agent: AgentInfo, name: String, requestId: String, fromHistory: Bool = false) async {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let api, agent.enabled, !creatingAgentConversation else { return }
        guard !title.isEmpty, title.utf16.count <= 60 else { error = "对话名称应为 1–60 字"; return }
        let connection = connectionId, navigation = navigationRequest
        error = nil; creatingAgentConversation = true
        defer { if connection == connectionId { creatingAgentConversation = false } }
        do {
            let room = try await api.newThread(agentId: agent.id, name: title, requestId: requestId)
            guard connection == connectionId, !deletedConversationIDs.contains(room.id) else { return }
            if !conversations.contains(where: { $0.id == room.id }) { conversations.append(room) }
            if navigation == navigationRequest, agentDetailId == agent.id || (fromHistory && agentDetailId == nil) { selectConversation(room.id) }
        } catch { if connection == connectionId { self.error = friendly(error) } }
    }
    @Published var modelUsage: [ModelUsage] = []
    @Published var usageBusy = false
    @Published var usageLoadedAt: Date?
    @Published var usageError: String?
    func loadUsage() async {
        guard let api, !usageBusy else { return }
        let connection = connectionId
        usageBusy = true; usageError = nil
        defer { if connection == connectionId { usageBusy = false } }
        do {
            let rows = try await api.usage()
            guard connection == connectionId else { return }
            modelUsage = rows; usageLoadedAt = Date()
        } catch { if connection == connectionId { usageError = friendly(error) } }
    }
    @Published var conversations: [Conversation] = []
    @Published var jobs: [AgentJob] = [] {
        didSet { cachedTimelineItems = nil }
    }
    @Published private var dismissedJobKeys = Set<String>() {
        didSet { cachedTimelineItems = nil }
    }
    private var visibleJobs: [AgentJob] { jobs.filter { $0.status != "FAILED" || !dismissedJobKeys.contains(dismissalKey($0)) } }
    var dismissedFailureCount: Int { jobs.filter { $0.status == "FAILED" && dismissedJobKeys.contains(dismissalKey($0)) }.count }
    private func dismissalKey(_ job: AgentJob) -> String {
        job.id + "#" + SHA256.hash(data: Data(job.error.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func dismissJob(_ job: AgentJob) {
        guard job.status == "FAILED" else { return }
        dismissedJobKeys.insert(dismissalKey(job)); saveDismissals()
    }
    func restoreDismissedJobs() {
        dismissedJobKeys.subtract(jobs.filter { $0.status == "FAILED" }.map { dismissalKey($0) }); saveDismissals()
    }
    private func saveDismissals() { guard !pendingKey.isEmpty else { return }; ChatPreferences.defaults.set(Array(dismissedJobKeys), forKey: pendingKey + ".dismissedJobs") }
    private func receiveJobs(_ incoming: [AgentJob]) {
        let active = Set(incoming.filter { $0.status != "FAILED" }.map(\.id))
        let retained = Set(dismissedJobKeys.filter { !active.contains($0.components(separatedBy: "#")[0]) })
        if retained != dismissedJobKeys { dismissedJobKeys = retained; saveDismissals() }
        if jobs != incoming { jobs = incoming }
    }

    @Published var selectedConversationId = "shared"
    @Published private(set) var deletingConversation = false
    private var deletedConversationIDs = Set<String>()
    private var directoryRevision = UUID()

    func previewConversationDeletion(_ room: Conversation) async throws -> ClearHistoryPreview {
        guard let api else { throw ClientError.message("请先连接服务器。") }
        let connection = connectionId
        let preview = try await api.deleteConversationPreview(room.id)
        guard connection == connectionId, !Task.isCancelled else { throw CancellationError() }
        return preview
    }

    func deleteConversation(_ preview: ClearHistoryPreview, requestId: String) async throws {
        guard let api, !deletingConversation else { return }
        let room = preview.conversationId, connection = connectionId
        guard !exportBusy, !clearBusy, !preparingImages, !importingDocuments,
              !pending.contains(where: { ($0.conversationId ?? "shared") == room && sending.contains($0.id) }),
              !unconfirmedDirectRooms.contains(room) else {
            throw ClientError.message("请等待消息发送、附件处理或导出完成后再删除。")
        }
        deletingConversation = true
        defer { if connection == connectionId { deletingConversation = false } }
        let result = try await api.deleteConversation(preview, requestId: requestId)
        guard connection == connectionId else { return }
        guard result.conversationId == room else { throw ClientError.message("服务端返回的会话不匹配，请刷新列表。") }
        directoryRevision = UUID()
        removeConversationLocally(room)
    }

    private func removeConversationLocally(_ room: String) {
        let agent = conversations.first(where: { $0.id == room })?.agentId
        deletedConversationIDs.insert(room)
        conversations.removeAll { $0.id == room }
        if selectedConversationId == room {
            let next = conversations.first { $0.agentId == agent && $0.kind == "direct" } ?? conversations.first
            selectConversation(next?.id ?? "shared")
            if !conversations.contains(where: { $0.agentId == agent && $0.kind == "direct" }),
               let agent = agents.first(where: { $0.id == agent }) { showAgentDetails(agent) }
        }
        for message in pending where (message.conversationId ?? "shared") == room {
            ChatImageFiles.remove(message.imageIds ?? [], scope: pendingKey)
            DocumentFiles.remove(message.documentIds ?? [], scope: pendingKey)
        }
        pending.removeAll { ($0.conversationId ?? "shared") == room }; savePending()
        drafts.removeValue(forKey: room); imageDrafts.removeValue(forKey: room); documentDrafts.removeValue(forKey: room)
        quoteDrafts.removeValue(forKey: room); scrollPositions.removeValue(forKey: room)
        roomCache.removeValue(forKey: room); roomCacheOrder.removeAll { $0 == room }
        unconfirmedDirectRooms.remove(room)
        documentGeneration = UUID(); importingDocuments = false
        compressionRequests = compressionRequests.filter { !$0.key.hasPrefix(room + ":") }
        let prefix = pendingKey + ".archive." + room + ":"
        for key in ChatPreferences.defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) { ChatPreferences.defaults.removeObject(forKey: key) }
        clearChatImages()
    }

    @Published var clearBusy = false
    @Published var clearPreview: ClearHistoryPreview?
    @Published var clearError: String?
    private var clearRequestId: String?
    private var historyRevision: Int64?
    func prepareClearHistory() async {
        guard let api else { return }
        let room = selectedConversationId, connection = connectionId
        clearBusy = true; clearError = nil; clearPreview = nil; clearRequestId = nil
        defer { clearBusy = false }
        do {
            let preview = try await api.clearHistoryPreview(conversation: room)
            guard connection == connectionId, room == selectedConversationId else { return }
            clearPreview = preview; clearRequestId = UUID().uuidString.lowercased()
        } catch { if connection == connectionId, room == selectedConversationId { clearError = friendly(error) } }
    }
    func clearCurrentHistory() async {
        guard let api, let preview = clearPreview, let requestId = clearRequestId, !clearBusy, !exportBusy,
              preview.conversationId == selectedConversationId else { return }
        guard !preparingImages, !currentPending.contains(where: { sending.contains($0.id) }) else { clearError = "请等待图片处理和消息发送完成后再清空。"; return }
        let connection = connectionId, room = preview.conversationId
        clearBusy = true; clearError = nil
        defer { clearBusy = false }
        do {
            let result = try await api.clearHistory(preview, requestId: requestId)
            guard connection == connectionId else { return }
            let ids = Set(jobs.map { $0.id })
            dismissedJobKeys = Set(dismissedJobKeys.filter { !ids.contains($0.components(separatedBy: "#")[0]) }); saveDismissals()
            for message in pending where (message.conversationId ?? "shared") == room { ChatImageFiles.remove(message.imageIds ?? [], scope: pendingKey);DocumentFiles.remove(message.documentIds ?? [],scope:pendingKey) }
            pending.removeAll { ($0.conversationId ?? "shared") == room }; savePending()
            scrollPositions.removeValue(forKey:room);drafts[room] = ""; imageDrafts[room] = [];documentDrafts.removeValue(forKey:room);documentGeneration=UUID();importingDocuments=false
            roomCache.removeValue(forKey: room); roomCacheOrder.removeAll { $0 == room }
            let prefix = pendingKey + ".archive." + room + ":"
            for key in ChatPreferences.defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) { ChatPreferences.defaults.removeObject(forKey: key) }
            compressionRequests = compressionRequests.filter { !$0.key.hasPrefix(room + ":") }
            clearChatImages()
            if room == selectedConversationId {
                quotedMessage=nil;quoteDrafts.removeValue(forKey:room)
                draftDocuments=[]
                generation = UUID(); draft = ""; draftImages = []; messages = []; jobs = []; contextOperations = []; contextInfo = nil
                historyRevision = result.historyRevision; initialLoaded = false; hasOlder = false; loadingOlder = false
                exportProgress = ""; exportError = nil; contextError = nil
                clearPreview = nil; clearRequestId = nil
                beginPolling()
            }
        } catch { if connection == connectionId { clearError = friendly(error) } }
    }
    private func receiveHistoryRevision(_ revision: Int64?) {
        guard let revision else { return }
        if (historyRevision != nil && historyRevision != revision) || (historyRevision == nil && revision > 0) {
            quotedMessage=nil;quoteDrafts.removeValue(forKey:selectedConversationId)
            messages = []; jobs = []; contextOperations = []; contextInfo = nil; hasOlder = false
            scrollPositions.removeValue(forKey:selectedConversationId);roomCache.removeValue(forKey: selectedConversationId); roomCacheOrder.removeAll { $0 == selectedConversationId }
            clearChatImages()
        }
        historyRevision = revision
    }
    struct ConversationScope: Equatable {
        let room: String
        let connection: UUID
    }

    struct ArchiveSelection: Equatable {
        let scope: ConversationScope
        let agentID: String
        let library: LeonBlogExporter.Destination?
    }

    struct PreparedArchive {
        let selection: ArchiveSelection
        let destination: LeonBlogExporter.Destination
        let pendingID: String?
    }

    var conversationScope: ConversationScope {
        .init(room: selectedConversationId, connection: connectionId)
    }

    @Published var exportBusy = false
    @Published var exportProgress = ""
    @Published var exportRoomId = ""
    @Published var exportError: String?
    private func archiveKey(room: String, agentId: String) -> String { pendingKey + ".archive." + room + ":" + agentId }
    private func clearPendingArchive(_ key: String) {
        ChatPreferences.defaults.removeObject(forKey: key)
        ChatPreferences.defaults.removeObject(forKey: key + ".destination")
    }
    private func clearPendingArchives(room: String) {
        let prefix = pendingKey + ".archive." + room + ":"
        for key in ChatPreferences.defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) { ChatPreferences.defaults.removeObject(forKey: key) }
    }
    private func discardChangedArchive(id: String, key: String, room: String, api: MessageAPI) async {
        // A busy room can be retried with the same ID; a changed topic needs a new snapshot.
        // Keep the pending archive if these read-only checks cannot establish which occurred.
        guard let archive = try? await api.archive(id), let context = try? await api.context(conversation: room),
              let newer = try? await api.page(conversation: room, after: archive.throughId) else { return }
        if context.topicStartedAfter >= archive.throughId || !newer.messages.isEmpty {
            if ChatPreferences.defaults.string(forKey: key) == id { clearPendingArchive(key) }
        }
    }
    func prepareArchive(_ selection: ArchiveSelection) async throws -> PreparedArchive {
        guard selection.scope == conversationScope, !selection.agentID.isEmpty else {
            throw ClientError.message("会话已切换，请重新打开归档。")
        }
        let key = archiveKey(room: selection.scope.room, agentId: selection.agentID)
        let pendingID = ChatPreferences.defaults.string(forKey: key)
        let destination: LeonBlogExporter.Destination
        if pendingID != nil {
            guard let data = ChatPreferences.defaults.data(forKey: key + ".destination"),
                  let saved = try? JSONDecoder().decode(LeonBlogExporter.Destination.self, from: data) else {
                throw ClientError.message("未完成归档的资料库配置无效，当前上下文已保留。")
            }
            destination = saved
        } else {
            guard let library = selection.library else {
                throw ClientError.message("请先连接 LeonBook 资料库，再归档当前对话。")
            }
            destination = try await Task.detached {
                try LeonBlogExporter.destination(root: library.root, user: library.user)
            }.value
        }
        try Task.checkCancellation()
        guard selection.scope == conversationScope else { throw CancellationError() }
        return PreparedArchive(selection: selection, destination: destination, pendingID: pendingID)
    }

    func startFreshRound(in scope: ConversationScope) async -> Bool {
        guard scope == conversationScope, let api, !exportBusy, !contextActionActive, currentPending.isEmpty, draftImages.isEmpty, draftDocuments.isEmpty, !preparingImages, !importingDocuments else { exportError = "请等待当前回复并处理待发送消息后再开始新对话。"; return false }
        let connection = connectionId, room = selectedConversationId
        exportBusy = true; exportError = nil
        defer { exportBusy = false }
        do {
            let info = try await api.context(conversation: room)
            let updated = try await api.configureContext(conversation: room, rounds: info.recentRounds, reset: true)
            if connection == connectionId { clearPendingArchives(room: room) }
            guard connection == connectionId, room == selectedConversationId else { return true }
            contextInfo = updated; exportRoomId = room; exportProgress = "已开始全新上下文，历史对话保留。"
            return true
        } catch { exportError = friendly(error); return false }
    }
    func exportCurrentRound(_ prepared: PreparedArchive, startNew: Bool) async -> Bool {
        guard prepared.selection.scope == conversationScope else {
            exportError = "会话已切换，请重新打开归档。"
            return false
        }
        guard let api, !exportBusy, !contextActionActive, currentPending.isEmpty, draftImages.isEmpty,
              draftDocuments.isEmpty, !preparingImages, !importingDocuments else {
            exportError = "请等待当前回复并处理待发送消息后再归档。"
            return false
        }
        let room = selectedConversationId, connection = connectionId
        let agentId = prepared.selection.agentID
        let destination = prepared.destination
        let key = archiveKey(room: room, agentId: agentId)
        let pendingID = ChatPreferences.defaults.string(forKey: key)
        guard pendingID == prepared.pendingID else {
            exportError = "归档状态已变化，请重新确认资料库后导出。"
            return false
        }
        let id = pendingID ?? UUID().uuidString.lowercased()
        exportBusy = true; exportRoomId = room; exportProgress = "正在生成本轮对话总结…"; exportError = nil
        defer { exportBusy = false }
        do {
            if pendingID != nil, let data = ChatPreferences.defaults.data(forKey: key + ".destination") {
                guard let saved = try? JSONDecoder().decode(LeonBlogExporter.Destination.self, from: data), saved == destination else {
                    throw ClientError.message("未完成归档的资料库与当前显示不一致，请重新打开导出窗口。")
                }
            }
            ChatPreferences.defaults.set(try JSONEncoder().encode(destination), forKey: key + ".destination")
            ChatPreferences.defaults.set(id, forKey: key)
            // A previous attempt may have saved the article before its readback or context reset failed.
            // Verify it before requesting another summary or downloading now-unavailable source files.
            var saved: LeonBlogExporter.Saved?
            if pendingID != nil { saved = try await Task.detached { try LeonBlogExporter.savedArchive(id: id, destination: destination) }.value }
            if saved == nil {
                let operation = try await api.archiveRound(conversation: room, agentId: agentId, requestId: id)
                if connection == connectionId, room == selectedConversationId { contextOperations.removeAll { $0.agentId == agentId }; contextOperations.append(operation); beginPolling() }
                var archive = try await api.archive(id)
                let deadline = Date().addingTimeInterval(900)
                while archive.operation.active, Date() < deadline {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    archive = try await api.archive(id)
                }
                if archive.operation.status == "FAILED" { clearPendingArchive(key) }
                guard archive.operation.status == "SUCCEEDED", !archive.summary.isEmpty else { throw ClientError.message(archive.operation.error.isEmpty ? "总结尚未完成，可稍后重试导出；当前上下文保留。" : archive.operation.error) }
                exportProgress = "正在复制图片和文档到 LeonBook…"
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("leon-archive-files-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: directory) }
                var files: [String: URL] = [:], documents: [String: URL] = [:]
                for image in LeonBlogExporter.images(in: archive) {
                    guard UUID(uuidString: image.id) != nil else { throw ClientError.message("归档图片标识无效。") }
                    let data = try await api.imageData(image.id)
                    let file = directory.appendingPathComponent(image.id + ".jpg")
                    try data.write(to: file, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    files[image.id] = file
                }
                for document in LeonBlogExporter.documents(in: archive) {
                    guard UUID(uuidString: document.id) != nil else { throw ClientError.message("归档文档标识无效。") }
                    let name = (document.name as NSString).lastPathComponent
                    guard !name.isEmpty, name != ".", name != "..", name != "/" else { throw ClientError.message("归档文档文件名无效。") }
                    let folder = directory.appendingPathComponent(document.id, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    let data = try await api.document(document.id, favorite: nil)
                    let file = folder.appendingPathComponent(name)
                    try data.write(to: file, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    documents[document.id] = file
                }
                let snapshot = archive, images = files, documentFiles = documents
                saved = try await Task.detached { try LeonBlogExporter.export(snapshot, destination: destination, imageFiles: images, documentFiles: documentFiles) }.value
            }
            guard let saved else { throw ClientError.message("LeonBook 尚未确认归档已保存，当前上下文已保留。") }
            exportProgress = "已保存 LeonBook 草稿「" + saved.title + "」"
            if startNew {
                let updated = try await api.finishArchive(id)
                if connection == connectionId, room == selectedConversationId { contextInfo = updated }
                exportProgress += "，已开始全新上下文。"
            }
            clearPendingArchive(key)
            if connection == connectionId, room == selectedConversationId { beginPolling() }
            return true
        } catch {
            if case ClientError.archiveConflict = error { await discardChangedArchive(id: id, key: key, room: room, api: api) }
            exportError = friendly(error)
            exportProgress = exportProgress.hasPrefix("已保存") ? exportProgress + "；尚未开始新对话。" : "归档未完成，当前上下文保留。"
            return false
        }
    }
    @Published var contextInfo: ConversationContext?
    @Published var contextError: String?
    @Published var contextOperations: [ContextOperation] = [] {
        didSet { cachedTimelineItems = nil }
    }
    @Published var compressionRequestBusy = false
    private var compressionRequests: [String: String] = [:]
    var contextActionActive: Bool { compressionRequestBusy || jobs.contains { $0.status == "PENDING" || $0.status == "RUNNING" } || contextOperations.contains { $0.active } }
    enum CommandSheet {
        case archive(exportOnly: Bool), context, clearHistory
    }

    func performCommand(_ command: ChatCommand, library: LeonBlogExporter.Destination? = nil,
                        present: (CommandSheet) -> Void = { _ in }) async {
        guard hasConnection else { error = "请先连接服务器"; return }
        if command == .context { draft = ""; present(.context); return }
        if command == .clear {
            guard !exportBusy, !preparingImages, !currentPending.contains(where: { sending.contains($0.id) }) else { error = "请等待归档、图片处理和发送完成后再清空。"; return }
            draft = ""; present(.clearHistory); return
        }
        if command == .newRound || command == .exportRound {
            guard draftImages.isEmpty, !preparingImages, currentPending.isEmpty else { error = "请先处理待发送消息和图片，再结束或导出本轮。"; return }
            draft = ""
            if command == .exportRound, availableAgents.count == 1 {
                let selection = ArchiveSelection(scope: conversationScope, agentID: availableAgents[0].id, library: library)
                do {
                    let prepared = try await prepareArchive(selection)
                    if prepared.pendingID != nil {
                        present(.archive(exportOnly: true))
                        return
                    }
                    if !(await exportCurrentRound(prepared, startNew: false)) { error = exportError }
                } catch is CancellationError {
                    return
                } catch {
                    exportError = friendly(error)
                    self.error = exportError
                }
            } else {
                present(.archive(exportOnly: command == .exportRound))
            }
            return
        }
        guard draftImages.isEmpty, !preparingImages else { error = "请先发送或移除待发送图片，再执行压缩命令。"; return }
        draft = ""
        if availableAgents.count == 1 { await compactContext(agentId: availableAgents[0].id) }
        else { present(.context) }
    }
    func compactContext(agentId: String, presentsErrorsInSheet: Bool = false) async {
        guard let api, !compressionRequestBusy else { return }
        guard !contextActionActive else { contextError = "请等待当前会话回复或压缩完成后再压缩上下文"; if !presentsErrorsInSheet { error = contextError }; return }
        let connection = connectionId, room = selectedConversationId
        let scope = room + ":" + agentId
        let requestId = compressionRequests[scope] ?? UUID().uuidString.lowercased()
        compressionRequests[scope] = requestId
        compressionRequestBusy = true; contextError = nil
        defer { compressionRequestBusy = false }
        do {
            let operation = try await api.compactContext(conversation: room, agentId: agentId, requestId: requestId)
            guard connection == connectionId else { return }
            compressionRequests.removeValue(forKey: scope)
            if room == selectedConversationId {
                contextOperations.removeAll { $0.agentId == operation.agentId }
                contextOperations.append(operation)
                beginPolling()
            }
        } catch {
            if connection == connectionId, room == selectedConversationId {
                contextError = friendly(error)
                if !presentsErrorsInSheet { self.error = contextError }
            }
        }
    }
    @Published var contextBusy = false
    func loadContext() async {
        guard let api else { return }
        let connection = connectionId, room = selectedConversationId
        contextBusy = true; contextError = nil
        defer { contextBusy = false }
        do {
            let info = try await api.context(conversation: room)
            guard connection == connectionId, room == selectedConversationId else { return }
            contextInfo = info
        } catch { if connection == connectionId, room == selectedConversationId { contextError = friendly(error) } }
    }
    func configureContext(rounds: Int, reset: Bool) async {
        guard let api else { return }
        let connection = connectionId, room = selectedConversationId
        contextBusy = true; contextError = nil
        defer { contextBusy = false }
        do {
            let info = try await api.configureContext(conversation: room, rounds: rounds, reset: reset)
            if reset, connection == connectionId { clearPendingArchives(room: room) }
            guard connection == connectionId, room == selectedConversationId else { return }
            contextInfo = info
            beginPolling()
        } catch { if connection == connectionId, room == selectedConversationId { contextError = friendly(error) } }
    }
    @Published private(set) var avatarSessionKey = UUID().uuidString
    func avatarId(for agentId: String?) -> String { agents.first { $0.id == agentId }?.avatarId ?? "alfred" }
    func avatarData(_ id: String) async -> Data? { guard let api else { return nil }; return try? await api.avatarData(id) }
    private var connectionId = UUID()
    private var drafts: [String:String] = [:]
    private struct RoomSnapshot {
        let messages: [Message]
        let jobs: [AgentJob]
        let operations: [ContextOperation]
        let context: ConversationContext?
        let loaded: Bool
        let hasOlder: Bool
        let historyRevision: Int64?
    }
    private var roomCache: [String: RoomSnapshot] = [:]
    private var roomCacheOrder: [String] = []
    private var navigationRequest = UUID()
    @Published private var unconfirmedDirectRooms = Set<String>()
    var openingDirectConversation: Bool { unconfirmedDirectRooms.contains(selectedConversationId) }
    private struct DirectCreation {
        let id = UUID()
        let task: Task<Conversation, Error>
    }
    private struct DirectSelection {
        let agentId: String
        let room: Conversation
        let connection: UUID
        let navigation: UUID
        let creation: DirectCreation
    }
    private var directCreations: [String: DirectCreation] = [:]
    // Known private conversations live under their Agent, so each Agent has one entry.
    var sidebarConversations: [Conversation] {
        conversations.filter { room in room.kind != "direct" || !agents.contains { $0.id == room.agentId } }
    }
    var sidebarAgents: [AgentInfo] {
        agents.filter { agent in agent.enabled || conversations.contains { $0.kind == "direct" && $0.agentId == agent.id } }
    }
    func isSelected(_ agent: AgentInfo) -> Bool { selectedConversation?.kind == "direct" && selectedConversation?.agentId == agent.id }
    private func rememberRoom() {
        let range=ConversationScrollPosition.cacheRange(ids:messageIDs,anchor:scrollPositions[selectedConversationId]?.messageID)
        let kept=Array(messages[range])
        roomCache[selectedConversationId] = RoomSnapshot(messages: kept, jobs: jobs, operations: contextOperations,
            context: contextInfo, loaded: initialLoaded || !messages.isEmpty, hasOlder: hasOlder || range.lowerBound>0, historyRevision: historyRevision)
        roomCacheOrder.removeAll { $0 == selectedConversationId }; roomCacheOrder.append(selectedConversationId)
        while roomCacheOrder.count > 12 {let evicted=roomCacheOrder.removeFirst();roomCache.removeValue(forKey:evicted);scrollPositions.removeValue(forKey:evicted)}
    }
    var currentPending: [Outgoing] { pending.filter { ($0.conversationId ?? "shared") == selectedConversationId } }
    var selectedConversation: Conversation? { conversations.first { $0.id == selectedConversationId } }
    var title: String { selectedConversation?.name ?? "设备群聊" }
    var availableAgents: [AgentInfo] { agents.filter { $0.enabled && (selectedConversation?.agentIds.contains($0.id) ?? (selectedConversationId == "shared")) } }

    func selectConversation(_ id: String, refresh: Bool = true) {
        guard !deletedConversationIDs.contains(id) else { return }
        agentDetailId = nil
        navigationRequest = UUID()
        guard id != selectedConversationId else { return }
        rememberRoom()
        quoteDrafts[selectedConversationId]=quotedMessage
        drafts[selectedConversationId] = draft
        imageDrafts[selectedConversationId] = draftImages;documentDrafts[selectedConversationId]=draftDocuments
        selectedConversationId = id
        quotedMessage=quoteDrafts[id]
        draft = drafts[id] ?? ""
        draftImages = imageDrafts[id] ?? [];draftDocuments=documentDrafts[id] ?? []
        generation = UUID(); contextError = nil; loadingOlder = false
        let cached = roomCache[id]
        historyRevision = cached?.historyRevision
        contextInfo = cached?.context; contextOperations = cached?.operations ?? []
        messages = cached?.messages ?? []; jobs = cached?.jobs ?? []
        initialLoaded = cached?.loaded ?? false; hasOlder = cached?.hasOlder ?? false
        loadingMessages = openingDirectConversation || (!initialLoaded && hasConnection && active)
        if refresh { beginPolling() } else { poller?.cancel() }
    }
    func mention(_ agent: AgentInfo) { draft += (draft.isEmpty || draft.last?.isWhitespace == true ? "" : " ") + "@\(agent.handle) " }
    /// Selection happens during the button action; network work never delays click feedback.
    func selectAgent(_ agent: AgentInfo) {
        guard let selection = prepareDirectSelection(agent) else { return }
        Task { await finishDirectSelection(selection) }
    }
    func openDirect(_ agent: AgentInfo) async {
        guard let selection = prepareDirectSelection(agent) else { return }
        await finishDirectSelection(selection)
    }
    private func prepareDirectSelection(_ agent: AgentInfo) -> DirectSelection? {
        let known = conversations.first(where: { $0.kind == "direct" && $0.agentId == agent.id })
        if let known, !unconfirmedDirectRooms.contains(known.id) {
            selectConversation(known.id); return nil
        }
        guard let api else { error = "请先连接服务器"; return nil }
        // A deleted default room must never be selected again, even as a temporary placeholder.
        let defaultID = "direct:" + agent.id
        let placeholderID = deletedConversationIDs.contains(defaultID) ? "opening:" + UUID().uuidString : defaultID
        let room = known ?? Conversation(id: placeholderID, name: agent.name, kind: "direct", agentId: agent.id, agentIds: [agent.id])
        unconfirmedDirectRooms.insert(room.id)
        if known == nil { conversations.append(room) }
        selectConversation(room.id, refresh: false)
        error = nil; loadingMessages = true; status = "正在打开私聊…"
        let creation: DirectCreation
        if let existing = directCreations[agent.id] { creation = existing }
        else {
            creation = DirectCreation(task: Task { try await api.direct(agent.id) })
            directCreations[agent.id] = creation
        }
        return DirectSelection(agentId: agent.id, room: room, connection: connectionId, navigation: navigationRequest, creation: creation)
    }
    private func finishDirectSelection(_ selection: DirectSelection) async {
        defer {
            if directCreations[selection.agentId]?.id == selection.creation.id { directCreations.removeValue(forKey: selection.agentId) }
        }
        do {
            let room = try await selection.creation.task.value
            guard !Task.isCancelled, selection.connection == connectionId, !deletedConversationIDs.contains(room.id) else { return }
            if let index = conversations.firstIndex(where: { $0.id == room.id }) { conversations[index] = room }
            else { conversations.append(room) }
            unconfirmedDirectRooms.remove(selection.room.id)
            if selection.room.id != room.id { conversations.removeAll { $0.id == selection.room.id } }
            guard navigationRequest == selection.navigation, selectedConversationId == selection.room.id else { return }
            if selectedConversationId != room.id { selectConversation(room.id) }
            else { beginPolling() }
        } catch {
            guard !Task.isCancelled, selection.connection == connectionId,
                  navigationRequest == selection.navigation, selectedConversationId == selection.room.id else { return }
            loadingMessages = false; status = "私聊打开失败，点击此 Agent 可重试"
            self.error = friendly(error)
        }
    }
    func createGroup(name: String, agentIds: [String]) async -> Bool {
        guard let api else { return false }
        let connection = connectionId
        do {
            let room = try await api.group(name: name, agentIds: agentIds); let rooms = try await api.conversations()
            guard connection == connectionId else { return false }
            conversations = rooms; selectConversation(room.id)
            return true
        }
        catch { self.error = friendly(error); return false }
    }
    func retryJob(_ job: AgentJob) async {
        guard let api else { return }
        do { try await api.retryJob(job); beginPolling() } catch { self.error = friendly(error) }
    }
    @Published var status = "尚未连接"
    @Published var error: String?
    @Published var connected = false
    @Published var hasOlder = false
    @Published var loadingOlder = false
    @Published var loadingMessages = false
    @Published var sending = Set<String>()
    @Published var configuring = false
    @Published private(set) var needsConnectionSetup = false
    @Published var address = ChatPreferences.defaults.string(forKey: "server") ?? "https://121.40.254.112"
    @Published var sender = ChatPreferences.defaults.string(forKey: "sender") ?? Host.current().localizedName ?? "我的 Mac"
    let deviceId: String
    private var api: MessageAPI?
    private var poller: Task<Void, Never>?
    private var directoryRefresh: Task<Void, Never>?
    private var lastDirectoryRefresh: Date?
    private var generation = UUID()
    private var pendingKey = ""
    private var active = true
    private var initialLoaded = false
    var hasConnection: Bool { api != nil }

    init(api: MessageAPI? = nil) {
        self.api = api
        deviceId = ChatPreferences.defaults.string(forKey: "deviceId") ?? UUID().uuidString.lowercased()
        ChatPreferences.defaults.set(deviceId, forKey: "deviceId")
    }

    func start() async {
        guard api == nil, !configuring else { return }
        status = "正在读取安全存储…"
        let token = await Keychain.read()
        guard api == nil, !configuring else { return }
        guard !token.isEmpty else { needsConnectionSetup = true; return }
        do {
            let base = try Endpoint.normalize(address)
            clearChatImages()
            api = MessageAPI(base: base, token: token)
            restorePending(base: base, token: token)
            status = "正在连接…"
            beginPolling()
        } catch { self.error = friendly(error); needsConnectionSetup = true }
    }

    func configure(address: String, token: String, sender: String) async -> Bool {
        guard !configuring else { return false }
        configuring = true
        defer { configuring = false }
        do {
            let base = try Endpoint.normalize(address)
            let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = sender.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !secret.isEmpty, secret.utf8.count <= 900, !secret.contains(where: { $0.isWhitespace }),
                  !secret.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !name.isEmpty, name.utf16.count <= 60, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ClientError.message("请填写访问令牌和 1–60 字的设备名称。")
            }
            guard sending.isEmpty else { throw ClientError.message("请等待正在发送的消息完成，再切换连接。") }
            let candidate = MessageAPI(base: base, token: secret)
            let page = try await candidate.page()
            let directory = try await candidate.agents()
            let rooms = try await candidate.conversations()
            try await Keychain.save(secret)
            generation = UUID(); connectionId = UUID(); avatarSessionKey = UUID().uuidString
            deletingConversation = false; deletedConversationIDs = []; directoryRevision = UUID()
            agentDetailId = nil; creatingAgentConversation = false
            modelUsage = []; usageError = nil; usageLoadedAt = nil; usageBusy = false
            scrollPositions=[:];navigationRequest = UUID(); roomCache = [:]; roomCacheOrder = []
            for creation in directCreations.values { creation.task.cancel() }
            directCreations = [:]; unconfirmedDirectRooms = []
            directoryRefresh?.cancel(); directoryRefresh = nil; lastDirectoryRefresh = Date()
            quotedMessage=nil;quoteDrafts=[:];favoriteRequests=[];collectionNotice=""
            documentGeneration=UUID();importingDocuments=false;draftDocuments=[];documentDrafts=[:]
            selectedConversationId = "shared"; drafts = [:]; imageDrafts = [:]; draftImages = []; contextInfo = nil; contextError = nil; contextOperations = []; compressionRequests = [:]
            agents = directory; conversations = rooms; jobs = page.jobs ?? []
            poller?.cancel()
            clearChatImages()
            api = candidate
            self.address = base.absoluteString
            self.sender = name
            ChatPreferences.defaults.set(self.address, forKey: "server")
            ChatPreferences.defaults.set(name, forKey: "sender")
            restorePending(base: base, token: secret)
            messages = Self.sortedUniquePage(page.messages)
            historyRevision = page.historyRevision
            initialLoaded = true
            hasOlder = page.hasMore
            reconcilePending(with: messages)
            draft = ""
            connected = true
            status = "已连接 · 自动同步"
            error = nil
            needsConnectionSetup = false
            beginPolling()
            return true
        } catch { self.error = friendly(error); return false }
    }

    func setActive(_ value: Bool) {
        active = value
        if value { beginPolling() } else { poller?.cancel(); directoryRefresh?.cancel(); status = "已暂停 · 返回后自动同步"; connected = false; loadingMessages = false }
    }

    func reconnect() { beginPolling() }

    private func refreshDirectoryIfNeeded() {
        guard directoryRefresh == nil, let api,
              lastDirectoryRefresh.map({ Date().timeIntervalSince($0) >= 10 }) ?? true else { return }
        let connection = connectionId
        let revision = directoryRevision, knownIDs = Set(conversations.map(\.id))
        lastDirectoryRefresh = Date()
        directoryRefresh = Task { [weak self] in
            guard let self else { return }
            defer { if connection == self.connectionId { self.directoryRefresh = nil } }
            async let agents = api.agents()
            async let rooms = api.conversations()
            async let presence: Void? = try? api.heartbeat(deviceId: self.deviceId, name: self.sender)
            do {
                let (directory, conversations) = try await (agents, rooms)
                guard !Task.isCancelled, connection == self.connectionId, revision == self.directoryRevision else { return }
                if self.agents != directory { self.agents = directory }
                var updated = conversations.filter { !self.deletedConversationIDs.contains($0.id) }
                for room in self.conversations where (!knownIDs.contains(room.id) || self.unconfirmedDirectRooms.contains(room.id)) && !updated.contains(where: { $0.id == room.id }) {
                    updated.append(room)
                }
                let updatedIDs = Set(updated.map(\.id))
                let outboxRooms = Set(self.pending.map { $0.conversationId ?? "shared" }).subtracting(["shared"])
                let removed = knownIDs.union(outboxRooms).subtracting(updatedIDs)
                if self.conversations != updated { self.conversations = updated }
                for room in removed { self.removeConversationLocally(room) }
            } catch { /* Directory refresh must not block the selected conversation. */ }
            _ = await presence
        }
    }

    private func beginPolling() {
        poller?.cancel()
        if openingDirectConversation {
            let creating = selectedConversation?.agentId.flatMap { directCreations[$0] } != nil
            loadingMessages = creating
            status = creating ? "正在打开私聊…" : "私聊未打开，点击此 Agent 可重试"
            return
        }
        guard active, let api else { return }
        let current = generation, conversation = selectedConversationId
        loadingMessages = !initialLoaded
        refreshDirectoryIfNeeded()
        poller = Task { [weak self] in
            var delay: UInt64 = 2
            while !Task.isCancelled {
                guard let self, self.generation == current else { return }
                do {
                    let initial = !self.initialLoaded
                    let page = try await api.page(conversation: conversation, after: initial ? nil : self.messages.last?.id ?? 0)
                    guard !Task.isCancelled, self.generation == current else { return }
                    self.receiveHistoryRevision(page.historyRevision)
                    if initial { self.hasOlder = page.hasMore; self.initialLoaded = true }
                    self.receiveJobs(page.jobs ?? [])
                    let operations = page.contextOperations ?? []
                    if self.contextOperations != operations { self.contextOperations = operations }
                    self.receiveMessages(page.messages)
                    if self.loadingMessages { self.loadingMessages = false }
                    if !self.connected { self.connected = true }
                    if self.status != "已连接 · 自动同步" { self.status = "已连接 · 自动同步" }
                    self.refreshDirectoryIfNeeded()
                    delay = 2
                    if !initial && page.hasMore { continue }
                } catch {
                    guard !Task.isCancelled, self.generation == current else { return }
                    self.loadingMessages = false
                    self.connected = false
                    self.status = self.friendly(error)
                    delay = min(delay * 2, 30)
                }
                do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
            }
        }
    }

    func loadOlder() async {
        guard let api, let first = messages.first, hasOlder, !loadingOlder else { return }
        let current = generation
        loadingOlder = true
        defer { if current == generation { loadingOlder = false } }
        do {
            let page = try await api.page(conversation: selectedConversationId, before: first.id)
            guard current == generation else { return }
            if let revision = page.historyRevision, let previous = historyRevision, revision != previous {
                receiveHistoryRevision(revision); generation = UUID(); initialLoaded = false; beginPolling(); return
            }
            receiveHistoryRevision(page.historyRevision)
            receiveMessages(page.messages)
            hasOlder = page.hasMore
        } catch { if current == generation { self.error = friendly(error) } }
    }

    func sendDraft(library: LeonBlogExporter.Destination? = nil, present: (CommandSheet) -> Void = { _ in }) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        if quotedMessage == nil,draftDocuments.isEmpty, let command = ChatCommand.exact(text) { await performCommand(command, library: library, present: present); return }
        if quotedMessage == nil,draftDocuments.isEmpty, ChatCommand.isAttempt(text) { error = "请选择 / 菜单中的有效命令，命令无需附加文字。"; return }
        do {for doc in draftDocuments {try DocumentFiles.save(doc,scope:pendingKey)}; for image in draftImages { try ChatImageFiles.save(image, scope: pendingKey) } }
        catch { self.error = "无法保存图片，请检查磁盘空间后重试。"; return }
        let message = Outgoing(clientMessageId: UUID().uuidString.lowercased(), deviceId: deviceId, sender: sender, platform: "macos", text: text, conversationId: selectedConversationId, mentionAgentIds: [], imageIds: draftImages.map(\.id), quoteMessageId:quotedMessage?.id, documentIds:draftDocuments.map(\.id), quote:quotedMessage, documents:draftDocuments.map(\.attachment))
        pending.append(message)
        savePending()
        quotedMessage=nil;quoteDrafts.removeValue(forKey:selectedConversationId)
        draft = ""; draftImages = []; imageDrafts[selectedConversationId] = [];draftDocuments=[];documentDrafts[selectedConversationId]=[]
        await retry(message)
    }

    func retry(_ message: Outgoing) async {
        guard let api, !configuring, !sending.contains(message.id) else { return }
        let current = connectionId
        sending.insert(message.id)
        defer { sending.remove(message.id) }
        do {
            for document in message.documents ?? [] {
                let data=try DocumentFiles.read(document.id,scope:pendingKey)
                guard current==connectionId else {return};try await api.uploadDocument(document,room:message.conversationId ?? "shared",data:data)
            }
            for id in message.imageIds ?? [] {
                if let data = ChatImageFiles.read(id, scope: pendingKey) {
                    _ = try await api.uploadImage(id: id, conversation: message.conversationId ?? "shared", data: data)
                }
            }
            // Sending must not advance the receive cursor: fetch all intervening messages first.
            _ = try await api.send(message)
            guard current == connectionId else { return }
            pending.removeAll { $0.id == message.id }
            savePending()
            ChatImageFiles.remove(message.imageIds ?? [], scope: pendingKey);DocumentFiles.remove(message.documentIds ?? [],scope:pendingKey)
            beginPolling()
        } catch { if current == connectionId { self.error = friendly(error) } }
    }

    private static func sortedUniquePage(_ messages: [Message]) -> [Message] {
        if zip(messages, messages.dropFirst()).allSatisfy({ $0.id < $1.id }) { return messages }
        let byID = Dictionary(messages.lazy.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        return byID.values.sorted { $0.id < $1.id }
    }

    private func receiveMessages(_ page: [Message]) {
        guard !page.isEmpty else { return }
        let incoming = Self.sortedUniquePage(page)
        if messages.last.map({ $0.id < incoming[0].id }) ?? true {
            messages.append(contentsOf: incoming)
        } else if let first = messages.first, incoming[incoming.count - 1].id < first.id {
            messages.insert(contentsOf: incoming, at: 0)
        } else {
            var byID = Dictionary(uniqueKeysWithValues: messages.lazy.map { ($0.id, $0) })
            for message in incoming { byID[message.id] = message }
            let merged = byID.values.sorted { $0.id < $1.id }
            if messages != merged { messages = merged }
        }
        reconcilePending(with: incoming)
    }

    private func reconcilePending(with received: [Message]) {
        guard !pending.isEmpty, !received.isEmpty else { return }
        let confirmed = Set(received.lazy.filter { $0.deviceId == self.deviceId }.map(\.clientMessageId))
        guard !confirmed.isEmpty else { return }
        let count = pending.count
        for message in pending where confirmed.contains(message.clientMessageId) { ChatImageFiles.remove(message.imageIds ?? [], scope: pendingKey);DocumentFiles.remove(message.documentIds ?? [],scope:pendingKey) }
        pending.removeAll { confirmed.contains($0.clientMessageId) }
        if count != pending.count { savePending() }
    }
    private func restorePending(base: URL, token: String) {
        pendingKey = "outbox." + SHA256.hash(data: Data((base.absoluteString + "\n" + token).utf8)).map { String(format: "%02x", $0) }.joined()
        pending = ChatPreferences.defaults.data(forKey: pendingKey).flatMap { try? JSONDecoder().decode([Outgoing].self, from: $0) } ?? []
        dismissedJobKeys = Set(ChatPreferences.defaults.stringArray(forKey: pendingKey + ".dismissedJobs") ?? [])
    }
    private func savePending() { ChatPreferences.defaults.set(try? JSONEncoder().encode(pending), forKey: pendingKey) }
    private func friendly(_ error: Error) -> String {
        if error is ClientError { return error.localizedDescription }
        if let e = error as? URLError, e.code == .cancelled { return "请求已取消" }
        return "连接未完成，请检查服务地址、网络及 HTTPS 证书后重试。"
    }
}
