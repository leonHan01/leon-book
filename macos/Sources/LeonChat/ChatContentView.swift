import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var store: ChatStore
    let archiveLibrary: LeonBlogExporter.Destination?
    @Environment(\.controlActiveState) private var activeState
    @State private var archiveSheet: ArchiveSheet?
    @State private var showSettings = false
    @State private var offeredConnectionSetup = false
    @State private var showNewGroup = false
    @State private var showContext = false
    @State private var showUsage = false
    @State private var showClearHistory = false
    @State private var branchMessage: Message?
    @State private var conversationToDelete: Conversation?
    @State private var historyAgentId: String?
    @StateObject private var viewport=ConversationViewport()
    @State private var searchPresented = false
    @State private var favoritesPresented = false
    @State private var searchRoom: String?
    @State private var searchTitle = "全部聊天记录"
    private let accent = Color(red: 0.18, green: 0.36, blue: 0.89)
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.bubble.right.fill").font(.title2).foregroundStyle(accent)
                    Text("Leon").font(.system(size: 25, weight: .bold, design: .rounded))
                }.padding(.top, 28)
                Button { searchRoom = nil; searchTitle = "全部聊天记录"; searchPresented = true } label: {
                    Label("搜索聊天记录", systemImage: "magnifyingglass").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(9)
                        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).disabled(!store.hasConnection).keyboardShortcut("f", modifiers: [.command, .shift])
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("会话").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { showNewGroup = true } label: { Image(systemName: "plus.bubble") }
                                .buttonStyle(.borderless).disabled(!store.hasConnection).help("新建群聊")
                        }
                        if store.conversations.isEmpty { Text("连接后显示会话").font(.caption).foregroundStyle(.secondary) }
                        ForEach(store.sidebarConversations) { room in
                            Button { store.selectConversation(room.id) } label: {
                                HStack(spacing: 8) {
                                    if room.kind == "direct" { AgentAvatarView(store: store, avatarId: store.avatarId(for: room.agentId), size: 28) }
                                    else { Image(systemName: "number").frame(width: 28) }
                                    Text(room.name).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(10).contentShape(Rectangle())
                                    .background(store.selectedConversationId == room.id ? accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain)
                        }
                        Text("AGENTS · 私聊").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 18)
                        ForEach(store.sidebarAgents) { agent in
                            Button {
                                historyAgentId = agent.id
                                store.selectAgent(agent)
                            } label: {
                                HStack(spacing: 9) {
                                    AgentAvatarView(store: store, avatarId: agent.avatarId ?? "alfred")
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(agent.name).lineLimit(1)
                                        Text("@\(agent.handle) · \(agent.enabled ? agent.provider : "已停用")").font(.system(size: 10)).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.padding(9).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    .background((store.agentDetailId == agent.id || store.agentDetailId == nil && store.isSelected(agent)) ? accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                SidebarFooter(
                    hasConnection: store.hasConnection,
                    openFavorites: { favoritesPresented = true },
                    openUsage: { showUsage = true },
                    openSettings: { showSettings = true }
                )
            }.padding(.horizontal, 20).frame(width: 208).frame(maxHeight: .infinity).background(.regularMaterial)
            Divider()
            if let agentId = store.agentDetailId {
                AgentDetailView(store: store, agentId: agentId, onDelete: { conversationToDelete = $0 }).id(agentId)
            } else {
            if let agentId = historyAgentId, let agent = store.agents.first(where: { $0.id == agentId }) {
                AgentConversationSidebar(store: store, agent: agent, onDelete: { conversationToDelete = $0 }).id(agentId)
                Divider()
            }
            VStack(spacing: 0) {
                HStack {
                    if store.selectedConversation?.kind == "direct" {
                        Button { if let agent = store.agents.first(where: { $0.id == store.selectedConversation?.agentId }) { store.showAgentDetails(agent) } } label: {
                            AgentAvatarView(store: store, avatarId: store.avatarId(for: store.selectedConversation?.agentId), size: 42)
                        }.buttonStyle(.plain).accessibilityLabel("查看 Agent 详情").help("查看 Agent 详情")
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.title).font(.system(size: 19, weight: .semibold))
                        HStack(spacing: 6) {
                            Circle().fill(store.connected ? .green : .orange).frame(width: 6, height: 6)
                            Text(store.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    Button { present(.archive(exportOnly: false)) } label: { Label("新对话", systemImage: "plus.bubble") }
                        .disabled(!store.hasConnection || store.exportBusy || store.openingDirectConversation).help("结束本轮，可导出到 LeonBook 后开始新对话")
                    Button { searchRoom = store.selectedConversationId; searchTitle = store.title; searchPresented = true } label: { Image(systemName: "magnifyingglass") }
                        .disabled(!store.hasConnection || store.openingDirectConversation).help("查找聊天记录").keyboardShortcut("f", modifiers: .command)
                    Button { showContext = true } label: { Label("上下文", systemImage: "brain") }
                        .disabled(!store.hasConnection || store.openingDirectConversation).help("查看对话摘要与上下文设置")
                    Button { store.reconnect() } label: { Image(systemName: "arrow.clockwise") }.help("立即同步")
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }.help("连接设置")
                }.buttonStyle(.borderless).padding(.horizontal, 26).padding(.vertical, 24)
                Divider()
                timeline
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if store.selectedConversation?.kind != "direct" {
                        HStack {
                            Menu("@ Agent") {
                                ForEach(store.availableAgents) { agent in Button("\(agent.name)  @\(agent.handle)") { store.mention(agent) } }
                            }.disabled(store.availableAgents.isEmpty)
                            Text("只有被 @ 的 Agent 会回复").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                    } else { Text("私聊 · Agent 将直接回复").font(.caption).foregroundStyle(.secondary) }
                    if let quote=store.quotedMessage {QuoteCard(store:store,quote:quote,room:store.selectedConversationId,title:store.title,cancel:store.cancelQuote)}
                    DocumentDraftsView(store:store)
                    MentionComposer(store: store, onSend: send, onCommand: runCommand)
                    HStack {
                        DocumentPickerButton(store:store)
                        Text("/ 命令 · ↵ 发送 · Shift+↵ 换行 · 最多 8,000 字符").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if store.draft.utf16.count > 8000 { Text("已超出字数限制").font(.caption).foregroundStyle(.red) }
                        Button(action: send) {
                            Label("发送", systemImage: "arrow.up").padding(.horizontal, 10)
                        }.buttonStyle(.borderedProminent).tint(accent).keyboardShortcut(.return, modifiers: .command)
                            .disabled(!store.canSend)
                    }
                }.padding(20)
            }.background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .overlay(alignment:.bottom) {if !store.collectionNotice.isEmpty {Text(store.collectionNotice).foregroundStyle(.white).padding(12).background(.black.opacity(0.8),in:RoundedRectangle(cornerRadius:7)).padding(.bottom,90)}}
        .sheet(item:$branchMessage) {message in BranchConversationView(store:store,message:message,sourceName:store.title) {store.selectConversation($0.id)}}
        .sheet(isPresented:$favoritesPresented) {FavoritesView(store:store) {store.selectConversation($0)}}
        .sheet(isPresented: $searchPresented) {
            ChatSearchView(store: store, room: searchRoom, title: searchTitle) { id in store.selectConversation(id) }
        }
        .sheet(isPresented: $showSettings) { ConnectionView(store: store) }
        .sheet(isPresented: $showNewGroup) { NewGroupView(store: store) }
        .sheet(isPresented: $showContext) { ContextSettingsView(store: store) }
        .sheet(isPresented: $showUsage) { TokenUsageView(store: store) }
        .sheet(item: $archiveSheet) { sheet in
            EndRoundView(store: store, sheet: sheet, library: archiveLibrary)
        }
        .sheet(isPresented: $showClearHistory) { ClearHistoryView(store: store) }
        .sheet(item: $conversationToDelete) { room in DeleteConversationView(store: store, room: room) }
        .alert("暂未完成", isPresented: Binding(get: { activeState == .key && store.error != nil && !showSettings && !showNewGroup && !showContext && !showUsage && archiveSheet == nil && !showClearHistory && conversationToDelete == nil }, set: { if !$0 { store.error = nil } })) {
            Button("知道了") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .focusedSceneValue(\.leonChatActions, LeonChatActions(openSettings: { showSettings = true }, sync: store.reconnect))
        .onChange(of: store.needsConnectionSetup) { _ in offerConnectionSetup() }
        .onChange(of: activeState) { _ in offerConnectionSetup() }
        .onChange(of: store.searchConnectionID) { _ in
            branchMessage = nil
            conversationToDelete = nil
            showClearHistory = false
            showContext = false
        }
        .onAppear {
            offerConnectionSetup()
            historyAgentId = store.selectedConversation?.kind == "direct" ? store.selectedConversation?.agentId : nil
        }
        .onChange(of: store.selectedConversationId) { _ in
            branchMessage = nil
            showClearHistory = false
            showContext = false
            historyAgentId = store.selectedConversation?.kind == "direct" ? store.selectedConversation?.agentId : nil
        }
    }

    private func offerConnectionSetup() {
        guard store.needsConnectionSetup, activeState == .key, !offeredConnectionSetup else { return }
        offeredConnectionSetup = true
        showSettings = true
    }

    private func send() {
        Task { await store.sendDraft(library: archiveLibrary, present: present) }
    }

    private func runCommand(_ command: ChatCommand) {
        Task { await store.performCommand(command, library: archiveLibrary, present: present) }
    }

    private func present(_ sheet: ChatStore.CommandSheet) {
        switch sheet {
        case let .archive(exportOnly):
            archiveSheet = ArchiveSheet(scope: store.conversationScope, exportOnly: exportOnly)
        case .context: showContext = true
        case .clearHistory: showClearHistory = true
        }
    }

    private func beginBranch(_ message: Message) {
        guard store.hasConnection, message.id > 0, message.conversationId == store.selectedConversationId else { return }
        branchMessage = message
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if store.hasOlder {
                        Button(store.loadingOlder ? "正在加载…" : "加载更早的消息") { viewport.loadOlder();Task { await store.loadOlder() } }
                            .disabled(store.loadingOlder).buttonStyle(.borderless).padding(.top, 12)
                    }
                    if store.messages.isEmpty && store.currentPending.isEmpty && store.loadingMessages {
                        ProgressView("正在加载会话…").padding(.vertical, 80)
                    }
                    if store.messages.isEmpty && store.currentPending.isEmpty && !store.loadingMessages {
                        VStack(spacing: 14) {
                            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 44, weight: .light)).foregroundStyle(accent)
                            Text("从一句话开始").font(.title3.bold())
                            Text("选择 Agent 开始私聊，\n或在群聊中 @指定 Agent。").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 100)
                    }
                    ForEach(TimelineItem.ordered(messages: store.messages, operations: store.contextOperations, jobs: store.visibleJobs)) { item in
                        switch item {
                        case .message(let message):
                        bubble(text: message.text, sender: message.sender, detail: (message.role == "assistant" ? "Agent · " : "") + message.date.formatted(date: .abbreviated, time: .shortened), mine: message.deviceId == store.deviceId, agentId: message.agentId, imageIds: (message.images ?? []).map(\.id), message:message)
                            .id(message.id).timelineMessage(message.id)
                        case .operation(let operation):
                        HStack(alignment: .top) {
                            if operation.active { ProgressView().controlSize(.small) }
                            else { Image(systemName: operation.status == "FAILED" ? "exclamationmark.bubble" : "checkmark.circle") }
                            Text("\(operation.agentName) · \(operation.progressText)").font(.caption)
                            Spacer()
                            if operation.status == "FAILED", operation.kind != "ARCHIVE" {
                                Button("重试压缩") { Task { await store.compactContext(agentId: operation.agentId) } }
                                    .buttonStyle(.borderless).disabled(store.contextActionActive)
                            }
                            Button("查看摘要") { showContext = true }.buttonStyle(.borderless)
                        }.foregroundStyle(.secondary).padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                        case .job(let job):
                        HStack(alignment: .top) {
                            Image(systemName: job.status == "FAILED" ? "exclamationmark.bubble" : "ellipsis.bubble")
                            if job.status == "RUNNING" { ProgressView().controlSize(.small) }
                            Text("\(job.agentName) · \(job.progressText)").font(.caption)
                                .accessibilityLabel("\(job.agentName) · \(job.progressText)")
                            Spacer()
                            if job.status == "FAILED" {
                                Button("重试回复") { Task { await store.retryJob(job) } }.buttonStyle(.borderless)
                                Button { store.dismissJob(job) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.borderless)
                                    .help("忽略此失败提示（仅这台 Mac，保留原消息）")
                                    .accessibilityLabel("忽略 \(job.agentName) 的失败提示")
                            }
                        }.foregroundStyle(.secondary).padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                    ForEach(store.currentPending) { message in
                        VStack(alignment: .trailing, spacing: 6) {
                            bubble(text: message.text, sender: message.sender, detail: store.sending.contains(message.id) ? "发送中…" : "尚未确认送达服务器", mine: true, imageIds: message.imageIds ?? [], pendingQuote:message.quote,pendingDocuments:message.documents ?? [])
                            if !store.sending.contains(message.id) {
                                Button("重试发送") { Task { await store.retry(message) } }.buttonStyle(.borderless)
                            }
                        }
                    }
                    if store.exportRoomId == store.selectedConversationId, !store.exportProgress.isEmpty {
                        HStack {
                            if store.exportBusy { ProgressView().controlSize(.small) }
                            Text(store.exportProgress).font(.caption)
                            Spacer()
                        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                    }
                    if store.dismissedFailureCount > 0 {
                        Button("恢复已忽略的失败提示（\(store.dismissedFailureCount)）") { store.restoreDismissedJobs() }
                            .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                    }
                    Color.clear.frame(height: 1).id("bottom").timelineBottom()
                }.padding(.horizontal, 12).padding(.vertical, 14)
                    .timelineContent().trackConversationScroll(viewport)
            }.timelineViewport()
            .task(id:store.selectedConversationId) {enterTimeline(proxy)}
            .onDisappear {viewport.leave(room:store.selectedConversationId)}
            .onChange(of:store.searchConnectionID) {_ in enterTimeline(proxy)}
            .onPreferenceChange(TimelineLayoutKey.self) {layout in
                guard viewport.room==store.selectedConversationId else {return};viewport.geometryChanged(layout,loaded:!store.loadingMessages)
            }
            .onChange(of:store.messages.map(\.id)) {_ in
                if viewport.room != store.selectedConversationId {enterTimeline(proxy)}
                viewport.receivedRows(room:store.selectedConversationId,rows:store.messages.map(\.id),pending:store.currentPending.map(\.id),loaded:!store.loadingMessages)
            }
            .onChange(of:store.currentPending.map(\.id)) {viewport.pendingChanged($0)}
            .onChange(of:store.loadingMessages) {viewport.loadedChanged(!$0)}
        }
    }
    private func enterTimeline(_ proxy:ScrollViewProxy){
        let room=store.selectedConversationId,connection=store.searchConnectionID
        viewport.enter(room:room,position:store.scrollPositions[room],rows:store.messages.map(\.id),pending:store.currentPending.map(\.id),loaded:!store.loadingMessages,proxy:proxy,anchor:{AnyHashable($0)}) {[weak store=store] position in
            guard let store,store.selectedConversationId==room,store.searchConnectionID==connection else {return};store.scrollPositions[room]=position
        }
    }
    private func bubble(text: String, sender: String, detail: String, mine: Bool, agentId: String? = nil, imageIds: [String] = [], message:Message? = nil, pendingQuote:MessageQuote? = nil,pendingDocuments:[DocumentAttachment]=[]) -> some View {
        HStack {
            if mine { Spacer(minLength: 70) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
                HStack(spacing: 7) {
                    if let agentId, let agent = store.agents.first(where: { $0.id == agentId }) {
                        Button { store.showAgentDetails(agent) } label: {
                            AgentAvatarView(store: store, avatarId: store.avatarId(for: agentId), size: 28)
                        }.buttonStyle(.plain).help("查看 \(agent.name) 的详情")
                    }
                    Text(sender).font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(message?.documents ?? pendingDocuments){document in DocumentCard(store:store,document:document,message:message,onBranch:beginBranch)}
                    ForEach(imageIds, id: \.self) { id in ChatImageView(store: store, imageId: id,onQuote:message.map {m in {store.quoteMessage(m)}},onFavorite:message.map {m in {let _ = Task {await store.favoriteMessage(m)}}},onBranch:message.map {m in {beginBranch(m)}}) }
                    if !text.isEmpty { MarkdownMessageView(text, mine: mine, onQuote:message.map {m in {store.quoteMessage(m)}}, onFavorite:message.map {m in {let _ = Task {await store.favoriteMessage(m)}}},onBranch:message.map {m in {beginBranch(m)}}) }
                }.padding(.horizontal, 16).padding(.vertical, 12)
                    .foregroundStyle(mine ? Color.white : Color.primary)
                    .background(mine ? accent : Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        if !mine {
                            RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                        }
                    }
                if let quote=message?.quote ?? pendingQuote {QuoteCard(store:store,quote:quote,room:message?.conversationId ?? store.selectedConversationId,title:store.title)}
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }.frame(maxWidth: mine ? 540 : .infinity, alignment: mine ? .trailing : .leading)
                .contextMenu {
                    if let message {
                        Button("引用") {store.quoteMessage(message)}
                        Button("收藏") {Task {await store.favoriteMessage(message)}}
                        Button("从这里创建分支") {beginBranch(message)}
                    }
                }
        }
    }
}

@MainActor
final class ConnectionDraft: ObservableObject {
    @Published var address = ""
    @Published var token = ""
    @Published var sender = ""
}

struct ConnectionView: View {
    private enum Section: Hashable { case connection, notifications }
    @ObservedObject var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft = ConnectionDraft()
    @State private var section = Section.connection

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("设置").font(.title2.bold())
            Picker("设置分类", selection: $section) {
                Text("连接").tag(Section.connection)
                Text("通知").tag(Section.notifications)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(store.configuring)
            Group {
                if section == .connection {
                    connectionSettings
                } else {
                    NotificationSettingsView()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
            Divider()
            HStack {
                if section == .connection {
                    Button("取消") { store.error = nil; dismiss() }
                        .keyboardShortcut(.cancelAction).disabled(store.configuring)
                    Spacer()
                    if store.configuring { ProgressView().controlSize(.small) }
                    Button("验证并连接") {
                        Task {
                            if await store.configure(address: draft.address, token: draft.token, sender: draft.sender) {
                                dismiss()
                            }
                        }
                    }
                        .buttonStyle(.borderedProminent).disabled(store.configuring)
                } else {
                    Spacer()
                    Button("完成") { store.error = nil; dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }.padding(28).frame(width: 480)
        .task {
            draft.address = store.address; draft.sender = store.sender
            let token = await Keychain.read()
            if draft.token.isEmpty { draft.token = token }
        }
        .interactiveDismissDisabled(store.configuring)
    }

    private var connectionSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("填写服务器地址和访问令牌，连接你的聊天服务。")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("服务地址", text: $draft.address)
                SecureField("访问令牌", text: $draft.token)
                TextField("设备名称", text: $draft.sender)
            }.textFieldStyle(.roundedBorder)
            if let error = store.error { Text(error).font(.callout).foregroundStyle(.red) }
            Text("访问令牌安全保存在 macOS 钥匙串中。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor
final class GroupDraft: ObservableObject {
    @Published var name = ""
    @Published var agentIds = Set<String>()
    @Published var creating = false
}
struct NewGroupView: View {
    @ObservedObject var store: ChatStore
    @StateObject private var draft = GroupDraft()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("新建群聊").font(.title2.bold())
            TextField("群聊名称", text: $draft.name).textFieldStyle(.roundedBorder)
            Text("选择加入群聊的 Agent").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(store.agents.filter { $0.enabled }) { agent in
                        Toggle("\(agent.name)  @\(agent.handle)", isOn: Binding(get: { draft.agentIds.contains(agent.id) }, set: { if $0 { draft.agentIds.insert(agent.id) } else { draft.agentIds.remove(agent.id) } }))
                    }
                }
            }.frame(maxHeight: 240)
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("取消") { store.error = nil; dismiss() }.disabled(draft.creating)
                Spacer()
                Button(draft.creating ? "创建中…" : "创建群聊") {
                    draft.creating = true
                    Task {
                        defer { draft.creating = false }
                        if await store.createGroup(name: draft.name, agentIds: draft.agentIds.sorted()) { dismiss() }
                    }
                }.buttonStyle(.borderedProminent).disabled(draft.creating || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.name.utf16.count > 60 || draft.agentIds.count > 32)
            }
        }.padding(28).frame(width: 380).interactiveDismissDisabled(draft.creating)
    }
}


@MainActor
final class ContextDraft: ObservableObject {
    @Published var rounds = 10
    @Published var confirmReset = false
}
struct ContextSettingsView: View {
    @ObservedObject var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft = ContextDraft()
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("对话上下文 · \(store.title)").font(.title2.bold())
            Text("回复携带完整对话、已确认事实和相关历史原文；Token 接近预算时才尝试压缩。").font(.callout).foregroundStyle(.secondary)
            if store.contextBusy { ProgressView("正在处理…").controlSize(.small) }
            if let error = store.contextError { Text(error).font(.callout).foregroundStyle(.red) }
            if let info = store.contextInfo {
                Text(info.compressionMode == "token" ? "按 Token 预算管理上下文，不再按对话轮数自动压缩。" : "当前服务端尚未提供新版记忆策略，请升级服务端。").font(.caption).foregroundStyle(.secondary)
                Text("上下文输入预算：约 \(info.inputTokenBudget.formatted()) Token，另为回复预留空间。").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(info.agents) { agent in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text(agent.agentName).font(.headline)
                                    Spacer()
                                    Button("压缩上下文") { Task { await store.compactContext(agentId: agent.agentId, presentsErrorsInSheet: true) } }
                                        .disabled(store.contextActionActive || store.contextBusy)
                                }
                                if store.jobs.contains(where: { $0.agentId == agent.id && $0.status == "RUNNING" && $0.phase == "COMPRESSING" }) || store.contextOperations.contains(where: { $0.agentId == agent.id && $0.active }) { Label("上下文压缩中…", systemImage: "arrow.triangle.2.circlepath").font(.caption) }
                                if agent.estimatedInputTokens > 0 {
                                    Text("最近请求：携带 \(agent.retainedRounds) 轮原文，估算输入 \(agent.estimatedInputTokens.formatted()) Token").font(.caption).foregroundStyle(.secondary)
                                }
                                if agent.lastCompressedAt > 0 {
                                    Text("摘要更新于 " + Date(timeIntervalSince1970: Double(agent.lastCompressedAt) / 1000).formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                }
                                if let count = agent.retrievedRounds, count > 0 { Text("最近检索了 \(count) 轮相关历史原文").font(.caption).foregroundStyle(.secondary) }
                                if agent.compressionFallback == true { Text("最近请求使用了完整原文回退").font(.caption).foregroundStyle(.secondary) }
                                DisclosureGroup("已确认事实（\((agent.facts ?? []).count)）") {
                                    if (agent.facts ?? []).isEmpty { Text("压缩时提取有用户原文依据的事实。").font(.caption).foregroundStyle(.secondary) }
                                    ForEach(agent.facts ?? []) { fact in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("\(fact.speaker)：\(fact.value)").font(.callout).textSelection(.enabled)
                                            Text("来源消息 #\(fact.sourceMessageId)").font(.caption).foregroundStyle(.secondary)
                                        }.padding(.top, 4)
                                    }
                                }
                                DisclosureGroup("阶段摘要") {
                                    Text(agent.summary.isEmpty ? "尚未需要压缩，当前使用原始对话。" : agent.summary)
                                        .font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                                }
                                Divider()
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 100, maxHeight: 300)
                Text("可用 /compact 主动压缩，保留最近一轮原文。群聊请选择 Agent。开启新话题保留聊天记录；压缩失败且完整原文仍在预算内时，会使用原文继续回复。").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("开启新话题…") { draft.confirmReset = true }.disabled(store.contextInfo == nil || store.contextBusy || store.contextActionActive)
                Button("刷新") { Task { await store.loadContext() } }.disabled(store.contextBusy)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).disabled(store.contextBusy)
            }
        }.padding(28).frame(width: 560)
        .task { await store.loadContext(); draft.rounds = store.contextInfo?.recentRounds ?? 10 }
        .onChange(of: store.jobs.filter { $0.phase == "COMPRESSING" && $0.status == "RUNNING" }.count) { _ in
            if !store.contextBusy { Task { await store.loadContext() } }
        }
        .onChange(of: store.contextOperations.map { $0.id + $0.status }.joined()) { _ in
            if !store.contextBusy { Task { await store.loadContext() } }
        }
        .interactiveDismissDisabled(store.contextBusy)
        .alert("开启新话题？", isPresented: $draft.confirmReset) {
            Button("取消", role: .cancel) {}
            Button("开启新话题") { Task { await store.configureContext(rounds: draft.rounds, reset: true) } }
        } message: { Text("后续回复将从新的上下文开始，旧摘要和已确认事实不再使用。聊天记录不会删除。") }
    }
}


