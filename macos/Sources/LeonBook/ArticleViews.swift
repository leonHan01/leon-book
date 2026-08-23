import AVKit
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WebKit

private enum ArticleEditorLayout {
    static let contentInset: CGFloat = 20
    static let titleVerticalInset: CGFloat = 24
}

struct ArticleReaderView: View {
    @ObservedObject var model: NativeAppModel

    var body: some View {
        Group {
            if let article = model.selectedArticle {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack {
                            Label(article.status.label, systemImage: article.status == .published ? "checkmark.circle.fill" : "pencil.circle.fill")
                                .foregroundStyle(article.status == .published ? .green : .orange)
                            Spacer()
                            Button("编辑") { model.editSelected() }
                            Button("移入回收站", role: .destructive) { Task { await model.deleteSelected() } }
                        }

                        Text(article.title)
                            .font(.system(size: 38, weight: .bold, design: .serif))
                        HStack(spacing: 12) {
                            Text(article.category)
                            Text("·")
                            Text("更新于 \(article.updatedAt.nativeDateLabel)")
                            if let wordCount = article.wordCount { Text("· \(wordCount) 字") }
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)

                        if !article.tags.isEmpty {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "tag.fill")
                                    .foregroundStyle(.tint)
                                ForEach(article.tags, id: \.self) { tag in
                                    Button {
                                        model.showArticles(tag: tag)
                                    } label: {
                                        Text("#\(tag)")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .help("查看标签 #\(tag) 的文章")
                                }
                            }
                        }

                        if !article.excerpt.isEmpty {
                            Text(article.excerpt)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }

                        if let banner = article.banner {
                            NativeImageView(url: banner.url, alt: banner.alt, store: model.store)
                        }

                        Divider()
                        MarkdownArticleBody(
                            body: article.body,
                            store: model.store,
                            articleLinks: model.articles,
                            onOpenArticle: model.openArticleLink
                        )

                        let attachmentMedia = article.media.filter {
                            !MarkdownArticleBody.imageURLs(in: article.body).contains($0.url)
                        }
                        if !attachmentMedia.isEmpty {
                            Divider()
                            Text("媒体").font(.headline)
                            ForEach(attachmentMedia) { media in
                                if media.isVideo {
                                    InlineVideoPlayer(media: media, store: model.store)
                                } else {
                                    NativeImageView(url: media.url, alt: media.name, store: model.store)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 800, alignment: .leading)
                    .padding(42)
                }
            } else {
                EmptyState(title: "选择一篇文章", message: "从左侧打开文章，或创建一篇新笔记。", actionTitle: "新文章") { model.newArticle() }
            }
        }
    }
}

private enum MarkdownArticleBlock {
    case image(url: String, alt: String)
    case text(String)
}

private struct MarkdownArticleBody: View {
    let markdown: String
    let store: LocalBlogStore
    let articleLinks: [NativeArticleSummary]
    let onOpenArticle: (String) -> Void

    init(
        body: String,
        store: LocalBlogStore,
        articleLinks: [NativeArticleSummary] = [],
        onOpenArticle: @escaping (String) -> Void = { _ in }
    ) {
        markdown = body
        self.store = store
        self.articleLinks = articleLinks
        self.onOpenArticle = onOpenArticle
    }

