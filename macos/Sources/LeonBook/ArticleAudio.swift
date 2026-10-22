import Foundation

extension NativeAppModel {
    /// Import first; the editor registers the attachment only after its original
    /// insertion point accepts the audio block.
    func importEditorAudio(from url: URL) async throws -> NativeMedia {
        guard !isBackingUp, !isMarkdownSourceReadOnly else {
            throw NativeStoreError.fileSystem("当前工作空间暂时不能插入音频。")
        }
        guard url.pathExtension.caseInsensitiveCompare("mp3") == .orderedSame else {
            throw NativeStoreError.fileSystem("文章音频仅支持 MP3 格式。")
        }
        let activeStore = store
        let documentID = editor.recoveryID
        let destination: NativeMediaUploadDestination = editor.slug.isEmpty ? .inbox : .article(slug: editor.slug)
        let generation = beginUpload()
        defer { endUpload() }
        guard let media = try await NativeMediaUpload.files(
            [url], kind: .audio, destination: destination, store: activeStore
        ).first else { throw NativeStoreError.fileSystem("无法导入音频。") }
        guard generation == workspaceGeneration, editor.recoveryID == documentID,
              !isMarkdownSourceReadOnly else {
            try? await activeStore.discardUnreferencedMedia([media])
            throw NativeStoreError.fileSystem("当前文章已改变，音频未插入。")
        }
        return media
    }

    func registerEditorAudio(_ media: NativeMedia) {
        editor.media.append(media)
        errorMessage = nil
        scheduleBackup()
    }
}
