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

expect(FileManager.default.fileExists(atPath: sourcePath("ContentView.swift")), "native SwiftUI content view should exist")
expect(FileManager.default.fileExists(atPath: sourcePath("LocalBlogStore.swift")), "native local store should exist")
expect(FileManager.default.fileExists(atPath: sourcePath("SQLiteDatabase.swift")), "SQLite database adapter should exist")
expect(FileManager.default.fileExists(atPath: sourcePath("MarkdownRenderer.swift")), "native Markdown renderer should exist")
expect(!FileManager.default.fileExists(atPath: sourcePath("LocalServerController.swift")), "HTTP server controller should be removed")
expect(!FileManager.default.fileExists(atPath: sourcePath("BlogWebView.swift")), "WKWebView wrapper should be removed")
expect(!FileManager.default.fileExists(atPath: sourcePath("BrowserModel.swift")), "browser model should be removed")

if let articleViews = try? String(contentsOfFile: sourcePath("ArticleViews.swift"), encoding: .utf8) {
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
    expect(articleViews.contains("MarkdownArticleBody(body: article.body, store: model.store)"), "article reader should render article Markdown instead of showing its source")
    expect(articleViews.contains("MarkdownDocumentView(markdown: markdown)"), "article reader should render complete Markdown documents")
    expect(articleViews.contains("NativeImageView(url: banner.url, alt: banner.alt, store: model.store)"), "article reader should render a banner image inline")
    expect(articleViews.contains("NativeImageView(url: media.url, alt: media.name, store: model.store)"), "article reader should render attached images inline")
    expect(articleViews.contains("NativeBodyEditor(text: $model.editor.body) { image, placeholder in"), "article editor should use the reliable native multiline input")
    expect(articleViews.contains("PastingTextView()"), "native body editor should receive keyboard input through its NSTextView subclass")
    expect(articleViews.contains("PastingTextView: NSTextView"), "native body editor should extend NSTextView for image paste handling")
    expect(articleViews.contains("override func paste(_ sender: Any?)"), "native body editor should intercept clipboard pastes")
    expect(articleViews.contains("NSPasteboard.PasteboardType.png"), "native body editor should support pasted PNG images")
    expect(articleViews.contains(".urlReadingFileURLsOnly"), "native body editor should support pasted image files")
    expect(articleViews.contains("registerForDraggedTypes([.fileURL, .png, .tiff])"), "native body editor should accept dragged image files")
    expect(articleViews.contains("override func performDragOperation"), "native body editor should handle image drops")
    expect(articleViews.contains("characterIndexForInsertion(at: dropPoint)"), "dropped images should be inserted at the drop location")
    expect(articleViews.contains("MarkdownPreview(markdown: model.editor.body, store: model.store)"), "article editor should render Markdown live beside its input")
    expect(articleViews.contains("Text(\"随输入更新\")"), "Markdown preview should identify that it updates as the user types")
    expect(!articleViews.contains("ScrollView {\n                VStack(alignment: .leading, spacing: 18)"), "article body input must not be nested inside the editor scroll view because macOS drops its keyboard input")
} else {
    failures.append("native article views should be readable")
}

if let markdownRenderer = try? String(contentsOfFile: sourcePath("MarkdownRenderer.swift"), encoding: .utf8) {
    expect(markdownRenderer.contains("case list"), "Markdown renderer should support ordered and unordered lists")
    expect(markdownRenderer.contains("case blockQuote"), "Markdown renderer should support block quotes")
    expect(markdownRenderer.contains("case codeBlock"), "Markdown renderer should support fenced and indented code blocks")
    expect(markdownRenderer.contains("case thematicBreak"), "Markdown renderer should support thematic breaks")
    expect(markdownRenderer.contains("case table"), "Markdown renderer should support GFM tables")
    expect(markdownRenderer.contains("taskState"), "Markdown renderer should support GFM task lists")
    expect(markdownRenderer.contains("text.strikethrough()"), "Markdown renderer should support GFM strikethrough")
    expect(markdownRenderer.contains("AttributedString(markdown: source)"), "Markdown renderer should retain standard inline Markdown styling")
} else {
    failures.append("native Markdown renderer should be readable")
}

if let contentView = try? String(contentsOfFile: sourcePath("ContentView.swift"), encoding: .utf8) {
    expect(contentView.contains("ActivityHeatmapView(activity: model.activity)"), "dashboard should display the activity heatmap")
    expect(contentView.contains("过去一年"), "activity heatmap should label its one-year range")
    expect(contentView.contains("case .moments: MomentFeedView(model: model)"), "ContentView should show the native moments feed")
    expect(contentView.contains("新建用户…"), "sidebar should support creating users")
    expect(contentView.contains("独立工作空间"), "sidebar should identify user-isolated workspaces")
} else {
    failures.append("native content view should be readable")
}