    private var blocks: [MarkdownArticleBlock] { Self.markdownBlocks(in: markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .image(url, alt):
                    NativeImageView(url: url, alt: alt, store: store)
                case let .text(markdown):
                    MarkdownDocumentView(
                        markdown: markdown,
                        articleLinks: articleLinks,
                        onOpenArticle: onOpenArticle
                    )
                }
            }
        }
    }

    static func imageURLs(in markdown: String) -> Set<String> {
        Set(markdownBlocks(in: markdown).compactMap { block in
            guard case let .image(url, _) = block else { return nil }
            return url
        })
    }

    private static func markdownBlocks(in markdown: String) -> [MarkdownArticleBlock] {
        let expression = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)\s]+)\)"#)
        let searchRange = NSRange(markdown.startIndex..., in: markdown)
        let matches = expression.matches(in: markdown, range: searchRange)
        guard !matches.isEmpty else { return markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.text(markdown)] }

        var blocks: [MarkdownArticleBlock] = []
        var cursor = markdown.startIndex
        for match in matches {
            guard let matchRange = Range(match.range, in: markdown),
                  let altRange = Range(match.range(at: 1), in: markdown),
                  let urlRange = Range(match.range(at: 2), in: markdown) else { continue }
            let textBefore = String(markdown[cursor..<matchRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !textBefore.isEmpty { blocks.append(.text(textBefore)) }
            blocks.append(.image(url: String(markdown[urlRange]), alt: String(markdown[altRange])))
            cursor = matchRange.upperBound
        }

        let trailingText = String(markdown[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailingText.isEmpty { blocks.append(.text(trailingText)) }
        return blocks
    }
}

struct MarkdownWebEmbedView: View {
    let embed: MarkdownWebEmbed

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(embed.title, systemImage: "safari")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    NSWorkspace.shared.open(embed.url)
                } label: {
                    Label("在浏览器中打开", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.secondary.opacity(0.08))

            MarkdownEmbeddedWebView(url: embed.url)
                .frame(maxWidth: .infinity, minHeight: embed.height, maxHeight: embed.height)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.24))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct MarkdownHTMLComponentView: View {
    let component: MarkdownHTMLComponent

    var body: some View {
        MarkdownHTMLWebView(html: component.html)
            .frame(maxWidth: .infinity, minHeight: component.height, maxHeight: component.height)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.2))
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel("HTML 组件")
    }
}

private struct MarkdownHTMLWebView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        loadHTML(in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        loadHTML(in: webView, coordinator: context.coordinator)
    }

    private func loadHTML(in webView: WKWebView, coordinator: Coordinator) {
        let document = Self.document(containing: html)
        guard coordinator.loadedDocument != document else { return }
        coordinator.loadedDocument = document
        webView.loadHTMLString(document, baseURL: nil)
    }

    private static func document(containing html: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            :root { color-scheme: light dark; }
            *, *::before, *::after { box-sizing: border-box; }
            html, body { min-height: 100%; }
            body {
              margin: 0;
              padding: 16px;
              overflow: auto;
              color: CanvasText;
              background: Canvas;
              font-family: -apple-system, BlinkMacSystemFont, sans-serif;
            }
            img, video, canvas, svg { max-width: 100%; }
          </style>
        </head>
        <body>
        \(html)
        </body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedDocument: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            if navigationAction.navigationType == .linkActivated {
                if Self.isHTTPURL(url) { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
                return
            }

            decisionHandler(url.scheme?.lowercased() == "about" ? .allow : .cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               Self.isHTTPURL(url) {
                NSWorkspace.shared.open(url)
            }
            return nil
        }

        private static func isHTTPURL(_ url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased() else { return false }
            return ["http", "https"].contains(scheme)
        }
    }
}

private struct MarkdownEmbeddedWebView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil,
                  let url = navigationAction.request.url,
                  isAllowed(url) else { return nil }
            webView.load(URLRequest(url: url))
            return nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url, isAllowed(url) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        private func isAllowed(_ url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased() else { return false }
            return ["http", "https"].contains(scheme)
        }
    }
}

private struct NativeImageView: View {
    let url: String
    let alt: String
    let store: LocalBlogStore

