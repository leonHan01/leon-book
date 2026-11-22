import SwiftUI

final class AgentDetailDraft: ObservableObject {
    @Published var showNewConversation = false
    @Published var name = ""
    var requestId = UUID().uuidString
}

struct AgentConversationSidebar: View {
    @ObservedObject var store: ChatStore
    let agent: AgentInfo
    let onDelete: (Conversation) -> Void
    @StateObject private var draft = AgentDetailDraft()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent.name).font(.headline).lineLimit(1)
                    Text("历史对话").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { draft.showNewConversation = true } label: { Image(systemName: "plus.bubble") }
                    .buttonStyle(.borderless)
                    .disabled(!agent.enabled || !store.hasConnection || store.creatingAgentConversation)
                    .help("新建对话").accessibilityLabel("新建对话")
            }
            Divider()
            ScrollView {
                LazyVStack(spacing: 4) {
                    if store.agentConversations(agent.id).isEmpty {
                        Text("暂无历史对话").font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                    }
                    ForEach(store.agentConversations(agent.id)) { room in
                        AgentHistoryRow(store: store, room: room, onDelete: onDelete)
                    }
                }
            }
            Spacer(minLength: 0)
        }.padding(16).frame(width: 210).frame(maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .controlBackgroundColor))
            .alert("新建对话", isPresented: $draft.showNewConversation) {
                TextField("对话名称", text: $draft.name)
                Button("取消", role: .cancel) {}
                Button("创建") {
                    Task {
                        await store.createAgentConversation(agent, name: draft.name, requestId: draft.requestId, fromHistory: true)
                        if store.error == nil { draft.name = ""; draft.requestId = UUID().uuidString }
                    }
                }.disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: { Text("为与 \(agent.name) 的独立对话起一个名字。") }
    }
}

struct AgentDetailView: View {
    @ObservedObject var store: ChatStore
    let agentId: String
    let onDelete: (Conversation) -> Void
    @StateObject private var draft = AgentDetailDraft()

    var body: some View {
        ScrollView {
            if let agent = store.agents.first(where: { $0.id == agentId }) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Button { store.agentDetailId = nil } label: { Label("返回聊天", systemImage: "chevron.left") }
                            .buttonStyle(.borderless)
                        Text("Agent 详情").font(.headline)
                        Spacer()
                        Button { store.reconnect() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            AgentAvatarView(store: store, avatarId: agent.avatarId ?? "alfred", size: 48)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(agent.name).font(.system(size: 22, weight: .bold))
                                Text("@\(agent.handle)" + (agent.enabled ? "" : " · 已停用")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 12)
                            Button(store.agentConversations(agentId).isEmpty ? "开始聊天" : "继续聊天") { store.selectAgent(agent) }
                                .buttonStyle(.borderedProminent).disabled(!agent.enabled || !store.hasConnection)
                        }
                        HStack(alignment: .top, spacing: 10) {
                            Text("介绍").font(.caption).foregroundStyle(.secondary).frame(width: 32, alignment: .leading)
                            Text((agent.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "暂无介绍" : agent.description!)
                                .lineSpacing(3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(alignment: .top, spacing: 10) {
                            Text("模型").font(.caption).foregroundStyle(.secondary).frame(width: 32, alignment: .leading)
                            Text("\(agent.provider) · \(agent.model)").textSelection(.enabled)
                        }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
                    HStack {
                        Text("历史对话 · \(store.agentConversations(agentId).count)").font(.headline)
                        Spacer()
                        Button { draft.showNewConversation = true } label: { Label("新建对话", systemImage: "plus") }
                            .disabled(!agent.enabled || !store.hasConnection || store.creatingAgentConversation)
                    }
                    if store.agentConversations(agentId).isEmpty {
                        Text("暂无历史对话，开始聊聊吧。").foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                    LazyVStack(spacing: 10) {
                        ForEach(store.agentConversations(agentId)) { room in
                            AgentHistoryRow(store: store, room: room, compact: false, onDelete: onDelete)
                        }
                    }
                }.padding(20).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
                    .alert("新建对话", isPresented: $draft.showNewConversation) {
                        TextField("对话名称", text: $draft.name)
                        Button("取消", role: .cancel) {}
                        Button("创建") {
                            Task {
                                await store.createAgentConversation(agent, name: draft.name, requestId: draft.requestId)
                                if store.agentDetailId == nil { draft.name = ""; draft.requestId = UUID().uuidString }
                            }
                        }.disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } message: { Text("为与 \(agent.name) 的独立对话起一个名字。") }
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    Button { store.agentDetailId = nil } label: { Label("返回聊天", systemImage: "chevron.left") }
                        .buttonStyle(.borderless)
                    Text("Agent 已不存在，请刷新列表。").foregroundStyle(.secondary)
                }.padding(40).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
    }
}
