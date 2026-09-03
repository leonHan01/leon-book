import SwiftUI

struct NativeSearchSheet: View {
    @ObservedObject var model: NativeAppModel
    let presentation: NativeSearchPresentation

    var body: some View {
        switch presentation {
        case .globalSearch:
            NativeSearchResultsView(model: model, articlesOnly: false)
        case .quickOpen:
            NativeSearchResultsView(model: model, articlesOnly: true)
        case .commandPalette:
            NativeCommandPaletteView(model: model)
        }
    }
}

private struct NativeSearchResultsView: View {
    @ObservedObject var model: NativeAppModel
    let articlesOnly: Bool
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var isSearchFocused: Bool

    private var title: String { articlesOnly ? "快速打开" : "全文搜索" }
    private var prompt: String {
        articlesOnly ? "输入文章标题、正文或属性…" : "搜索文章、属性、摘要、正文和微博…"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: articlesOnly ? "doc.text.magnifyingglass" : "magnifyingglass")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    TextField(LocalizedStringKey(prompt), text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($isSearchFocused)
                        .onSubmit { openSelection() }
                    if model.isSearchingGlobally {
                        ProgressView().controlSize(.small)
                    } else if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清空搜索")
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))

                if !articlesOnly {
                    Text("过滤：tag:标签  status:draft  [属性名:值]  type:article  date:2026-08-23")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(16)

            Divider()

            if model.globalSearchResults.isEmpty && !model.isSearchingGlobally {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text(LocalizedStringKey(query.isEmpty ? "没有可打开的内容" : "没有搜索结果"))
                        .font(.headline)
                    Text(LocalizedStringKey(query.isEmpty ? "创建文章或微博后会显示在这里。" : "尝试减少关键词，或使用 tag:、status:、[属性名:值] 和日期过滤。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(model.globalSearchResults) { result in
                        NativeSearchResultRow(result: result, hidesType: articlesOnly)
                            .tag(result.id)
                            .contentShape(Rectangle())
                            .simultaneousGesture(TapGesture(count: 2).onEnded {
                                model.openSearchResult(result)
                            })
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text(LocalizedStringKey(title))
                    .fontWeight(.semibold)
                Spacer()
                if !articlesOnly, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let target = NativeBookmarkTarget.search(query: query.trimmingCharacters(in: .whitespacesAndNewlines))
                    Button {
                        model.bookmarkSearch(query)
                    } label: {
                        Label(
                            LocalizedStringKey(model.isBookmarked(target) ? "取消收藏搜索" : "收藏搜索"),
                            systemImage: model.isBookmarked(target) ? "bookmark.fill" : "bookmark"
                        )
                    }
                    .buttonStyle(.borderless)
                }
                Text("↩ 打开  ·  Esc 关闭")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .frame(height: 38)
        }
        .frame(width: 720, height: articlesOnly ? 470 : 570)
        .onAppear {
            query = articlesOnly ? "" : model.globalSearchText
            selection = model.globalSearchResults.first?.id
            isSearchFocused = true
        }
        .onChange(of: query) { value in
            model.updateGlobalSearch(value, articlesOnly: articlesOnly)
        }
        .onChange(of: model.globalSearchResults) { results in
            if selection == nil || !results.contains(where: { $0.id == selection }) {
                selection = results.first?.id
            }
        }
        .onMoveCommand { direction in
            switch direction {
            case .up: moveSelection(by: -1)
            case .down: moveSelection(by: 1)
            default: break
            }
        }
        .onExitCommand { model.searchPresentation = nil }
    }

    private func openSelection() {
        let result = selection.flatMap { selected in
            model.globalSearchResults.first { $0.id == selected }
        } ?? model.globalSearchResults.first
        if let result { model.openSearchResult(result) }
    }

    private func moveSelection(by offset: Int) {
        let ids = model.globalSearchResults.map(\.id)
        guard !ids.isEmpty else { return }
        let current = selection.flatMap { ids.firstIndex(of: $0) } ?? (offset > 0 ? -1 : ids.count)
        selection = ids[min(max(current + offset, 0), ids.count - 1)]
    }
}

