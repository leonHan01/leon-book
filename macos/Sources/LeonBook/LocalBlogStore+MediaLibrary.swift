import AVFoundation
import Foundation

extension LocalBlogStore {
    func mediaLibrarySnapshot() throws -> NativeMediaLibrarySnapshot {
        try prepare()
        var groups: [NativeMediaGroup] = []
        try db().query("SELECT id, name FROM media_library_groups ORDER BY created_at, id") { row in
            groups.append(NativeMediaGroup(id: row.text(at: 0) ?? "", name: row.text(at: 1) ?? ""))
        }
        return NativeMediaLibrarySnapshot(groups: groups, items: try mediaLibraryItems())
    }

    func mediaLibraryItems() throws -> [NativeLibraryMedia] {
        try prepare()
        var names: [String: String] = [:]
        var introductions: [String: String] = [:]
        var memberships: [String: String] = [:]
        try db().query("""
        SELECT media_json FROM articles UNION ALL SELECT images_json FROM moments
        UNION ALL SELECT images_json FROM question_answers
        """) { row in
            guard let json = row.text(at: 0), let data = json.data(using: .utf8),
                  let media = try? JSONDecoder().decode([NativeMedia].self, from: data) else { return }
            for item in media where item.isVideo || item.isAudio {
                names[normalizeMediaURL(item.url)] = item.name
            }
        }
        try db().query("SELECT url, name, introduction, group_id FROM media_library_items") { row in
            if let url = row.text(at: 0) {
                names[url] = row.text(at: 1)
                introductions[url] = row.text(at: 2)
                memberships[url] = row.text(at: 3)
            }
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let directoryKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        var items: [NativeLibraryMedia] = []
        let directories = try FileManager.default.contentsOfDirectory(
            at: mediaURL, includingPropertiesForKeys: Array(directoryKeys), options: [.skipsHiddenFiles]
        )
        for directory in directories where !["whiteboards", "canvases"].contains(directory.lastPathComponent) {
            try Task.checkCancellation()
            let values = try directory.resourceValues(forKeys: directoryKeys)
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
            )
            for file in files {
                try Task.checkCancellation()
                guard let kind = NativePlayableMediaKind.kind(for: file),
                      let values = try? file.resourceValues(forKeys: keys),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let url = "/media/\(directory.lastPathComponent)/\(file.lastPathComponent)"
                items.append(NativeLibraryMedia(
                    media: NativeMedia(kind: kind.rawValue, name: names[url] ?? file.lastPathComponent,
                                       size: values.fileSize ?? 0, url: url),
                    modifiedAt: values.contentModificationDate ?? .distantPast,
                    introduction: introductions[url] ?? "", groupID: memberships[url]
                ))
            }
        }
        return items
    }

    @discardableResult
    func saveMediaIntroduction(_ introduction: String, for media: NativeMedia) throws -> String {
        try prepare()
        try validateLibraryMedia(media)
        let introduction = introduction.trimmingCharacters(in: .whitespacesAndNewlines)
        try db().execute("""
        INSERT INTO media_library_items(url, name, kind, introduction) VALUES(?, ?, ?, ?)
        ON CONFLICT(url) DO UPDATE SET introduction = excluded.introduction
        """, values: [.text(media.url), .text(media.name), .text(media.kind), .text(introduction)])
        return introduction
    }

    @discardableResult
    func createMediaGroup(name: String) throws -> NativeMediaGroup {
        try prepare()
        let name = try validatedMediaGroupName(name)
        let group = NativeMediaGroup(id: UUID().uuidString.lowercased(), name: name)
        try db().execute("INSERT INTO media_library_groups(id, name, created_at) VALUES(?, ?, ?)", values: [
            .text(group.id), .text(name), .text(NativeTimestamp.string(from: Date())),
        ])
        return group
    }

    func renameMediaGroup(id: String, name: String) throws {
        try prepare()
        try requireMediaGroup(id)
        let name = try validatedMediaGroupName(name, excluding: id)
        try db().execute("UPDATE media_library_groups SET name = ? WHERE id = ?", values: [.text(name), .text(id)])
    }

    /// Removing a group returns its media to the default group without moving files.
    func deleteMediaGroup(id: String) throws {
        try prepare()
        try requireMediaGroup(id)
        try db().execute("DELETE FROM media_library_groups WHERE id = ?", values: [.text(id)])
    }

