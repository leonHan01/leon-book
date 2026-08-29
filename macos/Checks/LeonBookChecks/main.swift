import Darwin
import Foundation

var failures: [String] = []

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures.append(message) }
}

let macosRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let sourcePath = { (name: String) in macosRoot.appendingPathComponent("Sources/LeonBook/\(name)").path }
let appSourcePath = { (name: String) in macosRoot.appendingPathComponent("Sources/LeonBookApp/\(name)").path }
let resourcePath = { (name: String) in macosRoot.appendingPathComponent("Resources/\(name)").path }

expect(FileManager.default.fileExists(atPath: sourcePath("ContentView.swift")), "native SwiftUI content view should exist")
expect(FileManager.default.fileExists(atPath: sourcePath("LocalBlogStore.swift")), "native local store should exist")
expect(FileManager.default.fileExists(atPath: sourcePath("SQLiteDatabase.swift")), "SQLite database adapter should exist")
expect(FileManager.default.fileExists(atPath: sourcePath("LocalBackupManager.swift")), "local backup manager should exist")
expect(FileManager.default.fileExists(atPath: sourcePath("MarkdownRenderer.swift")), "native Markdown renderer should exist")
expect(FileManager.default.fileExists(atPath: sourcePath("MarkdownSourceEventMonitor.swift")), "Markdown filesystem event monitor should exist")
expect(FileManager.default.fileExists(atPath: sourcePath("ObsidianVaultImporter.swift")), "Obsidian Vault importer should exist")
expect(FileManager.default.fileExists(atPath: sourcePath("SmartCollectionModels.swift")), "smart collection models should exist")
expect(FileManager.default.fileExists(atPath: sourcePath("SmartCollectionSQL.swift")), "smart collection SQL compiler should exist")
expect(FileManager.default.fileExists(atPath: sourcePath("SmartCollectionViews.swift")), "smart collection views should exist")
expect(FileManager.default.fileExists(atPath: sourcePath("ArticleLinkIdentityIndex.swift")), "article link identity index should exist")
expect(FileManager.default.fileExists(atPath: sourcePath("AutomationRouting.swift")), "automation URL routing should exist")
expect(FileManager.default.fileExists(atPath: sourcePath("WorkspaceLayouts.swift")), "saved workspace layouts should exist")
expect(FileManager.default.fileExists(atPath: sourcePath("ArticleEditorViews.swift")), "article editor views should be a separate module")
expect(FileManager.default.fileExists(atPath: sourcePath("ArticleProperties.swift")), "typed article properties should be a separate module")
expect(FileManager.default.fileExists(atPath: sourcePath("ArticleGraphProjection.swift")), "article graph projection module should exist")
expect(FileManager.default.fileExists(atPath: sourcePath("NavigationPageState.swift")), "lightweight navigation page state cache should exist")
expect(FileManager.default.fileExists(atPath: sourcePath("NativeAppModel+Article.swift")), "article app-model module should exist")
expect(FileManager.default.fileExists(atPath: sourcePath("NativeAppModel+Backup.swift")), "backup app-model module should exist")
expect(FileManager.default.fileExists(atPath: sourcePath("NativeAppModel+Import.swift")), "import app-model module should exist")
expect(FileManager.default.fileExists(atPath: sourcePath("NativeAppModel+Search.swift")), "search app-model module should exist")
expect(FileManager.default.fileExists(atPath: appSourcePath("LeonBookAutomationIntents.swift")), "App Intents should exist")
expect(!FileManager.default.fileExists(atPath: sourcePath("LocalServerController.swift")), "HTTP server controller should be removed")
expect(!FileManager.default.fileExists(atPath: sourcePath("BlogWebView.swift")), "WKWebView wrapper should be removed")
expect(!FileManager.default.fileExists(atPath: sourcePath("BrowserModel.swift")), "browser model should be removed")

if let properties = try? String(contentsOfFile: sourcePath("ArticleProperties.swift"), encoding: .utf8) {
    for kind in ["case text", "case list", "case number", "case date", "case checkbox", "case tags"] {
        expect(properties.contains(kind), "article properties should support \(kind.replacingOccurrences(of: "case ", with: "")) values")
    }
    expect(properties.contains("public static func validated("), "property validation should live behind one module interface")
    expect(properties.contains("public static func renaming("), "property rename conflict semantics should live in the property module")
    expect(properties.contains("The decoder also accepts the legacy"), "typed properties should preserve legacy JSON compatibility")
} else {
    failures.append("typed article properties should be readable")
}