if let localStore = try? String(contentsOfFile: sourcePath("LocalBlogStore.swift"), encoding: .utf8) {
    expect(localStore.contains("leon-book.sqlite"), "structured content should use a local SQLite database")
    expect(localStore.contains("CREATE TABLE IF NOT EXISTS articles"), "SQLite article schema should exist")
    expect(localStore.contains("migrateLegacyDataIfNeeded"), "legacy local files should migrate into SQLite")
    expect(localStore.contains("article_published"), "publishing an article should record activity")
    expect(localStore.contains("article_edited"), "editing an article should record activity")
    expect(localStore.contains("image_published"), "uploading an image should record activity")
    expect(localStore.contains("func listMoments()"), "LocalBlogStore should list moments")
    expect(localStore.contains("func saveMoment"), "LocalBlogStore should save moments")
    expect(localStore.contains("func updateMoment"), "LocalBlogStore should update moments")
    expect(localStore.contains("func deleteMoment"), "LocalBlogStore should delete moments")
    expect(localStore.contains("moment_published"), "LocalBlogStore should record moment publishing")
    expect(localStore.contains("moment_edited"), "LocalBlogStore should record moment edits")
} else {
    failures.append("native local store should be readable")
}

if let appModel = try? String(contentsOfFile: sourcePath("NativeAppModel.swift"), encoding: .utf8) {
    expect(appModel.contains("func uploadPastedImage"), "pasted images should be saved as local media")
    expect(appModel.contains("![粘贴的图片]"), "pasted images should be inserted as Markdown image links")
    expect(appModel.contains("func chooseMomentImages()"), "NativeAppModel should choose moment images")
    expect(appModel.contains("func uploadMomentPastedImages"), "NativeAppModel should save pasted and dropped moment images")
    expect(appModel.contains("func publishMoment()"), "NativeAppModel should publish moments")
    expect(appModel.contains("func beginEditingMoment(_ moment: NativeMoment)"), "NativeAppModel should begin moment editing")
    expect(appModel.contains("func cancelMomentEditing()"), "NativeAppModel should cancel moment editing")
    expect(appModel.contains("editingMomentID"), "NativeAppModel should track the moment being edited")
    expect(appModel.contains("func deleteMoment(_ moment: NativeMoment)"), "NativeAppModel should delete moments")
    expect(appModel.contains("slug: \"moments\""), "Moment images should be stored in the moments media directory")
    expect(appModel.contains("func createUser(named name: String)"), "app model should create users")
    expect(appModel.contains("func selectUser(_ user: NativeUser)"), "app model should switch users")
} else {
    failures.append("native app model should be readable")
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
    expect(momentViews.contains("删除这条微博？"), "Moment deletion should require confirmation")
    expect(momentViews.contains(".overlay(alignment: .topTrailing)"), "Moment deletion should sit in the card's topmost interaction layer")
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
    expect(momentViews.contains("编辑微博"), "Moment composer should identify edit mode")
    expect(momentViews.contains("保存修改"), "Moment composer should save edits")
    expect(momentViews.contains("NSEvent.addLocalMonitorForEvents(matching: .keyDown)"), "Image browser should capture keyboard navigation")
    expect(momentViews.contains("case 123:"), "Left arrow should show the previous image")
    expect(momentViews.contains("case 124:"), "Right arrow should show the next image")
    expect(momentViews.contains("CGImageSourceCreateThumbnailAtIndex"), "Moment previews should downsample images")
    expect(momentViews.contains("loadMode: .thumbnail(maxPixelSize: 720)"), "Moment feed should render image thumbnails")
    expect(momentViews.contains("mode: .fullSize"), "Image browser should load the selected image at full size")
    expect(
        !momentViews.contains("ScrollView {\n            VStack(alignment: .leading, spacing: 26)"),
        "Moment input must not be nested inside the history scroll view because macOS drops its keyboard input"
    )
} else {
    failures.append("native moment views should be readable")
}

if let richTextEditor = try? String(contentsOfFile: sourcePath("MomentRichTextEditor.swift"), encoding: .utf8) {
    expect(richTextEditor.contains("override func paste(_ sender: Any?)"), "Moment editor should accept pasted images")
    expect(richTextEditor.contains("override func performDragOperation"), "Moment editor should accept dropped images")
    expect(richTextEditor.contains("func toggleBold()"), "Moment editor should change selected text to bold")
    expect(richTextEditor.contains("func apply(color:"), "Moment editor should change selected text color")
    expect(richTextEditor.contains("registerForDraggedTypes([.fileURL, .png, .tiff])"), "Moment editor should register image drag types")
} else {
    failures.append("native rich text moment editor should be readable")
}

if failures.isEmpty {
    print("LeonBook native checks passed")
} else {
    for failure in failures { fputs("Check failed: \(failure)\n", stderr) }
    exit(1)
}
