import AppKit
import Combine
import ImageIO
import SwiftUI
@testable import LeonBook

private struct MomentScrollingFailure: Error, CustomStringConvertible {
    let description: String
}

final class MomentScrollingPerformanceTests {
    @MainActor
    func testFastPassingMediaDoesNotMountAndSettledMediaDoes() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var mounted = 0
        var unmounted = 0
        let media = MomentDeferredMedia(height: 100) {
            Text("Media").onAppear { mounted += 1 }.onDisappear { unmounted += 1 }
        }
        let host = NSHostingView(rootView: AnyView(Color.clear))
        host.sizingOptions = []
        window.contentView = host
        for index in 0..<5 {
            host.rootView = AnyView(media.id(index))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        host.rootView = AnyView(Color.clear)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 160_000_000)
        guard mounted == 0 else { throw MomentScrollingFailure(description: "fast-passing cards still construct expensive media views") }
        func settle() async throws {
            for _ in 0..<20 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        host.rootView = AnyView(media.id(99).environment(\.momentMediaIsScrolling, false))
        try await settle()
        guard mounted == 1 else { throw MomentScrollingFailure(description: "settled media did not appear exactly once: \(mounted)") }
        host.rootView = AnyView(media.id(99).environment(\.momentMediaIsScrolling, true))
        try await settle()
        guard mounted == 1, unmounted == 0 else {
            throw MomentScrollingFailure(description: "scrolling hid media that was already visible")
        }
        host.rootView = AnyView(media.id(100).environment(\.momentMediaIsScrolling, true))
        try await settle()
        guard mounted == 1 else { throw MomentScrollingFailure(description: "new media loaded during sustained scrolling") }
        host.rootView = AnyView(media.id(100).environment(\.momentMediaIsScrolling, false))
        try await settle()
        guard mounted == 2 else { throw MomentScrollingFailure(description: "new media did not load after scrolling settled") }
    }

    @MainActor
    func testVirtualColumnKeepsOnlyVisibleRowsAndUpdatesHeights() throws {
        let column = MomentColumnViewport()
        let ids = (0..<1000).map { "post-\($0)" }
        column.update(ids: ids, viewport: CGRect(x: 0, y: 0, width: 320, height: 700)) {
            Array(repeating: 200, count: ids.count)
        }
        guard column.layout.range == 0..<4, column.layout.totalHeight == 215_984 else {
            throw MomentScrollingFailure(description: "virtual column did not reserve offscreen rows without mounting them")
        }
        var changes = 0
        let subscription = column.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        for y in 1...20 {
            column.update(ids: ids, viewport: CGRect(x: 0, y: y, width: 320, height: 700)) { [] }
        }
        guard changes == 0 else { throw MomentScrollingFailure(description: "scrolling within a row rebuilds the column") }
        column.recordHeight(400, for: ids[0])
        guard column.layout.totalHeight == 216_184 else { throw MomentScrollingFailure(description: "measured height was not retained") }
        column.update(ids: ids, viewport: CGRect(x: 0, y: 100_000, width: 320, height: 700)) { [] }
        guard column.layout.range.lowerBound > 400, column.layout.range.count <= 5 else {
            throw MomentScrollingFailure(description: "a long scroll mounted historical rows")
        }
        column.update(ids: Array(ids.prefix(2)), viewport: CGRect(x: 0, y: 0, width: 240, height: 700)) { [100, 100] }
        guard column.layout.range == 0..<2, column.layout.totalHeight == 216 else {
            throw MomentScrollingFailure(description: "filtering/resizing retained stale card heights or indices")
        }
        column.recordHeight(300, for: ids[0])
        for step in 1...4 {
            column.update(ids: Array(ids.prefix(2)), viewport: CGRect(x: 0, y: 0, width: 240 + CGFloat(step) * 0.25, height: 700)) { [100, 100] }
        }
        guard column.layout.totalHeight == 216 else {
            throw MomentScrollingFailure(description: "small cumulative window resizes retained stale measured heights")
        }
    }