if var articleViews = try? String(contentsOfFile: sourcePath("ArticleViews.swift"), encoding: .utf8) {
    articleViews += (try? String(contentsOfFile: sourcePath("ArticleEditorViews.swift"), encoding: .utf8)) ?? ""
    expect(articleViews.contains("ArticleHistoryView"), "article reader and editor should expose version history")
    expect(articleViews.contains("ArticleRevisionDiffView"), "version history should compare revisions with current content")
    expect(articleViews.contains("ArticleTableOfContents"), "article reader should display a Markdown table of contents")
    expect(articleViews.contains("ScrollViewReader"), "article table of contents should support heading navigation")
    expect(articleViews.contains("scrollProxy.scrollTo(item.id, anchor: .top)"), "table-of-contents entries should scroll to their headings")
    expect(articleViews.contains("ArticleInspectorView"), "article reader should keep contextual navigation in a right inspector")
    expect(articleViews.contains("title: \"反向链接\""), "article inspector should expose backlinks")
    expect(articleViews.contains("title: \"出链\""), "article inspector should expose outgoing links")
    expect(articleViews.contains("title: \"未链接提及\""), "article inspector should expose unlinked mentions")
    expect(articleViews.contains("将 \\(mention.count) 处提及转为双链"), "unlinked mentions should expose one-click wiki-link conversion")
    expect(articleViews.contains("title: \"局部关系图\""), "article inspector should expose a local graph")
    expect(articleViews.contains("proxy.size.width < 980"), "article inspector should collapse at narrow widths")
    expect(articleViews.contains("ArticleHoverPreviewModifier"), "related articles should provide delayed hover previews")
    expect(articleViews.contains("ArticleLocalGraphView"), "article inspector should render one-hop article relationships")
    expect(articleViews.contains("model.scheduleEditorAutosave()"), "editor changes should schedule debounced recovery snapshots")
    expect(
        !articleViews.contains("ScrollView {\n                        VStack(alignment: .leading, spacing: 24) {\n                            titleSection\n                            writingSection"),
        "Markdown editor must not be nested inside the outer editor ScrollView"
    )
    expect(articleViews.contains("if media.isVideo"), "article reader should render videos separately from attachments")
    expect(articleViews.contains("InlineVideoPlayer(media: media, store: model.store)"), "article reader should embed video playback in the article")
    expect(!articleViews.contains("VideoPlayer(player:"), "article reader should avoid SwiftUI VideoPlayer, which aborts on macOS 26.5")
    expect(articleViews.contains("NativeAVPlayerView: NSViewRepresentable"), "article reader should bridge AVPlayerView directly")
    expect(articleViews.contains("AVPlayerView()"), "article reader should use AVPlayerView for embedded playback")
    expect(articleViews.contains("controlsStyle = .inline"), "embedded video should expose inline playback controls")
    expect(articleViews.contains("showsFullScreenToggleButton = true"), "embedded video should expose a fullscreen control")
    expect(articleViews.contains("Button(\"添加视频\")"), "article editor should allow selecting video media")
    expect(articleViews.contains("body: article.body,"), "article reader should render article Markdown instead of showing its source")
    expect(articleViews.contains("MarkdownDocumentView(\n                        markdown: markdown,"), "article reader should render complete Markdown documents")
    expect(articleViews.contains("import WebKit"), "article reader should use WebKit for embedded webpages")
    expect(articleViews.contains("MarkdownEmbeddedWebView(url: embed.url)"), "article reader should render webpage embed blocks")
    expect(articleViews.contains("WKWebView(frame: .zero)"), "article reader should create a native embedded webpage view")
    expect(articleViews.contains("在浏览器中打开"), "embedded webpages should provide an external browser fallback")
    expect(articleViews.contains("MarkdownHTMLWebView(html: component.html)"), "article reader should render HTML components")
    expect(articleViews.contains("loadHTMLString(document, baseURL: nil)"), "HTML components should load author HTML directly")
    expect(articleViews.contains("allowsContentJavaScript = true"), "HTML components should support JavaScript")
    expect(articleViews.contains("websiteDataStore = .nonPersistent()"), "HTML components should use an ephemeral web data store")
    expect(articleViews.contains("insertHTMLComponentTemplate()"), "article editor should insert an HTML component template")
    expect(articleViews.contains("标签，例如 #Swift #随笔"), "article editor should accept hashtag-style tags")
    expect(articleViews.contains("model.showArticles(tag: tag)"), "article reader tags should open the matching article filter")
    expect(articleViews.contains("article.pageViews"), "article reader should display its persisted page views")
    expect(articleViews.contains("ArticleLinkSuggestionMenu"), "article editor should offer article-link suggestions")
    expect(articleViews.contains("activeLinkQuery"), "article editor should detect a [[ article-link query")
    expect(articleViews.contains("[[\\(article.title)]]"), "selecting an article suggestion should insert a wiki-style link")
    expect(articleViews.contains("NativeImageView(url: banner.url, alt: banner.alt, store: model.store)"), "article reader should render a banner image inline")
    expect(articleViews.contains("NativeImageView(url: media.url, alt: media.name, store: model.store)"), "article reader should render attached images inline")
    expect(articleViews.contains("NativeBodyEditor(\n                text: $model.editor.body,"), "article editor should use the reliable native multiline input")
    expect(articleViews.contains(".padding(.leading, 12)"), "the Markdown placeholder should visually align with the native text caret")
    expect(articleViews.contains(".padding(.top, 12)"), "the Markdown placeholder should be vertically centered with the native text caret")
    expect(articleViews.contains("PastingTextView()"), "native body editor should receive keyboard input through its NSTextView subclass")
    expect(articleViews.contains("textView.isAutomaticDashSubstitutionEnabled = false"), "Markdown input should preserve triple hyphens for thematic breaks")
    expect(articleViews.contains("PastingTextView: NSTextView"), "native body editor should extend NSTextView for image paste handling")
    expect(articleViews.contains("override func viewDidMoveToWindow()"), "the native body editor should detect when it is attached to a window")
    expect(articleViews.contains("window.makeFirstResponder(self)"), "the native body editor should request the initial keyboard focus")
    expect(articleViews.contains("override func paste(_ sender: Any?)"), "native body editor should intercept clipboard pastes")
    expect(articleViews.contains("NSPasteboard.PasteboardType.png"), "native body editor should support pasted PNG images")
    expect(articleViews.contains(".urlReadingFileURLsOnly"), "native body editor should support pasted image files")
    expect(articleViews.contains("registerForDraggedTypes([.fileURL, .png, .tiff])"), "native body editor should accept dragged image files")
    expect(articleViews.contains("override func performDragOperation"), "native body editor should handle image drops")
    expect(articleViews.contains("characterIndexForInsertion(at: dropPoint)"), "dropped images should be inserted at the drop location")
    expect(articleViews.contains("NativeMarkdownLiveStyler.apply"), "inline live preview should style editable Markdown in place")
    expect(articleViews.contains("MarkdownPreview("), "split mode should retain the complete rendered Markdown preview")
    expect(articleViews.contains("let showsSidebar = editorMode != .focus && workspaceLayout.isEditorSidebarVisible"), "focus mode should hide the editor sidebar")
    expect(articleViews.contains("ForEach(NativeEditorSidebarPane.allCases)"), "article editor should switch among settings, properties, outline, and links")
    expect(articleViews.contains("private var editorPropertiesSidebar"), "article editor should expose editable properties")
    expect(articleViews.contains("ForEach(NativeArticlePropertyKind.allCases)"), "article properties should expose typed value editors")
    expect(articleViews.contains("EditorPropertyRenameSheet"), "article properties should support workspace-wide rename")
    expect(articleViews.contains("[属性名:值]"), "property editor should document structured search syntax")
    expect(articleViews.contains("private var editorOutlineSidebar"), "article editor should expose a live outline")
    expect(articleViews.contains("private var editorLinksSidebar"), "article editor should expose outgoing and incoming links")
    expect(articleViews.contains("切换编辑模式（⌘⌥1–4）"), "article editing modes should expose keyboard shortcuts")
    expect(articleViews.contains("private struct ArticleTabBar"), "article reader should expose a persistent tab strip")
    expect(articleViews.contains("model.navigateArticleBack"), "article tabs should expose back navigation")
    expect(articleViews.contains("model.navigateArticleForward"), "article tabs should expose forward navigation")
    expect(articleViews.contains("model.recentArticles"), "article tabs should expose recently viewed articles")
    expect(articleViews.contains("model.toggleArticleTabPin"), "article tabs should support pinning individual tabs")
    expect(articleViews.contains("model.closeArticleTab"), "article tabs should support closing individual tabs")
    expect(articleViews.contains("在新标签页打开"), "recent articles should offer an explicit new-tab action")
    expect(articleViews.contains("private struct ArticleCommentsSidebar"), "article reader should expose comments in the right sidebar")
    expect(articleViews.contains("private struct ArticleTextSelectionObserver"), "article body should monitor drag and double-click selections")
    expect(articleViews.contains("NativeReadableTextSelection.read"), "selected article text should be captured for anchored comments")
    expect(articleViews.contains("评论所选原文"), "comment composer should display the selected source quote")
    expect(articleViews.contains("回到评论对应的原文"), "anchored comments should navigate back to their source section")
    expect(articleViews.contains("model.createArticleComment"), "comment sidebar should create comments and replies")
    expect(articleViews.contains("model.deleteArticleComment"), "comment sidebar should delete comments with confirmation")
    expect(articleViews.contains("model.toggleArticleBookmark"), "article reader should bookmark the active article")
    expect(articleViews.contains("model.bookmarkHeading"), "article reader should bookmark individual headings")
    expect(articleViews.contains("model.articleScrollRevision"), "heading bookmarks should request reader scrolling")
    expect(articleViews.contains("Text(\"随输入更新\")"), "Markdown preview should identify that it updates as the user types")
    expect(!articleViews.contains("ScrollView {\n                VStack(alignment: .leading, spacing: 18)"), "article body input must not be nested inside the editor scroll view because macOS drops its keyboard input")
} else {
    failures.append("native article views should be readable")
}

