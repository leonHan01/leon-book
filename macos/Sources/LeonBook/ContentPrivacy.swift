import Foundation

/// One in-memory mode shared by the interactive windows. Other store clients
/// use the default visibility unless they explicitly opt in for a mobile sync.
final class NativeContentPrivacy: @unchecked Sendable {
    static let shared = NativeContentPrivacy()
    @TaskLocal static var includesPrivateForSync = false

    private let lock = NSLock()
    private var enabled = false

    var isEnabled: Bool { lock.withLock { enabled } }

    func setEnabled(_ value: Bool) {
        lock.withLock { enabled = value }
    }
}

extension LocalBlogStore {
    var showsPrivateContent: Bool {
        contentPrivacy?.isEnabled == true || NativeContentPrivacy.includesPrivateForSync
    }

    func permitsContent(isPrivate: Bool) -> Bool {
        !isPrivate || showsPrivateContent
    }

    func requireVisibleArticleContext(slug: String) throws {
        if !showsPrivateContent,
           try db().integer("SELECT is_private FROM articles WHERE slug = ?", values: [.text(slug)]) == 1 {
            throw NativeStoreError.notFound
        }
    }

    func setArticlePrivacy(slug: String, isPrivate: Bool, expectedUpdatedAt: String) throws -> NativeArticle {
        let article = try getArticle(slug: slug)
        guard article.updatedAt == expectedUpdatedAt else { throw NativeStoreError.conflict }
        guard !markdownWorkspaceSource.mode.isReadOnly else {
            // A mounted, read-only source keeps its metadata on disk. Store
            // visibility in the workspace database across source refreshes.
            try db().execute("""
            UPDATE articles SET is_private = ?, privacy_override = ?, updated_at = ?
            WHERE slug = ? AND updated_at = ? AND deleted_at IS NULL
            """, values: [.integer(isPrivate ? 1 : 0), .integer(isPrivate ? 1 : 0),
                         .text(nextTimestamp(after: article.updatedAt)), .text(slug), .text(expectedUpdatedAt)])
            guard try db().integer("SELECT changes()") == 1,
                  let updated = try storedArticle(withSlug: slug) else { throw NativeStoreError.conflict }
            markJSONBackupNeedsRebuild()
            return updated
        }
        return try saveArticle(.init(
            banner: article.banner, body: article.body, category: article.category, excerpt: article.excerpt,
            media: article.media, slug: slug, status: article.status, tags: article.tags, title: article.title,
            expectedUpdatedAt: expectedUpdatedAt, properties: article.properties, isPrivate: isPrivate
        ))
    }

    func privateContentIDs() throws -> (articles: Set<String>, moments: Set<String>, questions: Set<String>) {
        try prepare()
        var ids = [String: Set<String>]()
        try db().query("""
        SELECT 'article', slug FROM articles WHERE is_private = 1
        UNION ALL SELECT 'moment', id FROM moments WHERE is_private = 1
        UNION ALL SELECT 'question', id FROM questions WHERE is_private = 1
        """) { row in
            if let kind = row.text(at: 0), let id = row.text(at: 1) { ids[kind, default: []].insert(id) }
        }
        return (ids["article", default: []], ids["moment", default: []], ids["question", default: []])
    }

    func hiddenMediaPaths(matching path: String? = nil) throws -> Set<String> {
        guard !showsPrivateContent else { return [] }
        var hidden = Set<String>()
        try db().query("""
        SELECT ref.normalized_url
        FROM media_references AS ref
        LEFT JOIN articles AS a ON ref.owner_type = 'article' AND a.slug = ref.owner_id
        LEFT JOIN moments AS m ON ref.owner_type = 'moment' AND m.id = ref.owner_id
        LEFT JOIN question_answers AS answer ON ref.owner_type = 'answer' AND answer.id = ref.owner_id
        LEFT JOIN questions AS q ON q.id = answer.question_id
        \(path == nil ? "" : "WHERE ref.normalized_url = ?")
        GROUP BY ref.normalized_url
        HAVING MIN(COALESCE(a.is_private, m.is_private, q.is_private, 0)) = 1
        """, values: path.map { [.text(normalizeMediaURL($0))] } ?? [], checkingCancellation: true) { row in
            if let url = row.text(at: 0) { hidden.insert(url) }
        }
        return hidden
    }

    func contentVisibility(_ column: String = "is_private") -> String {
        showsPrivateContent ? "1" : "\(column) = 0"
    }
}
