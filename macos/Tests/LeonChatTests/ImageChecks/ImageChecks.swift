@testable import LeonChat
import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

@main
struct ImageChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ClientError.message(message) }
    }
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let context = CGContext(data: nil, width: 3200, height: 1600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.18, green: 0.36, blue: 0.89, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3200, height: 1600))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 200, y: 200, width: 1000, height: 700))
        let source = context.makeImage()!
        let png = NSMutableData()
        let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, source, nil)
        try check(CGImageDestinationFinalize(destination), "Fixture PNG encoding failed")
        let prepared = try ChatImageDraft.prepare(png as Data)
        let image = CGImageSourceCreateWithData(prepared.data as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil)! as NSDictionary
        try check(properties[kCGImagePropertyPixelWidth] as? Int == 1600 && properties[kCGImagePropertyPixelHeight] as? Int == 800, "Image was stretched or not downsized")
        try check(prepared.data.count <= 1024 * 1024 && prepared.data.starts(with: [0xff, 0xd8]), "Upload is not a bounded JPEG")
        let oriented = NSMutableData()
        let jpeg = CGImageDestinationCreateWithData(oriented, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(jpeg, source, [kCGImagePropertyOrientation: 6] as CFDictionary)
        try check(CGImageDestinationFinalize(jpeg), "Rotated fixture encoding failed")
        let upright = try ChatImageDraft.prepare(oriented as Data)
        let uprightProperties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(upright.data as CFData, nil)!, 0, nil)! as NSDictionary
        try check(uprightProperties[kCGImagePropertyPixelWidth] as? Int == 800 && uprightProperties[kCGImagePropertyPixelHeight] as? Int == 1600, "EXIF orientation not applied")
        var rejected = false
        do { _ = try ChatImageDraft.prepare(Data("invalid".utf8)) } catch { rejected = true }
        try check(rejected, "Invalid image was accepted")

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(png as Data, forType: .png)
        let editor = ComposerTextView(frame: .zero)
        editor.isRichText = false; editor.string = "保留文字 @writer"; editor.imagePasteboard = pasteboard
        var pasted: [Data] = []
        editor.pastedImages = { pasted = $0 }
        editor.paste(nil)
        try check(pasted == [png as Data] && editor.string == "保留文字 @writer", "Native image paste lost text or failed to route attachment")
        pasteboard.clearContents(); pasteboard.setString("普通文字", forType: .string)
        try check(ChatImagePasteboard.images(in: pasteboard).isEmpty, "Plain text was treated as an image")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("selected.png")
        try (png as Data).write(to: file)
        pasteboard.clearContents(); pasteboard.writeObjects([file as NSURL])
        try check(ChatImagePasteboard.images(in: pasteboard) == [png as Data], "Finder image-file paste failed")

        let outgoing = Outgoing(clientMessageId: "message", deviceId: "device", sender: "Mac", platform: "macos", text: "", conversationId: "shared", mentionAgentIds: [], imageIds: [prepared.id])
        let restored = try JSONDecoder().decode(Outgoing.self, from: JSONEncoder().encode(outgoing))
        try check(restored.text.isEmpty && restored.imageIds == [prepared.id], "Image-only outbox persistence changed attachment IDs")
        let payload = Data("{\"id\":1,\"clientMessageId\":\"m\",\"deviceId\":\"d\",\"sender\":\"Mac\",\"platform\":\"macos\",\"text\":\"\",\"createdAt\":1,\"images\":[{\"id\":\"\(prepared.id)\",\"mimeType\":\"image/jpeg\",\"width\":1600,\"height\":800,\"byteCount\":1234}]}".utf8)
        let message = try JSONDecoder().decode(Message.self, from: payload)
        try check(message.images?.first?.id == prepared.id && message.text.isEmpty, "History attachment decoding failed")
        print("PASS: image normalization, JPEG size cap, EXIF orientation, invalid-data rejection")
        print("PASS: native image paste and Finder-file paste preserve text; plain text stays unchanged")
        print("PASS: image-only outbox encoding and history image metadata decoding")
    }
}
