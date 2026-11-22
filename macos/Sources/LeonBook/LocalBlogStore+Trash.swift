import Foundation

extension LocalBlogStore {
    // MARK: - Trash

    func listTrash() throws -> [NativeTrashItem] {
        try prepare()
        var items: [NativeTrashItem] = []

        try db().query("""
        SELECT slug, title, excerpt, deleted_at, delete_expires_at
        FROM articles
        WHERE deleted_at IS NOT NULL AND delete_expires_at IS NOT NULL AND \(contentVisibility())
        """) { row in
            guard let slug = row.text(at: 0),
                  let title = row.text(at: 1),
                  let excerpt = row.text(at: 2),
                  let deletedAt = row.text(at: 3),
                  let expiresAt = row.text(at: 4) else {
                throw NativeStoreError.fileSystem(NativeLocalization.text("SQLite：回收站文章记录不完整"))
            }
            items.append(NativeTrashItem(
                kind: .article,
                key: slug,
                title: title,
                preview: excerpt,
                deletedAt: deletedAt,
                expiresAt: expiresAt
            ))
        }

        try db().query("""
        SELECT id, text, images_json, deleted_at, delete_expires_at
        FROM moments
        WHERE deleted_at IS NOT NULL AND delete_expires_at IS NOT NULL AND \(contentVisibility())
        """) { row in
            guard let id = row.text(at: 0),
                  let text = row.text(at: 1),
                  let imagesJSON = row.text(at: 2),
                  let deletedAt = row.text(at: 3),
                  let expiresAt = row.text(at: 4) else {
                throw NativeStoreError.fileSystem(NativeLocalization.text("SQLite：回收站微博记录不完整"))
            }
            let images: [NativeMedia] = try decode(imagesJSON)
            let preview = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "\(images.count) 张图片"
                : text
            items.append(NativeTrashItem(
                kind: .moment,
                key: id,
                title: "微博",
                preview: preview,
                deletedAt: deletedAt,
                expiresAt: expiresAt
            ))
        }

        return items.sorted { $0.deletedAt > $1.deletedAt }
    }

    func restoreTrash(_ item: NativeTrashItem) throws {
        try prepare()
        let safeKey = try requireSafeSegment(item.key, label: item.kind == .article ? "文章 slug" : "微博 ID")
        switch item.kind {
        case .article:
            try requireWritableArticleSource()
            guard let restoring = try storedArticle(withSlug: safeKey, includingDeleted: true),
                  permitsContent(isPrivate: restoring.isPrivate) else {
                throw NativeStoreError.notFound
            }
            try db().transaction {
                try db().execute(
                    "UPDATE articles SET deleted_at = NULL, delete_expires_at = NULL WHERE slug = ? AND deleted_at IS NOT NULL",
                    values: [.text(safeKey)]
                )
                try db().execute(
                    "DELETE FROM article_link_references WHERE source_slug = ?",
                    values: [.text(safeKey)]
                )
                try insertArticleLinkReferences(
                    sourceSlug: safeKey,
                    body: restoring.body,
                    into: db()
                )
                try replaceArticleFilterIndexes(restoring, isActive: true, in: db())
                try replaceShortSearchDocument(
                    type: "article",
                    id: restoring.slug,
                    source: articleSearchSource(restoring),
                    isActive: true,
                    in: db()
                )
            }
            if let restored = try storedArticle(withSlug: safeKey) {
                try? writeArticleSidecars(restored)
            }
            try rebuildIndex()
            try writeTrashBackup()
            markJSONBackupNeedsRebuild()
        case .moment:
            guard let restoring = try moment(withID: safeKey, includingDeleted: true),
                  permitsContent(isPrivate: restoring.isPrivate) else {
                throw NativeStoreError.notFound
            }
            try db().transaction {
                try db().execute(
                    "UPDATE moments SET deleted_at = NULL, delete_expires_at = NULL WHERE id = ? AND deleted_at IS NOT NULL",
                    values: [.text(safeKey)]
                )
                try replaceShortSearchDocument(
                    type: "moment",
                    id: restoring.id,
                    source: [restoring.text, restoring.tags.joined(separator: " "), restoring.createdAt],
                    isActive: true,
                    in: db()
                )
            }
            if let restored = try moment(withID: safeKey) {
                try writeMomentSidecar(restored)
            }
            try writeTrashBackup()
        }
    }

