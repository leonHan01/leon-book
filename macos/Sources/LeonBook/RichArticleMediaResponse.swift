import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct RichArticleMediaRange: Equatable {
    let statusCode: Int
    let offset: UInt64
    let length: UInt64
    let totalLength: UInt64

    static func resolve(_ header: String?, totalLength: UInt64) -> Self {
        let full = Self(statusCode: 200, offset: 0, length: totalLength, totalLength: totalLength)
        let unsatisfied = Self(statusCode: 416, offset: 0, length: 0, totalLength: totalLength)
        guard let header = header?.trimmingCharacters(in: .whitespacesAndNewlines),
              header.lowercased().hasPrefix("bytes="), !header.contains(",") else { return full }
        let parts = header.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return full }
        func number(_ value: Substring) -> UInt64? {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return UInt64(value)
        }
        if parts[0].isEmpty {
            guard let suffix = number(parts[1]) else { return full }
            guard suffix > 0, totalLength > 0 else { return unsatisfied }
            let length = min(suffix, totalLength)
            return Self(statusCode: 206, offset: totalLength - length, length: length, totalLength: totalLength)
        }
        guard let start = number(parts[0]) else { return full }
        let requestedEnd: UInt64
        if parts[1].isEmpty { requestedEnd = totalLength > 0 ? totalLength - 1 : 0 }
        else if let end = number(parts[1]) { requestedEnd = end }
        else { return full }
        guard start < totalLength, requestedEnd >= start else { return unsatisfied }
        let end = min(requestedEnd, totalLength - 1)
        return Self(statusCode: 206, offset: start, length: end - start + 1, totalLength: totalLength)
    }

    func response(url: URL, mimeType: String) -> HTTPURLResponse {
        var headers = ["Content-Type": mimeType, "Content-Length": String(length), "Accept-Ranges": "bytes"]
        if statusCode == 206 { headers["Content-Range"] = "bytes \(offset)-\(offset + length - 1)/\(totalLength)" }
        else if statusCode == 416 { headers["Content-Range"] = "bytes */\(totalLength)" }
        return HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}

/// Each request holds one chunk while its consumer delivers it to WebKit. There
/// is no unbounded AsyncStream buffer or detached producer reading ahead.
private actor RichArticleMediaFile {
    let url: URL
    private var handle: FileHandle?
    private var remaining: UInt64 = 0

    init(url: URL) { self.url = url }

    func prepare(rangeHeader: String?) throws -> RichArticleMediaRange {
        try Task.checkCancellation()
        let opened = try FileHandle(forReadingFrom: url)
        handle = opened
        let length = try opened.seekToEnd()
        let range = RichArticleMediaRange.resolve(rangeHeader, totalLength: length)
        remaining = range.length
        if remaining > 0 { try opened.seek(toOffset: range.offset) }
        return range
    }

    func nextChunk() throws -> Data? {
        try Task.checkCancellation()
        guard remaining > 0, let handle else { return nil }
        guard let data = try handle.read(upToCount: Int(min(remaining, UInt64(RichArticleMediaResponse.chunkSize)))),
              !data.isEmpty else { throw URLError(.cannotDecodeRawData) }
        remaining -= UInt64(data.count)
        try Task.checkCancellation()
        return data
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    deinit { try? handle?.close() }
}

enum RichArticleMediaResponse {
    static let chunkSize = 256 * 1024

    @MainActor
    static func send(
        fileURL: URL, request: URLRequest,
        onResponse: (URLResponse) -> Void,
        onData: (Data) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard let responseURL = request.url else { throw URLError(.badURL) }
        let rangeHeader = request.value(forHTTPHeaderField: "Range")
        let requestedPixels = URLComponents(url: responseURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "maxPixelSize" })?.value.flatMap(Int.init)
        if let requestedPixels, requestedPixels > 0,
           let png = try await RichArticleMediaThumbnail.shared.png(from: fileURL, maxPixelSize: requestedPixels) {
            let range = RichArticleMediaRange.resolve(rangeHeader, totalLength: UInt64(png.count))
            try Task.checkCancellation()
            onResponse(range.response(url: responseURL, mimeType: "image/png"))
            if request.httpMethod != "HEAD" {
                var offset = Int(range.offset), remaining = Int(range.length)
                while remaining > 0 {
                    try Task.checkCancellation()
                    let count = min(chunkSize, remaining)
                    onData(png.subdata(in: offset..<(offset + count)))
                    offset += count; remaining -= count
                    await Task.yield()
                }
            }
            try Task.checkCancellation()
            return
        }

        let file = RichArticleMediaFile(url: fileURL)
        do {
            let range = try await file.prepare(rangeHeader: rangeHeader)
            try Task.checkCancellation()
            let mime = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            onResponse(range.response(url: responseURL, mimeType: mime))
            if request.httpMethod != "HEAD" {
                while let chunk = try await file.nextChunk() {
                    try Task.checkCancellation()
                    onData(chunk)
                }
            }
            try Task.checkCancellation()
            await file.close()
        } catch {
            await file.close()
            throw error
        }
    }
}

/// Reuses the native thumbnail pipeline and retains a bounded encoded cache so
/// reopening a rich article does not PNG-encode the same decoded preview again.
actor RichArticleMediaThumbnail {
    static let shared = RichArticleMediaThumbnail()
    private let byteLimit = 16 * 1024 * 1024
    private var cache: [String: Data] = [:]
    private var access: [String] = []
    private var retainedBytes = 0

    func png(from url: URL, maxPixelSize requestedSize: Int) async throws -> Data? {
        try Task.checkCancellation()
        let size = min(max(1, requestedSize), 2400)
        // GIF, SVG, PDF and unfamiliar formats retain their original behavior.
        // ImageIO's frame count also protects animated PNG/WebP and multipage TIFF.
        guard ["png", "jpg", "jpeg", "webp", "heic", "heif", "bmp", "tif", "tiff"]
            .contains(url.pathExtension.lowercased()) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.standardizedFileURL.path)|\(fileSize)|\(modified)|\(size)"
        if let data = cached(key) { return data }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              max(width, height) > size else { return nil }
        let result = await NativeImagePipeline.shared.image(from: url, mode: .thumbnail(maxPixelSize: size))
        try Task.checkCancellation()
        if let data = cached(key) { return data }
        guard let image = result.image,
              let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:]) else { return nil }
        try Task.checkCancellation()
        if data.count <= byteLimit {
            while retainedBytes + data.count > byteLimit, let oldest = access.first {
                access.removeFirst()
                retainedBytes -= cache.removeValue(forKey: oldest)?.count ?? 0
            }
            cache[key] = data; access.append(key); retainedBytes += data.count
        }
        return data
    }

    private func cached(_ key: String) -> Data? {
        guard let data = cache[key] else { return nil }
        access.removeAll { $0 == key }; access.append(key)
        return data
    }
}
