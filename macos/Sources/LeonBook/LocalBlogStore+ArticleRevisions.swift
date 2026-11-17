import Foundation

extension LocalBlogStore {
    // MARK: - Article revisions and comments

    public func saveArticleAutosave(
        draftKey: String,
        articleSlug: String?,
        snapshot: NativeArticleRevisionSnapshot,
        at date: Date = Date()
    ) throws -> NativeArticleRevision {
        try prepare()
        let safeDraftKey = try requireSafeSegment(draftKey, label: "自动保存标识")
        let safeArticleSlug = try articleSlug.map { try requireSafeSegment($0, label: "文章 slug") }
        let timestamp = self.timestamp(from: date)
        let snapshotJSON = try jsonString(snapshot)
        let latest = try latestArticleRevision(
            whereClause: "draft_key = ? AND reason = ?",
            values: [.text(safeDraftKey), .text(NativeArticleRevisionReason.autosave.rawValue)]
        )

        if let latest,
           let bucketStart = NativeTimestamp.date(from: latest.createdAt),
           date.timeIntervalSince(bucketStart) < Self.articleAutosaveRevisionInterval {
            try db().execute(
                """
                UPDATE article_revisions
                SET article_slug = COALESCE(?, article_slug), snapshot_json = ?, updated_at = ?
                WHERE id = ?
                """,
                values: [
                    safeArticleSlug.map(SQLiteValue.text) ?? .null,
                    .text(snapshotJSON),
                    .text(timestamp),
                    .integer(latest.id),
                ]
            )
            return NativeArticleRevision(
                id: latest.id,
                syncID: latest.syncID,
                draftKey: latest.draftKey,
                articleSlug: safeArticleSlug ?? latest.articleSlug,
                reason: .autosave,
                snapshot: snapshot,
                createdAt: latest.createdAt,
                updatedAt: timestamp
            )
        }

        let revision = try insertArticleRevision(
            draftKey: safeDraftKey,
            articleSlug: safeArticleSlug,
            reason: .autosave,
            snapshot: snapshot,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        try trimArticleRevisions(draftKey: safeDraftKey)
        return revision
    }

    public func listArticleRevisions(articleSlug: String?, draftKey: String) throws -> [NativeArticleRevision] {
        try prepare()
        let safeDraftKey = try requireSafeSegment(draftKey, label: "版本历史标识")
        var revisions: [NativeArticleRevision] = []

        if let articleSlug {
            let safeArticleSlug = try requireSafeSegment(articleSlug, label: "文章 slug")
            try db().query(
                revisionSelect + " WHERE article_slug = ? OR draft_key = ? ORDER BY updated_at DESC, id DESC",
                values: [.text(safeArticleSlug), .text(safeDraftKey)]
            ) { row in
                revisions.append(try decodeArticleRevision(row))
            }
        } else {
            try db().query(
                revisionSelect + " WHERE draft_key = ? ORDER BY updated_at DESC, id DESC",
                values: [.text(safeDraftKey)]
            ) { row in
                revisions.append(try decodeArticleRevision(row))
            }
        }
        return revisions
    }

    public func latestArticleAutosave(articleSlug: String) throws -> NativeArticleRevision? {
        try prepare()
        let safeSlug = try requireSafeSegment(articleSlug, label: "文章 slug")
        return try latestArticleRevision(
            whereClause: "article_slug = ? AND reason = ?",
            values: [.text(safeSlug), .text(NativeArticleRevisionReason.autosave.rawValue)]
        )
    }

    public func latestUnsavedArticleAutosave() throws -> NativeArticleRevision? {
        try prepare()
        return try latestArticleRevision(
            whereClause: "article_slug IS NULL AND reason = ?",
            values: [.text(NativeArticleRevisionReason.autosave.rawValue)]
        )
    }

    public func attachArticleRevisions(draftKey: String, toArticleSlug articleSlug: String) throws {
        try prepare()
        let safeDraftKey = try requireSafeSegment(draftKey, label: "版本历史标识")
        let safeSlug = try requireSafeSegment(articleSlug, label: "文章 slug")
        try db().execute(
            "UPDATE article_revisions SET article_slug = ? WHERE draft_key = ? AND article_slug IS NULL",
            values: [.text(safeSlug), .text(safeDraftKey)]
        )
    }

    public func discardArticleAutosaves(draftKey: String, newerThan timestamp: String? = nil) throws {
        try prepare()
        let safeDraftKey = try requireSafeSegment(draftKey, label: "自动保存标识")
        if let timestamp {
            try db().execute(
                "DELETE FROM article_revisions WHERE draft_key = ? AND reason = ? AND updated_at > ?",
                values: [
                    .text(safeDraftKey),
                    .text(NativeArticleRevisionReason.autosave.rawValue),
                    .text(timestamp),
                ]
            )
        } else {
            try db().execute(
                "DELETE FROM article_revisions WHERE draft_key = ? AND reason = ?",
                values: [.text(safeDraftKey), .text(NativeArticleRevisionReason.autosave.rawValue)]
            )
        }
    }

    public func listArticleComments(articleSlug: String) throws -> [NativeArticleComment] {
        try prepare()
        let safeSlug = try requireSafeSegment(articleSlug, label: "文章 slug")
        var comments: [NativeArticleComment] = []
        try db().query(
            commentSelect + " WHERE article_slug = ? ORDER BY created_at, id",
            values: [.text(safeSlug)]
        ) { row in
            comments.append(try decodeArticleComment(row))
        }
        return comments
    }

    public func createArticleComment(
        articleSlug: String,
        authorName: String,
        text: String,
        selection: NativeArticleCommentSelection? = nil,
        parentID: String? = nil,
        at date: Date = Date()
    ) throws -> NativeArticleComment {
        try prepare()
        let safeSlug = try requireSafeSegment(articleSlug, label: "文章 slug")
        guard try storedArticle(withSlug: safeSlug) != nil else { throw NativeStoreError.notFound }

        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty, normalizedText.count <= 2_000 else {
            throw NativeStoreError.invalidComment
        }
        let normalizedAuthor = String(
            authorName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)
        )
        guard !normalizedAuthor.isEmpty else { throw NativeStoreError.invalidComment }

        let safeParentID = try parentID.map { try requireSafeSegment($0, label: "父评论标识") }
        if let safeParentID {
            let parentCount = try db().integer(
                "SELECT COUNT(*) FROM article_comments WHERE id = ? AND article_slug = ?",
                values: [.text(safeParentID), .text(safeSlug)]
            ) ?? 0
            guard parentCount == 1 else { throw NativeStoreError.notFound }
        }

        let normalizedSelection = selection.flatMap { value -> NativeArticleCommentSelection? in
            let quote = value.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !quote.isEmpty else { return nil }
            let anchor = (try? requireSafeSegment(value.anchorID, label: "评论锚点"))
                ?? NativeArticleCommentAnchor.articleTopID
            return NativeArticleCommentSelection(quote: String(quote.prefix(800)), anchorID: anchor)
        }
        let id = UUID().uuidString.lowercased()
        let createdAt = timestamp(from: date)
        let comment = NativeArticleComment(
            id: id,
            articleSlug: safeSlug,
            parentID: safeParentID,
            authorName: normalizedAuthor,
            text: normalizedText,
            selection: normalizedSelection,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        try db().execute(
            """
            INSERT INTO article_comments(
                id, article_slug, parent_id, author_name, text,
                quoted_text, anchor_id, created_at, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            values: [
                .text(comment.id),
                .text(comment.articleSlug),
                comment.parentID.map(SQLiteValue.text) ?? .null,
                .text(comment.authorName),
                .text(comment.text),
                comment.selection.map { .text($0.quote) } ?? .null,
                comment.selection.map { .text($0.anchorID) } ?? .null,
                .text(comment.createdAt),
                .text(comment.updatedAt),
            ]
        )
        return comment
    }

    public func deleteArticleComment(id: String, articleSlug: String) throws {
        try prepare()
        let safeID = try requireSafeSegment(id, label: "评论标识")
        let safeSlug = try requireSafeSegment(articleSlug, label: "文章 slug")
        let existingCount = try db().integer(
            "SELECT COUNT(*) FROM article_comments WHERE id = ? AND article_slug = ?",
            values: [.text(safeID), .text(safeSlug)]
        ) ?? 0
        guard existingCount == 1 else { throw NativeStoreError.notFound }
        var removedIDs: [String] = []
        try db().query(
            """
            WITH RECURSIVE removed(id) AS (
                SELECT id FROM article_comments WHERE id = ? AND article_slug = ?
                UNION ALL
                SELECT child.id FROM article_comments AS child
                JOIN removed AS parent ON child.parent_id = parent.id
            )
            SELECT id FROM removed
            """,
            values: [.text(safeID), .text(safeSlug)]
        ) { row in
            if let id = row.text(at: 0) { removedIDs.append(id) }
        }
        try db().execute(
            "DELETE FROM article_comments WHERE id = ? AND article_slug = ?",
            values: [.text(safeID), .text(safeSlug)]
        )
        for removedID in removedIDs {
            try recordPortableSidecarTombstone(kind: "comment", id: removedID)
        }
    }

    func purgeExpiredArticleRevisions() throws {
        let cutoff = timestamp(
            from: Date().addingTimeInterval(-TimeInterval(Self.articleRevisionRetentionDays) * 24 * 60 * 60)
        )
        try db().execute(
            "DELETE FROM article_revisions WHERE updated_at < ?",
            values: [.text(cutoff)]
        )
        try db().execute("""
        DELETE FROM article_revisions
        WHERE id NOT IN (
            SELECT id FROM article_revisions ORDER BY updated_at DESC, id DESC LIMIT 5000
        )
        """)
    }

    func trimArticleRevisions(draftKey: String) throws {
        try db().execute(
            """
            DELETE FROM article_revisions
            WHERE draft_key = ? AND id NOT IN (
                SELECT id FROM article_revisions
                WHERE draft_key = ?
                ORDER BY updated_at DESC, id DESC
                LIMIT ?
            )
            """,
            values: [
                .text(draftKey),
                .text(draftKey),
                .integer(Self.maximumArticleRevisionsPerDraft),
            ]
        )
    }

    func insertArticleRevision(
        draftKey: String,
        articleSlug: String?,
        reason: NativeArticleRevisionReason,
        snapshot: NativeArticleRevisionSnapshot,
        createdAt: String,
        updatedAt: String,
        syncID: String = UUID().uuidString.lowercased()
    ) throws -> NativeArticleRevision {
        try db().execute(
            """
            INSERT INTO article_revisions(
                sync_id, draft_key, article_slug, reason, snapshot_json, created_at, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?)
            """,
            values: [
                .text(syncID),
                .text(draftKey),
                articleSlug.map(SQLiteValue.text) ?? .null,
                .text(reason.rawValue),
                .text(try jsonString(snapshot)),
                .text(createdAt),
                .text(updatedAt),
            ]
        )
        guard let id = try db().integer("SELECT last_insert_rowid()") else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("SQLite：无法读取文章版本编号"))
        }
        return NativeArticleRevision(
            id: id,
            syncID: syncID,
            draftKey: draftKey,
            articleSlug: articleSlug,
            reason: reason,
            snapshot: snapshot,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func latestArticleRevision(
        whereClause: String,
        values: [SQLiteValue]
    ) throws -> NativeArticleRevision? {
        var revision: NativeArticleRevision?
        try db().query(
            revisionSelect + " WHERE \(whereClause) ORDER BY updated_at DESC, id DESC LIMIT 1",
            values: values
        ) { row in
            revision = try decodeArticleRevision(row)
        }
        return revision
    }
}
