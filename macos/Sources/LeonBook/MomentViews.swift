import AppKit
import ImageIO
import SwiftUI

struct MomentFeedView: View {
    @ObservedObject var model: NativeAppModel
    @State private var imageBrowser: MomentImageBrowserState?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("微博")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("用图片和一句话记录此刻，内容只保存在本机资料库中。")
                        .foregroundStyle(.secondary)
                }

                MomentComposerView(model: model)

                HStack(alignment: .firstTextBaseline) {
                    Text("历史微博")
                        .font(.title2.weight(.bold))
                    Text("\(model.moments.count) 条")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .frame(maxWidth: 1_100, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.top, 34)
            .padding(.bottom, 20)

            Divider()

            if model.moments.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 38))
                        .foregroundStyle(.secondary)
                    Text("还没有微博")
                        .font(.headline)
                    Text("发布第一条图文动态，它会显示在这里。")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(model.moments) { moment in
                            MomentCard(moment: moment, store: model.store) { index in
                                imageBrowser = MomentImageBrowserState(
                                    images: moment.images,
                                    initialIndex: index
                                )
                            } onEdit: {
                                model.beginEditingMoment(moment)
                            } onDelete: {
                                model.deleteMoment(moment)
                            }
                        }
                    }
                    .frame(maxWidth: 1_100, alignment: .leading)
                    .padding(.horizontal, 34)
                    .padding(.vertical, 22)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $imageBrowser) { browser in
            MomentImageBrowserView(
                images: browser.images,
                initialIndex: browser.initialIndex,
                store: model.store
            )
        }
    }
}

private struct MomentComposerView: View {
    @ObservedObject var model: NativeAppModel
    @StateObject private var richTextController = MomentRichTextController()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(
                    model.editingMomentID == nil ? "发布一条微博" : "编辑微博",
                    systemImage: model.editingMomentID == nil ? "square.and.pencil" : "pencil"
                )
                    .font(.headline)
                Spacer()
                Text("\(model.momentDraft.text.count) / 500")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    richTextController.toggleBold()
                } label: {
                    Image(systemName: "bold")
                }
                .help("加粗选中的文字")
                .keyboardShortcut("b", modifiers: .command)

                Menu {
                    Button("默认颜色") {
                        richTextController.apply(color: nil)
                    }
                    Divider()
                    ForEach(NativeMomentTextColor.allCases) { color in
                        Button {
                            richTextController.apply(color: color)
                        } label: {
                            Label(color.label, systemImage: "circle.fill")
                                .foregroundStyle(color.swiftUIColor)
                        }
                    }
                } label: {
                    Label("文字颜色", systemImage: "paintpalette")
                }
                .help("修改选中文字的颜色")

                Spacer()

                Text("拖入或粘贴图片可直接添加")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            MomentRichTextEditor(
                text: $model.momentDraft.text,
                textRuns: $model.momentDraft.textRuns,
                controller: richTextController,
                onPasteImages: model.uploadMomentPastedImages
            )
                .frame(height: 63)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.quaternary)
                }

            if !model.momentDraft.images.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(model.momentDraft.images) { image in
                            ZStack(alignment: .topTrailing) {
                                MomentImage(
                                    media: image,
                                    store: model.store,
                                    loadMode: .thumbnail(maxPixelSize: 240)
                                )
                                    .frame(width: 96, height: 96)
                                    .clipShape(RoundedRectangle(cornerRadius: 9))

                                Button {
                                    model.removeMomentImage(image)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title3)
                                        .symbolRenderingMode(.hierarchical)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.white, .black.opacity(0.6))
                                .padding(5)
                                .accessibilityLabel("移除图片 \(image.name)")
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            HStack(spacing: 12) {
                Button {
                    model.chooseMomentImages()
                } label: {
                    Label("添加图片", systemImage: "photo.on.rectangle.angled")
                }

                Text("最多 9 张图片")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if model.editingMomentID != nil {
                    Button("取消") {
                        model.cancelMomentEditing()
                    }
                    .disabled(model.isPublishingMoment)
                }

                Button {
                    model.publishMoment()
                } label: {
                    Label(
                        model.isPublishingMoment
                            ? "正在保存…"
                            : model.editingMomentID == nil ? "发布" : "保存修改",
                        systemImage: model.editingMomentID == nil ? "paperplane.fill" : "checkmark"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.momentDraft.isEmpty || model.isPublishingMoment)
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.quaternary)
        }
    }
}

