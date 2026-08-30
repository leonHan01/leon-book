import Foundation

extension LocalBlogStore {
    private struct PortableSidecarPreference: Codable {
        var enabledDirectoryPaths: [String] = []
    }

    private var portableSidecarPreferenceURL: URL {
        rootURL.appendingPathComponent("portable-sidecar.json")
    }

    private var portableSidecarDirectoryIdentifier: String {
        articlesURL.standardizedFileURL.resolvingSymlinksInPath().path
            .precomposedStringWithCanonicalMapping
    }

    private var portableSidecarRepository: NativePortableSidecarRepository {
        NativePortableSidecarRepository(markdownRootURL: articlesURL)
    }

    func portableSidecarStatus() throws -> NativePortableSidecarStatus {
        try prepare()
        let repository = portableSidecarRepository
        return NativePortableSidecarStatus(
            isEnabled: isPortableSidecarEnabledWithoutPreparing(),
            isWritable: !markdownWorkspaceSource.mode.isReadOnly,
            hasSidecar: repository.exists,
            directoryPath: repository.directoryURL.path,
            lastError: portableSidecarLastError
        )
    }

    @discardableResult
    func setPortableSidecarEnabled(_ enabled: Bool) throws -> NativePortableSidecarImportResult {
        try prepare()
        var preference = loadPortableSidecarPreference()
        var enabledPaths = Set(preference.enabledDirectoryPaths)
        let directoryID = portableSidecarDirectoryIdentifier
        if enabled { enabledPaths.insert(directoryID) }
        else { enabledPaths.remove(directoryID) }
        preference.enabledDirectoryPaths = enabledPaths.sorted()
        try persistPortableSidecarPreference(preference)
        portableSidecarLastError = nil
        guard enabled else { return NativePortableSidecarImportResult() }

        do {
            let imported = try importPortableSidecarWithoutPreparing()
            if !markdownWorkspaceSource.mode.isReadOnly {
                try exportPortableSidecarWithoutPreparing()
            }
            return imported
        } catch {
            enabledPaths.remove(directoryID)
            preference.enabledDirectoryPaths = enabledPaths.sorted()
            try? persistPortableSidecarPreference(preference)
            portableSidecarLastError = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    func synchronizePortableSidecar() throws -> NativePortableSidecarImportResult {
        try prepare()
        guard isPortableSidecarEnabledWithoutPreparing() else {
            throw NativeStoreError.fileSystem("请先启用 .leonbook 可移植状态")
        }
        do {
            let imported = try importPortableSidecarWithoutPreparing()
            if !markdownWorkspaceSource.mode.isReadOnly {
                try exportPortableSidecarWithoutPreparing()
            }
            portableSidecarLastError = nil
            return imported
        } catch {
            portableSidecarLastError = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    func importPortableSidecarIfEnabled() throws -> NativePortableSidecarImportResult {
        try prepare()
        guard isPortableSidecarEnabledWithoutPreparing() else {
            return NativePortableSidecarImportResult()
        }
        do {
            let result = try importPortableSidecarWithoutPreparing()
            portableSidecarLastError = nil
            return result
        } catch {
            portableSidecarLastError = error.localizedDescription
            throw error
        }
    }

    func exportPortableSidecarIfEnabled() throws {
        try prepare()
        guard isPortableSidecarEnabledWithoutPreparing(),
              !markdownWorkspaceSource.mode.isReadOnly else { return }
        do {
            try exportPortableSidecarWithoutPreparing()
            portableSidecarLastError = nil
        } catch {
            portableSidecarLastError = error.localizedDescription
            throw error
        }
    }

    func readPortableUIState() throws -> NativePortableUIState? {
        try prepare()
        guard isPortableSidecarEnabledWithoutPreparing() else { return nil }
        return try portableSidecarRepository.readUIState()
    }

    func writePortableUIState(_ state: NativePortableUIState) throws {
        try prepare()
        guard isPortableSidecarEnabledWithoutPreparing() else { return }
        guard !markdownWorkspaceSource.mode.isReadOnly else {
            throw NativeStoreError.readOnlyArticleSource
        }
        do {
            try portableSidecarRepository.writeUIState(
                state,
                updatedAt: NativeTimestamp.string(from: Date())
            )
            portableSidecarLastError = nil
        } catch {
            portableSidecarLastError = error.localizedDescription
            throw error
        }
    }

    func importPortableSidecarDuringPreparation() {
        guard isPortableSidecarEnabledWithoutPreparing() else { return }
        do {
            _ = try importPortableSidecarWithoutPreparing()
            portableSidecarLastError = nil
        } catch {
            portableSidecarLastError = error.localizedDescription
        }
    }

    private func exportPortableSidecarWithoutPreparing() throws {
        var comments: [NativeArticleComment] = []
        try db().query(commentSelect + " ORDER BY created_at, id") { row in
            comments.append(try decodeArticleComment(row))
        }

        var revisions: [NativeArticleRevision] = []
        try db().query(revisionSelect + " ORDER BY updated_at DESC, id DESC") { row in
            revisions.append(try decodeArticleRevision(row))
        }

        var bookmarks: [NativeBookmark] = []
        try db().query("SELECT bookmark_json FROM bookmarks ORDER BY position, created_at, id") { row in
            guard let raw = row.text(at: 0) else {
                throw NativeStoreError.fileSystem("SQLite：收藏记录不完整")
            }
            bookmarks.append(try decode(raw))
        }

        let commentTombstones = try portableSidecarTombstones(kind: "comment")
        let bookmarkTombstones = try portableSidecarTombstones(kind: "bookmark")

        try portableSidecarRepository.writeDatabaseState(
            comments: comments,
            commentTombstones: commentTombstones,
            revisions: revisions.map(NativePortableRevisionRecord.init),
            bookmarks: bookmarks,
            bookmarkTombstones: bookmarkTombstones,
            updatedAt: NativeTimestamp.string(from: Date())
        )
    }

    private func importPortableSidecarWithoutPreparing() throws -> NativePortableSidecarImportResult {
        let repository = portableSidecarRepository
        let state = try repository.readDatabaseState()
        var result = NativePortableSidecarImportResult()
        result.foundSidecar = repository.exists && state.hasAnyFile
        guard state.hasAnyFile else { return result }

        let articleSlugs = try existingArticleSlugsWithoutPreparing()
        try db().transaction {
            if let comments = state.comments {
                try importPortableComments(comments, articleSlugs: articleSlugs, result: &result)
            }
            if let revisions = state.revisions {
                try importPortableRevisions(revisions.records, result: &result)
            }
            if let bookmarks = state.bookmarks {
                try importPortableBookmarks(bookmarks, result: &result)
            }
        }
        return result
    }

    private func importPortableComments(
        _ archive: NativePortableCollection<NativeArticleComment>,
        articleSlugs: Set<String>,
        result: inout NativePortableSidecarImportResult
    ) throws {
        for tombstone in archive.tombstones.prefix(100_000) {
            guard let safeID = try? requireSafeSegment(tombstone.id, label: "评论标识") else { continue }
            let localUpdatedAt = try db().text(
                "SELECT updated_at FROM article_comments WHERE id = ?",
                values: [.text(safeID)]
            )
            guard let localUpdatedAt, localUpdatedAt <= tombstone.deletedAt else { continue }
            try db().execute("DELETE FROM article_comments WHERE id = ?", values: [.text(safeID)])
            try recordPortableSidecarTombstone(
                kind: "comment",
                id: safeID,
                deletedAt: tombstone.deletedAt
            )
            result.deletedCommentCount += 1
        }

        var pending = archive.records.prefix(100_000).filter {
            articleSlugs.contains($0.articleSlug)
        }
        var madeProgress = true
        while !pending.isEmpty, madeProgress {
            madeProgress = false
            var deferred: [NativeArticleComment] = []
            for comment in pending {
                guard let safeID = try? requireSafeSegment(comment.id, label: "评论标识"),
                      let safeSlug = try? requireSafeSegment(comment.articleSlug, label: "文章 slug"),
                      !comment.authorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      comment.authorName.count <= 80,
                      !comment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      comment.text.count <= 2_000 else { continue }
                let safeParentID = try comment.parentID.map {
                    try requireSafeSegment($0, label: "父评论标识")
                }
                if let safeParentID {
                    let parentExists = try db().integer(
                        "SELECT COUNT(*) FROM article_comments WHERE id = ? AND article_slug = ?",
                        values: [.text(safeParentID), .text(safeSlug)]
                    ) ?? 0
                    if parentExists == 0 {
                        deferred.append(comment)
                        continue
                    }
                }
                let existingUpdatedAt = try db().text(
                    "SELECT updated_at FROM article_comments WHERE id = ?",
                    values: [.text(safeID)]
                )
                if let existingUpdatedAt {
                    guard existingUpdatedAt < comment.updatedAt else {
                        madeProgress = true
                        continue
                    }
                }
                try db().execute(
                    """
                    INSERT INTO article_comments(
                        id, article_slug, parent_id, author_name, text,
                        quoted_text, anchor_id, created_at, updated_at
                    ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        article_slug = excluded.article_slug,
                        parent_id = excluded.parent_id,
                        author_name = excluded.author_name,
                        text = excluded.text,
                        quoted_text = excluded.quoted_text,
                        anchor_id = excluded.anchor_id,
                        created_at = excluded.created_at,
                        updated_at = excluded.updated_at
                    """,
                    values: [
                        .text(safeID),
                        .text(safeSlug),
                        safeParentID.map(SQLiteValue.text) ?? .null,
                        .text(comment.authorName),
                        .text(comment.text),
                        comment.selection.map { .text($0.quote) } ?? .null,
                        comment.selection.map { .text($0.anchorID) } ?? .null,
                        .text(comment.createdAt),
                        .text(comment.updatedAt),
                    ]
                )
                result.importedCommentCount += 1
                madeProgress = true
            }
            pending = deferred
        }
    }

    private func importPortableRevisions(
        _ revisions: [NativePortableRevisionRecord],
        result: inout NativePortableSidecarImportResult
    ) throws {
        for revision in revisions.prefix(5_000) {
            guard let safeSyncID = try? requireSafeSegment(revision.id, label: "版本同步标识"),
                  let safeDraftKey = try? requireSafeSegment(revision.draftKey, label: "版本草稿标识") else {
                continue
            }
            let safeArticleSlug = try revision.articleSlug.map {
                try requireSafeSegment($0, label: "文章 slug")
            }
            let existingUpdatedAt = try db().text(
                "SELECT updated_at FROM article_revisions WHERE sync_id = ?",
                values: [.text(safeSyncID)]
            )
            if let existingUpdatedAt {
                guard existingUpdatedAt < revision.updatedAt else { continue }
                try db().execute(
                    """
                    UPDATE article_revisions
                    SET draft_key = ?, article_slug = ?, reason = ?, snapshot_json = ?,
                        created_at = ?, updated_at = ?
                    WHERE sync_id = ?
                    """,
                    values: [
                        .text(safeDraftKey),
                        safeArticleSlug.map(SQLiteValue.text) ?? .null,
                        .text(revision.reason.rawValue),
                        .text(try jsonString(revision.snapshot)),
                        .text(revision.createdAt),
                        .text(revision.updatedAt),
                        .text(safeSyncID),
                    ]
                )
            } else {
                _ = try insertArticleRevision(
                    draftKey: safeDraftKey,
                    articleSlug: safeArticleSlug,
                    reason: revision.reason,
                    snapshot: revision.snapshot,
                    createdAt: revision.createdAt,
                    updatedAt: revision.updatedAt,
                    syncID: safeSyncID
                )
            }
            result.importedRevisionCount += 1
        }
    }

    private func importPortableBookmarks(
        _ archive: NativePortableCollection<NativeBookmark>,
        result: inout NativePortableSidecarImportResult
    ) throws {
        for tombstone in archive.tombstones.prefix(20_000) {
            guard let safeID = try? requireSafeSegment(tombstone.id, label: "收藏标识") else { continue }
            let exists = try db().integer(
                "SELECT COUNT(*) FROM bookmarks WHERE id = ?",
                values: [.text(safeID)]
            ) ?? 0
            guard exists > 0 else { continue }
            try db().execute("DELETE FROM bookmarks WHERE id = ?", values: [.text(safeID)])
            try recordPortableSidecarTombstone(
                kind: "bookmark",
                id: safeID,
                deletedAt: tombstone.deletedAt
            )
            result.deletedBookmarkCount += 1
        }

        for (position, bookmark) in archive.records.prefix(20_000).enumerated() {
            guard let safeID = try? requireSafeSegment(bookmark.id, label: "收藏标识"),
                  !bookmark.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  bookmark.title.count <= 120,
                  bookmark.groupName.count <= 80 else { continue }
            let existingJSON = try db().text(
                "SELECT bookmark_json FROM bookmarks WHERE id = ?",
                values: [.text(safeID)]
            )
            let encoded = try jsonString(bookmark)
            guard existingJSON != encoded else { continue }
            try db().execute(
                """
                INSERT INTO bookmarks(id, bookmark_json, position, created_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    bookmark_json = excluded.bookmark_json,
                    position = excluded.position,
                    created_at = excluded.created_at
                """,
                values: [
                    .text(safeID),
                    .text(encoded),
                    .integer(position),
                    .text(bookmark.createdAt),
                ]
            )
            result.importedBookmarkCount += 1
        }
    }

    private func existingArticleSlugsWithoutPreparing() throws -> Set<String> {
        var slugs = Set<String>()
        try db().query("SELECT slug FROM articles") { row in
            if let slug = row.text(at: 0) { slugs.insert(slug) }
        }
        return slugs
    }

    func recordPortableSidecarTombstone(
        kind: String,
        id: String,
        deletedAt: String = NativeTimestamp.string(from: Date())
    ) throws {
        try db().execute(
            """
            INSERT INTO portable_sidecar_tombstones(kind, record_id, deleted_at)
            VALUES (?, ?, ?)
            ON CONFLICT(kind, record_id) DO UPDATE SET deleted_at =
                CASE WHEN excluded.deleted_at > deleted_at THEN excluded.deleted_at ELSE deleted_at END
            """,
            values: [.text(kind), .text(id), .text(deletedAt)]
        )
    }

    private func portableSidecarTombstones(
        kind: String
    ) throws -> [NativePortableSidecarTombstone] {
        var tombstones: [NativePortableSidecarTombstone] = []
        try db().query(
            "SELECT record_id, deleted_at FROM portable_sidecar_tombstones WHERE kind = ? ORDER BY record_id",
            values: [.text(kind)]
        ) { row in
            guard let id = row.text(at: 0), let deletedAt = row.text(at: 1) else { return }
            tombstones.append(NativePortableSidecarTombstone(id: id, deletedAt: deletedAt))
        }
        return tombstones
    }

    private func isPortableSidecarEnabledWithoutPreparing() -> Bool {
        loadPortableSidecarPreference().enabledDirectoryPaths
            .contains(portableSidecarDirectoryIdentifier)
    }

    private func loadPortableSidecarPreference() -> PortableSidecarPreference {
        guard let data = try? Data(contentsOf: portableSidecarPreferenceURL),
              let preference = try? JSONDecoder().decode(PortableSidecarPreference.self, from: data) else {
            return PortableSidecarPreference()
        }
        return preference
    }

    private func persistPortableSidecarPreference(
        _ preference: PortableSidecarPreference
    ) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(preference).write(to: portableSidecarPreferenceURL, options: .atomic)
        } catch {
            throw NativeStoreError.fileSystem(
                "无法保存 .leonbook 同步设置：\(error.localizedDescription)"
            )
        }
    }
}
