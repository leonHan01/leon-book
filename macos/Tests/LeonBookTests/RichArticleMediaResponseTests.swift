import AppKit
import ImageIO
@testable import LeonBook

private struct ArticleMediaResponseFailure: Error, CustomStringConvertible {
    let description: String
}

private func mediaResponseExpect(_ condition: Bool, _ message: String) throws {
    if !condition { throw ArticleMediaResponseFailure(description: message) }
}

final class RichArticleMediaResponseTests {
    @MainActor
    func testMediaRangeResponsesAndHeadRequests() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("article-range-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        let bytes = Data((0..<700_000).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: file)
        let cases: [(String?, Int, Range<Int>, String?)] = [
            (nil, 200, 0..<bytes.count, nil),
            ("bytes=0-1", 206, 0..<2, "bytes 0-1/700000"),
            ("bytes=262130-524300", 206, 262130..<524301, "bytes 262130-524300/700000"),
            ("bytes=699990-", 206, 699990..<700000, "bytes 699990-699999/700000"),
            ("bytes=-17", 206, 699983..<700000, "bytes 699983-699999/700000"),
            ("bytes=699990-999999", 206, 699990..<700000, "bytes 699990-699999/700000"),
            ("bytes=700000-", 416, 0..<0, "bytes */700000"),
            ("bytes=20-10", 416, 0..<0, "bytes */700000"),
            ("bytes=-0", 416, 0..<0, "bytes */700000"),
            ("bytes=invalid", 200, 0..<bytes.count, nil),
            ("bytes=0-1,10-11", 200, 0..<bytes.count, nil),
        ]
        for (header, status, range, contentRange) in cases {
            var request = URLRequest(url: URL(string: "leonmedia://asset?path=test.mp4")!)
            request.setValue(header, forHTTPHeaderField: "Range")
            var response: HTTPURLResponse?, result = Data()
            try await RichArticleMediaResponse.send(fileURL: file, request: request,
                onResponse: { response = $0 as? HTTPURLResponse }, onData: { result.append($0) })
            try mediaResponseExpect(response?.statusCode == status && result == bytes.subdata(in: range),
                "incorrect response for \(header ?? "full request")")
            try mediaResponseExpect(response?.value(forHTTPHeaderField: "Content-Range") == contentRange
                && response?.value(forHTTPHeaderField: "Content-Length") == String(range.count)
                && response?.value(forHTTPHeaderField: "Accept-Ranges") == "bytes", "incorrect byte-range headers")
        }
        var head = URLRequest(url: URL(string: "leonmedia://asset?path=test.mp4")!)
        head.httpMethod = "HEAD"
        head.setValue("bytes=10-20", forHTTPHeaderField: "Range")
        var headResponse: HTTPURLResponse?, headBytes = 0
        try await RichArticleMediaResponse.send(fileURL: file, request: head,
            onResponse: { headResponse = $0 as? HTTPURLResponse }, onData: { headBytes += $0.count })
        try mediaResponseExpect(headBytes == 0 && headResponse?.statusCode == 206
            && headResponse?.value(forHTTPHeaderField: "Content-Length") == "11", "HEAD must return headers without reading the body")
        try Data().write(to: file)
        var emptyResponse: HTTPURLResponse?
        try await RichArticleMediaResponse.send(fileURL: file, request: head,
            onResponse: { emptyResponse = $0 as? HTTPURLResponse }, onData: { _ in headBytes += 1 })
        try mediaResponseExpect(emptyResponse?.statusCode == 416 && headBytes == 0, "range on an empty file must be unsatisfied")
    }