    func moveLibraryMedia(_ media: [NativeMedia], toGroup groupID: String?) throws {
        try prepare()
        let database = try db()
        try database.transaction {
            if let groupID { try requireMediaGroup(groupID) }
            for item in media {
                try validateLibraryMedia(item)
                try database.execute("""
                INSERT INTO media_library_items(url, name, kind, group_id) VALUES(?, ?, ?, ?)
                ON CONFLICT(url) DO UPDATE SET group_id = excluded.group_id
                """, values: [.text(item.url), .text(item.name), .text(item.kind), groupID.map(SQLiteValue.text) ?? .null])
            }
        }
    }

    /// Validate the batch before copying and retain library ownership separately
    /// from article attachments, so attachment cleanup cannot remove imports.
    func importLibraryMedia(_ urls: [URL], toGroup groupID: String? = nil) async throws {
        try prepare()
        if let groupID { try requireMediaGroup(groupID) }
        let writeLease = try WorkspaceStorageLifecycle.beginAsyncWrite(in: rootURL)
        defer { withExtendedLifetime(writeLease) {} }
        var sources: [(URL, NativePlayableMediaKind)] = []
        for url in urls {
            try Task.checkCancellation()
            guard url.isFileURL, let kind = NativePlayableMediaKind.kind(for: url),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw NativeStoreError.fileSystem(NativeLocalization.text("请选择 MP4、MOV 视频或 MP3、M4A、WAV 等音频文件：\(url.lastPathComponent)"))
            }
            let asset = AVURLAsset(url: url)
            let playable = try await asset.load(.isPlayable)
            let tracks = try await asset.loadTracks(withMediaType: kind == .video ? .video : .audio)
            guard playable, !tracks.isEmpty else {
                throw NativeStoreError.fileSystem(NativeLocalization.text("无法播放此文件，格式不支持或文件已损坏：\(url.lastPathComponent)"))
            }
            sources.append((url, kind))
        }

        var imported: [NativeMedia] = []
        do {
            for (url, kind) in sources {
                try Task.checkCancellation()
                let upload = try await uploadMedia(fileURL: url, kind: kind.rawValue, slug: "media-library")
                imported.append(NativeMedia(kind: kind.rawValue, name: upload.name, size: upload.size, url: upload.url))
            }
            try Task.checkCancellation()
            let database = try db()
            try database.transaction {
                // The actor can re-enter while AVFoundation validates or copies files.
                if let groupID { try requireMediaGroup(groupID) }
                for media in imported {
                    try database.execute("INSERT INTO media_library_items(url, name, kind, group_id) VALUES(?, ?, ?, ?)", values: [
                        .text(media.url), .text(media.name), .text(media.kind), groupID.map(SQLiteValue.text) ?? .null,
                    ])
                }
            }
        } catch {
            for media in imported {
                if let url = mediaURL(for: media.url) { try? FileManager.default.removeItem(at: url) }
            }
            throw error
        }
    }

    private func validateLibraryMedia(_ media: NativeMedia) throws {
        guard media.url.hasPrefix("/media/"), let url = mediaURL(for: media.url),
              media.url == "/media/\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)",
              NativePlayableMediaKind.kind(for: url)?.rawValue == media.kind,
              url.resolvingSymlinksInPath().path.hasPrefix(mediaURL.resolvingSymlinksInPath().path + "/"),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("影音文件不存在或不属于当前工作区。"))
        }
    }

    private func requireMediaGroup(_ id: String) throws {
        guard try db().integer("SELECT COUNT(*) FROM media_library_groups WHERE id = ?", values: [.text(id)]) == 1 else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("影音分组已不存在，请刷新后重试。"))
        }
    }

    private func validatedMediaGroupName(_ raw: String, excluding id: String? = nil) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name.count <= 80, name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("分组名称须为 1–80 个字符，不能包含换行。"))
        }
        let reserved = ["默认分组", "全部影音", "Default Group", "All Media"]
        guard !reserved.contains(where: { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("请使用与系统分组不同的名称。"))
        }
        var duplicate = false
        try db().query("SELECT id, name FROM media_library_groups") { row in
            if row.text(at: 0) != id, row.text(at: 1)?.localizedCaseInsensitiveCompare(name) == .orderedSame {
                duplicate = true
            }
        }
        guard !duplicate else { throw NativeStoreError.fileSystem(NativeLocalization.text("已存在同名影音分组。")) }
        return name
    }
}
