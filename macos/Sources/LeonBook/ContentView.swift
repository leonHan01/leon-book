import SwiftUI

public struct ContentView: View {
    @ObservedObject var model: NativeAppModel
    @StateObject private var workspaceLayout: NativeWorkspaceLayoutState
    @StateObject private var readingPreferences: NativeReadingPreferences
    @StateObject private var pageStateCache: NativeNavigationPageStateCache
    @State private var isPresentingNewUser = false

    public init(model: NativeAppModel) {
        self.model = model
        _workspaceLayout = StateObject(wrappedValue: NativeWorkspaceLayoutState())
        _readingPreferences = StateObject(wrappedValue: NativeReadingPreferences())
        _pageStateCache = StateObject(wrappedValue: NativeNavigationPageStateCache())
    }

    public var body: some View {
        NavigationSplitView {
            NativeSidebar(model: model, navigation: model.navigation, isPresentingNewUser: $isPresentingNewUser)
                .navigationSplitViewColumnWidth(
                    min: 210,
                    ideal: CGFloat(workspaceLayout.navigationSidebarWidth),
                    max: 380
                )
        } detail: {
            NativeNavigationDetail(
                model: model,
                navigation: model.navigation,
                workspaceLayout: workspaceLayout,
                readingPreferences: readingPreferences,
                pageStateCache: pageStateCache
            )
        }
        .frame(minWidth: 1_080, minHeight: 680)
        .toolbar {
            ToolbarItemGroup {
                Button { model.executeCommand(.globalSearch) } label: {
                    Label("搜索", systemImage: "magnifyingglass")
                }

                Button { model.executeCommand(.reload) } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)

                Button { model.executeCommand(.newArticle) } label: {
                    Label("新文章", systemImage: "square.and.pencil")
                }

                Button { model.executeCommand(.moments) } label: {
                    Label("发微博", systemImage: "square.grid.2x2")
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let error = model.errorMessage {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error).lineLimit(2)
                    Spacer()
                    if model.needsWorkDirectorySelection {
                        Button("选择工作目录") { model.chooseWorkDirectory() }
                    }
                    Button("关闭") { model.errorMessage = nil }
                }
                .font(.callout)
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding()
            }
        }
        .sheet(isPresented: $isPresentingNewUser) {
            NewUserSheet(model: model, isPresented: $isPresentingNewUser)
        }
        .sheet(item: $model.searchPresentation) { presentation in
            NativeSearchSheet(model: model, presentation: presentation)
        }
        .sheet(item: $model.articleSourceConflict) { conflict in
            ArticleSourceConflictSheet(model: model, conflict: conflict)
        }
        .focusedSceneObject(model)
        .task {
            workspaceLayout.prepare(for: model.currentUser.id)
            readingPreferences.prepare(for: model.currentUser.id)
        }
        .onChange(of: model.currentUser.id) { userID in
            workspaceLayout.prepare(for: userID)
            readingPreferences.prepare(for: userID)
        }
        .onOpenURL(perform: model.handleAutomationURL)
    }
}

