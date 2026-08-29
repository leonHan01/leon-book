import AppKit
import Foundation
import ImageIO

enum NativeImageLoadMode: Equatable, Sendable {
    case thumbnail(maxPixelSize: Int)
    case fullSize

    var cacheKey: String {
        switch self {
        case let .thumbnail(maxPixelSize): return "thumbnail-\(maxPixelSize)"
        case .fullSize: return "full-size"
        }
    }
}

struct NativeImageDecodeResult: @unchecked Sendable {
    let image: NSImage?
}

actor NativeImagePipeline {
    typealias Decoder = @Sendable (URL, NativeImageLoadMode) -> NSImage?

    static let shared = NativeImagePipeline(maximumConcurrentDecodes: 2)

    private let cache = NSCache<NSString, NSImage>()
    private let maximumConcurrentDecodes: Int
    private let decoder: Decoder
    private var activeDecodeCount = 0
    private var decodeWaiters: [CheckedContinuation<Void, Never>] = []
    private var inFlight: [String: Task<NativeImageDecodeResult, Never>] = [:]

    init(
        maximumConcurrentDecodes: Int = 2,
        decoder: @escaping Decoder = { url, mode in
            NativeImageDecoder.load(from: url, mode: mode)
        }
    ) {
        self.maximumConcurrentDecodes = max(1, maximumConcurrentDecodes)
        self.decoder = decoder
        cache.countLimit = 512
        cache.totalCostLimit = 192 * 1_024 * 1_024
    }

    func image(from url: URL, mode: NativeImageLoadMode) async -> NativeImageDecodeResult {
        let key = cacheKey(for: url, mode: mode)
        if mode != .fullSize, let cached = cache.object(forKey: key as NSString) {
            return NativeImageDecodeResult(image: cached)
        }
        if let task = inFlight[key] {
            return await task.value
        }

        await acquireDecodeSlot()
        guard !Task.isCancelled else {
            releaseDecodeSlot()
            return NativeImageDecodeResult(image: nil)
        }

        // Waiting for a slot yields the actor. Another caller may have started
        // this exact decode while this request was suspended.
        if let task = inFlight[key] {
            releaseDecodeSlot()
            return await task.value
        }
        if mode != .fullSize, let cached = cache.object(forKey: key as NSString) {
            releaseDecodeSlot()
            return NativeImageDecodeResult(image: cached)
        }

        let decoder = self.decoder
        let task = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return NativeImageDecodeResult(image: nil) }
            return NativeImageDecodeResult(image: decoder(url, mode))
        }
        inFlight[key] = task
        let decoded = await task.value
        inFlight[key] = nil
        releaseDecodeSlot()

        if mode != .fullSize, let image = decoded.image {
            cache.setObject(image, forKey: key as NSString, cost: imageCost(image))
        }
        return decoded
    }

    private func acquireDecodeSlot() async {
        if activeDecodeCount < maximumConcurrentDecodes {
            activeDecodeCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            decodeWaiters.append(continuation)
        }
    }

    private func releaseDecodeSlot() {
        if let waiter = decodeWaiters.first {
            decodeWaiters.removeFirst()
            waiter.resume()
        } else {
            activeDecodeCount = max(0, activeDecodeCount - 1)
        }
    }

    private func cacheKey(for url: URL, mode: NativeImageLoadMode) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.standardizedFileURL.path)|\(fileSize)|\(modifiedAt)|\(mode.cacheKey)"
    }

    private func imageCost(_ image: NSImage) -> Int {
        let representation = image.representations.first
        let width = representation?.pixelsWide ?? Int(image.size.width)
        let height = representation?.pixelsHigh ?? Int(image.size.height)
        return max(1, width * height * 4)
    }
}

private enum NativeImageDecoder {
    static func load(from url: URL, mode: NativeImageLoadMode) -> NSImage? {
        if mode == .fullSize {
            return NSImage(contentsOf: url)
        }

        guard case let .thumbnail(maxPixelSize) = mode else { return nil }
        let cachedURL = thumbnailCacheURL(for: url, maxPixelSize: maxPixelSize)
        if let cached = decodedImage(from: cachedURL) {
            return cached
        }
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            try? FileManager.default.removeItem(at: cachedURL)
        }
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              !Task.isCancelled else { return nil }
        persistThumbnail(image, at: cachedURL)
        return NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
    }

    private static func decodedImage(from url: URL) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
    }

    private static func thumbnailCacheURL(for sourceURL: URL, maxPixelSize: Int) -> URL {
        let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let signature = "\(sourceURL.standardizedFileURL.path)|\(fileSize)|\(modifiedAt)|\(maxPixelSize)"
        let filename = "\(stableHash(signature))-\(maxPixelSize).png"
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.leon-book.macos", isDirectory: true)
            .appendingPathComponent("image-thumbnails", isDirectory: true)
            .appendingPathComponent(filename)
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func persistThumbnail(_ image: CGImage, at url: URL) {
        guard !Task.isCancelled else { return }
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(".\(UUID().uuidString).tmp.png")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            guard !fileManager.fileExists(atPath: url.path) else { return }
            guard let destination = CGImageDestinationCreateWithURL(
                temporaryURL as CFURL,
                "public.png" as CFString,
                1,
                nil
            ) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                try? fileManager.removeItem(at: temporaryURL)
                return
            }
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            // Persistent thumbnails are optional; the in-memory decode remains usable.
        }
    }
}