private struct MomentCard: View {
    let moment: NativeMoment
    let store: LocalBlogStore
    let onOpenImage: (Int) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundStyle(.tint)
                Text("leon-book")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                HStack(alignment: .center, spacing: 8) {
                    Text(moment.createdAt.nativeDateLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Button(action: onEdit) {
                            Label("编辑", systemImage: "pencil")
                                .frame(minWidth: 58, minHeight: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered)
                        .help("编辑这条微博")
                        .accessibilityLabel("编辑这条微博")

                        Button(action: confirmDeletion) {
                            Label("删除", systemImage: "trash")
                                .frame(minWidth: 58, minHeight: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .help("删除这条微博")
                        .accessibilityLabel("删除这条微博")
                    }
                }
            }
            if !moment.text.isEmpty {
                MomentStyledText(text: moment.text, runs: moment.textRuns)
            }

            if !moment.images.isEmpty {
                MomentImageGrid(images: moment.images, store: store, onOpenImage: onOpenImage)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .strokeBorder(.quaternary)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func confirmDeletion() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "将这条微博移入回收站？"
        alert.informativeText = "微博和图片会保留 30 天，可在回收站中恢复，之后自动永久删除。"
        alert.addButton(withTitle: "移入回收站")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onDelete()
    }
}

private struct MomentStyledText: View {
    let text: String
    let runs: [NativeMomentTextRun]

    var body: some View {
        renderedText
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var renderedText: Text {
        let resolvedRuns = runs.map(\.text).joined() == text && !runs.isEmpty
            ? runs
            : [NativeMomentTextRun(text: text, bold: false, color: nil)]
        return resolvedRuns.reduce(Text("")) { partial, run in
            partial + styled(Text(run.text), run: run)
        }
    }

    private func styled(_ text: Text, run: NativeMomentTextRun) -> Text {
        let weighted = run.bold ? text.bold() : text
        return run.color.map { weighted.foregroundColor($0.swiftUIColor) } ?? weighted
    }
}

private struct MomentImageGrid: View {
    let images: [NativeMedia]
    let store: LocalBlogStore
    let onOpenImage: (Int) -> Void

    private var columns: Int {
        images.count == 1 ? 1 : images.count == 2 ? 2 : 3
    }

    private var imageHeight: CGFloat {
        images.count == 1 ? 250 : images.count == 2 ? 168 : 106
    }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: columns),
            spacing: 3
        ) {
            ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                Button {
                    onOpenImage(index)
                } label: {
                    MomentImage(
                        media: image,
                        store: store,
                        loadMode: .thumbnail(maxPixelSize: 720)
                    )
                        .frame(height: imageHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("放大浏览图片 \(image.name)")
                .accessibilityHint("点按打开图片浏览器")
            }
        }
    }
}

private enum MomentImageLoadMode: Equatable {
    case thumbnail(maxPixelSize: Int)
    case fullSize

    var cacheKey: String {
        switch self {
        case let .thumbnail(maxPixelSize): return "thumbnail-\(maxPixelSize)"
        case .fullSize: return "full-size"
        }
    }
}

private struct MomentImage: View {
    let media: NativeMedia
    let store: LocalBlogStore
    let loadMode: MomentImageLoadMode

    @State private var image: NSImage?
    @State private var failedToLoad = false

    init(
        media: NativeMedia,
        store: LocalBlogStore,
        loadMode: MomentImageLoadMode = .thumbnail(maxPixelSize: 480)
    ) {
        self.media = media
        self.store = store
        self.loadMode = loadMode
    }

