import AppKit
import Foundation
import ImageIO
import SwiftUI

private struct NativeImagePipelineKey: EnvironmentKey {
    static let defaultValue = NativeImagePipeline.shared
}

extension EnvironmentValues {
    var nativeImagePipeline: NativeImagePipeline {
        get { self[NativeImagePipelineKey.self] }
        set { self[NativeImagePipelineKey.self] = newValue }
    }
}

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

    static let shared = NativeImagePipeline(scheduler: .shared)

    private let cache = NativeMediaImageCache(byteLimit: 64 * 1_024 * 1_024, countLimit: 256)
    private let scheduler: NativeMediaDecodeScheduler
    private let decoder: Decoder

    init(
        maximumConcurrentDecodes: Int = 2,
        scheduler: NativeMediaDecodeScheduler? = nil,
        decoder: @escaping Decoder = { url, mode in
            NativeImageDecoder.load(from: url, mode: mode)
        }
    ) {
        self.scheduler = scheduler ?? NativeMediaDecodeScheduler(maximumConcurrentDecodes: maximumConcurrentDecodes)
        self.decoder = decoder
    }

    func image(from url: URL, mode: NativeImageLoadMode) async -> NativeImageDecodeResult {
        guard !Task.isCancelled else { return NativeImageDecodeResult(image: nil) }
        let key = cacheKey(for: url, mode: mode)
        if mode != .fullSize, let cached = cache.image(for: key) {
            return NativeImageDecodeResult(image: cached)
        }
        let decoder = self.decoder
        let cache = self.cache
        return await scheduler.decode(key: "image|\(key)", priority: mode == .fullSize ? .userInitiated : .utility) {
            if mode != .fullSize, let cached = cache.image(for: key) { return cached }
            guard let image = decoder(url, mode), !Task.isCancelled else { return nil }
            if mode != .fullSize { cache.insert(image, for: key) }
            return image
        }
    }

    var cachedByteCount: Int { cache.retainedBytes }

    private func cacheKey(for url: URL, mode: NativeImageLoadMode) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.standardizedFileURL.path)|\(fileSize)|\(modifiedAt)|\(mode.cacheKey)"
    }

}

private enum NativeImageDecoder {
    static func load(from url: URL, mode: NativeImageLoadMode) -> NSImage? {
        if mode == .fullSize {
            return fullSizeImage(from: url)
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
              let source = CGImageSourceCreateWithURL(
                url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary
              ) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              !Task.isCancelled else { return nil }
        persistThumbnail(image, at: cachedURL)
        return NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
    }

    private static func fullSizeImage(from url: URL) -> NSImage? {
        guard !Task.isCancelled else { return nil }
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary
        ), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            // Preserve AppKit support for formats ImageIO cannot rasterize.
            return NSImage(contentsOf: url)
        }
        // Decode on the pipeline's worker before publishing to SwiftUI. A lazy
        // NSImage(contentsOf:) can otherwise decompress the original at draw time.
        // The source dimensions keep every pixel; ImageIO applies EXIF orientation.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              !Task.isCancelled else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
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