private struct NativeSearchResultRow: View {
    let result: NativeGlobalSearchResult
    let hidesType: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: result.documentType.systemImage)
                .font(.title3)
                .foregroundStyle(result.documentType == .article ? Color.accentColor : .orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(result.title)
                        .font(.headline)
                        .lineLimit(1)
                    if !hidesType {
                        Text(LocalizedStringKey(result.documentType.label))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    if let status = result.status {
                        Text(LocalizedStringKey(status.label))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(searchResultDate)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if !result.snippet.isEmpty {
                    highlightedSnippet(result.snippet)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    if let category = result.category {
                        Label(category, systemImage: "folder")
                    }
                    ForEach(Array(result.tags.prefix(4)), id: \.self) { tag in
                        Text("#\(tag)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
    }

    private var searchResultDate: String {
        guard let date = NativeTimestamp.date(from: result.timestamp) else { return "" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func highlightedSnippet(_ source: String) -> Text {
        var remaining = source[...]
        var output = Text("")

        while let opening = remaining.range(of: "⟦") {
            output = output + Text(String(remaining[..<opening.lowerBound]))
            let afterOpening = remaining[opening.upperBound...]
            guard let closing = afterOpening.range(of: "⟧") else {
                return output + Text(String(afterOpening))
            }
            output = output + Text(String(afterOpening[..<closing.lowerBound]))
                .bold()
                .foregroundColor(.accentColor)
            remaining = afterOpening[closing.upperBound...]
        }
        return output + Text(String(remaining))
    }
}

private struct NativeCommandPaletteView: View {
    @ObservedObject var model: NativeAppModel
    @ObservedObject private var preferences: NativeCommandPreferences
    @State private var query = ""
    @State private var selection: NativeCommandID?
    @FocusState private var isSearchFocused: Bool

    init(model: NativeAppModel) {
        self.model = model
        _preferences = ObservedObject(wrappedValue: model.commandPreferences)
    }

    private var commands: [NativeCommandMatch] {
        model.commandRegistry.matches(
            query,
            on: .palette,
            context: model.commandContext,
            ranking: preferences.ranking
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField("输入命令…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isSearchFocused)
                    .onSubmit { runSelection() }
            }
            .padding(14)

            Divider()

            List(selection: $selection) {
                ForEach(commands) { command in
                    HStack(spacing: 12) {
                        Image(systemName: command.definition.systemImage)
                            .frame(width: 22)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(LocalizedStringKey(command.definition.title)).fontWeight(.medium)
                                if command.isPinned {
                                    Image(systemName: "pin.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.tint)
                                } else if command.isRecent && query.isEmpty {
                                    Text("最近")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Text(LocalizedStringKey(command.definition.detail))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            preferences.togglePinned(command.id)
                        } label: {
                            Image(systemName: command.isPinned ? "pin.slash" : "pin")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(Text(LocalizedStringKey(command.isPinned ? "取消固定" : "固定到命令面板顶部")))
                        if let shortcut = preferences.shortcut(for: command.definition) {
                            Text(shortcut.displayLabel)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 5)
                    .tag(command.id)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        model.executeCommand(command.id)
                    })
                }
            }
            .listStyle(.inset)

            Divider()
            HStack {
                Text("命令面板").fontWeight(.semibold)
                Spacer()
                Text("↩ 执行  ·  Esc 关闭").foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .frame(height: 38)
        }
        .frame(width: 650, height: 480)
        .onAppear {
            selection = commands.first?.id
            isSearchFocused = true
        }
        .onChange(of: query) { _ in
            selection = commands.first?.id
        }
        .onMoveCommand { direction in
            switch direction {
            case .up: moveSelection(by: -1)
            case .down: moveSelection(by: 1)
            default: break
            }
        }
        .onExitCommand { model.searchPresentation = nil }
    }

    private func runSelection() {
        if let selection, commands.contains(where: { $0.id == selection }) {
            model.executeCommand(selection)
        } else if let first = commands.first {
            model.executeCommand(first.id)
        }
    }

    private func moveSelection(by offset: Int) {
        let ids = commands.map(\.id)
        guard !ids.isEmpty else { return }
        let current = selection.flatMap { ids.firstIndex(of: $0) } ?? (offset > 0 ? -1 : ids.count)
        selection = ids[min(max(current + offset, 0), ids.count - 1)]
    }
}
