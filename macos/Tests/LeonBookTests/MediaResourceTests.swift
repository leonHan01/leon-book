import AppKit
@testable import LeonBook

private struct MediaResourceFailure: Error, CustomStringConvertible {
    let description: String
}

private final class MediaResourceProbe: @unchecked Sendable {
    private final class WeakImage {
        weak var value: NSImage?
        init(_ value: NSImage) { self.value = value }
    }
    private let lock = NSLock()
    private var images: [WeakImage] = []
    private var started = 0
    private var completed = 0
    private var active = 0
    private var peakActive = 0
    let gate = DispatchSemaphore(value: 0)

    func decode(blocking: Bool = false, delayed: Bool = false) -> NSImage? {
        lock.lock()
        started += 1
        active += 1
        peakActive = max(peakActive, active)
        lock.unlock()
        if blocking { _ = gate.wait(timeout: .now() + 5) }
        if delayed { usleep(20_000) }
        let image = NSImage(size: NSSize(width: 768, height: 768))
        lock.lock()
        images.append(WeakImage(image))
        active -= 1
        lock.unlock()
        return image
    }

    func finish() { lock.lock(); completed += 1; lock.unlock() }
    var counts: (started: Int, completed: Int, retained: Int, peakActive: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (started, completed, images.filter { $0.value != nil }.count, peakActive)
    }
}

final class MediaResourceTests {
    func testCancellingOneSubscriberKeepsSharedDecodeAlive() async throws {
        let probe = MediaResourceProbe()
        let pipeline = NativeImagePipeline(decoder: { _, _ in probe.decode(blocking: true) })
        let url = URL(fileURLWithPath: "/tmp/shared-media.png")
        let first = Task { await pipeline.image(from: url, mode: .thumbnail(maxPixelSize: 768)) }
        defer { probe.gate.signal() }
        for _ in 0..<100 where probe.counts.started == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        let second = Task { await pipeline.image(from: url, mode: .thumbnail(maxPixelSize: 768)) }
        try await Task.sleep(nanoseconds: 30_000_000)
        first.cancel()
        let cancelled = await first.value
        probe.gate.signal()
        let remaining = await second.value
        let cached = await pipeline.image(from: url, mode: .thumbnail(maxPixelSize: 768))
        guard cancelled.image == nil, let image = remaining.image, cached.image === image, probe.counts.started == 1 else {
            throw MediaResourceFailure(description: "cancelling one view must not cancel or duplicate another view's shared decode")
        }
    }

    func testImagesAndVideosShareTwoDecodeSlots() async throws {
        let probe = MediaResourceProbe()
        let scheduler = NativeMediaDecodeScheduler(maximumConcurrentDecodes: 2)
        let images = NativeImagePipeline(scheduler: scheduler, decoder: { _, _ in probe.decode(delayed: true) })
        let videos = NativeVideoThumbnailPipeline(scheduler: scheduler, decoder: { _, _ in probe.decode(delayed: true) })
        let loaded = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<24 {
                group.addTask {
                    let url = URL(fileURLWithPath: "/tmp/mixed-\(index)")
                    if index.isMultiple(of: 2) { return await images.image(from: url, mode: .thumbnail(maxPixelSize: 768)).image != nil }
                    return await videos.thumbnail(for: url, maxPixelSize: 768).image != nil
                }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }
        guard loaded == 24, probe.counts.started == 24, probe.counts.peakActive == 2 else {
            throw MediaResourceFailure(description: "mixed image/video decodes exceeded the shared budget: \(probe.counts)")
        }
    }

    func testVideoPosterCacheRetainsAtMost32MiB() async throws {
        let probe = MediaResourceProbe()
        let pipeline = NativeVideoThumbnailPipeline(decoder: { _, _ in probe.decode() })
        for index in 0..<40 {
            _ = await pipeline.thumbnail(for: URL(fileURLWithPath: "/tmp/video-cache-\(index).mp4"), maxPixelSize: 768)
        }
        let retainedBytes = probe.counts.retained * 768 * 768 * 4
        guard retainedBytes <= 32 * 1024 * 1024 else {
            throw MediaResourceFailure(description: "video poster cache exceeded its memory budget: \(retainedBytes)")
        }
    }

    func testCacheEvictsLeastRecentlyUsedAndReleasesOnPressure() throws {
        let cache = NativeMediaImageCache(byteLimit: 8, countLimit: 2)
        let a = NSImage(size: NSSize(width: 1, height: 1))
        let b = NSImage(size: NSSize(width: 1, height: 1))
        let c = NSImage(size: NSSize(width: 1, height: 1))
        cache.insert(a, for: "a")
        cache.insert(b, for: "b")
        _ = cache.image(for: "a")
        cache.insert(c, for: "c")
        guard cache.image(for: "b") == nil, cache.image(for: "a") === a, cache.retainedBytes == 8 else {
            throw MediaResourceFailure(description: "cache did not evict its least recently used image")
        }
        cache.insert(NSImage(size: NSSize(width: 10, height: 10)), for: "oversized")
        guard cache.retainedBytes == 8, cache.image(for: "oversized") == nil else {
            throw MediaResourceFailure(description: "an oversized entry must not exceed or flush the cache budget")
        }
        cache.removeAll() // The memory-pressure handler uses the same purge path.
        guard cache.retainedBytes == 0, cache.image(for: "a") == nil, cache.image(for: "c") == nil else {
            throw MediaResourceFailure(description: "memory pressure did not release cached images")
        }
    }

    func testCancelledThumbnailRequestsReleaseWhileDecoderIsBusy() async throws {
        let probe = MediaResourceProbe()
        let pipeline = NativeImagePipeline(maximumConcurrentDecodes: 1, decoder: { _, _ in probe.decode(blocking: true) })
        let first = Task { await pipeline.image(from: URL(fileURLWithPath: "/tmp/media-running.png"), mode: .thumbnail(maxPixelSize: 768)) }
        defer { probe.gate.signal() }
        for _ in 0..<100 where probe.counts.started == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        guard probe.counts.started == 1 else { throw MediaResourceFailure(description: "decoder did not start") }
        let waiting = (0..<60).map { index in
            Task {
                _ = await pipeline.image(from: URL(fileURLWithPath: "/tmp/media-queued-\(index).png"), mode: .thumbnail(maxPixelSize: 768))
                probe.finish()
            }
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        waiting.forEach { $0.cancel() }
        try await Task.sleep(nanoseconds: 50_000_000)
        let counts = probe.counts
        print("MEDIA_CANCEL completed=\(counts.completed)/60 decodes=\(counts.started)")
        guard counts.completed == 60, counts.started == 1 else {
            throw MediaResourceFailure(description: "cancelled offscreen requests remain retained behind a busy decoder: \(counts)")
        }
        probe.gate.signal()
        _ = await first.value
        for task in waiting { await task.value }
    }

    func testThumbnailCacheRetainsAtMost64MiB() async throws {
        let probe = MediaResourceProbe()
        let pipeline = NativeImagePipeline(decoder: { _, _ in probe.decode() })
        for index in 0..<80 {
            _ = await pipeline.image(from: URL(fileURLWithPath: "/tmp/media-cache-\(index).png"), mode: .thumbnail(maxPixelSize: 768))
        }
        let retainedBytes = probe.counts.retained * 768 * 768 * 4
        print("MEDIA_CACHE retainedBytes=\(retainedBytes) retainedImages=\(probe.counts.retained)")
        guard retainedBytes <= 64 * 1024 * 1024 else {
            throw MediaResourceFailure(description: "thumbnail cache retains \(retainedBytes) bytes after scrolling through 80 images")
        }
    }
}