if let markdownRenderer = try? String(contentsOfFile: sourcePath("MarkdownRenderer.swift"), encoding: .utf8) {
    expect(markdownRenderer.contains("case list"), "Markdown renderer should support ordered and unordered lists")
    expect(markdownRenderer.contains("marker = \"•\""), "Markdown renderer should display dash, plus, and asterisk list markers as unordered bullets")
    expect(
        markdownRenderer.contains("items: items,\n                articleLinks: articleLinks,\n                onToggleTask: onToggleTask\n            )\n                .font(typography.bodyFont.swiftUIFont(size: typography.fontSize))\n                .lineSpacing(typography.lineSpacing)"),
        "Markdown lists should use the same font and line spacing as body paragraphs"
    )
    expect(markdownRenderer.contains("case blockQuote"), "Markdown renderer should support block quotes")
    expect(markdownRenderer.contains("case codeBlock"), "Markdown renderer should support fenced and indented code blocks")
    expect(markdownRenderer.contains("case thematicBreak"), "Markdown renderer should support thematic breaks")
    expect(markdownRenderer.contains("enum MarkdownOutline"), "Markdown renderer should derive article outlines from parsed headings")
    expect(markdownRenderer.contains(".id(headingID)"), "Markdown headings should expose stable scrolling anchors")
    expect(markdownRenderer.contains("case table"), "Markdown renderer should support GFM tables")
    expect(
        markdownRenderer.contains(".frame(minWidth: 110, maxWidth: .infinity, alignment: cellAlignment(at: index))"),
        "Markdown table cells should fill their assigned Grid columns so borders and header fills stay continuous"
    )
    expect(markdownRenderer.contains("case webEmbed"), "Markdown renderer should support webpage embed blocks")
    expect(markdownRenderer.contains("MarkdownWebEmbedParser.fromFence"), "Markdown renderer should support embed code fences")
    expect(markdownRenderer.contains("fromHTML"), "Markdown renderer should support pasted iframe HTML")
    expect(markdownRenderer.contains("[\"http\", \"https\"]"), "webpage embeds should only allow HTTP(S) URLs")
    expect(markdownRenderer.contains("case htmlComponent"), "Markdown renderer should support HTML component blocks")
    expect(markdownRenderer.contains("html-render"), "Markdown renderer should require an explicit HTML rendering fence")
    expect(markdownRenderer.contains("min(max(requestedHeight, 160), 1_200)"), "HTML component heights should be bounded")
    expect(markdownRenderer.contains("taskState"), "Markdown renderer should support GFM task lists")
    expect(markdownRenderer.contains("text.strikethrough()"), "Markdown renderer should support GFM strikethrough")
    expect(markdownRenderer.contains("MarkdownTypography.normalizedCJKSpacing"), "Markdown renderer should remove redundant ASCII spacing between CJK punctuation and Han text")
    expect(markdownRenderer.contains("AttributedString(markdown: resolvedSource)"), "Markdown renderer should retain standard inline Markdown styling")
    expect(markdownRenderer.contains("MarkdownArticleLinkRenderer"), "Markdown renderer should resolve wiki-style article links")
    expect(markdownRenderer.contains("components.host == \"article\""), "Markdown renderer should intercept internal article links")
    expect(markdownRenderer.contains("URLQueryItem(name: \"target\""), "unresolved wiki links should retain their creation target")
    expect(markdownRenderer.contains("URLQueryItem(name: \"heading\""), "wiki links should preserve heading destinations")
} else {
    failures.append("native Markdown renderer should be readable")
}

if let settingsView = try? String(contentsOfFile: sourcePath("NativeSettingsView.swift"), encoding: .utf8) {
    expect(settingsView.contains("Obsidian Vault 导入"), "settings should expose Obsidian Vault import")
    expect(settingsView.contains("复制后的 Markdown 为权威数据"), "Obsidian import should identify copied Markdown as authoritative")
    expect(settingsView.contains("model.confirmObsidianImport()"), "Obsidian import should require an explicit confirmation")
    expect(settingsView.contains("命令与快捷键"), "settings should expose command hotkey customization")
    expect(settingsView.contains("阅读与编辑排版"), "settings should expose reading and editor typography")
    expect(settingsView.contains("NativeShortcutCaptureNSView"), "settings should record native keyboard shortcuts")
} else {
    failures.append("native settings view should be readable")
}

if let readingPreferences = try? String(contentsOfFile: sourcePath("ReadingPreferences.swift"), encoding: .utf8) {
    expect(readingPreferences.contains("profilesByUser"), "reading typography should persist independently per user")
    expect(readingPreferences.contains("readingWidth"), "reading typography should include content width")
    expect(readingPreferences.contains("paragraphSpacing"), "reading typography should include paragraph spacing")
    expect(readingPreferences.contains("NativeCodeFontFamily"), "reading typography should include a code font")
} else {
    failures.append("reading preferences should be readable")
}

if let workspaceLayouts = try? String(contentsOfFile: sourcePath("WorkspaceLayouts.swift"), encoding: .utf8) {
    expect(workspaceLayouts.contains("workspace-layouts.v2"), "named workspaces should use the v2 archive")
    expect(workspaceLayouts.contains("func createLayout("), "users should be able to create named workspaces")
    expect(workspaceLayouts.contains("var tabs: [NativeArticleTab]"), "workspace snapshots should persist article tabs")
    expect(workspaceLayouts.contains("readerInspectorWidth"), "workspace snapshots should persist sidebar widths")
    expect(workspaceLayouts.contains("splitFraction"), "workspace snapshots should persist split state")
} else {
    failures.append("workspace layouts should be readable")
}

if let commandRegistry = try? String(contentsOfFile: sourcePath("CommandRegistry.swift"), encoding: .utf8) {
    expect(commandRegistry.contains("public struct NativeCommandID"), "commands should use stable extensible IDs")
    expect(commandRegistry.contains("public func matches("), "command registry should own fuzzy matching")
    expect(commandRegistry.contains("pinnedCommandIDs"), "command registry preferences should persist pinned commands")
    expect(commandRegistry.contains("recentCommandIDs"), "command registry preferences should persist recent commands")
    expect(commandRegistry.contains("editor.insert.callout"), "command registry should expose editor slash commands")
} else {
    failures.append("native command registry should be readable")
}

