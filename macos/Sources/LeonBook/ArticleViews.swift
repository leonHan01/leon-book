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
                    MarkdownDocumentView(markdown: markdown)
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
        textView.font = .systemFont(ofSize: 18, weight: .regular)
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
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ArticleEditorView: View {
    @ObservedObject var model: NativeAppModel

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            Divider()

            GeometryReader { proxy in
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        ScrollView {
                            titleSection
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 30)
                        }
                        .frame(maxHeight: 260)

                        writingSection
                    }
                    .frame(width: proxy.size.width * 0.8)

                    Divider()

                    ScrollView {
                        editorSidebar
                            .padding(20)
                    }
                    .frame(width: proxy.size.width * 0.2)
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
        .padding(.horizontal, 24)
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
        .padding(.horizontal, 4)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            HSplitView {
                editorPane
                    .frame(minWidth: 230, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                MarkdownPreview(markdown: model.editor.body, store: model.store)
                    .frame(minWidth: 230, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(minHeight: 440)

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                Text("支持标题、列表、引用、代码、表格、加粗、斜体、删除线、链接和图片。复制或拖入图片后可直接加入正文。")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
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
                Text("⌘Z 可撤销")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            NativeBodyEditor(text: $model.editor.body) { image, placeholder in
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
                        .padding(18)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(16)
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
                    TextField("标签，用逗号分隔", text: $model.editor.tags)
                        .textFieldStyle(.roundedBorder)

                    Text("标签会帮助读者发现相关文章")
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
                                model.editor.media.removeAll { $0.id == media.id }
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
        model.editor.body.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    private var readingMinutes: Int {
        max(1, Int(ceil(Double(max(wordCount, 1)) / 500)))
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
