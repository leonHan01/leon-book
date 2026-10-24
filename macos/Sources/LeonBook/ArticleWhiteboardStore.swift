import CryptoKit
import Foundation
import ImageIO

struct ArticleWhiteboardAsset: Equatable {
    let source: String
    let preview: String
}

enum ArticleWhiteboardData {
    static let maximumSceneBytes = 16 * 1024 * 1024
    static let maximumPreviewBytes = 8 * 1024 * 1024
    static let directory = "whiteboards"

    static func sceneData(_ scene: String) throws -> Data {
        let data = Data(scene.utf8)
        guard data.count <= maximumSceneBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "excalidraw",
              object["version"] as? Int == 2,
              let elements = object["elements"] as? [[String: Any]], elements.count <= 20_000,
              object["appState"] is [String: Any],
              let files = object["files"] as? [String: Any] else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("画板数据无效或超过 16 MB，无法保存。"))
        }
        for element in elements where element["type"] as? String == "image" && element["isDeleted"] as? Bool != true {
            guard let id = element["fileId"] as? String,
                  let file = files[id] as? [String: Any],
                  let url = file["dataURL"] as? String, url.hasPrefix("data:image/") else {
                throw NativeStoreError.fileSystem(NativeLocalization.text("画板缺少图片原文件，无法保存。"))
            }
        }
        return data
    }

    static func previewData(_ url: String) throws -> Data {
        let prefix = "data:image/png;base64,"
        guard url.hasPrefix(prefix), url.utf8.count <= maximumPreviewBytes * 2,
              let data = Data(base64Encoded: String(url.dropFirst(prefix.count))),
              data.count <= maximumPreviewBytes,
              data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let image = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...4096).contains(width), (1...4096).contains(height) else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("画板预览无效或过大，请缩小画板后重试。"))
        }
        return data
    }

    static func filename(for source: String) throws -> String {
        let prefix = "/media/\(directory)/"
        guard source.hasPrefix(prefix), source.hasSuffix(".excalidraw") else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("画板源文件路径无效。"))
        }
        let filename = String(source.dropFirst(prefix.count))
        let hash = filename.dropLast(".excalidraw".count)
        guard hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("画板源文件路径无效。"))
        }
        return filename
    }
}

extension LocalBlogStore {
    // Immutable media belongs to the workspace, not an article slug. Old revisions
    // remain available to undo, draft recovery and article history, including trash.
    func saveWhiteboard(scene: String, preview: String) throws -> ArticleWhiteboardAsset {
        try prepare()
        try requireWritableArticleSource()
        let sourceData = try ArticleWhiteboardData.sceneData(scene)
        let previewData = try ArticleWhiteboardData.previewData(preview)
        var digest = SHA256()
        digest.update(data: sourceData)
        digest.update(data: previewData)
        let revision = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let directory = try whiteboardDirectory(create: true)
        let sourceURL = directory.appendingPathComponent(revision + ".excalidraw")
        let previewURL = directory.appendingPathComponent(revision + ".png")
        // Only publish references after both files exist. A failed second write
        // leaves an unreferenced file; it never invalidates the previous version.
        if !FileManager.default.fileExists(atPath: sourceURL.path) { try sourceData.write(to: sourceURL, options: .atomic) }
        if !FileManager.default.fileExists(atPath: previewURL.path) { try previewData.write(to: previewURL, options: .atomic) }
        return ArticleWhiteboardAsset(
            source: "/media/\(ArticleWhiteboardData.directory)/\(revision).excalidraw",
            preview: "/media/\(ArticleWhiteboardData.directory)/\(revision).png"
        )
    }

    func loadWhiteboard(source: String) throws -> String {
        try prepare()
        let filename = try ArticleWhiteboardData.filename(for: source)
        let directory = try whiteboardDirectory()
        let url = directory.appendingPathComponent(filename)
        guard url.resolvingSymlinksInPath().deletingLastPathComponent() == directory,
              let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= ArticleWhiteboardData.maximumSceneBytes else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("画板源文件无效或过大。"))
        }
        let scene = try String(contentsOf: url, encoding: .utf8)
        _ = try ArticleWhiteboardData.sceneData(scene)
        return scene
    }

    private func whiteboardDirectory(create: Bool = false) throws -> URL {
        let root = mediaURL.standardizedFileURL.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent(ArticleWhiteboardData.directory, isDirectory: true)
        guard directory.resolvingSymlinksInPath().deletingLastPathComponent() == root else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("画板目录超出当前工作区。"))
        }
        if create { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        return directory
    }
}
