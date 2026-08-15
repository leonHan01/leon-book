import AVKit
import AppKit
import SwiftUI

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
                            Button("删除", role: .destructive) { Task { await model.deleteSelected() } }
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

                        if !article.excerpt.isEmpty {
                            Text(article.excerpt)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }

                        if let banner = article.banner {
                            NativeImageView(url: banner.url, alt: banner.alt, store: model.store)
                        }

                        Divider()
                        MarkdownArticleBody(body: article.body, store: model.store)

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

    init(body: String, store: LocalBlogStore) {
        markdown = body
        self.store = store
    }

    private var blocks: [MarkdownArticleBlock] { Self.markdownBlocks(in: markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .image(url, alt):
                    NativeImageView(url: url, alt: alt, store: store)
                case let .text(markdown):
                    MarkdownText(markdown: markdown)
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

private struct MarkdownText: View {
    let markdown: String

    var body: some View {
        Group {
            if let attributed = try? AttributedString(markdown: markdown) {
                Text(attributed)
            } else {
                Text(markdown)
            }
        }
        .font(.system(size: 16, design: .serif))
        .lineSpacing(7)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            let fileURL = await store.mediaURL(for: url)
            image = NSImage(contentsOf: fileURL)
            failedToLoad = image == nil
        }
    }
}

private struct InlineVideoPlayer: View {
    let media: NativeMedia
    let store: LocalBlogStore

    @State private var player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let player {
                NativeAVPlayerView(player: player)
                    .frame(minHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel(media.name)
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
            player = AVPlayer(url: await store.mediaURL(for: media.url))
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

private struct NativeBodyEditor: NSViewRepresentable {
    @Binding var text: String
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
        textView.font = .systemFont(ofSize: 16, weight: .regular)
        textView.isHorizontallyResizable = false
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.string = text
        textView.textColor = .labelColor
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 16
        textView.textContainer?.widthTracksTextView = true
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        textView.onPasteImage = { [weak textView, weak coordinator = context.coordinator] image, selectedRange in
            guard let textView else { return }
            coordinator?.insertPastedImage(image, at: selectedRange, into: textView)
        }

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
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

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        guard let image = pastedImage(from: pasteboard) else {
            super.paste(sender)
            return
        }
        onPasteImage?(image, selectedRange())
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        pastedImage(from: sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let image = pastedImage(from: sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }
        let dropPoint = convert(sender.draggingLocation, from: nil)
        let location = characterIndexForInsertion(at: dropPoint)
        onPasteImage?(image, NSRange(location: location, length: 0))
        return true
    }

    private func pastedImage(from pasteboard: NSPasteboard) -> NSImage? {
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
                    MarkdownArticleBody(body: markdown, store: store)
                        .padding(.vertical, 4)
                }
            }
            .padding(16)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ArticleEditorView: View {
    @ObservedObject var model: NativeAppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.editor.isNew ? "新文章" : "编辑文章")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("添加封面") { model.chooseAndUpload(kind: "image", forArticle: model.editor.slug, banner: true) }
                Button("添加媒体") { model.chooseAndUpload(kind: "image", forArticle: model.editor.slug) }
                Button("添加视频") { model.chooseAndUpload(kind: "video", forArticle: model.editor.slug) }
                Button("保存草稿") { Task { await model.saveEditor(as: .draft) } }
                    .disabled(model.isSaving)
                Button("发布") { Task { await model.saveEditor(as: .published) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isSaving)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            Divider()

            VStack(alignment: .leading, spacing: 18) {
                    TextField("文章标题", text: $model.editor.title)
                        .font(.system(size: 28, weight: .bold, design: .serif))
                        .textFieldStyle(.plain)

                    HStack(spacing: 12) {
                        TextField("分类", text: $model.editor.category)
                            .textFieldStyle(.roundedBorder)
                        TextField("标签，用逗号分隔", text: $model.editor.tags)
                            .textFieldStyle(.roundedBorder)
                    }

                    TextField("摘要（可选）", text: $model.editor.excerpt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)

                    HSplitView {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Markdown 正文", systemImage: "text.alignleft")
                                .font(.headline)
                            NativeBodyEditor(text: $model.editor.body) { image, placeholder in
                                model.uploadPastedImage(image, placeholder: placeholder)
                            }
                                .padding(10)
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(alignment: .topLeading) {
                                    if model.editor.body.isEmpty {
                                        Text("从这里开始写……支持 Markdown 文本。")
                                            .foregroundStyle(.secondary)
                                            .padding(16)
                                            .allowsHitTesting(false)
                                    }
                                }
                        }
                        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                        MarkdownPreview(markdown: model.editor.body, store: model.store)
                    }
                    .frame(minHeight: 380)

                    Text("支持 # 标题、**加粗**、_斜体_、链接和 ![图片说明](图片路径)。复制或拖入图片后可直接加入正文。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let banner = model.editor.banner {
                        Label("封面：\(banner.name)", systemImage: "photo")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.editor.media) { media in
                        Label("附件：\(media.name)", systemImage: media.isVideo ? "video" : "photo")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(maxWidth: 900, maxHeight: .infinity, alignment: .topLeading)
            .padding(30)
        }
    }
}