    @MainActor
    func testMediaStreamsBeforeReadingTailAndBoundsChunks() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("article-stream-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        let tailOffset = RichArticleMediaResponse.chunkSize * 3
        var expected = Data(repeating: 17, count: tailOffset + 19)
        try expected.write(to: file)
        let patch = Data(repeating: 202, count: 19)
        var received = Data(), responseReceived = false, responsePrecededChunks = true
        var chunkLengths: [Int] = [], mutationError: Error?
        try await RichArticleMediaResponse.send(fileURL: file,
            request: URLRequest(url: URL(string: "leonmedia://asset?path=stream.mp4")!),
            onResponse: { _ in responseReceived = true },
            onData: { chunk in
                responsePrecededChunks = responsePrecededChunks && responseReceived
                chunkLengths.append(chunk.count)
                received.append(chunk)
                if chunkLengths.count == 1 {
                    // A whole-file implementation has already captured the old tail.
                    do {
                        let writer = try FileHandle(forWritingTo: file)
                        defer { try? writer.close() }
                        try writer.seek(toOffset: UInt64(tailOffset))
                        try writer.write(contentsOf: patch)
                    } catch { mutationError = error }
                }
            })
        if let mutationError { throw mutationError }
        expected.replaceSubrange(tailOffset..<expected.count, with: patch)
        try mediaResponseExpect(responsePrecededChunks && received == expected, "the first chunk must arrive before the tail is read")
        try mediaResponseExpect(chunkLengths.count >= 4 && chunkLengths.allSatisfy { $0 <= RichArticleMediaResponse.chunkSize },
            "media delivery must remain bounded to 256 KiB per chunk")
    }

    @MainActor
    func testMediaCancellationStopsAfterFirstChunk() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("article-cancel-stream-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 7, count: RichArticleMediaResponse.chunkSize * 3).write(to: file)
        let task = Task { @MainActor in
            var chunks = 0
            do {
                try await RichArticleMediaResponse.send(fileURL: file,
                    request: URLRequest(url: URL(string: "leonmedia://asset?path=cancel.mp4")!),
                    onResponse: { _ in }, onData: { _ in
                        chunks += 1
                        withUnsafeCurrentTask { $0?.cancel() }
                    })
                throw ArticleMediaResponseFailure(description: "a cancelled stream completed successfully")
            } catch is CancellationError {
                try mediaResponseExpect(chunks == 1, "cancellation must suppress further chunks")
            }
        }
        try await task.value
    }

    @MainActor
    func testMediaThumbnailsRespectDimensionsAndPreserveSpecialFormats() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("article-media-thumbnail-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 960, pixelsHigh: 640,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        memset(bitmap.bitmapData!, 128, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let source = directory.appendingPathComponent("large.png")
        let original = bitmap.representation(using: .png, properties: [:])!
        try original.write(to: source)
        var result = Data(), response: URLResponse?
        try await RichArticleMediaResponse.send(fileURL: source,
            request: URLRequest(url: URL(string: "leonmedia://asset?path=large.png&maxPixelSize=96")!),
            onResponse: { response = $0 }, onData: { result.append($0) })
        let decoded = NSBitmapImageRep(data: result)
        try mediaResponseExpect(response?.mimeType == "image/png" && decoded?.pixelsWide == 96 && decoded?.pixelsHigh == 64,
            "preview requests must decode to the requested pixel limit")
        let thumbnails = RichArticleMediaThumbnail()
        try mediaResponseExpect(try await thumbnails.png(from: source, maxPixelSize: 1200) == nil,
            "already small images must preserve the original bytes")
        for (name, type) in [("animated.gif", "com.compuserve.gif"), ("multipage.tiff", "public.tiff")] {
            let url = directory.appendingPathComponent(name)
            let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 2, nil)!
            CGImageDestinationAddImage(destination, bitmap.cgImage!, nil)
            CGImageDestinationAddImage(destination, bitmap.cgImage!, nil)
            try mediaResponseExpect(CGImageDestinationFinalize(destination), "cannot create multiframe fixture")
            try mediaResponseExpect(try await thumbnails.png(from: url, maxPixelSize: 96) == nil,
                "animated and multipage files must keep their original representation")
        }
        let svg = directory.appendingPathComponent("vector.svg")
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"960\" height=\"640\"/>".utf8).write(to: svg)
        try mediaResponseExpect(try await thumbnails.png(from: svg, maxPixelSize: 96) == nil,
            "vector images must not be converted to a bitmap preview")
    }
}
