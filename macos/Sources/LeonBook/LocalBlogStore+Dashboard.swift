import AVFoundation
import Foundation
import ImageIO

extension LocalBlogStore {
    func loadDashboard() throws -> NativeDashboardDocument {
        try prepare()
        return try readDashboard()
    }

    private func readDashboard() throws -> NativeDashboardDocument {
        guard let json = try db().text("SELECT value FROM metadata WHERE key = 'dashboard_v1'") else {
            return .standard
        }
        do {
            return try JSONDecoder().decode(NativeDashboardDocument.self, from: Data(json.utf8)).validated()
        } catch let error as NativeDashboardError { throw error }
        catch { throw NativeDashboardError.invalidDocument }
    }

    /// The revision check and write share a SQLite transaction, including across
    /// separate windows/stores. The complete workspace backup includes metadata.
    func saveDashboard(_ document: NativeDashboardDocument) throws -> NativeDashboardDocument {
        try prepare()
        var saved = try document.validated()
        let database = try db()
        try database.transaction {
            let current = try readDashboard()
            guard document.revision == current.revision else { throw NativeDashboardError.conflict }
            saved.revision += 1
            let json = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
            try database.execute("INSERT OR REPLACE INTO metadata(key, value) VALUES('dashboard_v1', ?)", values: [.text(json)])
        }
        return saved
    }

    func importDashboardMedia(_ file: URL, kind: NativeDashboardModuleKind) async throws -> NativeMedia {
        try prepare()
        let lease = try WorkspaceStorageLifecycle.beginAsyncWrite(in: rootURL)
        defer { withExtendedLifetime(lease) {} }
        guard file.isFileURL, kind.isMedia,
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw NativeStoreError.fileSystem(NativeLocalization.string("请选择有效的图片、音频或视频文件。", language: NativeLocalization.currentLanguage))
        }
        if kind == .image {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  CGImageSourceGetCount(source) > 0 else {
                throw NativeStoreError.fileSystem(NativeLocalization.string("无法读取这张图片。", language: NativeLocalization.currentLanguage))
            }
        } else {
            let asset = AVURLAsset(url: file)
            let playable = try await asset.load(.isPlayable)
            let tracks = try await asset.loadTracks(withMediaType: kind == .video ? .video : .audio)
            guard playable, !tracks.isEmpty else {
                throw NativeStoreError.fileSystem(NativeLocalization.string("无法播放此文件，格式不支持或文件已损坏。", language: NativeLocalization.currentLanguage))
            }
        }
        try Task.checkCancellation()
        let upload = try await uploadMedia(fileURL: file, kind: kind.rawValue, slug: "dashboard")
        return NativeMedia(kind: upload.kind, name: upload.name, size: upload.size, url: upload.url)
    }
}
