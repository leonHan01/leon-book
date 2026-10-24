import Foundation
import ImageIO

extension LocalBlogStore {
    func photoLibrarySnapshot() throws -> NativePhotoLibrarySnapshot {
        try prepare()
        var albums: [NativePhotoAlbum] = []
        try db().query("SELECT id, name FROM photo_albums ORDER BY created_at, id") { row in
            albums.append(NativePhotoAlbum(id: row.text(at: 0) ?? "", name: row.text(at: 1) ?? ""))
        }
        var names: [String: String] = [:]
        try db().query("""
        SELECT media_json FROM articles UNION ALL SELECT images_json FROM moments
        UNION ALL SELECT images_json FROM question_answers
        """) { row in
            guard let json = row.text(at: 0), let data = json.data(using: .utf8),
                  let media = try? JSONDecoder().decode([NativeMedia].self, from: data) else { return }
            for item in media where item.isImage { names[normalizeMediaURL(item.url)] = item.name }
        }
        var memberships: [String: String] = [:]
        try db().query("SELECT url, name, album_id FROM photo_library_items") { row in
            guard let url = row.text(at: 0) else { return }
            names[url] = row.text(at: 1)
            memberships[url] = row.text(at: 2)
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var photos: [NativeLibraryPhoto] = []
        let directories = try FileManager.default.contentsOfDirectory(
            at: mediaURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]
        )
        for directory in directories where !["whiteboards", "canvases"].contains(directory.lastPathComponent) {
            try Task.checkCancellation()
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
            )
            for file in files where Self.photoExtensions.contains(file.pathExtension.lowercased()) {
                guard let values = try? file.resourceValues(forKeys: keys),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let url = "/media/\(directory.lastPathComponent)/\(file.lastPathComponent)"
                photos.append(NativeLibraryPhoto(
                    media: NativeMedia(kind: "image", name: names[url] ?? file.lastPathComponent,
                                       size: values.fileSize ?? 0, url: url),
                    modifiedAt: values.contentModificationDate ?? .distantPast, albumID: memberships[url]
                ))
            }
        }
        return NativePhotoLibrarySnapshot(albums: albums, photos: photos)
    }

    @discardableResult
    func createPhotoAlbum(name: String) throws -> NativePhotoAlbum {
        try prepare()
        let name = try validatedPhotoAlbumName(name)
        let album = NativePhotoAlbum(id: UUID().uuidString.lowercased(), name: name)
        try db().execute("INSERT INTO photo_albums(id, name, created_at) VALUES(?, ?, ?)", values: [
            .text(album.id), .text(name), .text(NativeTimestamp.string(from: Date())),
        ])
        return album
    }

    func renamePhotoAlbum(id: String, name: String) throws {
        try prepare()
        let name = try validatedPhotoAlbumName(name, excluding: id)
        try requirePhotoAlbum(id)
        try db().execute("UPDATE photo_albums SET name = ? WHERE id = ?", values: [.text(name), .text(id)])
    }

    /// Album removal only removes organization. Photos remain in the library.
    func deletePhotoAlbum(id: String) throws {
        try prepare()
        try requirePhotoAlbum(id)
        try db().execute("DELETE FROM photo_albums WHERE id = ?", values: [.text(id)])
    }

    func movePhotos(_ media: [NativeMedia], toAlbum albumID: String?) throws {
        try prepare()
        let database = try db()
        try database.transaction {
            if let albumID { try requirePhotoAlbum(albumID) }
            for photo in media {
                try validateLibraryPhoto(photo)
                try database.execute("""
                INSERT INTO photo_library_items(url, name, album_id) VALUES(?, ?, ?)
                ON CONFLICT(url) DO UPDATE SET album_id = excluded.album_id
                """, values: [.text(photo.url), .text(photo.name), albumID.map(SQLiteValue.text) ?? .null])
            }
        }
    }

    /// Copy into managed storage, then commit the whole batch's ownership.
    /// A failed import leaves neither partial memberships nor orphan copies.
    func importLibraryPhotos(_ urls: [URL], toAlbum albumID: String?) async throws {
        try prepare()
        let writeLease = try WorkspaceStorageLifecycle.beginAsyncWrite(in: rootURL)
        defer { withExtendedLifetime(writeLease) {} }
        if let albumID { try requirePhotoAlbum(albumID) }
        for url in urls {
            guard url.isFileURL, Self.photoExtensions.contains(url.pathExtension.lowercased()),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetCount(source) > 0 else {
                throw NativeStoreError.fileSystem(NativeLocalization.text("无法读取图片：\(url.lastPathComponent)"))
            }
        }
        var imported: [NativeMedia] = []
        do {
            for url in urls {
                try Task.checkCancellation()
                let upload = try await uploadMedia(fileURL: url, kind: "image", slug: "photo-library")
                imported.append(NativeMedia(kind: "image", name: upload.name, size: upload.size, url: upload.url))
            }
            try Task.checkCancellation()
            try movePhotos(imported, toAlbum: albumID)
        } catch {
            for item in imported {
                if let url = mediaURL(for: item.url) { try? FileManager.default.removeItem(at: url) }
            }
            throw error
        }
    }

    private static let photoExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "avif"]

    private func validateLibraryPhoto(_ photo: NativeMedia) throws {
        guard photo.isImage, photo.url.hasPrefix("/media/"),
              let url = mediaURL(for: photo.url),
              photo.url == "/media/\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)",
              Self.photoExtensions.contains(url.pathExtension.lowercased()),
              url.resolvingSymlinksInPath().path.hasPrefix(mediaURL.resolvingSymlinksInPath().path + "/"),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("图片不存在或不属于当前工作区。"))
        }
    }

    private func requirePhotoAlbum(_ id: String) throws {
        guard try db().integer("SELECT COUNT(*) FROM photo_albums WHERE id = ?", values: [.text(id)]) == 1 else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("相册已不存在，请刷新后重试。"))
        }
    }

    private func validatedPhotoAlbumName(_ raw: String, excluding id: String? = nil) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name.count <= 80, name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("相册名称须为 1–80 个字符，不能包含换行。"))
        }
        var duplicate = false
        try db().query("SELECT id, name FROM photo_albums") { row in
            if row.text(at: 0) != id, row.text(at: 1)?.localizedCaseInsensitiveCompare(name) == .orderedSame {
                duplicate = true
            }
        }
        guard !duplicate else { throw NativeStoreError.fileSystem(NativeLocalization.text("已存在同名相册。")) }
        return name
    }
}
