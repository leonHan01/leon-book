import SwiftUI

final class ConversationRowHover: ObservableObject {
    @Published var hovering = false
}

final class ConversationDeletionState: ObservableObject {
    @Published var preview: ClearHistoryPreview?
    @Published var loading = false
    @Published var error: String?
    var requestId = UUID().uuidString.lowercased()
}

struct AgentHistoryRow: View {
    @ObservedObject var store: ChatStore
    let room: Conversation
    var compact = true
    @StateObject private var hover = ConversationRowHover()

    var body: some View {
        HStack(spacing: 4) {
            Button { store.selectConversation(room.id) } label: {
                HStack(spacing: compact ? 8 : 12) {
                    Image(systemName: "bubble.left").foregroundStyle(.secondary)
                    Text(room.name).lineLimit(compact ? 2 : 3).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button(role: .destructive) { store.conversationToDelete = room } label: {
                Image(systemName: "trash").frame(width: 24, height: 26).contentShape(Rectangle())
            }.buttonStyle(.borderless).opacity(hover.hovering ? 1 : 0)
                .disabled(!store.hasConnection || store.deletingConversation || store.creatingAgentConversation)
                .help("永久删除对话").accessibilityLabel("永久删除「\(room.name)」")
        }.padding(compact ? 10 : 18)
            .background(store.selectedConversationId == room.id ? Color.accentColor.opacity(0.12)
                : compact ? Color.clear : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: compact ? 8 : 12))
            .onHover { hover.hovering = $0 }
            .contextMenu {
                Button("永久删除对话…", role: .destructive) { store.conversationToDelete = room }
                    .disabled(!store.hasConnection || store.deletingConversation || store.creatingAgentConversation)
            }
    }
}

struct DeleteConversationView: View {
    @ObservedObject var store: ChatStore
    let room: Conversation
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = ConversationDeletionState()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("永久删除对话", systemImage: "trash").font(.title2.bold())
            Text("「\(room.name)」").font(.headline).textSelection(.enabled)
            Text("将从服务器数据库永久删除此会话、全部消息、图片、文档、AI 上下文和相关收藏副本，并清除本机草稿与缓存。此操作无法撤销。")
                .fixedSize(horizontal: false, vertical: true)
            Text("单独创建的分支、已导出的文件和既有备份仍保留。")
                .font(.caption).foregroundStyle(.secondary)
            if state.loading { ProgressView("正在读取会话信息…") }
            if let preview = state.preview {
                Text("已保存消息：\(preview.messageCount) 条").font(.callout)
                if preview.hasActiveWork {
                    Text("AI 正在回复、压缩或总结，请完成后刷新再删除。").foregroundStyle(.orange)
                }
            }
            if let error = state.error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("刷新信息") { Task { await loadPreview() } }.disabled(state.loading || store.deletingConversation)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.disabled(store.deletingConversation)
                Button(store.deletingConversation ? "正在删除…" : "永久删除", role: .destructive) {
                    guard let preview = state.preview else { return }
                    Task {
                        state.error = nil
                        do { try await store.deleteConversation(preview, requestId: state.requestId) }
                        catch { state.error = error.localizedDescription }
                    }
                }.disabled(state.preview == nil || state.preview?.hasActiveWork == true || state.loading || store.deletingConversation)
            }
        }.padding(28).frame(width: 460)
            .interactiveDismissDisabled(store.deletingConversation)
            .task { await loadPreview() }
    }

    @MainActor private func loadPreview() async {
        state.loading = true; state.error = nil; state.preview = nil
        defer { state.loading = false }
        do {
            state.preview = try await store.previewConversationDeletion(room)
            state.requestId = UUID().uuidString.lowercased()
        } catch { state.error = error.localizedDescription }
    }
}
