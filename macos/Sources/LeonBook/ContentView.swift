import SwiftUI

public struct ContentView: View {
    @ObservedObject var model: NativeAppModel
    @State private var isPresentingNewUser = false

    public init(model: NativeAppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 980, minHeight: 680)
        .toolbar {
            ToolbarItemGroup {
                Button { Task { try? await model.reload() } } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)

                Button { model.newArticle() } label: {
                    Label("新文章", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)

                Button { model.section = .moments } label: {
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
    }

    private var sidebar: some View {
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
                .disabled(model.isLoading || model.isSwitchingWorkspace || model.isSaving || model.isPublishingMoment)
            }

            Section("leon-book") {
                sidebarButton(.dashboard, title: "概览", icon: "rectangle.grid.2x2")
                sidebarButton(.articles, title: "全部文章", icon: "doc.text")
                sidebarButton(.moments, title: "微博", icon: "rectangle.3.group")
                sidebarButton(.editor, title: "写作", icon: "square.and.pencil")
                sidebarButton(.trash, title: "回收站 \(model.trashItems.count)", icon: "trash")
            }

            Section("状态") {
                Label {
                    Text(model.storageReady ? "本地文件已连接" : "正在读取本地文件")
                } icon: {
                    Image(systemName: model.storageReady ? "checkmark.circle.fill" : "circle.dotted")
                        .foregroundStyle(model.storageReady ? .green : .secondary)
                }
                Text("\(model.publishedArticles.count) 篇已发布 · \(model.draftArticles.count) 篇草稿 · \(model.moments.count) 条微博")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                sidebarButton(.settings, title: "设置", icon: "gearshape")
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 210)
    }

    @ViewBuilder
    private func sidebarButton(_ section: NativeSection, title: String, icon: String) -> some View {
        Button {
            model.section = section
            if section == .editor && model.editor.isNew == false { model.newArticle() }
        } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.section == section ? Color.accentColor : .primary)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.section {
        case .dashboard: DashboardView(model: model)
        case .articles: ArticleListView(model: model)
        case .moments: MomentFeedView(model: model)
        case .reader: ArticleReaderView(model: model)
        case .editor: ArticleEditorView(model: model)
        case .trash: TrashView(model: model)
        case .settings: NativeSettingsView(model: model)
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
                    StatCard(title: "已发布", value: "\(model.publishedArticles.count)", color: .blue)
                    StatCard(title: "草稿", value: "\(model.draftArticles.count)", color: .orange)
                    StatCard(title: "全部文章", value: "\(model.articles.count)", color: .purple)
                    StatCard(title: "微博", value: "\(model.moments.count)", color: .pink)
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
        VStack(spacing: 0) {
            HStack {
                Text("全部文章").font(.title2.weight(.semibold))
                Spacer()
                TextField("搜索标题、分类或标签", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }
            .padding(22)
            Divider()

            if model.filteredArticles.isEmpty {
                EmptyState(title: "没有匹配的文章", message: "试试其他搜索词，或者开始写一篇新文章。", actionTitle: "新文章") { model.newArticle() }
            } else {
                List(model.filteredArticles) { article in
                    ArticleRow(article: article) { model.selectSlug(article.slug) }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 18, bottom: 5, trailing: 18))
                }
                .listStyle(.plain)
            }
        }
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
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(article.status.label).font(.caption.weight(.medium))
                        .foregroundStyle(article.status == .published ? .green : .orange)
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
