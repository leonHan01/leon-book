import SwiftUI

struct ArticleLibraryView: View {
    @Environment(\.nativeAppPalette) private var appPalette

    @ObservedObject var model: NativeAppModel
    @AppStorage("articleLibraryLayout") private var allArticlesLayoutRaw = NativeArticleLibraryLayout.list.rawValue
    @AppStorage("articleLibraryBoardGroup") private var allArticlesBoardGroupRaw = NativeArticleGroupField.status.rawValue

    private var layout: NativeArticleLibraryLayout {
        NativeArticleLibraryLayout(rawValue: allArticlesLayoutRaw) ?? .list
    }

    var body: some View {
        let filteredArticles = model.filteredArticles
        let tagFilters = model.availableArticleTagFilters
        let currentLayout = layout
        let boardGroupBy = NativeArticleGroupField(rawValue: allArticlesBoardGroupRaw) ?? .status
        let groups = ArticleLibraryDisplayGroup.groups(articles: filteredArticles, by: .none)

        VStack(spacing: 0) {
            header(articleCount: filteredArticles.count, currentLayout: currentLayout)
            if !tagFilters.isEmpty {
                ArticleLibraryTagFilterBar(model: model, filters: tagFilters)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 14)
            }
            Divider()

            if filteredArticles.isEmpty {
                EmptyState(
                    title: "没有匹配的文章",
                    message: "试试其他搜索词，或者开始写一篇新文章。",
                    actionTitle: "新文章"
                ) { model.newArticle() }
            } else {
                switch currentLayout {
                case .list: listLayout(groups: groups)
                case .table: tableLayout(groups: groups)
                case .cards: cardLayout(groups: groups)
                case .board:
                    ArticleLibraryBoardView(
                        model: model,
                        articles: filteredArticles,
                        groupBy: boardGroupBy,
                        onChangeGroupBy: { field in
                            allArticlesBoardGroupRaw = field.rawValue
                        }
                    )
                case .calendar:
                    ArticleLibraryCalendarView(
                        model: model,
                        articles: filteredArticles
                    )
                }
            }
        }
    }

    private func header(
        articleCount: Int,
        currentLayout: NativeArticleLibraryLayout
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    if model.selectedArticleFolderPath == nil {
                        Text("全部文章").font(.title2.weight(.semibold))
                    } else {
                        Text(model.articleListTitle).font(.title2.weight(.semibold))
                    }
                    Text(NativeLocalization.text("\(articleCount) 篇文章"))
                        .font(.caption)
                        .foregroundStyle(appPalette.textSecondary)
                }
                Spacer()

                Menu {
                    ForEach(NativeArticleLibraryLayout.allCases) { option in
                        Button {
                            allArticlesLayoutRaw = option.rawValue
                        } label: {
                            Label(
                                LocalizedStringKey(option.label),
                                nativeIcon: currentLayout == option ? "checkmark" : option.systemImage
                            )
                        }
                    }
                } label: {
                    Label(LocalizedStringKey(currentLayout.label), nativeIcon: currentLayout.systemImage)
                }
                .help("切换列表、表格、卡片、看板或日历视图")

            }
            .controlSize(.small)

            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    NativeIcon.image("magnifyingglass")
                        .foregroundStyle(appPalette.textSecondary)
                    TextField("搜索标题、摘要、正文或标签", text: $model.searchText)
                        .textFieldStyle(.plain)
                        .onChange(of: model.searchText) { model.updateArticleListSearch($0) }
                    if model.isSearchingArticles { ProgressView().controlSize(.small) }
                }
                .font(.system(size: 12))
                .padding(10)
                .frame(maxWidth: 420)
                .background(appPalette.surfaceSecondary, in: RoundedRectangle(cornerRadius: 8))

                if model.isFilteringArticles {
                    Button("清除临时筛选") { model.clearArticleFilters() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
    }

    private func listLayout(groups: [ArticleLibraryDisplayGroup]) -> some View {
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.articles) { article in
                        ArticleLibraryListRow(model: model, article: article)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 5, leading: 18, bottom: 5, trailing: 18))
                    }
                } header: {
                    if groups.count > 1 { ArticleLibraryGroupHeader(group: group) }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func tableLayout(groups: [ArticleLibraryDisplayGroup]) -> some View {
        ArticleLibraryTableView(
            model: model,
            groups: groups
        )
    }

    private func cardLayout(groups: [ArticleLibraryDisplayGroup]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        if groups.count > 1 { ArticleLibraryGroupHeader(group: group) }
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 230, maximum: 330), spacing: 14)],
                            alignment: .leading,
                            spacing: 14
                        ) {
                            ForEach(group.articles) { article in
                                ArticleLibraryCard(model: model, article: article)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}

private struct ArticleLibraryTableView: View {
    @ObservedObject var model: NativeAppModel
    let groups: [ArticleLibraryDisplayGroup]

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(groups) { group in
                    ArticleLibraryTableGroup(
                        model: model,
                        group: group,
                        showsHeader: groups.count > 1
                    )
                }
            }
            .padding(20)
        }
    }
}