    @State private var image: NSImage?
    @State private var failedToLoad = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 680)
                    .accessibilityLabel(alt)
            } else if failedToLoad {
                Label("无法加载图片：\(alt)", systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView("正在加载图片…")
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .task(id: url) {
            guard let fileURL = await store.mediaURL(for: url) else {
                failedToLoad = true
                return
            }
            let decoded = await Task.detached(priority: .userInitiated) {
                NativeImageDecodeResult(
                    image: NativeImageLoader.thumbnail(from: fileURL, maxPixelSize: 2_400)
                )
            }.value
            guard !Task.isCancelled else { return }
            image = decoded.image
            failedToLoad = image == nil
        }
    }
}

private struct NativeImageDecodeResult: @unchecked Sendable {
    let image: NSImage?
}

private enum NativeImageLoader {
    static func thumbnail(from url: URL, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

private struct InlineVideoPlayer: View {
    let media: NativeMedia
    let store: LocalBlogStore

    @State private var player: AVPlayer?
    @State private var failedToLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let player {
                NativeAVPlayerView(player: player)
                    .frame(minHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel(media.name)
            } else if failedToLoad {
                Label("无法加载视频：\(media.name)", systemImage: "video.slash")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                ProgressView("正在加载视频…")
                    .frame(maxWidth: .infinity, minHeight: 320)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }

            Label(media.name, systemImage: "video")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .task(id: media.url) {
            guard let url = await store.mediaURL(for: media.url),
                  FileManager.default.fileExists(atPath: url.path) else {
                failedToLoad = true
                return
            }
            player = AVPlayer(url: url)
        }
        .onDisappear { player?.pause() }
    }
}

private struct NativeAVPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = true
        playerView.player = player
        return playerView
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        playerView.player = player
    }

    static func dismantleNSView(_ playerView: AVPlayerView, coordinator: ()) {
        playerView.player?.pause()
        playerView.player = nil
    }
}

@MainActor
private final class ArticleLinkAutocompleteController: ObservableObject {
    private weak var textView: NSTextView?
    @Published private(set) var activeLinkQuery: String?

    func attach(to textView: NSTextView) {
        self.textView = textView
    }

    func completeSuggestion(_ article: NativeArticleSummary) {
        guard let textView,
              let context = linkContext(in: textView.string, selectedRange: textView.selectedRange()) else {
            return
        }

        let replacement = "[[\(article.title)]]"
        guard textView.shouldChangeText(in: context.range, replacementString: replacement) else { return }
        textView.textStorage?.replaceCharacters(in: context.range, with: replacement)
        let cursor = context.range.location + (replacement as NSString).length
        textView.setSelectedRange(NSRange(location: cursor, length: 0))
        textView.didChangeText()
        activeLinkQuery = nil
        textView.window?.makeFirstResponder(textView)
    }

    func dismissSuggestions() {
        activeLinkQuery = nil
    }

    fileprivate func updateLinkQuery(from textView: NSTextView) {
        activeLinkQuery = linkContext(in: textView.string, selectedRange: textView.selectedRange())?.query
    }

    private func linkContext(in text: String, selectedRange: NSRange) -> (range: NSRange, query: String)? {
        guard selectedRange.length == 0 else { return nil }
        let source = text as NSString
        guard selectedRange.location <= source.length else { return nil }
        let prefix = source.substring(to: selectedRange.location) as NSString
        let opening = prefix.range(of: "[[", options: .backwards)
        guard opening.location != NSNotFound else { return nil }

        let queryRange = NSRange(
            location: opening.location + opening.length,
            length: selectedRange.location - opening.location - opening.length
        )
        let query = source.substring(with: queryRange)
        guard !query.contains("["),
              !query.contains("]"),
              !query.contains(where: { $0.isNewline }) else {
            return nil
        }
        return (NSRange(location: opening.location, length: selectedRange.location - opening.location), query)
    }
}