if let contentView = try? String(contentsOfFile: sourcePath("ContentView.swift"), encoding: .utf8) {
    expect(contentView.contains("ActivityHeatmapView(activity: model.activity)"), "dashboard should display the activity heatmap")
    expect(contentView.contains("过去一年"), "activity heatmap should label its one-year range")
    expect(contentView.contains("pageState: pageStateCache.moments"), "ContentView should restore lightweight moment page state")
    expect(contentView.contains("case .trash: TrashView(model: model)"), "ContentView should show the recycle bin")
    expect(contentView.contains("回收站"), "sidebar should expose the recycle bin")
    expect(contentView.contains("新建用户…"), "sidebar should support creating users")
    expect(contentView.contains("独立工作空间"), "sidebar should identify user-isolated workspaces")
    expect(contentView.contains("ArticleTagFilterBar"), "article list should expose hashtag filters")
    expect(contentView.contains("SmartArticleLibraryView(model: model)"), "article library should use smart collection views")
    expect(contentView.contains("Section(\"智能集合\")"), "sidebar should list saved smart collections")
    expect(contentView.contains("Section(\"收藏\")"), "sidebar should list saved bookmarks")
    expect(contentView.contains(".onOpenURL(perform: model.handleAutomationURL)"), "main window should receive leonbook URLs")
    let smartCollectionView = try? String(contentsOfFile: sourcePath("SmartCollectionViews.swift"), encoding: .utf8)
    expect(
        contentView.contains("搜索标题、摘要、正文或标签")
            || smartCollectionView?.contains("搜索标题、摘要、正文或标签") == true,
        "article list should describe its full-text search scope"
    )
    expect(contentView.contains("article.pageViews"), "article list rows should display page views")
    expect(contentView.contains("可多选，任一匹配"), "article tag filters should explain multi-select matching")
    expect(contentView.contains("private struct NativeNavigationDetail: View"), "ContentView should isolate navigation updates in a dedicated detail subtree")
    expect(contentView.contains("NativeSidebar(model: model, navigation: model.navigation"), "ContentView should isolate sidebar selection updates from the root split view")
    expect(contentView.contains("NativeNavigationDetail("), "ContentView should keep the root split view independent from section changes")
    expect(contentView.contains("switch navigation.section"), "ContentView should mount only the selected destination")
    expect(contentView.contains("NativeNavigationPageStateCache"), "ContentView should retain lightweight page state instead of view trees")
    expect(!contentView.contains("prewarmNavigationSections"), "ContentView should not prewarm inactive destinations")
    expect(!contentView.contains("RetainedNavigationPage"), "ContentView should not retain inactive hosting views")
    expect(
        contentView.contains(".frame(maxWidth: .infinity, alignment: .leading)\n                .contentShape(Rectangle())"),
        "sidebar navigation labels should expose their full row as the click target"
    )
    expect(contentView.contains("SidebarNavigationButtonStyle(isSelected:"), "sidebar navigation rows should use a dedicated hover style")
    expect(contentView.contains(".onHover { isHovered = $0 }"), "sidebar navigation rows should react to pointer movement")
} else {
    failures.append("native content view should be readable")
}

if let workspaceLayouts = try? String(contentsOfFile: sourcePath("WorkspaceLayouts.swift"), encoding: .utf8) {
    expect(workspaceLayouts.contains("case writing"), "workspace layouts should include writing")
    expect(workspaceLayouts.contains("case reading"), "workspace layouts should include reading")
    expect(workspaceLayouts.contains("case reviewing"), "workspace layouts should include reviewing")
    expect(workspaceLayouts.contains("saveActiveLayout"), "workspace layouts should allow overwriting the active preset")
    expect(workspaceLayouts.contains("profilesByUser"), "workspace layouts should persist independently for each user")
    expect(workspaceLayouts.contains("isEditorSidebarVisible"), "workspace layouts should remember editor sidebar visibility")
    expect(workspaceLayouts.contains("readerInspectorPane"), "workspace layouts should remember the reader inspector pane")
} else {
    failures.append("workspace layouts should be readable")
}

if let graphProjection = try? String(contentsOfFile: sourcePath("ArticleGraphProjection.swift"), encoding: .utf8),
   let graphView = try? String(contentsOfFile: sourcePath("ArticleGraphView.swift"), encoding: .utf8),
   let pageState = try? String(contentsOfFile: sourcePath("NavigationPageState.swift"), encoding: .utf8) {
    expect(graphProjection.contains("NativeArticleGraphProjector"), "graph filtering and clipping should live behind one projection interface")
    expect(graphProjection.contains("includesOrphans"), "graph projection should filter orphan nodes")
    expect(graphProjection.contains("nodeLimit"), "graph projection should clip nodes before rendering")
    expect(graphProjection.contains("degree[edge.sourceSlug"), "graph clipping should prioritize connected nodes")
    expect(graphView.contains("Slider(value: $pageState.zoom"), "graph view should expose zoom control")
    expect(graphView.contains("筛选标题、slug、标签或别名"), "graph view should expose text filtering")
    expect(graphView.contains("显示孤立节点"), "graph view should expose orphan filtering")
    expect(pageState.contains("NativeNavigationPageStateCache"), "inactive pages should retain only lightweight state")
    expect(pageState.contains("recordedPageViewIDs"), "moment impression state should survive view reconstruction")
} else {
    failures.append("graph projection and lightweight page state should be readable")
}

if let articleReader = try? String(contentsOfFile: sourcePath("ArticleViews.swift"), encoding: .utf8),
   let articleEditor = try? String(contentsOfFile: sourcePath("ArticleEditorViews.swift"), encoding: .utf8),
   let appModelCore = try? String(contentsOfFile: sourcePath("NativeAppModel.swift"), encoding: .utf8) {
    expect(articleReader.split(separator: "\n").count < 2_200, "article reader module should stay below the former monolithic size")
    expect(articleEditor.split(separator: "\n").count < 1_700, "article editor should be isolated from reader implementation")
    expect(appModelCore.split(separator: "\n").count < 2_000, "NativeAppModel core should delegate article, backup, import, and search modules")
} else {
    failures.append("split article and app-model modules should be readable")
}

if let app = try? String(contentsOfFile: appSourcePath("LeonBookApp.swift"), encoding: .utf8) {
    expect(app.contains("@SceneStorage(\"leon-book.window-id\")"), "each window should retain its own stable navigation scope")
    expect(app.contains("NativeAppModel(navigationScopeID: windowID)"), "each window should own an independent app model")
    expect(app.contains("@FocusedObject private var model: NativeAppModel?"), "menu commands should target the focused window")
    expect(app.contains("ForEach(menuCommands)"), "menus should be generated from the command registry")
    expect(app.contains("model?.executeCommand(definition.id)"), "menus should execute registered commands")
} else {
    failures.append("native app scene should be readable")
}