    @MainActor
    func testIdleVideoReentryKeepsPosterWithoutPublishingChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leon-video-reentry-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("media/moments")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = Bundle.module.url(forResource: "media-library-sample", withExtension: "mp4", subdirectory: "Fixtures")!
        try FileManager.default.copyItem(at: fixture, to: directory.appendingPathComponent("reentry.mp4"))
        let store = LocalBlogStore(rootURL: root)
        let playback = NativeInlineVideoPlayerModel(mediaID: "/media/moments/reentry.mp4")
        await playback.resolve(using: store)
        guard let poster = playback.poster else { throw MomentScrollingFailure(description: "missing video poster") }
        var invalidations = 0
        let subscription = playback.objectWillChange.sink { invalidations += 1 }
        defer { subscription.cancel() }
        for _ in 0..<20 {
            playback.release()
            await playback.resolve(using: store)
        }
        print("MOMENT_VIDEO_REENTRY invalidations=\(invalidations)")
        guard invalidations == 0, playback.poster === poster, playback.player == nil, playback.phase == .poster else {
            throw MomentScrollingFailure(description: "idle video scrolling reloads its poster and invalidates layout \(invalidations) times")
        }
        playback.release(discardPoster: true)
        guard playback.poster == nil, playback.player == nil else {
            throw MomentScrollingFailure(description: "offscreen video retains its local poster or player")
        }
        await playback.resolve(using: store)
        guard playback.poster === poster, playback.phase == .poster else {
            throw MomentScrollingFailure(description: "offscreen video did not reuse its bounded poster cache on return")
        }
        let otherStore = LocalBlogStore(rootURL: root.appendingPathComponent("other-workspace"))
        await playback.resolve(using: otherStore)
        guard case .failed = playback.phase, playback.poster == nil else {
            throw MomentScrollingFailure(description: "poster reuse leaked a video across workspaces")
        }
    }

    @MainActor
    func testMediaVisibilityOnlyChangesAtViewportBoundary() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 3000))
        scroll.documentView = document
        let probe = NativeMediaVisibilityView(frame: NSRect(x: 10, y: 60, width: 200, height: 100))
        var transitions: [Bool] = []
        probe.onChange = { transitions.append($0) }
        document.addSubview(probe)
        window.contentView = scroll
        func move(to y: CGFloat) async throws {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try await move(to: 0)
        for y in 1...20 { try await move(to: CGFloat(y)) }
        guard transitions == [true] else {
            throw MomentScrollingFailure(description: "scroll offsets inside the viewport repeatedly invalidate media: \(transitions)")
        }
        try await move(to: 1000)
        try await move(to: 1100)
        try await move(to: 0)
        guard transitions == [true, false, true] else {
            throw MomentScrollingFailure(description: "media visibility did not track leaving/entering the viewport: \(transitions)")
        }
        probe.stopObserving()
        probe.onChange = nil
    }

    /// Mount the actual feed offscreen and replay wheel-sized viewport changes.
    /// The temporary workspace uses the bundled MP4, never the user's library.
    @MainActor
    func testVideoFeedScrollFramesStayBounded() async throws {
        try await testFeedScrollFramesStayBounded(mediaKind: "video")
    }

    @MainActor
    func testImageFeedScrollFramesStayBounded() async throws {
        try await testFeedScrollFramesStayBounded(mediaKind: "image")
    }

    @MainActor
    func testMixedFeedScrollFramesStayBounded() async throws {
        try await testFeedScrollFramesStayBounded(mediaKind: "mixed")
    }

    @MainActor
    private func testFeedScrollFramesStayBounded(mediaKind: String) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leon-moment-scroll-\(UUID().uuidString)")
        let mediaDirectory = root.appendingPathComponent("media/moments")
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture: URL
        if mediaKind == "video" {
            fixture = ProcessInfo.processInfo.environment["LEON_MOMENT_SCROLL_FIXTURE"].map(URL.init(fileURLWithPath:))
                ?? Bundle.module.url(forResource: "media-library-sample", withExtension: "mp4", subdirectory: "Fixtures")!
        } else {
            fixture = root.appendingPathComponent("large-photo.jpg")
            guard let context = CGContext(data: nil, width: 4000, height: 3000, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let destination = CGImageDestinationCreateWithURL(fixture as CFURL, "public.jpeg" as CFString, 1, nil) else {
                throw MomentScrollingFailure(description: "cannot create large photo fixture")
            }
            context.setFillColor(NSColor.systemBlue.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
            context.setFillColor(NSColor.systemOrange.cgColor)
            context.fill(CGRect(x: 500, y: 500, width: 1500, height: 2000))
            context.setFillColor(NSColor.systemGreen.cgColor)
            context.fill(CGRect(x: 2000, y: 500, width: 1500, height: 2000))
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw MomentScrollingFailure(description: "cannot write large photo fixture")
            }
        }
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false, store: LocalBlogStore(rootURL: root))
        model.isLoading = false
        model.storageReady = true
        let momentCount = mediaKind == "mixed" ? 160 : 40
        let videoFixture = ProcessInfo.processInfo.environment["LEON_MOMENT_SCROLL_FIXTURE"].map(URL.init(fileURLWithPath:))
            ?? Bundle.module.url(forResource: "media-library-sample", withExtension: "mp4", subdirectory: "Fixtures")!
        model.moments = try (0..<momentCount).map { index in
            let attachmentCount = mediaKind == "mixed" ? 9 : mediaKind == "video" ? 3 : [1, 2, 9][index % 3]
            let attachments = try (0..<attachmentCount).map { item in
                let kind = mediaKind == "mixed" ? (item < 6 ? "image" : "video") : mediaKind
                let itemFixture = kind == "video" ? videoFixture : fixture
                let name = "scroll-\(index)-\(item).\(itemFixture.pathExtension)"
                try FileManager.default.copyItem(at: itemFixture, to: mediaDirectory.appendingPathComponent(name))
                return NativeMedia(kind: kind, name: name, size: 1000, url: "/media/moments/\(name)")
            }
            return NativeMoment(createdAt: "2026-10-30T12:00:00Z", id: "scroll-\(index)",
                                images: attachments,
                                text: "\(mediaKind.capitalized) \(index)", textRuns: [], updatedAt: "2026-10-30T12:00:00Z")
        }
        model.totalMomentCount = model.moments.count
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let suite = "MomentScrolling.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(ProcessInfo.processInfo.environment["LEON_MOMENT_SCROLL_LAYOUT"] ?? "fourColumnWaterfall", forKey: "momentFeedLayout")
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = NSHostingView(rootView: MomentFeedView(model: model, pageState: NativeMomentFeedPageState()).defaultAppStorage(defaults))
        host.sizingOptions = []
        window.contentView = host
        defer { window.close() }
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.hasVerticalScroller { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        guard let scroll = scrollView(in: host), let document = scroll.documentView else {
            throw MomentScrollingFailure(description: "missing feed scroll view")
        }
        guard document.bounds.height > CGFloat(momentCount) * 50 else {
            throw MomentScrollingFailure(description: "feed did not lay out all historical rows")
        }
        if ProcessInfo.processInfo.environment["LEON_MOMENT_SCROLL_WARM_START"] == "1" {
            for _ in 0..<20 {
                try await Task.sleep(nanoseconds: 50_000_000)
                host.layoutSubtreeIfNeeded()
            }
        }
        var frames: [Double] = []
        var scrollTimes: [Double] = []
        var layoutTimes: [Double] = []
        let steps = mediaKind == "mixed" ? 64 : 32
        for pass in 0..<2 {
            for step in 0..<steps {
                let started = ProcessInfo.processInfo.systemUptime
                let y = CGFloat(pass == 0 ? step : steps - 1 - step) * (mediaKind == "mixed" ? 600 : 210)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: min(y, max(0, document.bounds.height - 700))))
                scroll.reflectScrolledClipView(scroll.contentView)
                let scrolled = ProcessInfo.processInfo.systemUptime
                host.layoutSubtreeIfNeeded()
                let laidOut = ProcessInfo.processInfo.systemUptime
                scrollTimes.append((scrolled - started) * 1000)
                layoutTimes.append((laidOut - scrolled) * 1000)
                frames.append((laidOut - started) * 1000)
                // One render per simulated display frame. Deferred work gets
                // the same idle interval as a real 60 Hz scroll gesture.
                try await Task.sleep(nanoseconds: 16_666_667)
            }
        }
        let sorted = frames.sorted()
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        print("MOMENT_SCROLL media=\(mediaKind) frames=\(frames.count) p95MS=\(p95) maxMS=\(sorted.last!) documentHeight=\(document.bounds.height)")
        print("MOMENT_SCROLL_PARTS scrollP95=\(scrollTimes.sorted()[Int(Double(frames.count - 1) * 0.95)]) layoutP95=\(layoutTimes.sorted()[Int(Double(frames.count - 1) * 0.95)]) imageCacheBytes=\(await NativeImagePipeline.shared.cachedByteCount) videoCacheBytes=\(await NativeVideoThumbnailPipeline.shared.cachedByteCount)")
        if let path = ProcessInfo.processInfo.environment["LEON_MOMENT_SCROLL_PREVIEW"] {
            // Offscreen windows have no display link. Pump the final viewport
            // after timing so asynchronous posters can appear in the preview.
            for _ in 0..<20 {
                try await Task.sleep(nanoseconds: 50_000_000)
                host.layoutSubtreeIfNeeded()
            }
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
        guard p95 < 35 else {
            throw MomentScrollingFailure(description: "\(mediaKind) scrolling blocks the main thread: p95 \(p95) ms exceeds 35 ms")
        }
    }
}
