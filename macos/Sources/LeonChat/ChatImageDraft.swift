import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ChatImageDraft: Identifiable {
    let id: String
    let data: Data

    static func prepare(_ data: Data) throws -> ChatImageDraft {
        guard data.count <= 64 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16000, height <= 16000, width * height <= 48_000_000 else {
            throw ClientError.message("图片无法读取或尺寸过大，请选择其他图片。")
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1600]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let canvas = CGContext(data: nil, width: thumbnail.width, height: thumbnail.height, bitsPerComponent: 8,
                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ClientError.message("图片格式不受支持，请选择 PNG、JPG、HEIC 或 GIF。")
        }
        let bounds = CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height)
        canvas.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); canvas.fill(bounds)
        canvas.draw(thumbnail, in: bounds)
        guard let image = canvas.makeImage() else { throw ClientError.message("无法处理图片") }
        for quality in [0.85, 0.65, 0.45] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { break }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), output.length <= 1024 * 1024 {
                return ChatImageDraft(id: UUID().uuidString.lowercased(), data: output as Data)
            }
        }
        throw ClientError.message("图片压缩后仍过大，请缩小后发送。")
    }
}

enum ChatImageFiles {
    static func file(id: String, scope: String) throws -> URL {
        guard UUID(uuidString: id) != nil, !scope.isEmpty else { throw ClientError.message("图片存储不可用") }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("Leon/chat-images").appendingPathComponent(scope)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent(id + ".jpg")
    }
    static func save(_ image: ChatImageDraft, scope: String) throws {
        let url = try file(id: image.id, scope: scope)
        try image.data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func read(_ id: String, scope: String) -> Data? {
        guard let url = try? file(id: id, scope: scope) else { return nil }
        return try? Data(contentsOf: url)
    }
    static func remove(_ ids: [String], scope: String) {
        for id in ids { if let url = try? file(id: id, scope: scope) { try? FileManager.default.removeItem(at: url) } }
    }
}
