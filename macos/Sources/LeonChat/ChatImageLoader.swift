import AppKit
import ImageIO

@MainActor
final class ChatImageLoader {
    typealias Source = @Sendable () async throws -> Data

    private struct Thumbnail: @unchecked Sendable {
        let image: NSImage
    }

    private let cache = NSCache<NSString, NSImage>()
    private var downloads: [String: Task<Data, Error>] = [:]
    private var thumbnails: [String: Task<Thumbnail, Error>] = [:]
    private var cancelled = false

    init() {
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 128
    }

    func data(_ id: String, source: @escaping Source) async throws -> Data {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        let existing = downloads[id]
        let download = existing ?? Task.detached(priority: .utility, operation: source)
        if existing == nil { downloads[id] = download }
        defer { if existing == nil { downloads[id] = nil } }
        let bytes = try await download.value
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        return bytes
    }

    func thumbnail(_ id: String, pixels: Int, source: @escaping Source) async throws -> NSImage {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        let key = "\(id):\(pixels)"
        if let image = cache.object(forKey: key as NSString) { return image }
        let task: Task<Thumbnail, Error>
        if let existing = thumbnails[key] {
            task = existing
        } else {
            task = Task {
                defer { thumbnails[key] = nil }
                let bytes = try await data(id, source: source)
                let bitmap = try await ChatImageDecoder.shared.decode(bytes, pixels: pixels)
                try Task.checkCancellation()
                let image = Self.image(from: bitmap)
                cache.setObject(image, forKey: key as NSString, cost: bitmap.bytesPerRow * bitmap.height)
                return Thumbnail(image: image)
            }
            thumbnails[key] = task
        }
        let thumbnail = try await task.value
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        return thumbnail.image
    }

    func fullSize(_ id: String, source: @escaping Source) async throws -> NSImage {
        let bytes = try await data(id, source: source)
        let bitmap = try await ChatImageDecoder.shared.decode(bytes, pixels: nil)
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        return Self.image(from: bitmap)
    }

    func cancel() {
        cancelled = true
        for task in downloads.values { task.cancel() }
        for task in thumbnails.values { task.cancel() }
        cache.removeAllObjects()
    }

    private static func image(from bitmap: CGImage) -> NSImage {
        NSImage(cgImage: bitmap, size: NSSize(width: bitmap.width, height: bitmap.height))
    }
}

// ImageIO performs bitmap decoding on this actor's executor, one request at a time.
private actor ChatImageDecoder {
    static let shared = ChatImageDecoder()

    func decode(_ bytes: Data, pixels: Int?) throws -> CGImage {
        try Task.checkCancellation()
        guard let image = autoreleasepool(invoking: { () -> CGImage? in
            guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(pixels ?? max(width, height), max(width, height)),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }) else { throw ClientError.message("图片加载失败，点击重试") }
        return image
    }
}