    var body: some View {
        ZStack {
            Color.clear
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if failedToLoad {
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .clipped()
        .task(id: "\(media.url)|\(loadMode.cacheKey)") {
            image = nil
            failedToLoad = false
            guard let url = await store.mediaURL(for: media.url) else {
                failedToLoad = true
                return
            }
            image = MomentImageLoader.load(from: url, mode: loadMode)
            failedToLoad = image == nil
        }
        .accessibilityLabel(media.name)
    }
}

private enum MomentImageLoader {
    static func load(from url: URL, mode: MomentImageLoadMode) -> NSImage? {
        if mode == .fullSize {
            return NSImage(contentsOf: url)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        guard case let .thumbnail(maxPixelSize) = mode else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)

        guard let cgImage else { return nil }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }
}

private struct MomentImageBrowserState: Identifiable {
    let id = UUID()
    let images: [NativeMedia]
    let initialIndex: Int
}

private struct MomentImageBrowserView: View {
    let images: [NativeMedia]
    let initialIndex: Int
    let store: LocalBlogStore

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex = 0
    @State private var scale: CGFloat = 1
    @State private var keyboardMonitor: Any?

    private var selectedImage: NativeMedia { images[selectedIndex] }
    private var browserSize: CGSize {
        let available = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1_440, height: 900)
        return CGSize(width: available.width * 0.94, height: available.height * 0.90)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(selectedImage.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text("\(selectedIndex + 1) / \(images.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    scale = max(1, scale - 0.5)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .disabled(scale <= 1)
                .help("缩小")
                Button {
                    scale = min(4, scale + 0.5)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .disabled(scale >= 4)
                .help("放大")
                Button("适合窗口") {
                    scale = 1
                }
                .disabled(scale == 1)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .help("关闭图片浏览器")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            HStack(spacing: 14) {
                Button {
                    showPreviousImage()
                } label: {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.system(size: 30))
                }
                .buttonStyle(.plain)
                .disabled(selectedIndex == 0)
                .accessibilityLabel("上一张图片")

                MomentZoomableImage(media: selectedImage, store: store, scale: $scale)
                    .id(selectedImage.id)

                Button {
                    showNextImage()
                } label: {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 30))
                }
                .buttonStyle(.plain)
                .disabled(selectedIndex == images.count - 1)
                .accessibilityLabel("下一张图片")
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            ScrollView(.horizontal) {
                HStack(spacing: 9) {
                    ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                        Button {
                            selectedIndex = index
                            scale = 1
                        } label: {
                            MomentImage(
                                media: image,
                                store: store,
                                loadMode: .thumbnail(maxPixelSize: 180)
                            )
                                .frame(width: 74, height: 74)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7)
                                        .strokeBorder(
                                            index == selectedIndex ? Color.accentColor : .clear,
                                            lineWidth: 3
                                        )
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("查看第 \(index + 1) 张图片")
                    }
                }
                .padding(14)
            }
            .scrollIndicators(.hidden)
            .frame(height: 104)
        }
        .frame(width: browserSize.width, height: browserSize.height)
        .background(Color.gray.opacity(0.72).ignoresSafeArea())
        .onAppear {
            selectedIndex = min(max(0, initialIndex), max(0, images.count - 1))
            installKeyboardMonitor()
        }
        .onDisappear {
            removeKeyboardMonitor()
        }
    }

    private func installKeyboardMonitor() {
        guard keyboardMonitor == nil else { return }

        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let navigationModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
            guard event.modifierFlags.intersection(navigationModifiers).isEmpty else {
                return event
            }

            switch event.keyCode {
            case 123:
                showPreviousImage()
                return nil
            case 124:
                showNextImage()
                return nil
            case 53:
                dismiss()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyboardMonitor() {
        guard let keyboardMonitor else { return }
        NSEvent.removeMonitor(keyboardMonitor)
        self.keyboardMonitor = nil
    }

    private func showPreviousImage() {
        guard selectedIndex > 0 else { return }
        selectedIndex -= 1
        scale = 1
    }

    private func showNextImage() {
        guard selectedIndex < images.count - 1 else { return }
        selectedIndex += 1
        scale = 1
    }
}

private struct MomentZoomableImage: View {
    let media: NativeMedia
    let store: LocalBlogStore
    @Binding var scale: CGFloat

    @State private var image: NSImage?
    @State private var failedToLoad = false
    @State private var gestureStartScale: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    Color.clear
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(
                                width: max(proxy.size.width, proxy.size.width * scale),
                                height: max(proxy.size.height, proxy.size.height * scale)
                            )
                    } else if failedToLoad {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
                .frame(
                    width: max(proxy.size.width, proxy.size.width * scale),
                    height: max(proxy.size.height, proxy.size.height * scale)
                )
            }
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = min(4, max(1, gestureStartScale * value))
                    }
                    .onEnded { _ in
                        gestureStartScale = scale
                    }
            )
        }
        .background(Color.gray.opacity(0.48), in: RoundedRectangle(cornerRadius: 12))
        .task(id: media.url) {
            guard let url = await store.mediaURL(for: media.url) else {
                failedToLoad = true
                return
            }
            image = MomentImageLoader.load(from: url, mode: .fullSize)
            failedToLoad = image == nil
        }
        .accessibilityLabel("大图浏览：\(media.name)")
    }
}

private extension NativeMomentTextColor {
    var swiftUIColor: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        }
    }
}