if let automation = try? String(contentsOfFile: sourcePath("AutomationRouting.swift"), encoding: .utf8) {
    expect(automation.contains("case newArticle"), "automation routes should create articles")
    expect(automation.contains("case openArticle"), "automation routes should open articles")
    expect(automation.contains("case search"), "automation routes should open search")
    expect(automation.contains("case today"), "automation routes should open today's moments")
    expect(automation.contains("NativeAutomationInbox"), "cold-launch intents should persist pending routes")
    expect(automation.contains("commandInvocation"), "automation URLs should adapt into registered command invocations")
} else {
    failures.append("automation routing should be readable")
}

if let intents = try? String(contentsOfFile: appSourcePath("LeonBookAutomationIntents.swift"), encoding: .utf8) {
    expect(intents.contains("import AppIntents"), "automation actions should use App Intents")
    expect(intents.contains("LeonBookNewArticleIntent"), "Shortcuts should create articles")
    expect(intents.contains("LeonBookOpenArticleIntent"), "Shortcuts should open articles")
    expect(intents.contains("LeonBookSearchIntent"), "Shortcuts should search")
    expect(intents.contains("LeonBookTodayIntent"), "Shortcuts should open today's moments")
    expect(intents.contains("AppShortcutsProvider"), "App Intents should publish preconfigured shortcuts")
    expect(intents.contains("NativeCommandInvocation"), "App Intents should enqueue registered command invocations")
} else {
    failures.append("App Intents should be readable")
}

if let infoPlist = try? String(contentsOfFile: resourcePath("Info.plist"), encoding: .utf8) {
    expect(infoPlist.contains("CFBundleURLTypes"), "app metadata should register URL types")
    expect(infoPlist.contains("<string>leonbook</string>"), "app metadata should register the leonbook scheme")
} else {
    failures.append("app Info.plist should be readable")
}

if let localStore = try? String(contentsOfFile: sourcePath("LocalBlogStore.swift"), encoding: .utf8) {
    expect(localStore.contains("leon-book.sqlite"), "structured content should use a local SQLite database")
    expect(localStore.contains("CREATE TABLE IF NOT EXISTS articles"), "SQLite article schema should exist")
    expect(localStore.contains("CREATE VIRTUAL TABLE IF NOT EXISTS content_search USING fts5"), "SQLite should expose a unified FTS5 index")
    expect(localStore.contains("tokenize = 'trigram'"), "FTS5 should use trigram tokenization for Chinese substring search")
    expect(localStore.contains("public func search("), "LocalBlogStore should expose unified full-text search")
    expect(localStore.contains("CREATE TABLE IF NOT EXISTS article_revisions"), "SQLite should retain article recovery snapshots")
    expect(localStore.contains("CREATE TABLE IF NOT EXISTS article_comments"), "SQLite should persist article comments")
    expect(localStore.contains("CREATE TABLE IF NOT EXISTS article_link_references"), "SQLite should persist incremental article links")
    expect(localStore.contains("CREATE VIRTUAL TABLE IF NOT EXISTS article_mention_search USING fts5"), "SQLite should persist an incremental mention index")
    expect(localStore.contains("migrateArticleDerivedIndexesIfNeeded"), "existing workspaces should backfill article-derived indexes")
    expect(localStore.contains("jsonBackupFilesArePresent"), "startup should verify compatibility exports without decoding every article body")
    expect(localStore.contains("indexedOutgoingArticles("), "opening one article should query only its indexed outgoing links")
    expect(localStore.contains("indexedIncomingArticles("), "opening one article should query only candidate indexed backlinks")
    expect(localStore.contains("FOREIGN KEY(parent_id) REFERENCES article_comments(id) ON DELETE CASCADE"), "deleting a comment should cascade to its replies")
    expect(localStore.contains("public func createArticleComment("), "LocalBlogStore should create anchored article comments")
    expect(localStore.contains("public func listArticleComments("), "LocalBlogStore should list article comments")
    expect(localStore.contains("public func deleteArticleComment("), "LocalBlogStore should delete article comments")
    expect(localStore.contains("func saveArticleAutosave"), "LocalBlogStore should save rolling article autosaves")
    expect(localStore.contains("articleRevisionRetentionDays = 30"), "article revisions should have a bounded retention period")
    expect(localStore.contains("deleted_at TEXT"), "SQLite content schema should support soft deletion")
    expect(localStore.contains("delete_expires_at TEXT"), "SQLite content schema should track trash expiry")
    expect(localStore.contains("migrateLegacyDataIfNeeded"), "legacy local files should migrate into SQLite")
    expect(localStore.contains("article_published"), "publishing an article should record activity")
    expect(localStore.contains("article_edited"), "editing an article should record activity")
    expect(localStore.contains("image_published"), "uploading an image should record activity")
    expect(localStore.contains("func listMoments()"), "LocalBlogStore should list moments")
    expect(localStore.contains("private func unlinkedMention("), "article relations should detect plain-text unlinked mentions")
    expect(localStore.contains("public func convertUnlinkedMention("), "article relations should convert unlinked mentions safely")
    expect(localStore.contains("title, aliases, body"), "article aliases should be indexed in full-text search")
    expect(localStore.contains("category, properties, status"), "typed article properties should be indexed in full-text search")
    expect(localStore.contains("public func renameArticleProperty("), "LocalBlogStore should rename a property across the workspace")
    expect(localStore.contains("json_each(property_article.properties_json)"), "property search should filter exact keys and values")
    expect(localStore.contains("func saveMoment"), "LocalBlogStore should save moments")
    expect(localStore.contains("func updateMoment"), "LocalBlogStore should update moments")
    expect(localStore.contains("func deleteMoment"), "LocalBlogStore should delete moments")
    expect(localStore.contains("page_views INTEGER NOT NULL DEFAULT 0"), "SQLite content schemas should persist page views")
    expect(localStore.contains("func incrementArticlePageViews"), "LocalBlogStore should increment article page views atomically")
    expect(localStore.contains("func incrementMomentPageViews"), "LocalBlogStore should increment moment page views atomically")
    expect(localStore.contains("changedRelativePaths: Set<String>"), "Markdown sync should expose a changed-path incremental API")
    expect(localStore.contains("markdownSyncCandidates("), "incremental Markdown sync should query only affected index records")
    expect(localStore.contains("moment_published"), "LocalBlogStore should record moment publishing")
    expect(localStore.contains("moment_edited"), "LocalBlogStore should record moment edits")
    expect(localStore.contains("func listTrash()"), "LocalBlogStore should list recycle bin items")
    expect(localStore.contains("func restoreTrash"), "LocalBlogStore should restore recycle bin items")
    expect(localStore.contains("func permanentlyDeleteTrash"), "LocalBlogStore should permanently delete recycle bin items")
    expect(localStore.contains("purgeExpiredTrash"), "LocalBlogStore should purge expired recycle bin items")
    expect(localStore.contains("NativeArticleTag.normalized(article.tags)"), "article tags should normalize hashtag input before persistence")
    expect(localStore.contains("CREATE TABLE IF NOT EXISTS smart_collections"), "SQLite should persist smart collections")
    expect(localStore.contains("CREATE TABLE IF NOT EXISTS bookmarks"), "SQLite should persist bookmarks")
    expect(localStore.contains("public func listArticles(in collection:"), "store should evaluate smart collection queries")
    expect(localStore.contains("NativeSmartCollectionSQLCompiler.compile(collection)"), "smart collections should filter and sort in SQLite")
    expect(localStore.contains("public func saveSmartCollection"), "store should save smart collection configuration")
    expect(localStore.contains("public func saveBookmark"), "store should save bookmark targets")
} else {
    failures.append("native local store should be readable")
}

