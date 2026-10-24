import AppKit
import Foundation

enum NativeArticleAudioDrop {
    /// Match the browser's dropped filenames to native file URLs, preserving
    /// order even when separate folders contain files with the same name.
    static func fileURLs(from pasteboard: NSPasteboard, matching names: [String]) -> [URL]? {
        guard !names.isEmpty, names.allSatisfy({ ($0 as NSString).pathExtension.lowercased() == "mp3" }),
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
    /// insertion point accepts the audio block.
    func importEditorAudio(from url: URL) async throws -> NativeMedia {
        guard !isBackingUp, !isMarkdownSourceReadOnly else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("当前工作空间暂时不能插入音频。"))
        }
        guard url.pathExtension.caseInsensitiveCompare("mp3") == .orderedSame else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("文章音频仅支持 MP3 格式。"))
        }
        let activeStore = store
        let documentID = editor.recoveryID
        let destination: NativeMediaUploadDestination = editor.slug.isEmpty ? .inbox : .article(slug: editor.slug)
        let generation = beginUpload()
        defer { endUpload() }
        guard let media = try await NativeMediaUpload.files(
            [url], kind: .audio, destination: destination, store: activeStore
        ).first else { throw NativeStoreError.fileSystem(NativeLocalization.text("无法导入音频。")) }
        guard generation == workspaceGeneration, editor.recoveryID == documentID,
              !isMarkdownSourceReadOnly else {
            try? await activeStore.discardUnreferencedMedia([media])
            throw NativeStoreError.fileSystem(NativeLocalization.text("当前文章已改变，音频未插入。"))
        }
        return media
    }

    func registerEditorAudio(_ media: NativeMedia) {
        editor.media.append(media)
        errorMessage = nil
        scheduleBackup()
    }
}
