import Foundation

public struct NativeMomentComment: Codable, Hashable, Identifiable {
    public let id: String
    public let momentID: String
    public let parentID: String?
    public let authorName: String
    public let text: String
    public let createdAt: String
}

extension LocalBlogStore {
    public func listMomentComments(momentID: String) throws -> [NativeMomentComment] {
        try prepare()
        let safeID = try requireActiveCommentMoment(momentID)
        var comments: [NativeMomentComment] = []
        try db().query(
            """
            SELECT id, moment_id, parent_id, author_name, text, created_at
            FROM moment_comments WHERE moment_id = ? ORDER BY created_at, id
            """,
            values: [.text(safeID)]
        ) { row in
            guard let id = row.text(at: 0), let momentID = row.text(at: 1),
                  let author = row.text(at: 3), let text = row.text(at: 4),
                  let createdAt = row.text(at: 5) else {
                throw NativeStoreError.fileSystem(NativeLocalization.text("SQLite：微博评论记录不完整"))
            }
            comments.append(NativeMomentComment(
                id: id, momentID: momentID, parentID: row.text(at: 2),
                authorName: author, text: text, createdAt: createdAt
            ))
        }
        return comments
    }

    public func createMomentComment(
        momentID: String,
        authorName: String,
        text: String,
        parentID: String? = nil,
        at date: Date = Date()
    ) throws -> NativeMomentComment {
        try prepare()
        let safeID = try requireSafeSegment(momentID, label: "微博 ID")
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = String(authorName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !normalizedText.isEmpty, normalizedText.count <= 2_000, !author.isEmpty else {
            throw NativeStoreError.invalidComment
        }
        let safeParentID = try parentID.map { try requireSafeSegment($0, label: "父评论标识") }
        let id = UUID().uuidString.lowercased()
        var createdAt = NativeTimestamp.string(from: date)
        try db().transaction {
            _ = try requireActiveCommentMoment(safeID)
            if let safeParentID {
                guard try db().integer(
                    "SELECT COUNT(*) FROM moment_comments WHERE id = ? AND moment_id = ?",
                    values: [.text(safeParentID), .text(safeID)]
                ) == 1 else { throw NativeStoreError.notFound }
            }
            // Keep replies after their parents even when two windows submit
            // within the same millisecond.
            if let latest = try db().text(
                "SELECT created_at FROM moment_comments WHERE moment_id = ? ORDER BY created_at DESC LIMIT 1",
                values: [.text(safeID)]
            ), createdAt <= latest, let latestDate = NativeTimestamp.date(from: latest) {
                createdAt = NativeTimestamp.string(from: latestDate.addingTimeInterval(0.001))
            }
            try db().execute(
                """
                INSERT INTO moment_comments(id, moment_id, parent_id, author_name, text, created_at)
                VALUES(?, ?, ?, ?, ?, ?)
                """,
                values: [
                    .text(id), .text(safeID), safeParentID.map(SQLiteValue.text) ?? .null,
                    .text(author), .text(normalizedText), .text(createdAt),
                ]
            )
        }
        return NativeMomentComment(
            id: id, momentID: safeID, parentID: safeParentID,
            authorName: author, text: normalizedText,
            createdAt: createdAt
        )
    }

    public func deleteMomentComment(id: String, momentID: String) throws {
        try prepare()
        let safeMomentID = try requireActiveCommentMoment(momentID)
        let safeID = try requireSafeSegment(id, label: "评论标识")
        guard try db().integer(
            "SELECT COUNT(*) FROM moment_comments WHERE id = ? AND moment_id = ?",
            values: [.text(safeID), .text(safeMomentID)]
        ) == 1 else { throw NativeStoreError.notFound }
        try db().execute(
            "DELETE FROM moment_comments WHERE id = ? AND moment_id = ?",
            values: [.text(safeID), .text(safeMomentID)]
        )
    }

    private func requireActiveCommentMoment(_ id: String) throws -> String {
        let safeID = try requireSafeSegment(id, label: "微博 ID")
        guard try db().integer(
            "SELECT COUNT(*) FROM moments WHERE id = ? AND deleted_at IS NULL",
            values: [.text(safeID)]
        ) == 1 else { throw NativeStoreError.notFound }
        return safeID
    }
}

extension NativeAppModel {
    func createMomentComment(momentID: String, text: String, parentID: String?) async throws {
        guard storageReady, !isSavingMomentComment, !isBackingUp,
              !isRestoringBackup, !isSwitchingWorkspace else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("请等待当前资料库操作完成后再评论。"))
        }
        isSavingMomentComment = true
        defer { isSavingMomentComment = false }
        _ = try await store.createMomentComment(
            momentID: momentID, authorName: currentUser.name, text: text, parentID: parentID
        )
        scheduleBackup()
    }

    func deleteMomentComment(_ comment: NativeMomentComment) async throws {
        guard storageReady, !isSavingMomentComment, !isBackingUp,
              !isRestoringBackup, !isSwitchingWorkspace,
              comment.authorName == currentUser.name else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("当前无法删除这条评论。"))
        }
        isSavingMomentComment = true
        defer { isSavingMomentComment = false }
        try await store.deleteMomentComment(id: comment.id, momentID: comment.momentID)
        scheduleBackup()
    }

    func updateMomentCommentCount(momentID: String, count: Int) {
        guard let index = moments.firstIndex(where: { $0.id == momentID }),
              moments[index].commentCount != count else { return }
        moments[index].commentCount = count
    }
}
