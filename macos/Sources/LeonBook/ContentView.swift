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
        HStack(spacing: 0) {
            NativeWorkspaceRail(model: model, navigation: model.navigation)

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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NativeTheme.canvas)
            }
            .navigationSplitViewStyle(.balanced)
        }
        .frame(minWidth: 1_080, minHeight: 680)
        .toolbarBackground(NativeTheme.sidebar, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .disabled(model.isRestoringBackup)
        .environment(\.nativeDeclarativeExtensions, model.declarativeExtensions)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                NativeWorkspaceTitle(model: model, navigation: model.navigation)
            }
            ToolbarItem {
                Button { model.executeCommand(.newArticle) } label: {
                    Label("新文章", systemImage: "square.and.pencil")
                }
                .help("新文章")
            }
            ToolbarItem {
                Menu {
                    Button("搜索", systemImage: "magnifyingglass") { model.executeCommand(.globalSearch) }
                    Button("快速打开", systemImage: "doc.text.magnifyingglass") { model.executeCommand(.quickOpen) }
                    Button("命令面板", systemImage: "command") { model.executeCommand(.commandPalette) }
                    Divider()
                    Button("刷新", systemImage: "arrow.clockwise") { model.executeCommand(.reload) }
                        .disabled(model.isLoading)
                    Button("设置", systemImage: "gearshape") { model.section = .settings }
                } label: {
                    Label("工作区操作", systemImage: "ellipsis")
                }
                .help("工作区操作")
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
            loadPortableUIState(for: model.currentUser.id)
        }
        .onChange(of: model.currentUser.id) { userID in
            workspaceLayout.prepare(for: userID)
            readingPreferences.prepare(for: userID)
            loadPortableUIState(for: userID)
        }
        .onChange(of: model.portableSidecarRevision) { _ in
            loadPortableUIState(for: model.currentUser.id)
        }
        .onChange(of: workspaceLayout.profiles) { _ in
            persistPortableUIState(for: model.currentUser.id)
        }
        .onChange(of: workspaceLayout.activeLayoutID) { _ in
            persistPortableUIState(for: model.currentUser.id)
        }
        .onChange(of: readingPreferences.profile) { _ in
            persistPortableUIState(for: model.currentUser.id)
        }
        .onOpenURL(perform: model.handleAutomationURL)
        .nativeAppTheme()
    }

    private func loadPortableUIState(for userID: String) {
        guard model.isPortableSidecarEnabled else { return }
        let activeStore = model.store
        Task {
            do {
                if let state = try await activeStore.readPortableUIState() {
                    guard model.currentUser.id == userID else { return }
                    workspaceLayout.applyPortableState(state.workspaceLayouts, for: userID)
                    readingPreferences.applyPortableProfile(state.readingProfile, for: userID)
                } else if model.isPortableSidecarWritable {
                    let state = portableUIState(for: userID)
                    try await activeStore.writePortableUIState(state)
                }
            } catch {
                guard model.currentUser.id == userID else { return }
                model.errorMessage = ".leonbook 布局同步失败：\(error.localizedDescription)"
            }
        }
    }

    private func persistPortableUIState(for userID: String) {
        guard model.isPortableSidecarEnabled,
              model.isPortableSidecarWritable,
              model.currentUser.id == userID else { return }
        let state = portableUIState(for: userID)
        let activeStore = model.store
        Task {
            do {
                try await activeStore.writePortableUIState(state)
            } catch {
                guard model.currentUser.id == userID else { return }
                model.errorMessage = ".leonbook 布局写入失败：\(error.localizedDescription)"
            }
        }
    }

    private func portableUIState(for userID: String) -> NativePortableUIState {
        NativePortableUIState(
            workspaceLayouts: workspaceLayout.portableState(for: userID),
            readingProfile: readingPreferences.profile
        )
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
                    .nativePrimaryButton()
            }
            .padding(16)
        }
        .frame(minWidth: 860, minHeight: 580)
    }

    private func conflictVersion(title: String, subtitle: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringKey(title)).font(.headline)
            Text(subtitle).font(.callout.weight(.medium)).lineLimit(2)
            ScrollView {
                Text(body)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SidebarNavigationButtonStyle: ButtonStyle {
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
            .foregroundStyle(isSelected ? NativeTheme.deepBlue : NativeTheme.textPrimary)
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
            return NativeTheme.selection
        }
        if isSelected {
            return NativeTheme.selection
        }
        return isHovered ? NativeTheme.surfaceSecondary : .clear
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
        case .canvas: InfiniteCanvasView(model: model)
        case .moments:
            MomentFeedView(
                model: model,
                pageState: pageStateCache.moments
            )
        case .qAndA: QAndAView(model: model)
        case .todos: TodoListView(model: model)
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
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("概览")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(NativeTheme.textSecondary)
                    Text("你的本地写作空间")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(NativeTheme.textPrimary)
                }

                newArticleCard

                HStack(spacing: 0) {
                    StatCard(title: "全部文章", value: "\(model.articles.count)")
                    Divider().frame(height: 32)
                    StatCard(title: "已发布", value: "\(model.publishedArticleCount)")
                    Divider().frame(height: 32)
                    StatCard(title: "草稿", value: "\(model.draftArticleCount)")
                    Divider().frame(height: 32)
                    StatCard(title: "微博", value: "\(model.totalMomentCount)")
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("最近编辑")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Button { model.showAllArticles() } label: {
                            HStack(spacing: 5) {
                                Text("查看全部")
                                Image(systemName: "arrow.right").font(.system(size: 10))
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(NativeTheme.textSecondary)
                    }

                    if model.articles.isEmpty {
                        EmptyState(title: "还没有文章", message: "从一篇新笔记开始。", actionTitle: "写第一篇") { model.newArticle() }
                    } else {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.articles.prefix(5))) { article in
                                ArticleRow(article: article) { model.selectSlug(article.slug) }
                            }
                        }
                    }
                }

                Divider()
                ActivityHeatmapView(activity: model.activity)
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(NativeTheme.canvas)
    }

    private var newArticleCard: some View {
        Button { model.executeCommand(.newArticle) } label: {
            VStack(alignment: .leading, spacing: 28) {
                Text("从一篇新笔记开始。")
                    .font(.system(size: 15))
                    .foregroundStyle(NativeTheme.textSecondary)
                HStack {
                    Label("新文章", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(NativeTheme.textPrimary)
                    Spacer()
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(NativeTheme.buttonBlue, in: Circle())
                }
            }
            .padding(20)
            .background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18).strokeBorder(NativeTheme.border)
            }
            .shadow(color: NativeTheme.shadow.opacity(0.025), radius: 12, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("新文章")
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
                        .font(.system(size: 14, weight: .semibold))
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
                                        .help(day.tracked ? Text("\(day.date)：\(day.count) 次创作活动") : Text(""))
                                        .accessibilityLabel(day.tracked ? Text("\(day.date)，\(day.count) 次创作活动") : Text(""))
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
        .padding(.vertical, 4)
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
        var calendar = Calendar.current
        calendar.locale = NativeLocalization.currentLanguage.locale
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let start = calendar.firstWeekday - 1
        let shownWeekdays = Set([2, 4, 6])
        return (0..<7).map { index in
            let weekdayIndex = (index + start) % 7
            let weekday = weekdayIndex + 1
            return shownWeekdays.contains(weekday) ? symbols[weekdayIndex] : ""
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

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 11))
                .foregroundStyle(NativeTheme.textSecondary)
            Text(value)
                .font(.system(size: 24, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(NativeTheme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
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
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(NativeTheme.surfaceSecondary)
                    .frame(width: 36, height: 40)
                    .overlay {
                        Image(systemName: article.status == .published ? "doc.text.fill" : "doc.badge.ellipsis")
                            .foregroundStyle(NativeTheme.textSecondary)
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text(article.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
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
                    Text(LocalizedStringKey(article.status.label)).font(.caption.weight(.medium))
                        .foregroundStyle(article.status == .published ? NativeTheme.accent : NativeTheme.textSecondary)
                    Label("\(article.pageViews) PV", systemImage: "eye")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(article.updatedAt.nativeDateLabel).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(isHovered ? NativeTheme.surfaceSecondary : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
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
            Text(LocalizedStringKey(title)).font(.headline)
            Text(LocalizedStringKey(message)).font(.callout).foregroundStyle(.secondary)
            Button(action: action) {
                Text(LocalizedStringKey(actionTitle))
            }
            .nativePrimaryButton()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

extension String {
    var nativeDateLabel: String {
        guard let date = NativeTimestamp.date(from: self) else { return self }
        return date.formatted(
            .dateTime.year().month(.abbreviated).day()
                .locale(NativeLocalization.currentLanguage.locale)
        )
    }
}
