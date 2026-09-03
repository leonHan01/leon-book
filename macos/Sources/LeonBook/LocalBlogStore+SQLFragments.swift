import Foundation

extension LocalBlogStore {
    var articleSelect: String {
        "SELECT slug, title, body, category, excerpt, banner_json, media_json, status, tags_json, updated_at, published_at, word_count, page_views, deleted_at, delete_expires_at, properties_json, source_relative_path, source_content_hash, source_imported_at FROM articles"
    }

    func qualifiedArticleSelect(_ alias: String) -> String {
        let columns = [
            "slug", "title", "body", "category", "excerpt", "banner_json", "media_json", "status",
            "tags_json", "updated_at", "published_at", "word_count", "page_views", "deleted_at",
            "delete_expires_at", "properties_json", "source_relative_path", "source_content_hash",
            "source_imported_at",
        ].map { "\(alias).\($0)" }.joined(separator: ", ")
        return "SELECT \(columns) FROM articles AS \(alias)"
    }

    var articleSummarySelect: String {
        "SELECT slug, title, category, excerpt, banner_json, status, tags_json, updated_at, published_at, word_count, page_views, properties_json, source_relative_path FROM articles"
    }

    func qualifiedArticleSummarySelect(_ alias: String) -> String {
        let columns = [
            "slug", "title", "category", "excerpt", "banner_json", "status", "tags_json", "updated_at",
            "published_at", "word_count", "page_views", "properties_json", "source_relative_path",
        ].map { "\(alias).\($0)" }.joined(separator: ", ")
        return "SELECT \(columns) FROM articles AS \(alias)"
    }

    var momentSelect: String {
        "SELECT id, created_at, updated_at, text, text_runs_json, images_json, tags_json, is_favorite, deleted_at, delete_expires_at FROM moments"
    }

    var questionSelect: String {
        """
        SELECT q.id, q.title, q.body, q.tags_json, q.created_at, q.updated_at,
               (SELECT COUNT(*) FROM question_answers AS a WHERE a.question_id = q.id)
        FROM questions AS q
        """
    }

    var questionAnswerSelect: String {
        "SELECT id, question_id, body, images_json, created_at, updated_at FROM question_answers"
    }

    var revisionSelect: String {
        "SELECT id, sync_id, draft_key, article_slug, reason, snapshot_json, created_at, updated_at FROM article_revisions"
    }

    var commentSelect: String {
        "SELECT id, article_slug, parent_id, author_name, text, quoted_text, anchor_id, created_at, updated_at FROM article_comments"
    }

    func decodeArticleComment(_ row: SQLiteRow) throws -> NativeArticleComment {
        guard let id = row.text(at: 0),
              let articleSlug = row.text(at: 1),
              let authorName = row.text(at: 3),
              let text = row.text(at: 4),
              let createdAt = row.text(at: 7),
              let updatedAt = row.text(at: 8) else {
            throw NativeStoreError.fileSystem("SQLite：文章评论记录不完整")
        }
        let selection: NativeArticleCommentSelection?
        if let quote = row.text(at: 5), let anchorID = row.text(at: 6) {
            selection = NativeArticleCommentSelection(quote: quote, anchorID: anchorID)
        } else {
            selection = nil
        }
        return NativeArticleComment(
            id: id,
            articleSlug: articleSlug,
            parentID: row.text(at: 2),
            authorName: authorName,
            text: text,
            selection: selection,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

struct NativeActivityEvent: Codable, Equatable {
    let type: String
    let createdAt: String
}

struct NativeTrashedArticle: Codable, Equatable {
    let article: NativeArticle
    let deletedAt: String
    let expiresAt: String
}

struct NativeTrashedMoment: Codable, Equatable {
    let moment: NativeMoment
    let deletedAt: String
    let expiresAt: String
}

struct NativeTrashBackup: Codable, Equatable {
    let articles: [NativeTrashedArticle]
    let moments: [NativeTrashedMoment]
}