private struct ArticleSourceConflictSheet: View {
    @ObservedObject var model: NativeAppModel
    let conflict: NativeArticleSourceConflict

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Markdown 修改冲突").font(.title2.weight(.semibold))
                Text("外部文件 \(conflict.external.sourceRelativePath) 在编辑期间发生变化。比较后再决定，不会自动覆盖任何版本。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            Divider()
            HStack(spacing: 0) {
                conflictVersion(
                    title: "编辑器中的版本",
                    subtitle: conflict.local.title,
                    body: conflict.local.body
                )
                Divider()
                conflictVersion(
                    title: "外部 Markdown 版本",
                    subtitle: conflict.external.title,
                    body: conflict.external.body
                )
            }
            Divider()
            HStack {
                Button("保留两份") { model.resolveArticleSourceConflictAsCopy() }
                Spacer()
                Button("使用外部版本") { model.resolveArticleSourceConflictUsingExternal() }
                Button("用编辑器版本覆盖") { model.resolveArticleSourceConflictByOverwriting() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(minWidth: 860, minHeight: 580)
    }

    private func conflictVersion(title: String, subtitle: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(subtitle).font(.callout.weight(.medium)).lineLimit(2)
            ScrollView {
                Text(body)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct NativeSidebar: View {
    @ObservedObject var model: NativeAppModel
    @ObservedObject var navigation: NativeNavigationState
    @Binding var isPresentingNewUser: Bool
    @State private var smartCollectionEditorRequest: SmartCollectionEditorRequest?

    var body: some View {
        let articleFolderFilters = model.availableArticleFolderFilters

        List {
            Section("用户") {
                Menu {
                    ForEach(model.users) { user in
                        Button {
                            model.selectUser(user)
                        } label: {
                            Label(user.name, systemImage: user.id == model.currentUser.id ? "checkmark" : "person")
                        }
                        .disabled(user.id == model.currentUser.id)
                    }
                    Divider()
                    Button("新建用户…") { isPresentingNewUser = true }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(model.currentUser.name, systemImage: "person.crop.circle.fill")
                        Text("独立工作空间")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(
                    model.isLoading
                        || model.isSwitchingWorkspace
                        || model.isSaving
                        || model.isPublishingMoment
                        || model.isPublishingQuestion
                        || model.isPublishingQuestionAnswer
                )
            }

            Section("leon-book") {
                sidebarButton(.dashboard, title: "概览", icon: "rectangle.grid.2x2")
                articleLibraryButton
                if model.isKnowledgeGraphModuleEnabled {
                    sidebarButton(.graph, title: "关系图", icon: "point.3.connected.trianglepath.dotted")
                }
                sidebarButton(.moments, title: "微博", icon: "rectangle.3.group")
                sidebarButton(.qAndA, title: "问答", icon: "questionmark.bubble")
                sidebarButton(.editor, title: "写作", icon: "square.and.pencil")
                sidebarButton(.trash, title: "回收站 \(model.trashItems.count)", icon: "trash")
            }

            if !articleFolderFilters.isEmpty {
                Section("文件夹") {
                    ForEach(articleFolderFilters) { folder in
                        Button {
                            model.showArticleFolder(folder.path)
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "folder")
                                Text(folder.name).lineLimit(1)
                                Spacer()
                                Text("\(folder.count)").foregroundStyle(.secondary)
                            }
                            .padding(.leading, CGFloat(folder.depth) * 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(SidebarNavigationButtonStyle(
                            isSelected: navigation.section == .articles
                                && model.selectedArticleFolderPath == folder.path
                        ))
                    }
                }
            }

            Section("智能集合") {
                ForEach(model.smartCollections) { collection in
                    Button {
                        model.showSmartCollection(collection)
                    } label: {
                        Label(collection.name, systemImage: "rectangle.stack.badge.play")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SidebarNavigationButtonStyle(
                        isSelected: navigation.section == .articles
                            && model.selectedSmartCollectionID == collection.id
                    ))
                    .contextMenu {
                        Button("编辑") {
                            smartCollectionEditorRequest = SmartCollectionEditorRequest(collection: collection)
                        }
                        Button("删除", role: .destructive) {
                            Task { await model.deleteSmartCollection(collection) }
                        }
                    }
                }
                Button {
                    smartCollectionEditorRequest = SmartCollectionEditorRequest(collection: nil)
                } label: {
                    Label("新建智能集合…", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            if !model.bookmarks.isEmpty {
                Section("收藏") {
                    ForEach(model.bookmarks) { bookmark in
                        Button {
                            model.openBookmark(bookmark)
                        } label: {
                            Label(bookmark.title, systemImage: bookmark.target.systemImage)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("移除收藏", role: .destructive) {
                                model.deleteBookmark(bookmark)
                            }
                        }
                    }
                }
            }

            Section("状态") {
                Label {
                    Text(model.storageReady ? "本地文件已连接" : "正在读取本地文件")
                } icon: {
                    Image(systemName: model.storageReady ? "checkmark.circle.fill" : "circle.dotted")
                        .foregroundStyle(model.storageReady ? .green : .secondary)
                }
                Text("\(model.publishedArticleCount) 篇已发布 · \(model.draftArticleCount) 篇草稿 · \(model.totalMomentCount) 条微博 · \(model.totalQuestionCount) 个问题")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                sidebarButton(.settings, title: "设置", icon: "gearshape")
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 210)
        .sheet(item: $smartCollectionEditorRequest) { request in
            SmartCollectionEditorSheet(model: model, collection: request.collection)
        }
    }

    private var articleLibraryButton: some View {
        Button {
            model.showAllArticles()
        } label: {
            Label("全部文章", systemImage: "doc.text")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarNavigationButtonStyle(
            isSelected: navigation.section == .articles
                && model.selectedSmartCollectionID == nil
                && model.selectedArticleFolderPath == nil
        ))
        .foregroundStyle(
            navigation.section == .articles
                && model.selectedSmartCollectionID == nil
                && model.selectedArticleFolderPath == nil
                ? Color.accentColor : .primary
        )
    }

    @ViewBuilder
    private func sidebarButton(_ section: NativeSection, title: String, icon: String) -> some View {
        Button {
            model.section = section
            if section == .editor && model.editor.isNew == false { model.newArticle() }
        } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarNavigationButtonStyle(isSelected: navigation.section == section))
        .foregroundStyle(navigation.section == section ? Color.accentColor : .primary)
    }
}

private struct SidebarNavigationButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        SidebarNavigationButtonBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct SidebarNavigationButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.easeOut(duration: 0.08), value: isHovered)
            .animation(.easeOut(duration: 0.06), value: configuration.isPressed)
            .onHover { isHovered = $0 }
    }

    private var backgroundColor: Color {
        if configuration.isPressed {
            return Color.accentColor.opacity(isSelected ? 0.22 : 0.12)
        }
        if isSelected {
            return Color.accentColor.opacity(isHovered ? 0.18 : 0.12)
        }
        return isHovered ? Color.primary.opacity(0.07) : .clear
    }
}

private struct NativeNavigationDetail: View {
    let model: NativeAppModel
    @ObservedObject var navigation: NativeNavigationState
    @ObservedObject var workspaceLayout: NativeWorkspaceLayoutState
    @ObservedObject var readingPreferences: NativeReadingPreferences
    @ObservedObject var pageStateCache: NativeNavigationPageStateCache

    var body: some View {
        switch navigation.section {
        case .dashboard: DashboardView(model: model)
        case .articles: ArticleListView(model: model)
        case .graph: ArticleGraphView(model: model, pageState: pageStateCache.graph)
        case .moments:
            MomentFeedView(
                model: model,
                pageState: pageStateCache.moments
            )
        case .qAndA: QAndAView(model: model)
        case .reader: ArticleReaderView(
            model: model,
            workspaceLayout: workspaceLayout,
            readingPreferences: readingPreferences
        )
        case .editor: ArticleEditorView(
            model: model,
            workspaceLayout: workspaceLayout,
            readingPreferences: readingPreferences
        )
        case .trash: TrashView(model: model)
        case .settings: NativeSettingsView(model: model, readingPreferences: readingPreferences)
        }
    }
}

private struct NewUserSheet: View {
    @ObservedObject var model: NativeAppModel
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("新建用户")
                .font(.title2.weight(.semibold))
            Text("每位用户都拥有独立的文章、草稿、媒体和创作活动。")
                .foregroundStyle(.secondary)
            TextField("用户名", text: $name)
                .textFieldStyle(.roundedBorder)
                .onChange(of: name) { _ in validationMessage = nil }
                .onSubmit { createUser() }
            if let validationMessage {
                Text(validationMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("新建并进入") { createUser() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSwitchingWorkspace)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func createUser() {
        Task {
            if await model.createUser(named: name) {
                isPresented = false
            } else {
                validationMessage = model.errorMessage
            }
        }
    }
}

private struct DashboardView: View {
    @ObservedObject var model: NativeAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("leon-book")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                    Text("你的本地写作空间")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 14) {
                    StatCard(title: "已发布", value: "\(model.publishedArticleCount)", color: .blue)
                    StatCard(title: "草稿", value: "\(model.draftArticleCount)", color: .orange)
                    StatCard(title: "全部文章", value: "\(model.articles.count)", color: .purple)
                    StatCard(title: "微博", value: "\(model.totalMomentCount)", color: .pink)
                }

                ActivityHeatmapView(activity: model.activity)

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("最近编辑")
                            .font(.title2.weight(.semibold))
                        Spacer()
                        Button("查看全部") { model.section = .articles }
                    }

                    if model.articles.isEmpty {
                        EmptyState(title: "还没有文章", message: "从一篇新笔记开始。", actionTitle: "写第一篇") { model.newArticle() }
                    } else {
                        ForEach(Array(model.articles.prefix(5))) { article in
                            ArticleRow(article: article) { model.selectSlug(article.slug) }
                        }
                    }
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(38)
        }
    }
}

private struct ActivityHeatmapView: View {
    let activity: [NativeActivityDay]

    private let cellSize: CGFloat = 12
    private let cellSpacing: CGFloat = 3

    private var total: Int { activity.reduce(0) { $0 + $1.count } }

    private var activityByDate: [String: Int] {
        Dictionary(uniqueKeysWithValues: activity.map { ($0.date, $0.count) })
    }

    private var weeks: [[HeatmapDay]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let firstTrackedDay = calendar.date(byAdding: .day, value: -364, to: today) ?? today
        let weekday = calendar.component(.weekday, from: firstTrackedDay)
        let weekdayOffset = (weekday - calendar.firstWeekday + 7) % 7
        let firstCalendarDay = calendar.date(byAdding: .day, value: -weekdayOffset, to: firstTrackedDay) ?? firstTrackedDay
        var days: [HeatmapDay] = []
        var currentDay = firstCalendarDay

        while currentDay <= today {
            let date = dateKey(currentDay, calendar: calendar)
            days.append(HeatmapDay(date: date, count: activityByDate[date] ?? 0, tracked: currentDay >= firstTrackedDay))
            currentDay = calendar.date(byAdding: .day, value: 1, to: currentDay) ?? today.addingTimeInterval(24 * 60 * 60)
        }

        return stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("创作活动")
                        .font(.title2.weight(.semibold))
                    Text("发布文章、编辑文章或上传图片时留下记录")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("过去一年 \(total) 次活动")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    weekdayLabels
                    HStack(alignment: .top, spacing: cellSpacing) {
                        ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                            VStack(spacing: cellSpacing) {
                                ForEach(week) { day in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(color(for: day.count))
                                        .frame(width: cellSize, height: cellSize)
                                        .opacity(day.tracked ? 1 : 0)
                                        .help(day.tracked ? "\(day.date)：\(day.count) 次创作活动" : "")
                                        .accessibilityLabel(day.tracked ? "\(day.date)，\(day.count) 次创作活动" : "")
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 5) {
                Spacer()
                Text("少")
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: level == 4 ? 5 : level))
                        .frame(width: cellSize, height: cellSize)
                }
                Text("多")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }

    private var weekdayLabels: some View {
        VStack(spacing: cellSpacing) {
            ForEach(Array(heatmapWeekdaySymbols.enumerated()), id: \.offset) { _, label in
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: cellSize, alignment: .trailing)
            }
        }
    }

    private var heatmapWeekdaySymbols: [String] {
        let symbols = ["日", "一", "二", "三", "四", "五", "六"]
        let start = Calendar.current.firstWeekday - 1
        let shown = Set(["一", "三", "五"])
        return (0..<7).map { index in
            let symbol = symbols[(index + start) % 7]
            return shown.contains(symbol) ? symbol : ""
        }
    }

    private func color(for count: Int) -> Color {
        switch count {
        case ...0: Color.secondary.opacity(0.13)
        case 1: Color.accentColor.opacity(0.28)
        case 2: Color.accentColor.opacity(0.48)
        case 3...4: Color.accentColor.opacity(0.7)
        default: Color.accentColor
        }
    }

    private func dateKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

private struct HeatmapDay: Identifiable {
    let date: String
    let count: Int
    let tracked: Bool

    var id: String { date }
}

private struct StatCard: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ArticleListView: View {
    @ObservedObject var model: NativeAppModel

    var body: some View {
        SmartArticleLibraryView(model: model)
    }
}

private struct ArticleTagFilterBar: View {
    @ObservedObject var model: NativeAppModel
    let tagFilters: [NativeArticleTagFilter]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("标签筛选", systemImage: "tag")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tagFilters) { tagFilter in
                        let isSelected = model.isArticleTagSelected(tagFilter.tag)
                        Button {
                            model.toggleArticleTagFilter(tagFilter.tag)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "tag")
                                Text("#\(tagFilter.tag)")
                                Text("\(tagFilter.count)")
                                    .foregroundStyle(isSelected ? .primary : .secondary)
                            }
                            .font(.caption)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(
                                isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                        .help("筛选标签 #\(tagFilter.tag)：\(tagFilter.count) 篇文章")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("文章标签筛选，可多选，任一匹配")
    }
}

private struct ArticleRow: View {
    let article: NativeArticleSummary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !article.tags.isEmpty {
                        Text(article.tags.map { "#\($0)" }.joined(separator: "  "))
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .lineLimit(1)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(article.status.label).font(.caption.weight(.medium))
                        .foregroundStyle(article.status == .published ? .green : .orange)
                    Label("\(article.pageViews) PV", systemImage: "eye")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(article.updatedAt.nativeDateLabel).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct EmptyState: View {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 34)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary)
            Button(actionTitle, action: action).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

extension String {
    var nativeDateLabel: String {
        guard let date = NativeTimestamp.date(from: self) else { return self }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
