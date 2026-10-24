import AppKit
import SwiftUI

struct NativePhotoBrowserState: Identifiable {
    let id = UUID()
    let images: [NativeMedia]
    let initialIndex: Int
}

/// Shared cached, downsampled images keep large libraries inexpensive to browse.
struct NativePhotoThumbnail: View {
    let media: NativeMedia
    let store: LocalBlogStore
    var pixelSize = 240
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.clear
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else if failed {
                NativeIcon.image("photo.badge.exclamationmark").foregroundStyle(.secondary)
            } else { ProgressView().controlSize(.small) }
        }
        .clipped()
        .task(id: "\(media.id)|\(pixelSize)") {
            image = nil
            failed = false
            guard let url = await store.mediaURL(for: media.url) else { failed = true; return }
            let result = await NativeImagePipeline.shared.image(from: url, mode: .thumbnail(maxPixelSize: pixelSize))
            guard !Task.isCancelled else { return }
            image = result.image
            failed = image == nil
        }
        .accessibilityLabel(media.name)
    }
}

struct NativePhotoBrowserView: View {
    let images: [NativeMedia]
    let store: LocalBlogStore
    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var scale: CGFloat = 1
    @State private var showsThumbnails = true

    init(images: [NativeMedia], initialIndex: Int, store: LocalBlogStore) {
        self.images = images
        self.store = store
        _index = State(initialValue: min(max(0, initialIndex), max(0, images.count - 1)))
    }

    private var browserSize: CGSize {
        let available = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 900)
        return CGSize(width: min(1180, available.width * 0.88), height: min(860, available.height * 0.86))
    }

    var body: some View {
        VStack(spacing: 0) {
            if images.indices.contains(index) {
                toolbar
                Divider().overlay(Color.white.opacity(0.12))
                ZStack {
                    NativePhotoZoomView(media: images[index], store: store, scale: $scale)
                        .id(images[index].id)
                        .padding(.horizontal, 54)
                        .padding(.vertical, 12)
                    HStack {
                        Button { navigate(-1) } label: { NativeIcon.image("chevron.left").frame(width: 36, height: 64) }
                            .keyboardShortcut(.leftArrow, modifiers: [])
                            .disabled(index == 0)
                            .accessibilityLabel("上一张图片")
                        Spacer()
                        Button { navigate(1) } label: { NativeIcon.image("chevron.right").frame(width: 36, height: 64) }
                            .keyboardShortcut(.rightArrow, modifiers: [])
                            .disabled(index == images.count - 1)
                            .accessibilityLabel("下一张图片")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsThumbnails { thumbnailStrip }
                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(images[index].size), countStyle: .file))
                    Spacer()
                    Text("← → 切换 · 双击缩放 · 拖动查看 · Esc 关闭")
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
        }
        .frame(width: browserSize.width, height: browserSize.height)
        .background(Color(white: 0.09))
        .foregroundStyle(.white.opacity(0.9))
        .preferredColorScheme(.dark)
        .task(id: index) {
            // Only neighbors are prefetched; the strip itself stays lazy.
            for next in [index + 1, index - 1] where images.indices.contains(next) {
                guard !Task.isCancelled, let url = await store.mediaURL(for: images[next].url) else { continue }
                _ = await NativeImagePipeline.shared.image(from: url, mode: .thumbnail(maxPixelSize: 2400))
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(images[index].name).font(.headline).lineLimit(1).truncationMode(.middle)
                Text("\(index + 1) / \(images.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { scale = max(1, scale - 0.5) } label: { NativeIcon.image("minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: [])
                .disabled(scale <= 1).help("缩小")
            Text("\(Int(scale * 100))%").font(.caption.monospacedDigit()).frame(width: 45)
                .help("相对于适合窗口的缩放比例")
            Button { scale = min(6, scale + 0.5) } label: { NativeIcon.image("plus.magnifyingglass") }
                .keyboardShortcut("+", modifiers: [])
                .disabled(scale >= 6).help("放大")
            Button("适合窗口") { scale = 1 }.keyboardShortcut("0", modifiers: [])
            Button { showsThumbnails.toggle() } label: { NativeIcon.image("rectangle.bottomthird.inset.filled") }
                .help("显示或隐藏缩略图")
            Button {
                Task { if let url = await store.mediaURL(for: images[index].url) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            } label: { NativeIcon.image("folder") }
            .help("在 Finder 中显示")
            Button { dismiss() } label: { NativeIcon.image("xmark").frame(width: 24, height: 24) }
                .keyboardShortcut(.cancelAction)
                .help("关闭图片浏览器")
                .accessibilityLabel("关闭图片浏览器")
        }
        .buttonStyle(.borderless)
        .padding(16)
    }

    private var thumbnailStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(Array(images.enumerated()), id: \.element.id) { position, media in
                        Button { index = position; scale = 1 } label: {
                            NativePhotoThumbnail(media: media, store: store, pixelSize: 180)
                                .frame(width: 66, height: 58)
                                .padding(3)
                                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(position == index ? Color.accentColor : .clear, lineWidth: 2) }
                        }
                        .id(position)
                        .buttonStyle(.plain)
                        .accessibilityLabel(NativeLocalization.text("查看第 \(position + 1) 张图片"))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }
            .frame(height: 84)
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(index, anchor: .center) }
            .onChange(of: index) { value in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(value, anchor: .center) } }
        }
    }

    private func navigate(_ delta: Int) {
        guard images.indices.contains(index + delta) else { return }
        index += delta
        scale = 1
    }
}

