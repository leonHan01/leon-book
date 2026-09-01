import SwiftUI

struct SmartCollectionEditorRequest: Identifiable {
    let id = UUID()
    let collection: NativeSmartCollection?
}

struct SmartArticleLibraryView: View {
    @ObservedObject var model: NativeAppModel
    @AppStorage("articleLibraryLayout") private var allArticlesLayoutRaw = NativeSmartCollectionLayout.list.rawValue
    @AppStorage("articleLibraryBoardGroup") private var allArticlesBoardGroupRaw = NativeArticleGroupField.status.rawValue
    @State private var editorRequest: SmartCollectionEditorRequest?

    private var layout: NativeSmartCollectionLayout {
        model.selectedSmartCollection?.layout
            ?? NativeSmartCollectionLayout(rawValue: allArticlesLayoutRaw)
            ?? .list
    }

    var body: some View {
        let filteredArticles = model.filteredArticles
        let tagFilters = model.availableArticleTagFilters
        let currentLayout = layout
        let boardGroupBy = model.selectedSmartCollection.map {
            $0.groupBy == .none ? NativeArticleGroupField.status : $0.groupBy
        } ?? NativeArticleGroupField(rawValue: allArticlesBoardGroupRaw) ?? .status
        let groups = SmartArticleDisplayGroup.groups(
            articles: filteredArticles,
            by: model.selectedSmartCollection?.groupBy ?? .none
        )

        VStack(spacing: 0) {
            header(articleCount: filteredArticles.count, currentLayout: currentLayout)
            if !tagFilters.isEmpty {
                SmartArticleTagFilterBar(model: model, filters: tagFilters)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 14)
            }
            Divider()

            if filteredArticles.isEmpty {
                EmptyState(
                    title: "没有匹配的文章",
                    message: emptyMessage,
                    actionTitle: "新文章"
                ) { model.newArticle() }
            } else {
                switch currentLayout {
                case .list: listLayout(groups: groups)
                case .table: tableLayout(groups: groups)
                case .cards: cardLayout(groups: groups)
                case .board:
                    SmartCollectionBoardView(
                        model: model,
                        articles: filteredArticles,
                        groupBy: boardGroupBy,
                        onChangeGroupBy: { field in
                            if model.selectedSmartCollection == nil {
                                allArticlesBoardGroupRaw = field.rawValue
                            } else {
                                model.setSmartCollectionGroupBy(field)
                            }
                        }
                    )
                case .calendar:
                    SmartCollectionCalendarView(
                        model: model,
                        articles: filteredArticles,
                        collection: model.selectedSmartCollection
                    )
                }
            }
        }
        .sheet(item: $editorRequest) { request in
            SmartCollectionEditorSheet(model: model, collection: request.collection)
        }
    }

    private var emptyMessage: String {
        guard let collection = model.selectedSmartCollection else {
            return "试试其他搜索词，或者开始写一篇新文章。"
        }
        if collection.unsupportedFilterExpressionCount > 0 {
            return "此 Base 含 \(collection.unsupportedFilterExpressionCount) 个尚不能在本地索引中执行的筛选表达式；表达式已保留，请在 Obsidian 中运行或改用受支持的字段比较。"
        }
        return "调整智能集合的筛选条件，或创建符合条件的文章。"
    }

    private func header(
        articleCount: Int,
        currentLayout: NativeSmartCollectionLayout
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.articleListTitle).font(.title2.weight(.semibold))
                Text("\(articleCount) 篇 · 虚拟集合，不移动原文章")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if let definition = model.selectedSmartCollectionDefinition,
               definition.views.count > 1 {
                Picker("Base 视图", selection: Binding(
                    get: { model.selectedSmartCollectionViewID ?? definition.views[0].id },
                    set: { model.selectSmartCollectionView($0) }
                )) {
                    ForEach(definition.views) { view in
                        Text(view.name).tag(view.id)
                    }
                }
                .frame(width: 150)
                .help("切换 .base 中的命名视图")
            }

            Menu {
                ForEach(NativeSmartCollectionLayout.allCases) { option in
                    Button {
                        if model.selectedSmartCollection == nil {
                            allArticlesLayoutRaw = option.rawValue
                        } else {
                            model.setSmartCollectionLayout(option)
                        }
                    } label: {
                        Label(
                            option.label,
                            systemImage: currentLayout == option ? "checkmark" : option.systemImage
                        )
                    }
                }
            } label: {
                Label(currentLayout.label, systemImage: currentLayout.systemImage)
            }
            .help("切换列表、表格、卡片、看板或日历视图")

            TextField("搜索标题、摘要、正文或标签", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onChange(of: model.searchText) { model.updateArticleListSearch($0) }
            if model.isSearchingArticles { ProgressView().controlSize(.small) }
            if model.isFilteringArticles {
                Button("清除临时筛选") { model.clearArticleFilters() }
                    .buttonStyle(.bordered)
            }

            Menu {
                Button("新建智能集合…") {
                    editorRequest = SmartCollectionEditorRequest(collection: nil)
                }
                if let collection = model.selectedSmartCollection {
                    Button("编辑“\(collection.name)”…") {
                        editorRequest = SmartCollectionEditorRequest(collection: collection)
                    }
                    Divider()
                    Button("删除当前集合", role: .destructive) {
                        Task { await model.deleteSmartCollection(collection) }
                    }
                }
            } label: {
                Label("集合", systemImage: "slider.horizontal.3")
            }
        }
        .padding(22)
    }

    private func listLayout(groups: [SmartArticleDisplayGroup]) -> some View {
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.articles) { article in
                        SmartArticleListRow(model: model, article: article)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 5, leading: 18, bottom: 5, trailing: 18))
                    }
                } header: {
                    if groups.count > 1 { SmartArticleGroupHeader(group: group) }
                }
            }
        }
        .listStyle(.plain)
    }

    private func tableLayout(groups: [SmartArticleDisplayGroup]) -> some View {
        SmartCollectionTableView(
            model: model,
            collection: model.selectedSmartCollection ?? NativeSmartCollection(name: "全部文章"),
            groups: groups
        )
    }

    private func cardLayout(groups: [SmartArticleDisplayGroup]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        if groups.count > 1 { SmartArticleGroupHeader(group: group) }
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 230, maximum: 330), spacing: 14)],
                            alignment: .leading,
                            spacing: 14
                        ) {
                            ForEach(group.articles) { article in
                                SmartArticleCard(model: model, article: article)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}

struct SmartCollectionEmbedView: View {
    let reference: String
    let store: LocalBlogStore
    let onOpenArticle: (NativeArticleLinkDestination) -> Void
    @State private var collection: NativeSmartCollection?
    @State private var articles: [NativeArticleSummary] = []
    @State private var errorMessage: String?
    @Environment(\.nativeDeclarativeExtensions) private var declarativeExtensions

    private var columns: [NativeSmartCollectionColumn] {
        let visible = collection?.columns.filter { !$0.isHidden } ?? []
        return Array((visible.isEmpty ? NativeSmartCollection.defaultColumns : visible).prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let collection {
                HStack {
                    Label(collection.name, systemImage: "tablecells")
                        .font(.headline)
                    Spacer()
                    Text("\(articles.count) 篇")
                        .font(.caption).foregroundStyle(.secondary)
                }
                switch collection.layout {
                case .table: embeddedTable(collection)
                case .list: embeddedList
                case .cards: embeddedCards
                case .board: embeddedCards
                case .calendar: embeddedList
                }
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在载入 Base…").foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor.opacity(0.2)) }
        .task(id: reference) { await load() }
    }

    private func embeddedTable(_ collection: NativeSmartCollection) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                GridRow {
                    ForEach(columns) { column in
                        Text(column.displayTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: min(column.width, 190), alignment: .leading)
                    }
                }
                Divider().gridCellColumns(columns.count)
                ForEach(Array(articles.prefix(20))) { article in
                    GridRow {
                        ForEach(columns) { column in
                            let value = NativeSmartCollectionFormulaEngine.value(
                                for: column,
                                article: article,
                                collection: collection,
                                baseFunctions: declarativeExtensions.baseFunctions.map(\.function)
                            )
                            if column.source == .system,
                               NativeSmartCollectionSystemField(rawValue: column.key) == .title {
                                Button(article.title) { open(article) }
                                    .buttonStyle(.plain).fontWeight(.medium)
                                    .frame(width: min(column.width, 190), alignment: .leading)
                            } else {
                                Text(value.displayText.isEmpty ? "—" : value.displayText)
                                    .lineLimit(1)
                                    .frame(width: min(column.width, 190), alignment: .leading)
                            }
                        }
                    }
                    .font(.callout)
                }
            }
        }
    }

    private var embeddedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(articles.prefix(20))) { article in
                Button { open(article) } label: {
                    HStack {
                        Text(article.title).fontWeight(.medium)
                        Spacer()
                        Text(article.updatedAt.nativeDateLabel).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var embeddedCards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
            ForEach(Array(articles.prefix(12))) { article in
                Button { open(article) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(article.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                        Text(article.excerpt.isEmpty ? article.category : article.excerpt)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func open(_ article: NativeArticleSummary) {
        onOpenArticle(NativeArticleLinkDestination(
            target: article.slug,
            resolvedSlug: article.slug,
            heading: nil,
            label: article.title
        ))
    }

    @MainActor
    private func load() async {
        do {
            let parsed = NativeArticleLink.Reference(rawValue: reference)
            let rawTarget = parsed.target.removingPercentEncoding ?? parsed.target
            let filename = URL(fileURLWithPath: rawTarget).deletingPathExtension().lastPathComponent
            let collections = try await store.listSmartCollections()
            guard let matched = collections.first(where: {
                $0.id.caseInsensitiveCompare(filename) == .orderedSame
                    || $0.name.caseInsensitiveCompare(filename) == .orderedSame
                    || $0.name.caseInsensitiveCompare(parsed.label) == .orderedSame
            }) else {
                errorMessage = "找不到 Base：\(parsed.target)"
                return
            }
            let viewID = parsed.heading.flatMap { heading in
                matched.views.first(where: {
                    $0.name.caseInsensitiveCompare(heading) == .orderedSame
                })?.id
            }
            let selected = matched.materialized(viewID: viewID)
            collection = selected
            articles = try await store.listArticles(in: selected)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SmartCollectionTableView: View {
    @ObservedObject var model: NativeAppModel
    let collection: NativeSmartCollection
    let groups: [SmartArticleDisplayGroup]

    private var columns: [NativeSmartCollectionColumn] {
        let visible = collection.columns.filter { !$0.isHidden }
        return visible.isEmpty ? NativeSmartCollection.defaultColumns : visible
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(groups) { group in
                    SmartCollectionTableGroup(
                        model: model,
                        collection: collection,
                        columns: columns,
                        group: group,
                        showsHeader: groups.count > 1
                    )
                }
            }
            .padding(20)
        }
    }
}

private struct SmartCollectionTableGroup: View {
    @ObservedObject var model: NativeAppModel
    let collection: NativeSmartCollection
    let columns: [NativeSmartCollectionColumn]
    let group: SmartArticleDisplayGroup
    let showsHeader: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader { SmartArticleGroupHeader(group: group) }
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    ForEach(columns) { column in
                        Text(column.displayTitle)
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
                        ForEach(columns) { column in
                            SmartCollectionCell(
                                model: model,
                                collection: collection,
                                column: column,
                                article: article
                            )
                            .frame(width: column.width, alignment: .leading)
                        }
                        SmartArticleBookmarkButton(model: model, article: article)
                            .frame(width: 24)
                    }
                    .font(.callout)
                    .padding(.vertical, 7)
                    Divider()
                }

                if columns.contains(where: { $0.summary != nil }) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(columns) { column in
                            SmartCollectionSummaryCell(
                                collection: collection,
                                column: column,
                                articles: group.articles
                            )
                        }
                        Color.clear.frame(width: 24, height: 1)
                    }
                    .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 14)
            .fixedSize(horizontal: true, vertical: false)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct SmartCollectionSummaryCell: View {
    let collection: NativeSmartCollection
    let column: NativeSmartCollectionColumn
    let articles: [NativeArticleSummary]
    @Environment(\.nativeDeclarativeExtensions) private var declarativeExtensions

    var body: some View {
        if let summary = column.summary {
            let value = NativeSmartCollectionFormulaEngine.summary(
                summary,
                column: column,
                articles: articles,
                collection: collection,
                baseFunctions: declarativeExtensions.baseFunctions.map(\.function)
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.label).font(.caption2).foregroundStyle(.secondary)
                Text(value.displayText.isEmpty ? "—" : value.displayText)
                    .font(.caption.weight(.semibold))
            }
            .frame(width: column.width, alignment: .leading)
        } else {
            Color.clear.frame(width: column.width, height: 1)
        }
    }
}

private struct SmartCollectionCell: View {
    @ObservedObject var model: NativeAppModel
    let collection: NativeSmartCollection
    let column: NativeSmartCollectionColumn
    let article: NativeArticleSummary
    @Environment(\.nativeDeclarativeExtensions) private var declarativeExtensions

    var body: some View {
        if column.source == .property {
            SmartEditablePropertyCell(
                model: model,
                article: article,
                key: column.key,
                kind: column.propertyKind == .text
                    ? article.properties[column.key]?.kind
                        ?? article.properties.first(where: {
                        $0.key.caseInsensitiveCompare(column.key) == .orderedSame
                    })?.value.kind ?? .text
                    : column.propertyKind
            )
        } else if column.source == .system,
                  NativeSmartCollectionSystemField(rawValue: column.key) == .title {
            Button(article.title) { model.selectSlug(article.slug) }
                .buttonStyle(.plain)
                .fontWeight(.medium)
                .lineLimit(1)
        } else {
            let value = NativeSmartCollectionFormulaEngine.value(
                for: column,
                article: article,
                collection: collection,
                baseFunctions: declarativeExtensions.baseFunctions.map(\.function)
            )
            Text(value.displayText.isEmpty ? "—" : value.displayText)
                .foregroundStyle(value.displayText.isEmpty ? .tertiary : .primary)
                .lineLimit(1)
        }
    }
}

private struct SmartEditablePropertyCell: View {
    @ObservedObject var model: NativeAppModel
    let article: NativeArticleSummary
    let key: String
    let kind: NativeArticlePropertyKind
    @State private var text: String

    init(model: NativeAppModel, article: NativeArticleSummary, key: String, kind: NativeArticlePropertyKind) {
        self.model = model
        self.article = article
        self.key = key
        self.kind = kind
        let value = article.properties.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value
        _text = State(initialValue: value?.editorText ?? "")
    }

    var body: some View {
        propertyEditor
        .onChange(of: article.updatedAt) { _ in
            text = article.properties.first(where: {
                $0.key.caseInsensitiveCompare(key) == .orderedSame
            })?.value.editorText ?? ""
        }
        .help(propertyHelp)
    }

    private func commit() {
        model.updateArticleProperty(article: article, key: key, kind: kind, text: text)
    }

    @ViewBuilder
    private var propertyEditor: some View {
        switch kind {
        case .rollup:
            Text(NativeArticleRollup.displayText(
                specification: text,
                article: article,
                articles: model.articles
            ))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        case .checkbox:
            let checked = NativeArticlePropertyValue.fromEditor(kind: .checkbox, text: text).booleanValue
            Button {
                setAndCommit(checked ? "false" : "true")
            } label: {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
        case .select, .status:
            Menu {
                ForEach(scalarOptions, id: \.self) { option in
                    Button {
                        setAndCommit(option)
                    } label: {
                        Label(option, systemImage: text == option ? "checkmark" : kind.systemImage)
                    }
                }
                if !text.isEmpty {
                    Divider()
                    Button("清空", role: .destructive) { setAndCommit("") }
                }
            } label: {
                Label(text.isEmpty ? "选择" : text, systemImage: kind.systemImage)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
        case .relation:
            Menu {
                ForEach(model.articles.filter { $0.slug != article.slug }) { destination in
                    Button {
                        toggleRelation(destination)
                    } label: {
                        Label(
                            destination.title,
                            systemImage: relationContains(destination) ? "checkmark" : "doc.text"
                        )
                    }
                }
                if !relationValues.isEmpty {
                    Divider()
                    Button("清空关联", role: .destructive) { setAndCommit("") }
                }
            } label: {
                Label(
                    relationValues.isEmpty ? "选择页面" : "\(relationValues.count) 个页面",
                    systemImage: "arrow.triangle.branch"
                )
            }
            .menuStyle(.borderlessButton)
        default:
            TextField("空", text: $text)
                .textFieldStyle(.plain)
                .onSubmit(commit)
        }
    }

    private var scalarOptions: [String] {
        var values = kind == .status ? ["未开始", "进行中", "已完成"] : []
        if !text.isEmpty { values.append(text) }
        for candidate in model.articles {
            guard let value = candidate.properties.first(where: {
                $0.key.caseInsensitiveCompare(key) == .orderedSame
            })?.value.editorText, !value.isEmpty else { continue }
            values.append(value)
        }
        var unique: [String] = []
        for value in values where !unique.contains(where: {
            $0.caseInsensitiveCompare(value) == .orderedSame
        }) {
            unique.append(value)
        }
        return unique
    }

    private var relationValues: [String] {
        NativeArticlePropertyValue.fromEditor(kind: .relation, text: text).listValues
    }

    private func relationContains(_ destination: NativeArticleSummary) -> Bool {
        relationValues.contains(where: { reference in
            destination.slug.caseInsensitiveCompare(reference) == .orderedSame
                || destination.title.caseInsensitiveCompare(reference) == .orderedSame
                || destination.aliases.contains(where: {
                    $0.caseInsensitiveCompare(reference) == .orderedSame
                })
        })
    }

    private func toggleRelation(_ destination: NativeArticleSummary) {
        var values = relationValues.filter { reference in
            destination.slug.caseInsensitiveCompare(reference) != .orderedSame
                && destination.title.caseInsensitiveCompare(reference) != .orderedSame
                && !destination.aliases.contains(where: {
                    $0.caseInsensitiveCompare(reference) == .orderedSame
                })
        }
        if !relationContains(destination) { values.append(destination.slug) }
        setAndCommit(values.joined(separator: ", "))
    }

    private func setAndCommit(_ value: String) {
        text = value
        model.updateArticleProperty(article: article, key: key, kind: kind, text: value)
    }

    private var propertyHelp: String {
        switch kind {
        case .rollup: return "根据关联页面实时计算汇总结果"
        case .select, .status: return "选择工作区中已有的选项"
        case .relation: return "选择或取消关联页面"
        default: return "直接编辑属性：\(key)，回车保存到 Markdown frontmatter"
        }
    }
}

private struct SmartArticleDisplayGroup: Identifiable {
    let id: String
    let label: String
    var articles: [NativeArticleSummary]

    static func groups(
        articles: [NativeArticleSummary],
        by field: NativeArticleGroupField
    ) -> [SmartArticleDisplayGroup] {
        guard field != .none else {
            return [SmartArticleDisplayGroup(id: "all", label: "全部", articles: articles)]
        }
        var groups: [SmartArticleDisplayGroup] = []
        var indexByLabel: [String: Int] = [:]
        for article in articles {
            let label = field.label(for: article)
            if let index = indexByLabel[label] {
                groups[index].articles.append(article)
            } else {
                indexByLabel[label] = groups.count
                groups.append(SmartArticleDisplayGroup(id: label, label: label, articles: [article]))
            }
        }
        return groups
    }
}

private struct SmartArticleGroupHeader: View {
    let group: SmartArticleDisplayGroup

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

private struct SmartArticleListRow: View {
    @ObservedObject var model: NativeAppModel
    let article: NativeArticleSummary

    var body: some View {
        HStack(spacing: 12) {
            Button { model.selectSlug(article.slug) } label: {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(article.status == .published ? Color.blue.opacity(0.12) : Color.orange.opacity(0.12))
                        .frame(width: 42, height: 42)
                        .overlay {
                            Image(systemName: article.status == .published ? "doc.text.fill" : "doc.badge.ellipsis")
                                .foregroundStyle(article.status == .published ? .blue : .orange)
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
                        Text(article.status.label).font(.caption.weight(.medium))
                            .foregroundStyle(article.status == .published ? .green : .orange)
                        Text("\(article.pageViews) PV · \(article.updatedAt.nativeDateLabel)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            SmartArticleBookmarkButton(model: model, article: article)
        }
        .padding(12)
        .contextMenu {
            Button(model.isBookmarked(.article(slug: article.slug)) ? "取消收藏" : "收藏文章") {
                model.toggleArticleBookmark(article)
            }
            Button("移动或重命名 Markdown…") {
                model.promptToMoveArticleSource(article)
            }
        }
    }
}

private struct SmartArticleCard: View {
    @ObservedObject var model: NativeAppModel
    let article: NativeArticleSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Image(systemName: article.status == .published ? "doc.text.fill" : "doc.badge.ellipsis")
                    .font(.title2)
                    .foregroundStyle(article.status == .published ? .blue : .orange)
                Spacer()
                SmartArticleBookmarkButton(model: model, article: article)
            }
            Button { model.selectSlug(article.slug) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(article.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                    Text(article.excerpt.isEmpty ? "暂无摘要" : article.excerpt)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 2)
            HStack {
                Label(article.category, systemImage: "folder")
                Spacer()
                Text("\(article.wordCount) 字")
            }
            .font(.caption).foregroundStyle(.secondary)
            if !article.tags.isEmpty {
                Text(article.tags.prefix(3).map { "#\($0)" }.joined(separator: "  "))
                    .font(.caption).foregroundStyle(.tint).lineLimit(1)
            }
        }
        .padding(16)
        .frame(minHeight: 180, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
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

private struct SmartArticleBookmarkButton: View {
    @ObservedObject var model: NativeAppModel
    let article: NativeArticleSummary

    var body: some View {
        let bookmarked = model.isBookmarked(.article(slug: article.slug))
        Button { model.toggleArticleBookmark(article) } label: {
            Image(systemName: bookmarked ? "bookmark.fill" : "bookmark")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(bookmarked ? Color.accentColor : .secondary)
        .help(bookmarked ? "取消收藏文章" : "收藏文章")
    }
}

private struct SmartArticleTagFilterBar: View {
    @ObservedObject var model: NativeAppModel
    let filters: [NativeArticleTagFilter]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Label("临时标签", systemImage: "tag").font(.caption).foregroundStyle(.secondary)
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

struct SmartCollectionEditorSheet: View {
    @ObservedObject var model: NativeAppModel
    let originalCollection: NativeSmartCollection?
    @State private var draft: NativeSmartCollection
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    init(model: NativeAppModel, collection: NativeSmartCollection?) {
        self.model = model
        originalCollection = collection
        _draft = State(initialValue: collection ?? NativeSmartCollection())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(originalCollection == nil ? "新建智能集合" : "编辑智能集合")
                        .font(.title2.weight(.semibold))
                    Text("保存筛选、最多三层排序、分组方式和默认布局")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            Divider()

            Form {
                Section("名称与视图") {
                    TextField("集合名称", text: $draft.name)
                    Picker("默认布局", selection: $draft.layout) {
                        ForEach(NativeSmartCollectionLayout.allCases) {
                            Label($0.label, systemImage: $0.systemImage).tag($0)
                        }
                    }
                    Picker("分组", selection: $draft.groupBy) {
                        ForEach(NativeArticleGroupField.allCases) { Text($0.label).tag($0) }
                    }
                }

                Section("公式字段") {
                    ForEach($draft.formulas) { $formula in
                        SmartCollectionFormulaRow(formula: $formula) {
                            draft.formulas.removeAll(where: { $0.id == formula.id })
                        }
                    }
                    if draft.formulas.count < 20 {
                        Button {
                            let suffix = draft.formulas.count + 1
                            draft.formulas.append(NativeSmartCollectionFormula(
                                key: "formula_\(suffix)",
                                name: "公式 \(suffix)",
                                expression: "0"
                            ))
                        } label: { Label("添加公式", systemImage: "function") }
                    }
                    Text("支持 Property/文章字段、+ − × ÷、比较、if、round、today、date、daysBetween、formatDate 等。带空格的 Property 使用 prop(\"截止日期\")。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("表格列") {
                    ForEach($draft.columns) { $column in
                        SmartCollectionColumnEditorRow(
                            column: $column,
                            formulas: draft.formulas,
                            onMoveUp: { moveColumn(column.id, offset: -1) },
                            onMoveDown: { moveColumn(column.id, offset: 1) },
                            onDelete: { draft.columns.removeAll(where: { $0.id == column.id }) }
                        )
                    }
                    if draft.columns.count < 30 {
                        Menu {
                            Button("文章字段") { draft.columns.append(.system(.title, width: 180)) }
                            Button("Property") {
                                draft.columns.append(NativeSmartCollectionColumn(
                                    source: .property,
                                    key: "property",
                                    title: "Property"
                                ))
                            }
                            Button("公式") {
                                let formula = draft.formulas.first
                                draft.columns.append(NativeSmartCollectionColumn(
                                    source: .formula,
                                    key: formula?.key ?? "formula",
                                    title: formula?.name ?? "公式"
                                ))
                            }
                        } label: { Label("添加列", systemImage: "plus.rectangle.on.rectangle") }
                    }
                    Text("列顺序、80–480 pt 宽度、隐藏状态和汇总方式会随集合保存。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("筛选") {
                    if draft.hasAdvancedFilter {
                        Label("此 Base 使用递归 and/or/not；请在 .base YAML 中编辑高级筛选。应用会原样保留。", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("组合逻辑", selection: $draft.matchMode) {
                        ForEach(NativeSmartCollectionMatchMode.allCases) { Text($0.label).tag($0) }
                    }
                    ForEach($draft.rules) { $rule in
                        SmartCollectionRuleRow(rule: $rule) {
                            draft.rules.removeAll(where: { $0.id == rule.id })
                        }
                    }
                    Button {
                        guard draft.rules.count < 20 else { return }
                        draft.rules.append(NativeSmartCollectionRule())
                    } label: {
                        Label("添加筛选条件", systemImage: "plus")
                    }
                    Text("属性筛选会读取文章 YAML/Properties 中保存到 SQLite 的键值。日期格式为 YYYY-MM-DD。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(draft.hasAdvancedFilter)

                Section("排序优先级") {
                    ForEach($draft.sorts) { $sort in
                        HStack {
                            Picker("字段", selection: $sort.field) {
                                ForEach(NativeArticleSortField.allCases) { Text($0.label).tag($0) }
                            }
                            Picker("方向", selection: $sort.ascending) {
                                Text("升序").tag(true)
                                Text("降序").tag(false)
                            }
                            Button(role: .destructive) {
                                draft.sorts.removeAll(where: { $0.id == sort.id })
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                    if draft.sorts.count < 3 {
                        Button {
                            draft.sorts.append(NativeArticleSortDescriptor(field: .title, ascending: true))
                        } label: {
                            Label("添加次级排序", systemImage: "plus")
                        }
                    }
                    Text("排序按从上到下的优先级执行。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let originalCollection {
                    Button("删除", role: .destructive) {
                        Task {
                            await model.deleteSmartCollection(originalCollection)
                            dismiss()
                        }
                    }
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    isSaving = true
                    Task {
                        if await model.saveSmartCollection(draft) { dismiss() }
                        isSaving = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isSaving
                        || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !draft.rules.allSatisfy(\.isValid)
                        || !draft.formulas.allSatisfy(\.isValid)
                        || !columnsAreValid
                )
            }
            .padding(16)
        }
        .frame(width: 820, height: 820)
    }

    private var columnsAreValid: Bool {
        draft.columns.allSatisfy { column in
            switch column.source {
            case .system: return NativeSmartCollectionSystemField(rawValue: column.key) != nil
            case .property: return NativeArticleProperties.isValidKey(column.key)
            case .formula:
                return draft.formulas.contains { $0.key.caseInsensitiveCompare(column.key) == .orderedSame }
            }
        }
    }

    private func moveColumn(_ id: UUID, offset: Int) {
        guard let source = draft.columns.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard draft.columns.indices.contains(destination) else { return }
        draft.columns.swapAt(source, destination)
    }
}

private struct SmartCollectionFormulaRow: View {
    @Binding var formula: NativeSmartCollectionFormula
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                TextField("公式键", text: $formula.key).frame(width: 140)
                TextField("显示名称", text: $formula.name).frame(width: 160)
                TextField("表达式", text: $formula.expression)
                    .font(.system(.body, design: .monospaced))
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
        }
    }
}

private struct SmartCollectionColumnEditorRow: View {
    @Binding var column: NativeSmartCollectionColumn
    let formulas: [NativeSmartCollectionFormula]
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Picker("来源", selection: $column.source) {
                    ForEach(NativeSmartCollectionColumnSource.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 125)
                .onChange(of: column.source) { source in
                    column.basePropertyOverride = nil
                    switch source {
                    case .system: column.key = NativeSmartCollectionSystemField.title.rawValue
                    case .property: column.key = "property"
                    case .formula: column.key = formulas.first?.key ?? "formula"
                    }
                }
                .onChange(of: column.key) { _ in column.basePropertyOverride = nil }

                switch column.source {
                case .system:
                    Picker("字段", selection: $column.key) {
                        ForEach(NativeSmartCollectionSystemField.allCases) {
                            Text($0.label).tag($0.rawValue)
                        }
                    }
                    .frame(width: 150)
                case .property:
                    TextField("Property 名", text: $column.key).frame(width: 150)
                    Picker("类型", selection: $column.propertyKind) {
                        ForEach(NativeArticlePropertyKind.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(width: 110)
                case .formula:
                    Picker("公式", selection: $column.key) {
                        ForEach(formulas) { Text($0.name).tag($0.key) }
                    }
                    .frame(width: 180)
                }

                TextField("列标题", text: $column.title).frame(minWidth: 120)
                Button(action: onMoveUp) { Image(systemName: "arrow.up") }.buttonStyle(.borderless)
                Button(action: onMoveDown) { Image(systemName: "arrow.down") }.buttonStyle(.borderless)
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            HStack(spacing: 12) {
                Stepper("宽度 \(Int(column.width))", value: $column.width, in: 80...480, step: 10)
                    .frame(width: 170)
                Toggle("隐藏", isOn: $column.isHidden).toggleStyle(.checkbox)
                Picker("汇总", selection: $column.summary) {
                    Text("无汇总").tag(nil as NativeSmartCollectionSummary?)
                    ForEach(NativeSmartCollectionSummary.allCases) { summary in
                        Text(summary.label).tag(summary as NativeSmartCollectionSummary?)
                    }
                }
                .frame(width: 150)
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

private struct SmartCollectionRuleRow: View {
    @Binding var rule: NativeSmartCollectionRule
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("字段", selection: $rule.field) {
                ForEach(NativeSmartCollectionField.allCases) { Text($0.label).tag($0) }
            }
            .frame(width: 125)
            .onChange(of: rule.field) { field in
                rule.comparison = rule.compatibleOperators[0]
                if field == .status { rule.value = NativeArticleStatus.published.rawValue }
                else if field.isNumber { rule.value = "0" }
                else if field.isDate { rule.value = Self.today }
                else { rule.value = "" }
            }

            if rule.field == .property {
                TextField("属性名", text: $rule.propertyKey).frame(width: 110)
            }

            Picker("比较", selection: $rule.comparison) {
                ForEach(rule.compatibleOperators) { Text($0.label).tag($0) }
            }
            .frame(width: 105)

            if rule.comparison.needsValue {
                if rule.field == .status {
                    Picker("值", selection: $rule.value) {
                        ForEach(NativeArticleStatus.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .frame(width: 110)
                } else {
                    TextField(rule.field.isDate ? "YYYY-MM-DD" : "值", text: $rule.value)
                        .frame(minWidth: 130)
                }
            } else {
                Spacer(minLength: 130)
            }

            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
    }

    private static var today: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