if let collectionSQL = try? String(contentsOfFile: sourcePath("SmartCollectionSQL.swift"), encoding: .utf8) {
    expect(collectionSQL.contains("struct NativeSmartCollectionSQLQuery"), "smart collection SQL should expose one compiled query boundary")
    expect(collectionSQL.contains("json_each"), "smart collection SQL should query tags and typed properties without decoding all articles")
    expect(collectionSQL.contains("julianday"), "smart collection date filters should compare normalized instants")
} else {
    failures.append("smart collection SQL compiler should be readable")
}

if let smartCollections = try? String(contentsOfFile: sourcePath("SmartCollectionViews.swift"), encoding: .utf8) {
    expect(smartCollections.contains("case .list: listLayout"), "smart collections should expose list layout")
    expect(smartCollections.contains("case .table: tableLayout"), "smart collections should expose table layout")
    expect(smartCollections.contains("case .cards: cardLayout"), "smart collections should expose cards layout")
    expect(smartCollections.contains("最多三层排序"), "smart collection editor should explain multi-sort")
    expect(smartCollections.contains("属性筛选"), "smart collection editor should expose article properties")
} else {
    failures.append("smart collection views should be readable")
}

if let backupManager = try? String(contentsOfFile: sourcePath("LocalBackupManager.swift"), encoding: .utf8) {
    expect(backupManager.contains("createSnapshot"), "backup manager should create snapshots")
    expect(backupManager.contains("createManagedSnapshot"), "backup manager should create policy-managed snapshots")
    expect(backupManager.contains("clonefile"), "backup manager should use copy-on-write clones when available")
    expect(backupManager.contains("linkItem"), "backup manager should reuse unchanged files when cloning is unavailable")
    expect(backupManager.contains("SHA256"), "backup manifests should protect files with checksums")
    expect(backupManager.contains("ensureSufficientCapacity"), "backup manager should preserve minimum free disk space")
    expect(backupManager.contains("enforceRetention"), "backup manager should remove expired and excess snapshots")
    expect(backupManager.contains("validateSnapshot"), "backup manager should validate snapshots before restore")
    expect(backupManager.contains("restoreSnapshot"), "backup manager should restore through an atomic staging directory")
    expect(backupManager.contains("isSameOrDescendant"), "backup manager should reject recursive backup paths")
    expect(backupManager.contains(".leon-book.lock"), "backup manager should exclude the active lock file")
    expect(backupManager.contains("backup-manifest.json"), "backup snapshots should include a manifest")
} else {
    failures.append("local backup manager should be readable")
}

if let settingsView = try? String(contentsOfFile: sourcePath("NativeSettingsView.swift"), encoding: .utf8) {
    expect(settingsView.contains("设置备份路径"), "settings should expose backup path selection")
    expect(settingsView.contains("立即备份"), "settings should expose manual backup")
    expect(settingsView.contains("自动备份与保留策略"), "settings should expose backup retention controls")
    expect(settingsView.contains("备份后最低剩余空间"), "settings should expose a free-space reserve")
    expect(settingsView.contains("快照浏览"), "settings should list available backup snapshots")
    expect(settingsView.contains("validateBackupSnapshot"), "settings should validate an individual snapshot")
    expect(settingsView.contains("restoreBackupSnapshot"), "settings should restore an individual snapshot")
    expect(settingsView.contains("FileVault"), "settings should explain encrypted backup storage")
} else {
    failures.append("native settings view should be readable")
}