private struct NativePhotoZoomView: View {
    let media: NativeMedia
    let store: LocalBlogStore
    @Binding var scale: CGFloat
    @State private var image: NSImage?
    @State private var failed = false
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    @State private var gestureStart: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.clear
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(scale)
                        .offset(offset)
                } else if failed {
                    VStack(spacing: 10) {
                        NativeIcon.image("photo.badge.exclamationmark", size: 32)
                        Text("图片无法读取或已被移走")
                    }
                } else { ProgressView() }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .clipped()
            .onTapGesture(count: 2) { scale = scale > 1 ? 1 : 2 }
            .gesture(DragGesture().onChanged { value in
                offset = clamped(CGSize(width: dragStart.width + value.translation.width,
                                        height: dragStart.height + value.translation.height), in: proxy.size)
            }.onEnded { _ in dragStart = offset })
            .simultaneousGesture(MagnificationGesture().onChanged { value in
                if gestureStart == nil { gestureStart = scale }
                scale = min(6, max(1, (gestureStart ?? 1) * value))
            }.onEnded { _ in gestureStart = nil })
            .onChange(of: scale) { _ in
                offset = clamped(offset, in: proxy.size)
                dragStart = offset
            }
            .onChange(of: proxy.size) { _ in offset = .zero; dragStart = .zero }
        }
        .task(id: scale > 1) {
            // Decode original pixels only when zooming; fit-to-window uses a bounded image.
            guard let url = await store.mediaURL(for: media.url) else { failed = true; return }
            let result = await NativeImagePipeline.shared.image(
                from: url, mode: scale > 1 ? .fullSize : .thumbnail(maxPixelSize: 2400)
            )
            guard !Task.isCancelled else { return }
            image = result.image
            failed = image == nil
        }
        .accessibilityLabel(NativeLocalization.text("大图浏览：\(media.name)"))
    }

    private func clamped(_ value: CGSize, in viewport: CGSize) -> CGSize {
        guard let image, image.size.width > 0, image.size.height > 0 else { return .zero }
        let fit = min(viewport.width / image.size.width, viewport.height / image.size.height)
        let x = max(0, (image.size.width * fit * scale - viewport.width) / 2)
        let y = max(0, (image.size.height * fit * scale - viewport.height) / 2)
        return CGSize(width: min(x, max(-x, value.width)), height: min(y, max(-y, value.height)))
    }
}
