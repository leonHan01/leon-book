import AppKit
import Foundation

enum NativeArticleMediaDrop {
    static func kind(for url: URL) -> NativeMediaUploadKind? {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif": return .image
        case "mp4", "mov", "m4v", "webm": return .video
        case "mp3": return .audio
        default: return nil
        }
    }

    /// Match the browser's dropped filenames to native file URLs, preserving
    /// order even when separate folders contain files with the same name.
    static func fileURLs(from pasteboard: NSPasteboard, matching names: [String]) -> [URL]? {
        guard !names.isEmpty, names.allSatisfy({ kind(for: URL(fileURLWithPath: $0)) != nil }),
              let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return nil }
        var remaining = objects.compactMap { $0 as? URL }
        var result: [URL] = []
        for name in names {
            guard let index = remaining.firstIndex(where: { $0.lastPathComponent == name }),
                  (try? remaining[index].resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            result.append(remaining.remove(at: index))
        }
        return result
    }
}

extension NativeAppModel {
    /// Import first; the editor registers the attachment only after its original
    /// insertion point accepts the media block.
    func importEditorMedia(from url: URL) async throws -> NativeMedia {
        guard !isBackingUp, !isMarkdownSourceReadOnly else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("当前工作空间暂时不能插入媒体。"))
        }
        guard url.isFileURL, let kind = NativeArticleMediaDrop.kind(for: url) else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("请拖入图片、视频或 MP3 文件。"))
        }
        let activeStore = store
        let documentID = editor.recoveryID
        let destination: NativeMediaUploadDestination = editor.slug.isEmpty ? .inbox : .article(slug: editor.slug)
        let generation = beginUpload()
        defer { endUpload() }
        guard let media = try await NativeMediaUpload.files(
            [url], kind: kind, destination: destination, store: activeStore
        ).first else { throw NativeStoreError.fileSystem(NativeLocalization.text("无法导入媒体。")) }
        guard generation == workspaceGeneration, editor.recoveryID == documentID,
              !isMarkdownSourceReadOnly else {
            try? await activeStore.discardUnreferencedMedia([media])
            throw NativeStoreError.fileSystem(NativeLocalization.text("当前文章已改变，媒体未插入。"))
        }
        return media
    }

    func registerEditorMedia(_ media: NativeMedia) {
        editor.media.append(media)
        errorMessage = nil
        scheduleBackup()
    }
}