private struct NativeBodyEditor: NSViewRepresentable {
    @Binding var text: String
    let linkController: ArticleLinkAutocompleteController
    let onPasteImage: (NSImage, String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        let textView = PastingTextView()
        textView.allowsUndo = true
        textView.autoresizingMask = [.width]
        textView.backgroundColor = .textBackgroundColor
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 18, weight: .regular)
        textView.isHorizontallyResizable = false
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.string = text
        textView.textColor = .labelColor
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        // The editor itself has a 10-point outer inset and its placeholder has
        // an 18-point inset. Keep the editable glyphs (and therefore caret)
        // on that same 18-point leading edge.
        textView.textContainer?.lineFragmentPadding = 8
        textView.textContainer?.widthTracksTextView = true
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        textView.onPasteImage = { [weak textView, weak coordinator = context.coordinator] image, selectedRange in
            guard let textView else { return }
            coordinator?.insertPastedImage(image, at: selectedRange, into: textView)
        }
        linkController.attach(to: textView)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        linkController.attach(to: textView)
        guard textView.string != text else { return }
        textView.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeBodyEditor

        init(parent: NativeBodyEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.linkController.updateLinkQuery(from: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.linkController.updateLinkQuery(from: textView)
        }

        func insertPastedImage(_ image: NSImage, at selectedRange: NSRange, into textView: NSTextView) {
            let placeholder = "[[正在上传图片:\(UUID().uuidString.lowercased())]]"
            textView.insertText(placeholder, replacementRange: selectedRange)
            parent.text = textView.string
            parent.onPasteImage(image, placeholder)
        }
    }
}

private final class PastingTextView: NSTextView {
    var onPasteImage: ((NSImage, NSRange) -> Void)?
    private var requestedInitialFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !requestedInitialFocus else { return }
        requestedInitialFocus = true

        // NSViewRepresentable creates the editor before it has a window. Wait
        // until it is attached, then focus it once so a new writing view accepts
        // keyboard input without requiring an extra click.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types = super.readablePasteboardTypes
        for imageType in [.png, .tiff, .fileURL] as [NSPasteboard.PasteboardType] where !types.contains(imageType) {
            types.append(imageType)
        }
        return types
    }

    override func paste(_ sender: Any?) {
        if insertPastedImage(from: .general, at: selectedRange()) { return }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if insertPastedImage(from: .general, at: selectedRange()) { return }
        super.pasteAsPlainText(sender)
    }

    override func readSelection(
        from pasteboard: NSPasteboard,
        type: NSPasteboard.PasteboardType
    ) -> Bool {
        if insertPastedImage(from: pasteboard, at: selectedRange()) { return true }
        return super.readSelection(from: pasteboard, type: type)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        pastedImage(from: sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let dropPoint = convert(sender.draggingLocation, from: nil)
        let location = characterIndexForInsertion(at: dropPoint)
        guard insertPastedImage(
            from: sender.draggingPasteboard,
            at: NSRange(location: location, length: 0)
        ) else {
            return super.performDragOperation(sender)
        }
        return true
    }

    @discardableResult
    private func insertPastedImage(from pasteboard: NSPasteboard, at range: NSRange) -> Bool {
        guard let image = pastedImage(from: pasteboard), let onPasteImage else { return false }
        onPasteImage(image, range)
        return true
    }

    private func pastedImage(from pasteboard: NSPasteboard) -> NSImage? {
        // Some apps expose copied images as an NSImage object instead of
        // advertising a concrete PNG/TIFF representation.
        if let image = pasteboard
            .readObjects(forClasses: [NSImage.self])?
            .compactMap({ $0 as? NSImage })
            .first {
            return image
        }

        // Prefer the original image representation so JPEG, HEIC, WebP,
        // and other image formats copied by browsers/design tools work too.
        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types {
                guard let uniformType = UTType(type.rawValue),
                      uniformType.conforms(to: .image),
                      let data = item.data(forType: type),
                      let image = NSImage(data: data) else { continue }
                return image
            }
        }

        // Keep the explicit AppKit fallbacks for screenshots and older apps
        // that provide data lazily through these pasteboard types.
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let image = NSImage(data: data) {
                return image
            }
        }

        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return urls?.lazy.compactMap(NSImage.init(contentsOf:)).first
    }
}

