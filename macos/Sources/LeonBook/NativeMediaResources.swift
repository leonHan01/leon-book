import AppKit
import Foundation

/// A hard byte budget, unlike NSCache's advisory cost limit. The cache is also
/// used by decoder workers so a completed decode is cached before waiters wake.
final class NativeMediaImageCache: @unchecked Sendable {
    private struct Entry {
        let image: NSImage
        let cost: Int
        var access: UInt64
    }

    private let lock = NSLock()
    private let byteLimit: Int
    private let countLimit: Int
    private var entries: [String: Entry] = [:]
    private var byteCost = 0
    private var clock: UInt64 = 0
    private let pressure: DispatchSourceMemoryPressure

    init(byteLimit: Int, countLimit: Int) {
        self.byteLimit = max(0, byteLimit)
        self.countLimit = max(0, countLimit)
        pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        pressure.setEventHandler { [weak self] in self?.removeAll() }
        pressure.resume()
    }

    func image(for key: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        clock &+= 1
        entry.access = clock
        entries[key] = entry
        return entry.image
    }

    func insert(_ image: NSImage, for key: String) {
        let representation = image.representations.first
        let cost: Int
        if let bitmap = representation as? NSBitmapImageRep {
            cost = max(1, bitmap.bytesPerRow * bitmap.pixelsHigh)
        } else {
            cost = max(1, (representation?.pixelsWide ?? Int(image.size.width))
                * (representation?.pixelsHigh ?? Int(image.size.height)) * 4)
        }
        lock.lock()
        defer { lock.unlock() }
        if let old = entries.removeValue(forKey: key) { byteCost -= old.cost }
        guard cost <= byteLimit, countLimit > 0 else { return }
        while byteCost + cost > byteLimit || entries.count >= countLimit {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key,
                  let removed = entries.removeValue(forKey: oldest) else { break }
            byteCost -= removed.cost
        }
        clock &+= 1
        entries[key] = Entry(image: image, cost: cost, access: clock)
        byteCost += cost
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        byteCost = 0
    }

    var retainedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return byteCost
    }

    deinit { pressure.cancel() }
}

/// Image and video workers share a CPU/decoder budget. Each subscriber owns a
/// continuation, so an offscreen view can leave immediately even when another
/// subscriber still needs the same decode. Running synchronous work keeps its
/// slot until it really exits; cancellation cannot oversubscribe the decoders.
actor NativeMediaDecodeScheduler {
    static let shared = NativeMediaDecodeScheduler(maximumConcurrentDecodes: 2)

    private struct Job {
        let id = UUID()
        let priority: TaskPriority
        let operation: @Sendable () -> NSImage?
        var subscribers: [UUID: CheckedContinuation<NativeImageDecodeResult, Never>]
        var task: Task<Void, Never>?
    }

    private let maximumConcurrentDecodes: Int
    private var active = 0
    private var jobs: [String: Job] = [:]
    private var pending: [String] = []

    init(maximumConcurrentDecodes: Int = 2) {
        self.maximumConcurrentDecodes = max(1, maximumConcurrentDecodes)
    }

    func decode(key: String, priority: TaskPriority = .utility,
                operation: @escaping @Sendable () -> NSImage?) async -> NativeImageDecodeResult {
        let subscriber = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: NativeImageDecodeResult(image: nil))
                    return
                }
                if jobs[key] != nil {
                    jobs[key]?.subscribers[subscriber] = continuation
                } else {
                    jobs[key] = Job(priority: priority, operation: operation, subscribers: [subscriber: continuation])
                    // An explicitly opened original goes ahead of queued previews.
                    if priority == .userInitiated { pending.insert(key, at: 0) }
                    else { pending.append(key) }
                }
                startPending()
            }
        } onCancel: {
            Task { await self.cancel(key: key, subscriber: subscriber) }
        }
    }

    private func cancel(key: String, subscriber: UUID) {
        guard let continuation = jobs[key]?.subscribers.removeValue(forKey: subscriber) else { return }
        continuation.resume(returning: NativeImageDecodeResult(image: nil))
        if jobs[key]?.subscribers.isEmpty == true {
            let job = jobs.removeValue(forKey: key)
            pending.removeAll { $0 == key }
            job?.task?.cancel()
        }
    }

    private func startPending() {
        while active < maximumConcurrentDecodes, !pending.isEmpty {
            let key = pending.removeFirst()
            guard let job = jobs[key] else { continue }
            active += 1
            jobs[key]?.task = Task.detached(priority: job.priority) { [operation = job.operation, id = job.id] in
                let result = autoreleasepool {
                    NativeImageDecodeResult(image: Task.isCancelled ? nil : operation())
                }
                await self.finish(key: key, id: id, result: result)
            }
        }
    }

    private func finish(key: String, id: UUID, result: NativeImageDecodeResult) {
        if let job = jobs[key], job.id == id {
            jobs[key] = nil
            for subscriber in job.subscribers.values { subscriber.resume(returning: result) }
        }
        active -= 1
        startPending()
    }
}