private struct ArticleLibraryTableGroup: View {
    @Environment(\.nativeAppPalette) private var appPalette

    @ObservedObject var model: NativeAppModel
    let group: ArticleLibraryDisplayGroup
    let showsHeader: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader { ArticleLibraryGroupHeader(group: group) }
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    ForEach(ArticleTableColumn.allCases) { column in
                        Text(LocalizedStringKey(column.title))
                            .frame(width: column.width, alignment: .leading)
                    }
                    Text("").frame(width: 24)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)

                Divider()

                ForEach(group.articles) { article in
                    HStack(spacing: 12) {
                        ForEach(ArticleTableColumn.allCases) { column in
                            Group {
                                if column == .title {
                                    Button(article.title) { model.selectSlug(article.slug) }
                                        .buttonStyle(.plain)
                                        .fontWeight(.medium)
                                } else {
                                    Text(column.text(for: article))
                                }
                            }
                            .lineLimit(1)
                            .frame(width: column.width, alignment: .leading)
                        }
                        ArticleLibraryBookmarkButton(model: model, article: article)
                            .frame(width: 24)
                    }
                    .font(.callout)
                    .padding(.vertical, 7)
                    Divider()
                }
            }
            .padding(.horizontal, 14)
            .fixedSize(horizontal: true, vertical: false)
            .background(appPalette.surface, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct ArticleLibraryDisplayGroup: Identifiable {
    let id: String
    let label: String
    var articles: [NativeArticleSummary]

    static func groups(
        articles: [NativeArticleSummary],
        by field: NativeArticleGroupField
    ) -> [ArticleLibraryDisplayGroup] {
        guard field != .none else {
            return [ArticleLibraryDisplayGroup(id: "all", label: "全部", articles: articles)]
        }
        var groups: [ArticleLibraryDisplayGroup] = []
        var indexByLabel: [String: Int] = [:]
        for article in articles {
            let label = field.label(for: article)
            if let index = indexByLabel[label] {
                groups[index].articles.append(article)
            } else {
                indexByLabel[label] = groups.count
                groups.append(ArticleLibraryDisplayGroup(id: label, label: label, articles: [article]))
            }
        }
        return groups
    }
}

private struct ArticleLibraryGroupHeader: View {
    let group: ArticleLibraryDisplayGroup

    var body: some View {
        HStack {
            Text(group.label).font(.headline)
            Text("\(group.articles.count)")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .padding(.horizontal, 4)
    }
}

private struct ArticleLibraryListRow: View {
    @Environment(\.nativeAppPalette) private var appPalette

    @ObservedObject var model: NativeAppModel
    let article: NativeArticleSummary

    var body: some View {
        HStack(spacing: 12) {
            Button { model.selectSlug(article.slug) } label: {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(article.status == .published ? appPalette.lightBlue : appPalette.surfaceSecondary)
                        .frame(width: 42, height: 42)
                        .overlay {
                            NativeIcon.image(article.status == .published ? "doc.text.fill" : "doc.badge.ellipsis")
                                .foregroundStyle(article.status == .published ? appPalette.accent : appPalette.textSecondary)
                        }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(article.title).font(.headline).foregroundStyle(.primary)
                        Text(article.excerpt.isEmpty ? article.category : article.excerpt)
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        if !article.tags.isEmpty {
                            Text(article.tags.map { "#\($0)" }.joined(separator: "  "))
                                .font(.caption).foregroundStyle(.tint).lineLimit(1)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(LocalizedStringKey(article.status.label)).font(.caption.weight(.medium))
                            .foregroundStyle(article.status == .published ? appPalette.accent : appPalette.textSecondary)
                        Text("\(article.pageViews) PV · \(article.updatedAt.nativeDateLabel)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ArticleLibraryBookmarkButton(model: model, article: article)
        }
        .padding(12)
        .contextMenu {
            Button(LocalizedStringKey(model.isBookmarked(.article(slug: article.slug)) ? "取消收藏" : "收藏文章")) {
                model.toggleArticleBookmark(article)
            }
            Button("移动或重命名 Markdown…") {
                model.promptToMoveArticleSource(article)
            }
        }
    }
}

private struct ArticleLibraryCard: View {
    @Environment(\.nativeAppPalette) private var appPalette

    @ObservedObject var model: NativeAppModel
    let article: NativeArticleSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                NativeIcon.image(article.status == .published ? "doc.text.fill" : "doc.badge.ellipsis", size: 24)
                    .foregroundStyle(article.status == .published ? appPalette.accent : appPalette.textSecondary)
                Spacer()
                ArticleLibraryBookmarkButton(model: model, article: article)
            }
            Button { model.selectSlug(article.slug) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(article.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                    Group {
                        if article.excerpt.isEmpty {
                            Text("暂无摘要")
                        } else {
                            Text(article.excerpt)
                        }
                    }
                        .font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 2)
            HStack {
                Label(article.category, nativeIcon: "folder")
                Spacer()
                Text(NativeLocalization.text("\(article.wordCount) 字"))
            }
            .font(.caption).foregroundStyle(.secondary)
            if !article.tags.isEmpty {
                Text(article.tags.prefix(3).map { "#\($0)" }.joined(separator: "  "))
                    .font(.caption).foregroundStyle(.tint).lineLimit(1)
            }
        }
        .padding(16)
        .frame(minHeight: 180, alignment: .topLeading)
        .background(appPalette.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.16))
        }
        .contextMenu {
            Button("移动或重命名 Markdown…") {
                model.promptToMoveArticleSource(article)
            }
        }
    }
}

private struct ArticleLibraryBookmarkButton: View {
    @ObservedObject var model: NativeAppModel
    let article: NativeArticleSummary

    var body: some View {
        let bookmarked = model.isBookmarked(.article(slug: article.slug))
        Button { model.toggleArticleBookmark(article) } label: {
            NativeIcon.image(bookmarked ? "bookmark.fill" : "bookmark")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(bookmarked ? Color.accentColor : .secondary)
        .help(Text(LocalizedStringKey(bookmarked ? "取消收藏文章" : "收藏文章")))
    }
}

private struct ArticleLibraryTagFilterBar: View {
    @ObservedObject var model: NativeAppModel
    let filters: [NativeArticleTagFilter]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Label("临时标签", nativeIcon: "tag", iconSize: 12).font(.caption).foregroundStyle(.secondary)
                ForEach(filters) { filter in
                    let selected = model.isArticleTagSelected(filter.tag)
                    Button {
                        model.toggleArticleTagFilter(filter.tag)
                    } label: {
                        Text("#\(filter.tag)  \(filter.count)")
                            .font(.caption)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private enum ArticleTableColumn: String, CaseIterable, Identifiable {
    case title, status, category, tags, updatedAt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title: return "标题"
        case .status: return "状态"
        case .category: return "分类"
        case .tags: return "标签"
        case .updatedAt: return "更新时间"
        }
    }

    var width: CGFloat {
        switch self {
        case .title: return 220
        case .status: return 90
        case .category: return 120
        case .tags: return 160
        case .updatedAt: return 130
        }
    }

    func text(for article: NativeArticleSummary) -> String {
        switch self {
        case .title: return article.title
        case .status: return NativeLocalization.string(article.status.label, language: NativeLocalization.currentLanguage)
        case .category: return article.category
        case .tags: return article.tags.joined(separator: ", ")
        case .updatedAt: return article.updatedAt.nativeDateLabel
        }
    }
}
