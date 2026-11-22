import SwiftUI

/// WeChat-style entry, keyword excerpts, and an anchored view of the original history.
@MainActor
struct ChatSearchView: View {
    @ObservedObject var store: ChatStore
    @StateObject private var search: ChatSearchState
    @State private var selected: ChatSearchHit?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    let title: String
    let openRoom: (String) -> Void
    init(store: ChatStore, room: String? = nil, title: String = "全部聊天记录", initialHit:ChatSearchHit? = nil, openRoom: @escaping (String) -> Void) {
        self.store = store; self.title = title; self.openRoom = openRoom
        _selected=State(initialValue:initialHit)
        _search = StateObject(wrappedValue: ChatSearchState(room: room, fetch: store.searchMessages))
    }
    var body: some View {
        ZStack {
            // Keep the result list mounted so returning from a match preserves its scroll position.
            VStack(spacing: 0) { searchHeader; Divider(); resultList }
                .opacity(selected == nil ? 1 : 0).allowsHitTesting(selected == nil).accessibilityHidden(selected != nil)
            if let hit = selected {
                ChatSearchHistoryView(store: store, hit: hit, back: { selected = nil }, enter: {
                    if let room = hit.message.conversationId { dismiss(); openRoom(room) }
                }).id(hit.id)
            }
        }
        .background(searchBackground)
        .onChange(of: search.query) { _ in search.changed() }
        .onChange(of: store.searchConnectionID) { _ in
            selected = nil; search.query = ""; search.changed(); dismiss()
        }
        .onDisappear { search.stop() }
        .task { focused = selected == nil }
        #if os(macOS)
        .frame(minWidth: 660, idealWidth: 760, minHeight: 520, idealHeight: 640)
        #endif
    }
    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索聊天记录", text: $search.query)
                        .textFieldStyle(.plain).focused($focused)
                        .submitLabel(.search).onSubmit { search.changed(immediate: true) }
                        .accessibilityIdentifier("chat_search_input")
                    if !search.query.isEmpty {
                        Button { search.query = ""; focused = true } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("清除搜索词")
                    }
                }.padding(11).background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                Button("取消") { dismiss() }.foregroundStyle(.green)
            }
        }.padding(16)
    }
    private var resultList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    hint("输入关键字，查找文字聊天记录", symbol: "magnifyingglass")
                } else {
                    if !search.results.isEmpty {
                        Text("聊天记录 · 已找到 \(search.results.count) 条\(search.hasMore ? "，可继续加载" : "")")
                            .font(.caption).foregroundStyle(.secondary).padding(16)
                    }
                    ForEach(search.results) { hit in
                        Button { focused = false; selected = hit } label: { resultRow(hit) }
                            .buttonStyle(.plain).accessibilityIdentifier("search_result_\(hit.id)")
                        Divider().padding(.leading, 70)
                    }
                    if search.busy { ProgressView("正在搜索…").frame(maxWidth: .infinity).padding(24) }
                    if let error = search.error {
                        VStack(spacing: 12) { Text(error).foregroundStyle(.secondary); Button("重试") { search.retry() } }
                            .frame(maxWidth: .infinity).padding(24)
                    } else if search.searched && search.results.isEmpty && !search.busy {
                        hint("未找到相关聊天记录", symbol: "text.magnifyingglass")
                    }
                    if search.hasMore && !search.busy && search.error == nil {
                        Button("加载更多聊天记录") { search.more() }.frame(maxWidth: .infinity).padding(20)
                    }
                }
            }
        }.accessibilityIdentifier("chat_search_results")
    }
    private func resultRow(_ hit: ChatSearchHit) -> some View {
        HStack(alignment: .top, spacing: 12) {
            #if os(macOS)
            AgentAvatarView(store: store, avatarId: store.avatarId(for: hit.message.agentId), size: 40)
            #else
            AgentAvatar(store: store, agent: store.agent(hit.message.agentId), size: 40)
            #endif
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(search.room == nil ? hit.conversationName : hit.message.sender).font(.system(size: 16, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(hit.message.date.formatted(date: .numeric, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                }
                if search.room == nil { Text(hit.message.sender).font(.caption).foregroundStyle(.secondary) }
                highlightedSearchText(SearchExcerpt.text(hit.message.text, query: search.query.trimmingCharacters(in: .whitespacesAndNewlines)), query: search.query.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 14)).lineLimit(3).multilineTextAlignment(.leading).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(16).contentShape(Rectangle())
    }
    private func hint(_ text: String, symbol: String) -> some View {
        VStack(spacing: 16) { Image(systemName: symbol).font(.system(size: 34)); Text(text).font(.callout) }
            .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 80)
    }
}

private var searchBackground: Color {
    #if os(macOS)
    Color(nsColor: .windowBackgroundColor)
    #else
    Color(uiColor: .systemBackground)
    #endif
}

private func highlightedSearchText(_ value: String, query: String) -> Text {
    guard !query.isEmpty else { return Text(value) }
    var result = Text(""); var start = value.startIndex
    while start < value.endIndex, let range = value.range(of: query, options: .caseInsensitive, range: start..<value.endIndex) {
        result = result + Text(String(value[start..<range.lowerBound])) + Text(String(value[range])).foregroundColor(.green).bold()
        start = range.upperBound
    }
    return result + Text(String(value[start...]))
}

@MainActor
private struct ChatSearchHistoryView: View {
    @ObservedObject var store: ChatStore
    @StateObject private var history: ChatSearchHistory
    @State private var followAnchor = true
    let back: () -> Void
    let enter: () -> Void
    init(store: ChatStore, hit: ChatSearchHit, back: @escaping () -> Void, enter: @escaping () -> Void) {
        self.store = store; self.back = back; self.enter = enter
        _history = StateObject(wrappedValue: ChatSearchHistory(hit: hit, fetch: store.searchHistory))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: back) { Label("搜索结果", systemImage: "chevron.left") }
                Spacer(minLength: 8)
                Text(history.hit.conversationName).font(.headline).lineLimit(1)
                Spacer(minLength: 8)
                Button("进入会话", action: enter).disabled(history.messages.isEmpty)
            }.padding(16)
            Divider()
            ScrollViewReader { proxy in
                GeometryReader { geometry in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            if history.hasOlder {
                                Button("查看更早的消息") {
                                    followAnchor = false; let anchor = history.messages.first?.id
                                    Task { await history.load("before"); if let anchor { proxy.scrollTo(anchor, anchor: .top) } }
                                }.disabled(history.busy).padding(12)
                            }
                            ForEach(history.messages) { message in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(message.sender) · \(message.date.formatted(date: .numeric, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                    originalMessage(message, width: geometry.size.width - 32, resized: {
                                        if followAnchor { proxy.scrollTo(history.hit.id, anchor: .center) }
                                    })
                                }.padding(8)
                                    .background(message.id == history.hit.id ? Color.green.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                                    .overlay { if message.id == history.hit.id { RoundedRectangle(cornerRadius: 10).stroke(Color.green.opacity(0.6), lineWidth: 1) } }
                                    .id(message.id)
                            }
                            if history.hasNewer {
                                Button("查看更新的消息") { followAnchor = false; Task { await history.load("after") } }
                                    .disabled(history.busy).padding(12)
                            }
                            if history.busy { ProgressView("正在加载聊天记录…").padding(20) }
                            if let error = history.error {
                                Text(error).foregroundStyle(.secondary).padding(16)
                                Button("重新定位原消息") { Task { await history.load(); proxy.scrollTo(history.hit.id, anchor: .center) } }.disabled(history.busy)
                            }
                        }.padding(8)
                            .background(GeometryReader { size in Color.clear.preference(key: SearchHistoryHeight.self, value: size.size.height) })
                    }.onPreferenceChange(SearchHistoryHeight.self) { _ in
                        if followAnchor { DispatchQueue.main.async { if followAnchor { proxy.scrollTo(history.hit.id, anchor: .center) } } }
                    }.simultaneousGesture(DragGesture().onChanged { _ in followAnchor = false })
                }
                .task {
                    await history.load(); proxy.scrollTo(history.hit.id, anchor: .center)
                    do { try await Task.sleep(nanoseconds: 1_200_000_000) } catch { return }
                    followAnchor = false
                }
            }
        }.background(searchBackground).onDisappear { history.stop() }
    }
    @ViewBuilder private func originalMessage(_ message: Message, width: CGFloat, resized: @escaping () -> Void) -> some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(message.images ?? []) { image in ChatImageView(store: store, imageId: image.id) }
            if !message.text.isEmpty { MarkdownMessageView(message.text, mine: false) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        #else
        MessageBubble(store: store, message: message, openAgent: { _ in }, availableWidth: width, resized: resized)
        #endif
    }
}

private struct SearchHistoryHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
