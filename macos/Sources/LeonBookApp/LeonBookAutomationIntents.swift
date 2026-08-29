import AppIntents
import Foundation
import LeonBook

struct LeonBookNewArticleIntent: AppIntent {
    static let title: LocalizedStringResource = "新建 leon-book 文章"
    static let description = IntentDescription("打开 leon-book，并预填一篇新文章。")
    static let openAppWhenRun = true

    @Parameter(title: "标题") var articleTitle: String?
    @Parameter(title: "正文") var content: String?
    @Parameter(title: "来源网址") var sourceURL: URL?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        NativeAutomationInbox.enqueue(NativeCommandInvocation.newArticle(
            title: articleTitle,
            content: content,
            sourceURL: sourceURL?.absoluteString
        ))
        return .result(dialog: "已在 leon-book 中打开新文章。")
    }
}

struct LeonBookOpenArticleIntent: AppIntent {
    static let title: LocalizedStringResource = "打开 leon-book 文章"
    static let description = IntentDescription("根据稳定 slug 打开一篇 leon-book 文章。")
    static let openAppWhenRun = true

    @Parameter(title: "文章 slug") var slug: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        NativeAutomationInbox.enqueue(NativeCommandInvocation.openArticle(slug: slug))
        return .result(dialog: "正在 leon-book 中打开文章。")
    }
}

struct LeonBookSearchIntent: AppIntent {
    static let title: LocalizedStringResource = "搜索 leon-book"
    static let description = IntentDescription("打开 leon-book 全文搜索并填入查询。")
    static let openAppWhenRun = true

    @Parameter(title: "搜索内容") var query: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        NativeAutomationInbox.enqueue(NativeCommandInvocation.search(query: query))
        return .result(dialog: "已在 leon-book 中开始搜索。")
    }
}

struct LeonBookTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "打开 leon-book 今天"
    static let description = IntentDescription("打开 leon-book 的今日动态。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        NativeAutomationInbox.enqueue(NativeCommandInvocation.today)
        return .result(dialog: "已打开 leon-book 今日动态。")
    }
}

struct LeonBookAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LeonBookNewArticleIntent(),
            phrases: ["用 \(.applicationName) 新建文章"],
            shortTitle: "新建文章",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: LeonBookOpenArticleIntent(),
            phrases: ["用 \(.applicationName) 打开文章"],
            shortTitle: "打开文章",
            systemImageName: "doc.text.magnifyingglass"
        )
        AppShortcut(
            intent: LeonBookSearchIntent(),
            phrases: ["用 \(.applicationName) 搜索"],
            shortTitle: "搜索",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: LeonBookTodayIntent(),
            phrases: ["用 \(.applicationName) 打开今天"],
            shortTitle: "今天",
            systemImageName: "calendar"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .blue
}
