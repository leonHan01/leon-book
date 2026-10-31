import AppKit
import ImageIO
import SwiftUI
@testable import LeonBook

private struct MomentImageLoadingFailure: Error, CustomStringConvertible {
    let description: String
}

private final class MomentImageLoadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(String, NativeImageLoadMode)] = []

    func decode(_ url: URL, _ mode: NativeImageLoadMode) -> NSImage? {
        lock.lock()
        requests.append((url.lastPathComponent, mode))
        lock.unlock()
        return NSImage(size: NSSize(width: 32, height: 32))
    }

    var loads: [(String, NativeImageLoadMode)] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

@MainActor
final class MomentImageLoadingTests {
    func testLargePhotoThumbnailAndOriginalPreserveSizeAndOrientation() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("large-photo.jpg")
        guard let context = CGContext(data: nil, width: 4000, height: 3000, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw MomentImageLoadingFailure(description: "could not create large photo fixture")
        }
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw MomentImageLoadingFailure(description: "could not write large photo fixture")
        }
        let pipeline = NativeImagePipeline()
        let thumbnail = await pipeline.image(from: url, mode: .thumbnail(maxPixelSize: 192)).image
        guard let small = thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              small.width == 144, small.height == 192 else {
            throw MomentImageLoadingFailure(description: "feed thumbnail must be downsampled and respect photo orientation")
        }
        let original = await pipeline.image(from: url, mode: .fullSize).image
        guard let full = original?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              full.width == 3000, full.height == 4000 else {
            throw MomentImageLoadingFailure(description: "opening a thumbnail must retain all original pixels and photo orientation")
        }
        print("MOMENT_IMAGE_PIXELS thumbnail=\(small.width)x\(small.height) original=\(full.width)x\(full.height)")
    }

    func testFeedLoadsOnlyVisibleThumbnailsAtDisplaySize() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let probe = MomentImageLoadProbe()
        let pipeline = NativeImagePipeline(decoder: { probe.decode($0, $1) })
        let content = ScrollView {
            VStack(spacing: 0) {
                MomentImageGrid(images: [media(0)], store: store, onOpenImage: { _ in })
                Color.clear.frame(height: 2000)
                MomentImageGrid(images: [media(1)], store: store, onOpenImage: { _ in })
            }
        }
        .environment(\.displayScale, 2)
        .environment(\.nativeImagePipeline, pipeline)
        let (window, host) = mount(content, width: 180, height: 300)
        defer { window.close() }
        try await settle(host)
        let loads = probe.loads
        print("MOMENT_IMAGE_FEED initialLoads=\(loads)")
        guard loads.count == 1, loads.first?.0 == "image-0.png",
              case let .thumbnail(maxPixelSize)? = loads.first?.1, maxPixelSize <= 384 else {
            throw MomentImageLoadingFailure(description: "feed must load only the visible image at its actual Retina size: \(loads)")
        }
        guard let scroll = findScroll(in: host), let document = scroll.documentView else {
            throw MomentImageLoadingFailure(description: "missing image feed scroll view")
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - scroll.contentSize.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host)
        guard probe.loads.map(\.0) == ["image-0.png", "image-1.png"] else {
            throw MomentImageLoadingFailure(description: "scrolling into view must load the second thumbnail: \(probe.loads)")
        }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host)
        guard probe.loads.count == 2 else {
            throw MomentImageLoadingFailure(description: "scrolling back decoded cached thumbnails again")
        }
    }

    func testBrowserLoadsOnlySelectedOriginal() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = MomentImageLoadProbe()
        let pipeline = NativeImagePipeline(decoder: { probe.decode($0, $1) })
        let browser = MomentImageBrowserView(images: (0..<3).map(media), initialIndex: 2,
                                           store: LocalBlogStore(rootURL: root))
            .environment(\.nativeImagePipeline, pipeline)
        let (window, host) = mount(browser, width: 1000, height: 760)
        defer { window.close() }
        try await settle(host)
        let originals = probe.loads.filter { $0.1 == .fullSize }.map(\.0)
        print("MOMENT_IMAGE_BROWSER originals=\(originals)")
        guard originals == ["image-2.png"] else {
            throw MomentImageLoadingFailure(description: "opening image 3 must not load other originals: \(originals)")
        }
    }

    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leon-moment-images-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("media/moments")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<3 { try Data([0]).write(to: directory.appendingPathComponent("image-\(index).png")) }
        return root
    }

    private func media(_ index: Int) -> NativeMedia {
        NativeMedia(kind: "image", name: "image-\(index).png", size: 1, url: "/media/moments/image-\(index).png")
    }

    private func mount<Content: View>(_ content: Content, width: CGFloat, height: CGFloat) -> (NSWindow, NSHostingView<Content>) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        window.contentView = host
        return (window, host)
    }

    private func settle(_ host: NSView) async throws {
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func findScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScroll(in: $0) }.first
    }
}