struct ArchiveSheet: Identifiable {
    let id = UUID()
    let scope: ChatStore.ConversationScope
    let exportOnly: Bool
}

struct EndRoundView: View {
    @ObservedObject var store: ChatStore
    let sheet: ArchiveSheet
    let library: LeonBlogExporter.Destination?
    @State private var agentID = ""
    @State private var prepared: ChatStore.PreparedArchive?
    @State private var loading = false
    @State private var submitting = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private var selection: ChatStore.ArchiveSelection {
        .init(scope: sheet.scope, agentID: agentID, library: library)
    }

    private var current: Bool { sheet.scope == store.conversationScope }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(sheet.exportOnly ? "导出本轮对话" : "结束本轮对话").font(.title2.bold())
            Text("LeonBook 文章会先展示 AI 总结，再展示本轮原始对话、引用、图片和文档，并附完整原文文件。文章保存为草稿。").foregroundStyle(.secondary)
            if !sheet.exportOnly { Text("归档成功后开始完全新的上下文。也可以仅开始新对话，历史记录保留。").font(.callout) }
            Picker("总结使用的 Agent", selection: $agentID) {
                Text("请选择 Agent").tag("")
                ForEach(store.availableAgents) { Text($0.name + " · " + $0.model).tag($0.id) }
            }.disabled(submitting || !current)
            if let prepared, prepared.selection == selection {
                Text("资料库：" + prepared.destination.root + " · 用户：" + prepared.destination.user)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if loading { ProgressView("正在读取资料库…").controlSize(.small) }
            if submitting { ProgressView(store.exportProgress).controlSize(.small) }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }.disabled(submitting)
                if !sheet.exportOnly {
                    Button("仅开始新对话") { Task { await submit(resetOnly: true) } }
                        .disabled(!current || store.exportBusy || store.contextActionActive)
                }
                Spacer()
                Button(sheet.exportOnly ? "导出到 LeonBook" : "导出并开始新对话") { Task { await submit() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!current || store.exportBusy || store.contextActionActive || loading || prepared?.selection != selection)
            }
        }.padding(28).frame(width: 600)
        .onAppear { if store.availableAgents.count == 1 { agentID = store.availableAgents[0].id } }
        .task(id: selection) { await loadDestination(for: selection) }
        .onChange(of: store.conversationScope) { _ in if !submitting { dismiss() } }
        .interactiveDismissDisabled(submitting)
    }

    private func loadDestination(for selection: ChatStore.ArchiveSelection) async {
        prepared = nil
        guard !selection.agentID.isEmpty, current else { loading = false; return }
        loading = true
        defer { if !Task.isCancelled { loading = false } }
        do {
            let result = try await store.prepareArchive(selection)
            guard !Task.isCancelled else { return }
            prepared = result
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func submit(resetOnly: Bool = false) async {
        guard current, !submitting else { return }
        submitting = true
        error = nil
        defer { submitting = false }
        let succeeded: Bool
        if resetOnly {
            succeeded = await store.startFreshRound(in: sheet.scope)
        } else {
            guard let prepared, prepared.selection == selection else { return }
            succeeded = await store.exportCurrentRound(prepared, startNew: !sheet.exportOnly)
        }
        if succeeded || !current { dismiss(); return }
        error = store.exportError
        // A failed attempt may have created or discarded a pinned request.
        await loadDestination(for: selection)
    }
}

struct ClearHistoryView: View {
    @ObservedObject var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("清空当前会话记录", systemImage: "trash").font(.title2.bold())
            if let preview = store.clearPreview {
                Text("将永久删除「\(preview.conversationName)」中的 \(preview.messageCount) 条已保存消息，以及本会话图片和 AI 对话上下文。").font(.callout)
                if preview.hasActiveWork { Text("当前仍有回复、压缩或总结任务，请完成后刷新。").foregroundStyle(.orange) }
            }
            Text("当前设备的未发送内容也会丢弃。其他会话、Agent 设置和已导出的 LeonBook 文章保留。此操作无法撤销；需要保留时，请先用 /export 导出。").font(.callout).foregroundStyle(.secondary)
            if store.clearBusy { ProgressView(store.clearPreview == nil ? "正在读取会话状态…" : "正在清空记录…").controlSize(.small) }
            if let error = store.clearError { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(store.clearBusy)
                Button("刷新") { Task { await store.prepareClearHistory() } }.disabled(store.clearBusy)
                Spacer()
                Button("永久清空", role: .destructive) { Task { await store.clearCurrentHistory(); if store.clearPreview == nil && store.clearError == nil { dismiss() } } }
                    .disabled(store.clearBusy || store.clearPreview == nil || store.clearPreview?.hasActiveWork == true)
            }
        }.padding(28).frame(width: 560)
        .task { await store.prepareClearHistory() }
        .interactiveDismissDisabled(store.clearBusy)
    }
}