if var appModel = try? String(contentsOfFile: sourcePath("NativeAppModel.swift"), encoding: .utf8) {
    for module in ["NativeAppModel+Article.swift", "NativeAppModel+Backup.swift", "NativeAppModel+Import.swift", "NativeAppModel+Search.swift"] {
        appModel += (try? String(contentsOfFile: sourcePath(module), encoding: .utf8)) ?? ""
    }
    expect(appModel.contains("3_000_000_000"), "article autosave should use a three-second debounce")
    expect(appModel.contains("restoreLatestUnsavedArticleDraftIfNeeded"), "startup should restore an unsaved new article")
    expect(appModel.contains("restoreLatestAutosaveIfNeeded"), "editing a saved article should recover newer autosaved content")
    expect(appModel.contains("func uploadPastedImage"), "pasted images should be saved as local media")
    expect(appModel.contains("![粘贴的图片]"), "pasted images should be inserted as Markdown image links")
    expect(appModel.contains("func chooseMomentImages()"), "NativeAppModel should choose moment images")
    expect(appModel.contains("func uploadMomentPastedImages"), "NativeAppModel should save pasted and dropped moment images")
    expect(appModel.contains("moment-image-\\(UUID().uuidString.lowercased()).png"), "moment paste temp files should interpolate a unique UUID")
    expect(appModel.contains("func publishMoment()"), "NativeAppModel should publish moments")
    expect(appModel.contains("func beginEditingMoment(_ moment: NativeMoment)"), "NativeAppModel should begin moment editing")
    expect(appModel.contains("func cancelMomentEditing()"), "NativeAppModel should cancel moment editing")
    expect(appModel.contains("editingMomentID"), "NativeAppModel should track the moment being edited")
    expect(appModel.contains("func deleteMoment(_ moment: NativeMoment)"), "NativeAppModel should delete moments")
    expect(appModel.contains("trashItems"), "NativeAppModel should publish recycle bin items")
    expect(appModel.contains("func restoreTrash"), "NativeAppModel should restore recycle bin items")
    expect(appModel.contains("func permanentlyDeleteTrash"), "NativeAppModel should permanently delete recycle bin items")
    expect(appModel.contains("slug: \"moments\""), "Moment images should be stored in the moments media directory")
    expect(appModel.contains("func createUser(named name: String)"), "app model should create users")
    expect(appModel.contains("func selectUser(_ user: NativeUser)"), "app model should switch users")
    expect(appModel.contains("selectedMomentTags: Set<String>"), "Moment tag filters should support selecting multiple tags")
    expect(appModel.contains("availableMomentTagFilters"), "Moment tags should include their post counts")
    expect(appModel.contains("if $0.count != $1.count { return $0.count > $1.count }"), "Moment tags should be sorted by post count")
    expect(appModel.contains("func toggleMomentTagFilter(_ tag: String)"), "Moment tags should be toggled independently")
    expect(appModel.contains("selectedArticleTags: Set<String>"), "Article tag filters should support selecting multiple tags")
    expect(appModel.contains("availableArticleTagFilters"), "Article tags should include their post counts")
    expect(appModel.contains("func toggleArticleTagFilter(_ tag: String)"), "Article tags should be toggled independently")
    expect(appModel.contains("func openArticleLink(_ slug: String)"), "NativeAppModel should open a linked article")
    expect(appModel.contains("func openArticleLink(_ destination: NativeArticleLinkDestination)"), "NativeAppModel should preserve full wiki-link destinations")
    expect(appModel.contains("private func createArticle(from destination:"), "missing wiki-link targets should open article creation")
    expect(appModel.contains("func convertUnlinkedMention(_ mention:"), "NativeAppModel should convert unlinked mentions")
    expect(appModel.contains("public func handleAutomationURL(_ url: URL)"), "NativeAppModel should handle leonbook URLs")
    expect(appModel.contains("consumeAutomationInbox"), "NativeAppModel should consume cold-launch intent routes")
    expect(appModel.contains("public func executeCommand(_ invocation: NativeCommandInvocation)"), "NativeAppModel should execute all command adapters through one interface")
    expect(appModel.contains("momentDateFilter = .today"), "today automation should open today's moments")
    expect(appModel.contains("articleTabs: [NativeArticleTab]"), "NativeAppModel should retain article tabs")
    expect(appModel.contains("NSEvent.modifierFlags"), "command-click should be detected for new article tabs")
    expect(appModel.contains("func navigateArticleBack()"), "NativeAppModel should navigate backward within a tab")
    expect(appModel.contains("func navigateArticleForward()"), "NativeAppModel should navigate forward within a tab")
    expect(appModel.contains("persistArticleNavigationState"), "article tabs and recents should persist per user")
    expect(appModel.contains("leon-book.article-navigation."), "article navigation persistence should be scoped by user")
    expect(appModel.contains("articleComments: [NativeArticleComment]"), "NativeAppModel should publish comments for the selected article")
    expect(appModel.contains("func prepareArticleComment("), "NativeAppModel should anchor selected text for a comment")
    expect(appModel.contains("func createArticleComment("), "NativeAppModel should create comments and replies")
    expect(appModel.contains("func deleteArticleComment("), "NativeAppModel should delete comments")
    expect(appModel.contains("public func presentQuickSwitcher()"), "NativeAppModel should expose the quick switcher")
    expect(appModel.contains("public func presentCommandPalette()"), "NativeAppModel should expose the command palette")
    expect(appModel.contains("func updateArticleListSearch("), "the existing article search box should query the FTS index")
    expect(appModel.contains("recordsPageView: Bool = true"), "article selection should distinguish user views from background reloads")
    expect(appModel.contains("func recordMomentPageView(_ moment: NativeMoment)"), "NativeAppModel should record visible moment page views")
    expect(appModel.contains("let navigation = NativeNavigationState()"), "navigation changes should use an isolated observable state")
    expect(appModel.contains("get { navigation.section }") && appModel.contains("navigation.section = newValue"), "section changes should not invalidate every content observer")
    expect(appModel.contains("MarkdownSourceEventMonitor"), "Markdown auto-sync should use filesystem events")
    expect(appModel.contains("700_000_000"), "Markdown filesystem events should be coalesced before syncing")
    expect(appModel.contains("15 * 60 * 1_000_000_000"), "Markdown sync should retain a low-frequency full verification")
    expect(!appModel.contains("Task.sleep(nanoseconds: 2_000_000_000)"), "Markdown sync should not scan the whole library every two seconds")
} else {
    failures.append("native app model should be readable")
}

if let sourceMonitor = try? String(
    contentsOfFile: sourcePath("MarkdownSourceEventMonitor.swift"),
    encoding: .utf8
) {
    expect(sourceMonitor.contains("FSEventStreamCreate"), "Markdown monitor should use recursive FSEvents")
    expect(sourceMonitor.contains("kFSEventStreamCreateFlagFileEvents"), "Markdown monitor should request file-level paths")
    expect(sourceMonitor.contains("kFSEventStreamEventFlagMustScanSubDirs"), "dropped filesystem events should request a full verification")
} else {
    failures.append("Markdown filesystem event monitor should be readable")
}

if let userWorkspaceStore = try? String(contentsOfFile: sourcePath("UserWorkspaceStore.swift"), encoding: .utf8) {
    expect(userWorkspaceStore.contains("CREATE TABLE IF NOT EXISTS users"), "users should be managed by SQLite")
    expect(userWorkspaceStore.contains("app_settings"), "active user should be managed by local SQLite settings")
    expect(userWorkspaceStore.contains("NativeUser.leon"), "leon should be the default user")
    expect(userWorkspaceStore.contains("workspaces"), "users should receive isolated workspace directories")
    expect(userWorkspaceStore.contains("migrateLegacyWorkspaceIfNeeded"), "existing local data should migrate into leon's workspace")
} else {
    failures.append("user workspace store should be readable")
}