    func permanentlyDeleteTrash(_ item: NativeTrashItem) throws {
        try prepare()
        let safeKey = try requireSafeSegment(item.key, label: item.kind == .article ? "文章 slug" : "微博 ID")
        switch item.kind {
        case .article:
            try requireWritableArticleSource()
            guard let article = try storedArticle(withSlug: safeKey, includingDeleted: true),
                  try db().text("SELECT deleted_at FROM articles WHERE slug = ? AND \(contentVisibility())", values: [.text(safeKey)]) != nil else {
                throw NativeStoreError.notFound
            }
            try MarkdownArticleSource.remove(relativePath: article.sourceRelativePath, in: articlesURL)
            try db().transaction {
                try db().execute("DELETE FROM articles WHERE slug = ? AND deleted_at IS NOT NULL", values: [.text(safeKey)])
                try db().execute(
                    "DELETE FROM article_revisions WHERE article_slug = ? OR draft_key = ?",
                    values: [.text(safeKey), .text(safeKey)]
                )
            }
            removeArticleFiles(for: safeKey)
            try rebuildIndex()
            try writeTrashBackup()
        case .moment:
            guard let moment = try moment(withID: safeKey, includingDeleted: true),
                  try db().text("SELECT deleted_at FROM moments WHERE id = ? AND \(contentVisibility())", values: [.text(safeKey)]) != nil else {
                throw NativeStoreError.notFound
            }
            try db().execute("DELETE FROM moments WHERE id = ? AND deleted_at IS NOT NULL", values: [.text(safeKey)])
            try removeUnreferencedMomentImages(moment.images, includingDeleted: true)
            removeMomentSidecar(id: safeKey)
            try writeTrashBackup()
        }
    }

    func emptyTrash() throws {
        try prepare()
        var articlesToDelete: [(slug: String, sourcePath: String)] = []
        var momentsToDelete: [(id: String, images: [NativeMedia])] = []
        let visibility = contentVisibility()

        try db().query("SELECT slug, source_relative_path FROM articles WHERE deleted_at IS NOT NULL AND \(visibility)") { row in
            if let slug = row.text(at: 0) {
                articlesToDelete.append((slug, row.text(at: 1) ?? "\(slug).md"))
            }
        }
        try db().query("SELECT id, images_json FROM moments WHERE deleted_at IS NOT NULL AND \(visibility)") { row in
            guard let id = row.text(at: 0), let imagesJSON = row.text(at: 1) else { return }
            momentsToDelete.append((id: id, images: try decode(imagesJSON)))
        }

        try db().transaction {
            try db().execute("DELETE FROM articles WHERE deleted_at IS NOT NULL AND \(visibility)")
            try db().execute("DELETE FROM moments WHERE deleted_at IS NOT NULL AND \(visibility)")
            for article in articlesToDelete {
                try db().execute(
                    "DELETE FROM article_revisions WHERE article_slug = ? OR draft_key = ?",
                    values: [.text(article.slug), .text(article.slug)]
                )
            }
        }
        for article in articlesToDelete {
            removeArticleFiles(for: article.slug, sourceRelativePath: article.sourcePath)
        }
        for moment in momentsToDelete {
            try removeUnreferencedMomentImages(moment.images, includingDeleted: true)
            removeMomentSidecar(id: moment.id)
        }
        try rebuildIndex()
        try writeTrashBackup()
    }

    func purgeExpiredTrash() throws {
        let now = timestamp(from: Date())
        var articlesToDelete: [(slug: String, sourcePath: String)] = []
        var momentsToDelete: [(id: String, images: [NativeMedia])] = []

        try db().query(
            "SELECT slug, source_relative_path FROM articles WHERE deleted_at IS NOT NULL AND delete_expires_at <= ?",
            values: [.text(now)]
        ) { row in
            if let slug = row.text(at: 0) {
                articlesToDelete.append((slug, row.text(at: 1) ?? "\(slug).md"))
            }
        }
        try db().query(
            "SELECT id, images_json FROM moments WHERE deleted_at IS NOT NULL AND delete_expires_at <= ?",
            values: [.text(now)]
        ) { row in
            guard let id = row.text(at: 0), let imagesJSON = row.text(at: 1) else { return }
            momentsToDelete.append((id: id, images: try decode(imagesJSON)))
        }
        guard !articlesToDelete.isEmpty || !momentsToDelete.isEmpty else { return }

        try db().transaction {
            try db().execute(
                "DELETE FROM articles WHERE deleted_at IS NOT NULL AND delete_expires_at <= ?",
                values: [.text(now)]
            )
            try db().execute(
                "DELETE FROM moments WHERE deleted_at IS NOT NULL AND delete_expires_at <= ?",
                values: [.text(now)]
            )
            for article in articlesToDelete {
                try db().execute(
                    "DELETE FROM article_revisions WHERE article_slug = ? OR draft_key = ?",
                    values: [.text(article.slug), .text(article.slug)]
                )
            }
        }
        for article in articlesToDelete {
            removeArticleFiles(for: article.slug, sourceRelativePath: article.sourcePath)
        }
        for moment in momentsToDelete {
            try removeUnreferencedMomentImages(moment.images, includingDeleted: true)
            removeMomentSidecar(id: moment.id)
        }
        try rebuildIndex()
        try writeTrashBackup()
    }
}
