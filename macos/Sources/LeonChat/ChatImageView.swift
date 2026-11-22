import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
struct ChatImageView: View {
    @ObservedObject var store: ChatStore
    let imageId: String
    var onQuote:(()->Void)? = nil
    var onFavorite:(()->Void)? = nil
    var onBranch:(()->Void)? = nil
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: NSImage?
    @State private var thumbnailFailed = false
    @State private var thumbnailRetry = 0
    @State private var previewPresented = false
    @State private var previewImage: NSImage?
    @State private var previewFailed = false
    @State private var previewRetry = 0
    @State private var branchAfterPreview=false
    @State private var previewSize = CGSize(width: 1200, height: 850)

    var body: some View {
        Button {
            if thumbnail != nil { openPreview() } else { thumbnailRetry += 1 }
        } label: {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .overlay {
                    GeometryReader { geometry in
                        let pixels = max(64, Int(ceil((geometry.size.width - 6) * displayScale / 64)) * 64)
                        Group {
                            if let thumbnail {
                                Image(nsImage: thumbnail).resizable().scaledToFit().padding(3)
                            } else if thumbnailFailed {
                                Label("图片加载失败，点击重试", systemImage: "arrow.clockwise").font(.caption)
                            } else { ProgressView().controlSize(.small) }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                            .task(id: "\(store.imageCacheRevision):\(imageId):\(pixels):\(thumbnailRetry)") {
                                thumbnailFailed = false
                                do {
                                    let image = try await store.imageThumbnail(imageId, pixels: pixels)
                                    try Task.checkCancellation()
                                    thumbnail = image
                                } catch is CancellationError {
                                } catch { if !Task.isCancelled { thumbnailFailed = true } }
                            }
                    }
                }.frame(maxWidth: 360).clipShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityLabel("聊天图片，点击查看大图")
            .contextMenu { saveButton;messageActions }
            .onDisappear { thumbnail = nil }
            .onChange(of: store.imageCacheRevision) { _ in
                thumbnail = nil; previewImage = nil; previewPresented = false; branchAfterPreview = false
            }
            .sheet(isPresented: $previewPresented, onDismiss: finishPreview) {
                Group {
                    if let previewImage {
                        ChatImagePreview(image: previewImage, close: { previewPresented = false },
                                         actions: Group { saveButton; messageActions }, download: downloadButton)
                    } else {
                        VStack(spacing: 16) {
                            if previewFailed {
                                Button("图片加载失败，点击重试") { previewRetry += 1 }
                            } else { ProgressView().controlSize(.small) }
                            Button("关闭") { previewPresented = false }.keyboardShortcut(.cancelAction)
                        }
                    }
                }.frame(width: previewSize.width, height: previewSize.height)
                    .task(id: previewRetry) {
                        previewFailed = false
                        do {
                            let image = try await store.fullSizeImage(imageId)
                            try Task.checkCancellation()
                            previewImage = image
                        } catch is CancellationError {
                        } catch { if !Task.isCancelled { previewFailed = true } }
                    }
            }
    }
    private func openPreview() {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let available = screen?.visibleFrame.size ?? CGSize(width: 1440, height: 1000)
        previewSize = CGSize(width: min(1600, floor(available.width * 0.92)),
                             height: min(1100, floor(available.height * 0.92)))
        previewPresented = true
    }
    private func finishPreview() {
        previewImage = nil
        if branchAfterPreview { branchAfterPreview = false; onBranch?() }
    }
    @ViewBuilder private var messageActions:some View {
        if let onQuote {Button("引用") {previewPresented=false;onQuote()}}
        if let onFavorite {Button("收藏") {previewPresented=false;onFavorite()}}
        if let onBranch {Button("从这里创建分支") {if previewPresented {branchAfterPreview=true;previewPresented=false} else {onBranch()}}}
    }
    private var saveButton: some View {
        Button { saveImage() } label: { Label("保存图片…",systemImage:"square.and.arrow.down") }.disabled(thumbnail == nil && previewImage == nil)
    }
    private var downloadButton: some View {
        Button { saveImage() } label: {
            Image(systemName:"arrow.down.to.line").font(.system(size:20,weight:.medium))
                .foregroundStyle(.primary).frame(width:48,height:48)
                .background(.regularMaterial,in:Circle())
                .overlay(Circle().stroke(.primary.opacity(0.08),lineWidth:1))
                .shadow(color:.black.opacity(0.15),radius:7,y:3)
        }
        .buttonStyle(.plain).help("下载并保存图片")
        .accessibilityLabel("下载并保存图片").accessibilityIdentifier("download_chat_image")
    }
    private func saveImage() {
        let revision = store.imageCacheRevision
        let panel = NSSavePanel();panel.title = "保存图片";panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = "Leon-\(imageId).jpg";panel.canCreateDirectories = true
        let completion: (NSApplication.ModalResponse) -> Void = { result in
            guard result == .OK, let url = panel.url else {return}
            Task { @MainActor in
                guard revision == store.imageCacheRevision else { return }
                do {
                    let data = try await store.imageData(imageId)
                    guard revision == store.imageCacheRevision else { return }
                    try await Task.detached(priority: .utility) { try data.write(to: url, options: .atomic) }.value
                } catch is CancellationError {
                } catch {
                    let alert = NSAlert(error: error)
                    if let window = NSApp.keyWindow { _ = await alert.beginSheetModal(for: window) } else { alert.runModal() }
                }
            }
        }
        if let window = NSApp.keyWindow {panel.beginSheetModal(for:window,completionHandler:completion)} else {panel.begin(completionHandler:completion)}
    }
}