if let momentViews = try? String(contentsOfFile: sourcePath("MomentViews.swift"), encoding: .utf8) {
    expect(momentViews.contains("struct MomentFeedView"), "MomentFeedView should be present")
    expect(momentViews.contains("MomentRichTextEditor("), "Moments should support rich text publishing")
    expect(momentViews.contains(".frame(height: 63)"), "Moment input should use the compact 63-point height")
    expect(momentViews.contains("richTextController.toggleBold()"), "Moments should support bold text")
    expect(momentViews.contains("richTextController.apply(color:"), "Moments should support text colors")
    expect(momentViews.contains("最多 9 张图片"), "Moments should communicate the image limit")
    expect(momentViews.contains("LazyVStack(spacing: 16)"), "Moment history should display one post per row")
    expect(momentViews.contains("MomentImageBrowserView"), "Moments should present an image browser")
    expect(momentViews.contains(".accessibilityElement(children: .ignore)"), "Moment image grids should expose one accessibility node instead of one node per thumbnail")
    expect(momentViews.contains(".accessibilityAction { onOpenImage(0) }"), "The combined moment image node should open the image browser")
    expect(momentViews.contains("将这条微博移入回收站？"), "Moment deletion should require confirmation")
    expect(!momentViews.contains(".overlay(alignment: .topTrailing)"), "Moment card actions must participate in header layout so they do not overlap the date")
    expect(!momentViews.contains("VStack(alignment: .trailing, spacing: 8)"), "Moment header actions should stay inline so they do not create blank space before the content")
    expect(momentViews.contains("Button(action: confirmDeletion)"), "Moment cards should expose a direct delete control")
    expect(momentViews.contains("Label(\"删除\", systemImage: \"trash\")"), "Moment deletion should have a clear label and trash icon")
    expect(momentViews.contains(".contentShape(Rectangle())"), "Moment deletion should have an explicit rectangular hit target")
    expect(momentViews.contains("let alert = NSAlert()"), "Moment deletion should use a native macOS confirmation alert")
    expect(momentViews.contains("alert.runModal() == .alertFirstButtonReturn"), "Moment deletion should only continue after native confirmation")
    expect(momentViews.contains(".allowsHitTesting(false)"), "Decorative moment card overlays should not intercept delete clicks")
    expect(momentViews.contains("available.width * 0.94"), "Image browser should use the available screen space")
    expect(momentViews.contains("MagnificationGesture()"), "Image browser should support magnifying images")
    expect(momentViews.contains("showNextImage()"), "Image browser should support next image navigation")
    expect(momentViews.contains("Button(action: onEdit)"), "Moment cards should expose an edit control")
    expect(momentViews.contains("moment.pageViews"), "Moment cards should display page views")
    expect(momentViews.contains("recordPageViewIfVisible"), "Moment cards should count only visible feed impressions")
    expect(momentViews.contains("let displayContent = moment.displayContent"), "Moment cards should derive display content only once per render")
    expect(momentViews.contains(".accessibilityLabel(accessibilitySummary("), "Moment cards should expose one concise accessibility summary")
    expect(momentViews.contains(".accessibilityAction(named: Text(\"编辑\"))"), "Combined moment cards should preserve their edit accessibility action")
    expect(momentViews.contains(".accessibilityAction(named: Text(\"删除\"))"), "Combined moment cards should preserve their delete accessibility action")
    expect(momentViews.contains("编辑微博"), "Moment composer should identify edit mode")
    expect(momentViews.contains("保存修改"), "Moment composer should save edits")
    expect(momentViews.contains("collapsedTimelineDays"), "Moment timeline should track collapsed days")
    expect(momentViews.contains("toggleTimelineDay"), "Moment timeline days should be independently collapsible")
    expect(momentViews.contains("已折叠"), "Collapsed moment days should show their hidden post count")
    expect(momentViews.contains("MomentTagSuggestionMenu"), "Moments should show matching tag suggestions while typing")
    expect(momentViews.contains("tagSuggestions"), "Moments should filter existing tags into suggestions")
    expect(momentViews.contains("availableMomentTagFilters"), "Moment tags should be shown as a filter tile collection")
    expect(momentViews.contains("可多选 · 任一匹配"), "Moment tag filters should explain multi-select matching")
    expect(momentViews.contains("@AppStorage(\"momentFeedLayout\")"), "Moment feed layout selection should persist")
    expect(momentViews.contains("doubleColumnWaterfall"), "Moment feed should offer a double-column waterfall layout")
    expect(momentViews.contains("threeColumnWaterfall"), "Moment feed should offer a three-column waterfall layout")
    expect(momentViews.contains("fourColumnWaterfall"), "Moment feed should offer a four-column waterfall layout")
    expect(momentViews.contains("momentWaterfallColumns(for: group.moments)"), "Multi-column moment feed should use lazy waterfall columns")
    expect(momentViews.contains("private func momentColumn"), "Moment waterfall columns should distribute cards without eager size measurement")
    expect(!momentViews.contains("MomentMasonryLayout: Layout"), "Moment waterfall should not eagerly measure every card through a custom Layout")
    expect(momentViews.contains("momentFeedMaximumWidth: CGFloat = 1_760"), "Moment feed should use the expanded page width")
    expect(momentViews.contains("NSEvent.addLocalMonitorForEvents(matching: .keyDown)"), "Image browser should capture keyboard navigation")
    expect(momentViews.contains("navigationModifiers"), "Image browser should allow unmodified arrow keys")
    expect(momentViews.contains("case 123:"), "Left arrow should show the previous image")
    expect(momentViews.contains("case 124:"), "Right arrow should show the next image")
    expect(momentViews.contains("Color.gray.opacity(0.72)"), "Image browser should use a translucent gray background")
    expect(momentViews.contains("Color.gray.opacity(0.48)"), "Image canvas should use a translucent gray background")
    expect(momentViews.contains("CGImageSourceCreateThumbnailAtIndex"), "Moment previews should downsample images")
    expect(momentViews.contains("loadMode: .thumbnail(maxPixelSize: 720)"), "Moment feed should render image thumbnails")
    expect(momentViews.contains("let momentTimeline = model.momentTimeline"), "Moment timeline should be derived once per feed render")
    expect(momentViews.contains("maximumConcurrentDecodes = 2"), "Moment thumbnail decoding should leave CPU capacity for navigation")
    expect(momentViews.contains("Task.detached(priority: .utility)"), "Moment thumbnail decoding should not compete at user-initiated priority")
    expect(momentViews.contains("withTaskCancellationHandler"), "Moment thumbnail decoding should respond when its view disappears")
    expect(momentViews.contains("moment-thumbnails"), "Moment thumbnails should persist in the system cache")
    expect(momentViews.contains(".aspectRatio(contentMode: .fit)"), "Moment thumbnails should show the complete image")
    expect(momentViews.contains("Color.clear"), "Moment image canvases should reveal the card background instead of forcing white")
    expect(!momentViews.contains("Color(nsColor: .controlBackgroundColor)"), "Moment image canvases should not force a white control background")
    expect(momentViews.contains("mode: .fullSize"), "Image browser should load the selected image at full size")
    expect(
        !momentViews.contains("ScrollView {\n            VStack(alignment: .leading, spacing: 26)"),
        "Moment input must not be nested inside the history scroll view because macOS drops its keyboard input"
    )
} else {
    failures.append("native moment views should be readable")
}

if let trashViews = try? String(contentsOfFile: sourcePath("TrashViews.swift"), encoding: .utf8) {
    expect(trashViews.contains("struct TrashView"), "TrashView should be present")
    expect(trashViews.contains("恢复"), "TrashView should restore deleted content")
    expect(trashViews.contains("永久删除"), "TrashView should permanently delete content")
    expect(trashViews.contains("清空回收站"), "TrashView should support emptying the recycle bin")
    expect(trashViews.contains("保留 30 天"), "TrashView should explain the retention period")
} else {
    failures.append("native trash views should be readable")
}

if let richTextEditor = try? String(contentsOfFile: sourcePath("MomentRichTextEditor.swift"), encoding: .utf8) {
    expect(richTextEditor.contains("override func paste(_ sender: Any?)"), "Moment editor should accept pasted images")
    expect(richTextEditor.contains("override func performDragOperation"), "Moment editor should accept dropped images")
    expect(richTextEditor.contains("func toggleBold()"), "Moment editor should change selected text to bold")
    expect(richTextEditor.contains("func apply(color:"), "Moment editor should change selected text color")
    expect(richTextEditor.contains("registerForDraggedTypes([.fileURL, .png, .tiff])"), "Moment editor should register image drag types")
    expect(richTextEditor.contains("activeTagQuery"), "Moment editor should detect a tag query at the cursor")
    expect(richTextEditor.contains("completeTagSuggestion"), "Moment editor should insert a selected tag suggestion")
} else {
    failures.append("native rich text moment editor should be readable")
}

if failures.isEmpty {
    print("LeonBook native checks passed")
} else {
    for failure in failures { fputs("Check failed: \(failure)\n", stderr) }
    exit(1)
}
