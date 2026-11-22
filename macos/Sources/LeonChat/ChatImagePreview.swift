import SwiftUI
import AppKit

struct ChatImagePreview<Actions: View, Download: View>: View {
    let image: NSImage
    let close: () -> Void
    let actions: Actions
    let download: Download
    @State private var zoom: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let viewport = CGSize(width: geometry.size.width, height: max(1, geometry.size.height - 44))
            let imageSize = CGSize(width: max(1, image.size.width), height: max(1, image.size.height))
            let fit = min(viewport.width / imageSize.width, viewport.height / imageSize.height)
            let scale = zoom ?? fit
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Text("图片预览").font(.headline)
                    Spacer()
                    Button { zoom = max(0.05, scale / 1.25) } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }.disabled(scale <= 0.05).help("缩小图片").accessibilityLabel("缩小图片")
                    Text("\(Int((scale * 100).rounded()))%")
                        .font(.callout.monospacedDigit()).frame(minWidth: 48)
                        .accessibilityLabel("缩放比例 \(Int((scale * 100).rounded()))%")
                    Button { zoom = min(max(4, fit), scale * 1.25) } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }.disabled(scale >= max(4, fit)).help("放大图片").accessibilityLabel("放大图片")
                    Button("适应窗口") { zoom = nil }
                    Button("原始尺寸") { zoom = 1 }
                    Button("关闭", action: close).keyboardShortcut(.cancelAction)
                }.frame(height: 32)
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(width: imageSize.width * scale, height: imageSize.height * scale)
                        .textSelection(.disabled)
                        .contextMenu { actions }
                        .frame(width: max(viewport.width, imageSize.width * scale),
                               height: max(viewport.height, imageSize.height * scale))
                }
                .frame(width: viewport.width, height: viewport.height)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(alignment: .bottomTrailing) { download.padding(16) }
            }
        }.padding(16)
    }
}