private struct MarkdownPreview: View {
    let markdown: String
    let store: LocalBlogStore
    let articleLinks: [NativeArticleSummary]
    let onOpenArticle: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("实时预览", systemImage: "eye")
                    .font(.headline)
                Spacer()
                Text("随输入更新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "text.document")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("开始输入 Markdown")
                            .font(.headline)
                        Text("标题、强调、链接和图片会在这里实时渲染。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    MarkdownArticleBody(
                        body: markdown,
                        store: store,
                        articleLinks: articleLinks,
                        onOpenArticle: onOpenArticle
                    )
                        .padding(.vertical, 4)
                }
            }
            .padding(16)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(ArticleEditorLayout.contentInset)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ArticleEditorView: View {
    @ObservedObject var model: NativeAppModel
    @StateObject private var articleLinkController = ArticleLinkAutocompleteController()

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            Divider()

            GeometryReader { proxy in
                let settingsWidth = min(max(proxy.size.width * 0.22, 260), 340)

                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        titleSection
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, ArticleEditorLayout.titleVerticalInset)

                        writingSection
                    }
                    .frame(width: proxy.size.width - settingsWidth - 1, alignment: .leading)

                    Divider()

                    ScrollView {
                        editorSidebar
                            .padding(ArticleEditorLayout.contentInset)
                    }
                    .frame(width: settingsWidth)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.34))
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var editorHeader: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil")
                        .foregroundStyle(.tint)
                    Text("写作工作台")
                        .font(.headline)

                    Text(model.editor.status.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(model.editor.status == .published ? .green : .orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            (model.editor.status == .published ? Color.green : Color.orange).opacity(0.12),
                            in: Capsule()
                        )
                }

                Text(model.editor.isNew ? "创建一篇新文章" : "继续编辑这篇文章")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                Button("添加封面") {
                    model.chooseAndUpload(kind: "image", forArticle: model.editor.slug, banner: true)
                }
                Button("添加图片") {
                    model.chooseAndUpload(kind: "image", forArticle: model.editor.slug)
                }
                Button("添加视频") {
                    model.chooseAndUpload(kind: "video", forArticle: model.editor.slug)
                }
            } label: {
                Label("添加素材", systemImage: "paperclip")
            }
            .help("添加封面、图片或视频")

            Button {
                Task { await model.saveEditor(as: .draft) }
            } label: {
                Label(model.isSaving ? "保存中…" : "保存草稿", systemImage: "tray.and.arrow.down")
            }
            .disabled(model.isSaving)

            Button {
                Task { await model.saveEditor(as: .published) }
            } label: {
                Label("发布", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isSaving)
        }
        .controlSize(.large)
        .padding(.horizontal, ArticleEditorLayout.contentInset)
        .padding(.vertical, 14)
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.editor.isNew ? "新文章" : "编辑文章")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)

            TextField("给这篇文章起个标题", text: $model.editor.title)
                .font(.system(size: 40, weight: .bold, design: .serif))
                .textFieldStyle(.plain)

            Divider()

            TextField("写一句摘要，让读者快速了解这篇文章（可选）", text: $model.editor.excerpt, axis: .vertical)
                .font(.title3)
                .foregroundStyle(.secondary)
                .textFieldStyle(.plain)
                .lineLimit(2...4)
        }
        .padding(.horizontal, ArticleEditorLayout.contentInset)
    }

    private var writingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("正文", systemImage: "text.alignleft")
                        .font(.headline)
                    Text("使用 Markdown 写作，右侧会同步显示效果")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 12) {
                    Label("\(wordCount) 字", systemImage: "character.cursor.ibeam")
                    Label("约 \(readingMinutes) 分钟", systemImage: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, ArticleEditorLayout.contentInset)
            .padding(.vertical, 14)

            Divider()

            HSplitView {
                editorPane
                    .frame(minWidth: 230, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                MarkdownPreview(
                    markdown: model.editor.body,
                    store: model.store,
                    articleLinks: model.articles,
                    onOpenArticle: model.openArticleLink
                )
                    .frame(minWidth: 230, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(minHeight: 440)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                    Text("支持标题、列表、引用、代码、表格、加粗、斜体、删除线、链接和图片。复制或拖入图片后可直接加入正文。")
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "safari")
                    Text("网页嵌入：单独一行粘贴 <iframe src=\"…\"></iframe>，或使用 ```embed 代码块放入网页 URL。")
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                    Text("HTML 组件：使用 ```html-render height=360 代码块；组件支持 CSS 和 JavaScript。")
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "link")
                    Text("文章关联：输入 [[ 后按标题联想，选择后会插入 [[文章标题]]。")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, ArticleEditorLayout.contentInset)
            .padding(.vertical, 11)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.48), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.quaternary)
        }
    }

    private var editorPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Markdown 编辑", systemImage: "pencil.line")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    insertHTMLComponentTemplate()
                } label: {
                    Label("HTML 组件", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(.borderless)
                .help("插入可直接渲染的 HTML 组件")
                Text("⌘Z 可撤销")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            NativeBodyEditor(
                text: $model.editor.body,
                linkController: articleLinkController
            ) { image, placeholder in
                model.uploadPastedImage(image, placeholder: placeholder)
            }
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.quaternary)
            }
            .overlay(alignment: .topLeading) {
                if model.editor.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("从这里开始写……")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        // Text's CJK glyphs begin slightly inside their layout
                        // box, while the NSTextView caret does not. Offset the
                        // prompt by 6 points so its visible first glyph aligns
                        // with the caret.
                        .padding(.leading, 12)
                        .padding(.top, 18)
                        .allowsHitTesting(false)
                }
            }

            if let query = articleLinkController.activeLinkQuery, !articleLinkSuggestions.isEmpty {
                ArticleLinkSuggestionMenu(
                    query: query,
                    articles: articleLinkSuggestions,
                    onSelect: articleLinkController.completeSuggestion,
                    onDismiss: articleLinkController.dismissSuggestions
                )
            }
        }
        .padding(ArticleEditorLayout.contentInset)
    }

    private var editorSidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("文章设置")
                .font(.title3.weight(.semibold))

            EditorCard(title: "发布状态", systemImage: "paperplane") {
                HStack(spacing: 10) {
                    Image(systemName: model.editor.status == .published ? "checkmark.circle.fill" : "pencil.circle.fill")
                        .font(.title3)
                        .foregroundStyle(model.editor.status == .published ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.editor.status == .published ? "已发布" : "草稿")
                            .font(.subheadline.weight(.semibold))
                        if let updatedAt = model.editor.updatedAt {
                            Text("最近保存：\(updatedAt.nativeDateLabel)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("尚未保存")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Text("保存草稿后可以继续编辑，发布后文章会出现在博客中。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            EditorCard(title: "分类与标签", systemImage: "tag") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("分类", text: $model.editor.category)
                        .textFieldStyle(.roundedBorder)
                    TextField("标签，例如 #Swift #随笔", text: $model.editor.tags)
                        .textFieldStyle(.roundedBorder)

                    if !tagSuggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(tagSuggestions, id: \.self) { tag in
                                    Button("#\(tag)") {
                                        appendTag(tag)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }

                    Text("输入 #标签，使用空格继续添加；也兼容原来的逗号分隔。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            EditorCard(title: "封面图", systemImage: "photo") {
                if let banner = model.editor.banner {
                    HStack(spacing: 10) {
                        NativeImageView(url: banner.url, alt: banner.alt, store: model.store)
                            .frame(width: 64, height: 52)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(banner.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(2)
                            Text("已添加")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)
                    }
                } else {
                    Button {
                        model.chooseAndUpload(kind: "image", forArticle: model.editor.slug, banner: true)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "photo.badge.plus")
                                .font(.title3)
                            Text("添加一张封面图")
                                .font(.caption.weight(.medium))
                            Text("推荐横向图片")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [5]))
                        }
                    }
                    .buttonStyle(.plain)
                }

                if model.editor.banner != nil {
                    Button("更换封面") {
                        model.chooseAndUpload(kind: "image", forArticle: model.editor.slug, banner: true)
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            EditorCard(title: "附件", systemImage: "paperclip") {
                if model.editor.media.isEmpty {
                    Text("还没有图片或视频附件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(model.editor.media) { media in
                            EditorAttachmentRow(media: media) {
                                model.removeEditorMedia(media)
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button("图片") {
                        model.chooseAndUpload(kind: "image", forArticle: model.editor.slug)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("视频") {
                        model.chooseAndUpload(kind: "video", forArticle: model.editor.slug)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            EditorCard(title: "文章概览", systemImage: "chart.bar") {
                HStack {
                    EditorMetric(value: "\(wordCount)", label: "字")
                    Divider().frame(height: 26)
                    EditorMetric(value: "\(model.editor.media.count)", label: "个附件")
                }
            }
        }
    }

    private var wordCount: Int {
        NativeWritingMetrics.characterCount(of: model.editor.body)
    }

    private var readingMinutes: Int {
        max(1, Int(ceil(Double(max(wordCount, 1)) / 500)))
    }

    private var tagSuggestions: [String] {
        let chosen = NativeArticleTag.parse(model.editor.tags)
        return model.availableArticleTags.filter { suggestion in
            !chosen.contains { $0.caseInsensitiveCompare(suggestion) == .orderedSame }
        }
    }

    private var articleLinkSuggestions: [NativeArticleSummary] {
        guard let query = articleLinkController.activeLinkQuery else { return [] }
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.articles.filter { article in
            normalized.isEmpty
                || article.title.localizedCaseInsensitiveContains(normalized)
                || article.slug.localizedCaseInsensitiveContains(normalized)
        }
        .prefix(8)
        .map { $0 }
    }

    private func appendTag(_ tag: String) {
        guard !NativeArticleTag.parse(model.editor.tags).contains(where: {
            $0.caseInsensitiveCompare(tag) == .orderedSame
        }) else {
            return
        }
        let separator = model.editor.tags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : " "
        model.editor.tags += "\(separator)#\(tag)"
    }

    private func insertHTMLComponentTemplate() {
        let template = """
        ```html-render height=360
        <div style="padding: 20px; border-radius: 12px; background: #2563eb; color: white;">
          <h2 style="margin-top: 0;">HTML 组件</h2>
          <p>在这里输入 HTML、CSS 或 JavaScript。</p>
        </div>
        ```
        """
        let separator = model.editor.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : (model.editor.body.hasSuffix("\n") ? "\n" : "\n\n")
        model.editor.body += separator + template
    }
}

private struct ArticleLinkSuggestionMenu: View {
    let query: String
    let articles: [NativeArticleSummary]
    let onSelect: (NativeArticleSummary) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(
                    query.isEmpty ? "关联到文章" : "匹配的文章",
                    systemImage: "link"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("关闭文章联想")
            }

            ForEach(articles) { article in
                Button {
                    onSelect(article)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(article.title)
                                .font(.callout.weight(.medium))
                            Text("\(article.category) · \(article.slug)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("插入")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary)
        }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("文章关联建议")
    }
}

private struct EditorCard<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary)
        }
    }
}

private struct EditorAttachmentRow: View {
    let media: NativeMedia
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: media.isVideo ? "video.fill" : "photo.fill")
                .font(.caption)
                .foregroundStyle(.tint)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))

            Text(media.name)
                .font(.caption)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("移除附件")
        }
    }
}

private struct EditorMetric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
