import Foundation

extension LocalBlogStore {
    // MARK: - Markdown workspace

    public func markdownWorkspaceSourceState() throws -> NativeMarkdownWorkspaceSource {
        try prepare()
        return markdownWorkspaceSource
    }

    public func markdownSourceDirectoryURL() throws -> URL {
        try prepare()
        return articlesURL
    }

    /// Changes only the authoritative Markdown root. Structured data and app
    /// support files remain under `rootURL` for every mode.
    @discardableResult
    public func configureMarkdownWorkspaceSource(
        mode: NativeMarkdownWorkspaceMode,
        directoryURL: URL? = nil
    ) throws -> NativeMarkdownSyncResult {
        try prepare()
        let nextSource: NativeMarkdownWorkspaceSource
        if mode.isMounted {
            guard let directoryURL else {
                throw NativeStoreError.fileSystem(NativeLocalization.text("挂载模式需要选择 Markdown 文件夹"))
            }
            let resolved = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
            try validateMarkdownSourceDirectory(resolved, requiresWriteAccess: !mode.isReadOnly)
            nextSource = NativeMarkdownWorkspaceSource(mode: mode, directoryPath: resolved.path)
        } else {
            nextSource = .managed
        }
        guard nextSource != markdownWorkspaceSource else { return try refreshMarkdownSources() }

        let previousSource = markdownWorkspaceSource
        markdownWorkspaceSource = nextSource
        do {
            try persistMarkdownWorkspaceSource()
        } catch {
            markdownWorkspaceSource = previousSource
            try? persistMarkdownWorkspaceSource()
            throw error
        }
        defer {
            NotificationCenter.default.post(name: .leonBookMarkdownConfigurationChanged, object: rootURL)
        }
        return try refreshMarkdownSources(restoringDeletedSources: true)
    }

    static func loadMarkdownWorkspaceSource(from rootURL: URL) -> NativeMarkdownWorkspaceSource {
        let url = rootURL.appendingPathComponent("markdown-source.json")
        guard let data = try? Data(contentsOf: url),
              let source = try? JSONDecoder().decode(NativeMarkdownWorkspaceSource.self, from: data),
              source.mode.isMounted == (source.directoryPath != nil) else {
            return .managed
        }
        return source
    }

    func reloadMarkdownWorkspaceSource() throws {
        guard FileManager.default.fileExists(atPath: markdownWorkspaceSourceURL.path) else {
            markdownWorkspaceSource = .managed
            return
        }
        do {
            let source = try JSONDecoder().decode(
                NativeMarkdownWorkspaceSource.self,
                from: Data(contentsOf: markdownWorkspaceSourceURL)
            )
            guard source.mode.isMounted == (source.directoryPath != nil) else {
                throw NativeStoreError.fileSystem(NativeLocalization.text("Markdown 工作区配置无效"))
            }
            markdownWorkspaceSource = source
        } catch {
            throw NativeStoreError.fileSystem(NativeLocalization.text("无法读取 Markdown 工作区配置：\(error.localizedDescription)"))
        }
    }

    private func persistMarkdownWorkspaceSource() throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(markdownWorkspaceSource)
                .write(to: markdownWorkspaceSourceURL, options: .atomic)
        } catch {
            throw NativeStoreError.fileSystem(NativeLocalization.text("无法保存 Markdown 工作区配置：\(error.localizedDescription)"))
        }
    }

    func validateMarkdownSourceDirectory(
        _ url: URL,
        requiresWriteAccess: Bool
    ) throws {
        var isDirectory: ObjCBool = false
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("Markdown 文件夹不存在：\(url.path)"))
        }
        guard fileManager.isReadableFile(atPath: url.path) else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("没有 Markdown 文件夹的读取权限：\(url.path)"))
        }
        if requiresWriteAccess, !fileManager.isWritableFile(atPath: url.path) {
            throw NativeStoreError.fileSystem(NativeLocalization.text("没有 Markdown 文件夹的写入权限：\(url.path)"))
        }
    }

    func requireWritableArticleSource() throws {
        try reloadMarkdownWorkspaceSource()
        guard !markdownWorkspaceSource.mode.isReadOnly else {
            throw NativeStoreError.readOnlyArticleSource
        }
    }

    public func listArticles(includeDrafts: Bool = true) throws -> [NativeArticleSummary] {
        try prepare()
        let sql = """
        \(articleSummarySelect)
        WHERE deleted_at IS NULL AND \(contentVisibility())
        \(includeDrafts ? "" : "AND status = 'published'")
        ORDER BY updated_at DESC
        """
        var articles: [NativeArticleSummary] = []
        try db().query(sql) { row in
            articles.append(try decodeArticleSummary(row))
        }
        return articles
    }

    func listArticleSummaries(slugs: [String]) throws -> [NativeArticleSummary] {
        try prepare()
        let uniqueSlugs = Array(Set(slugs))
        guard !uniqueSlugs.isEmpty else { return [] }
        var articles: [NativeArticleSummary] = []
        for start in stride(from: 0, to: uniqueSlugs.count, by: 200) {
            let chunk = Array(uniqueSlugs[start..<min(start + 200, uniqueSlugs.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            try db().query("""
            \(articleSummarySelect)
            WHERE deleted_at IS NULL AND \(contentVisibility()) AND slug IN (\(placeholders))
            """, values: chunk.map(SQLiteValue.text)) { row in
                articles.append(try decodeArticleSummary(row))
            }
        }
        return articles
    }

    /// Reconciles ordinary Markdown files into SQLite-derived indexes. Paths are
    /// matched first, then stable frontmatter slugs, then content hashes so an
    /// external filesystem rename does not change the article identity.
    @discardableResult
    public func refreshMarkdownSources() throws -> NativeMarkdownSyncResult {
        try refreshMarkdownSources(restoringDeletedSources: markdownWorkspaceSource.mode.isMounted)
    }

    private func refreshMarkdownSources(
        restoringDeletedSources: Bool
    ) throws -> NativeMarkdownSyncResult {
        try prepare()
        let records = try MarkdownArticleSource.scan(in: articlesURL)
        if restoringDeletedSources {
            try restoreDeletedArticlesPresentInSelectedSource(records)
        }
        let activeArticles = try allArticles()
        let deletedIdentities = try deletedArticleSourceIdentities()
        return try reconcileMarkdownSources(
            records: records,
            activeArticles: activeArticles,
            knownSlugs: try storedArticleSlugs(),
            deletedSlugs: deletedIdentities.slugs,
            deletedPaths: deletedIdentities.paths,
            affectedPaths: nil
        )
    }

    /// Reconciles only paths reported by the filesystem event stream. Existing
    /// directory paths are scanned recursively, while deleted paths are matched
    /// against SQLite without rereading unrelated Markdown files.
    @discardableResult
    public func refreshMarkdownSources(
        changedRelativePaths: Set<String>,
        changedDirectoryPrefixes: Set<String> = []
    ) throws -> NativeMarkdownSyncResult {
        try prepare()
        let paths = try Set(changedRelativePaths.map(MarkdownArticleSource.validatedRelativePath))
        let directories = try Set(
            changedDirectoryPrefixes.map(MarkdownArticleSource.validatedRelativeDirectoryPath)
        )
        if directories.contains("") { return try refreshMarkdownSources() }
        guard !paths.isEmpty || !directories.isEmpty else { return NativeMarkdownSyncResult() }

        var recordsByPath: [String: MarkdownArticleSourceRecord] = [:]
        for path in paths {
            if let record = try MarkdownArticleSource.readIfPresent(
                relativePath: path,
                in: articlesURL
            ) {
                recordsByPath[record.relativePath] = record
            }
        }
        for directory in directories {
            for record in try MarkdownArticleSource.scan(in: articlesURL, beneath: directory) {
                recordsByPath[record.relativePath] = record
            }
        }
        let records = recordsByPath.values.sorted {
            $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending
        }
        if markdownWorkspaceSource.mode.isMounted {
            try restoreDeletedArticlesPresentInSelectedSource(records)
        }
        let candidates = try markdownSyncCandidates(
            records: records,
            changedPaths: paths,
            changedDirectories: directories
        )
        let deletedIdentities = try deletedArticleSourceIdentities()
        let affectedPaths: (String) -> Bool = { path in
            paths.contains(path) || directories.contains { path.hasPrefix($0 + "/") }
        }
        return try reconcileMarkdownSources(
            records: records,
            activeArticles: candidates,
            knownSlugs: try storedArticleSlugs(),
            deletedSlugs: deletedIdentities.slugs,
            deletedPaths: deletedIdentities.paths,
            affectedPaths: affectedPaths
        )
    }

    private func reconcileMarkdownSources(
        records: [MarkdownArticleSourceRecord],
        activeArticles: [NativeArticle],
        knownSlugs initialKnownSlugs: Set<String>,
        deletedSlugs: Set<String>,
        deletedPaths: Set<String>,
        affectedPaths: ((String) -> Bool)?
    ) throws -> NativeMarkdownSyncResult {
        let scannedPaths = Set(records.map(\.relativePath))

        var byPath = Dictionary(uniqueKeysWithValues: activeArticles.map { ($0.sourceRelativePath, $0) })
        let bySlug = Dictionary(uniqueKeysWithValues: activeArticles.map { ($0.slug, $0) })
        var byHash: [String: [NativeArticle]] = [:]
        for article in activeArticles {
            if let hash = article.sourceContentHash { byHash[hash, default: []].append(article) }
        }

        var matchedSlugs = Set<String>()
        var knownSlugs = initialKnownSlugs
        var insertedCount = 0
        var updatedCount = 0
        var movedCount = 0
        var unchangedCount = 0
        var warnings: [String] = []
        var changes: [(previous: NativeArticle?, updated: NativeArticle)] = []
        var sourceMoves: [(oldPath: String, newPath: String)] = []

        for record in records {
            if deletedPaths.contains(record.relativePath)
                || record.slug.map(deletedSlugs.contains) == true {
                warnings.append(NativeLocalization.text("\(record.relativePath)：对应文章仍在回收站，已跳过"))
                continue
            }

            let hashMatch = byHash[record.contentHash]?.filter { article in
                !matchedSlugs.contains(article.slug)
                    && !FileManager.default.fileExists(
                        atPath: articlesURL.appendingPathComponent(article.sourceRelativePath).path
                    )
            }
            let slugMatch = record.slug.flatMap { bySlug[$0] }.flatMap {
                !matchedSlugs.contains($0.slug)
                    && !FileManager.default.fileExists(
                        atPath: articlesURL.appendingPathComponent($0.sourceRelativePath).path
                    ) ? $0 : nil
            }
            let matched = byPath[record.relativePath].flatMap {
                matchedSlugs.contains($0.slug) ? nil : $0
            } ?? slugMatch ?? (hashMatch?.count == 1 ? hashMatch?.first : nil)

            if let matched {
                matchedSlugs.insert(matched.slug)
                if matched.sourceContentHash == record.contentHash,
                   matched.sourceRelativePath == record.relativePath {
                    unchangedCount += 1
                    continue
                }
                let wasMoved = matched.sourceRelativePath != record.relativePath
                let updated = try article(from: record, preserving: matched)
                changes.append((matched, updated))
                byPath[record.relativePath] = updated
                if wasMoved {
                    movedCount += 1
                    sourceMoves.append((matched.sourceRelativePath, record.relativePath))
                } else {
                    updatedCount += 1
                }
                continue
            }

            let slug = uniqueSourceSlug(for: record, knownSlugs: &knownSlugs)
            let inserted = article(from: record, slug: slug)
            matchedSlugs.insert(slug)
            changes.append((nil, inserted))
            insertedCount += 1
        }

        let missingArticles = activeArticles.filter { article in
            !matchedSlugs.contains(article.slug)
                && !scannedPaths.contains(article.sourceRelativePath)
                && (affectedPaths?(article.sourceRelativePath) ?? true)
        }
        let deletedAt = timestamp(from: Date())
        let expiresAt = timestamp(afterDays: Self.trashRetentionDays)
        try db().transaction {
            for change in changes {
                if let previous = change.previous {
                    _ = try insertArticleRevision(
                        draftKey: previous.slug,
                        articleSlug: previous.slug,
                        reason: .savedVersion,
                        snapshot: NativeArticleRevisionSnapshot(article: previous),
                        createdAt: change.updated.updatedAt,
                        updatedAt: change.updated.updatedAt
                    )
                }
                try insertArticle(change.updated, into: db())
            }
            for article in missingArticles {
                try db().execute(
                    "UPDATE articles SET deleted_at = ?, delete_expires_at = ? WHERE slug = ?",
                    values: [.text(deletedAt), .text(expiresAt), .text(article.slug)]
                )
            }
        }
        let repairedBacklinks: [NativeArticle]
        if markdownWorkspaceSource.mode.isReadOnly, !sourceMoves.isEmpty {
            repairedBacklinks = []
            warnings.append(NativeLocalization.text("检测到 Markdown 文件移动；只读挂载不会自动改写其他文件中的双链"))
        } else {
            repairedBacklinks = try repairBacklinks(after: sourceMoves)
        }
        updatedCount += repairedBacklinks.count

        if !changes.isEmpty || !missingArticles.isEmpty || !repairedBacklinks.isEmpty {
            do {
                for change in changes { try writeArticleJSONSidecars(change.updated) }
                for article in repairedBacklinks { try writeArticleJSONSidecars(article) }
                for article in missingArticles { removeArticleJSONSidecars(for: article.slug) }
                try rebuildIndex()
                try writeTrashBackup()
            } catch {
                markJSONBackupNeedsRebuild()
                warnings.append(NativeLocalization.text("Markdown 已同步，但 JSON 备份需要稍后重建"))
            }
        }
        let affectedArticleSlugs = Set(changes.map(\.updated.slug))
            .union(missingArticles.map(\.slug))
            .union(repairedBacklinks.map(\.slug))
            .sorted()
        return NativeMarkdownSyncResult(
            insertedCount: insertedCount,
            updatedCount: updatedCount,
            movedCount: movedCount,
            deletedCount: missingArticles.count,
            unchangedCount: unchangedCount,
            affectedArticleSlugs: affectedArticleSlugs,
            warnings: warnings
        )
    }

    /// A source switch is not a user deletion. If Markdown still exists in the
    /// newly selected root, revive its prior SQLite identity instead of leaving
    /// the article hidden in Trash or allocating a suffixed slug.
    private func restoreDeletedArticlesPresentInSelectedSource(
        _ records: [MarkdownArticleSourceRecord]
    ) throws {
        for record in records {
            let slug = record.slug ?? ""
            var matchedSlug: String?
            try db().query(
                """
                SELECT slug FROM articles
                WHERE deleted_at IS NOT NULL
                  AND (source_relative_path = ? OR (? <> '' AND slug = ?))
                ORDER BY CASE WHEN source_relative_path = ? THEN 0 ELSE 1 END
                LIMIT 1
                """,
                values: [
                    .text(record.relativePath),
                    .text(slug),
                    .text(slug),
                    .text(record.relativePath),
                ]
            ) { row in
                matchedSlug = row.text(at: 0)
            }
            if let matchedSlug {
                try db().execute(
                    "UPDATE articles SET deleted_at = NULL, delete_expires_at = NULL WHERE slug = ?",
                    values: [.text(matchedSlug)]
                )
            }
        }
    }

    private func markdownSyncCandidates(
        records: [MarkdownArticleSourceRecord],
        changedPaths: Set<String>,
        changedDirectories: Set<String>
    ) throws -> [NativeArticle] {
        var articlesBySlug: [String: NativeArticle] = [:]
        func append(where clause: String, values: [SQLiteValue]) throws {
            try db().query(
                articleSelect + " WHERE deleted_at IS NULL AND (\(clause))",
                values: values
            ) { row in
                let article = try decodeArticle(row)
                articlesBySlug[article.slug] = article
            }
        }
        func appendChunks(values: [String], column: String) throws {
            let chunkSize = 200
            for start in stride(from: 0, to: values.count, by: chunkSize) {
                let chunk = Array(values[start..<min(start + chunkSize, values.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                try append(
                    where: "\(column) IN (\(placeholders))",
                    values: chunk.map(SQLiteValue.text)
                )
            }
        }

        try appendChunks(
            values: Array(changedPaths.union(records.map(\.relativePath))),
            column: "source_relative_path"
        )
        try appendChunks(
            values: Array(Set(records.compactMap(\.slug))),
            column: "slug"
        )
        try appendChunks(
            values: Array(Set(records.map(\.contentHash))),
            column: "source_content_hash"
        )
        for directory in changedDirectories {
            try append(
                where: "instr(source_relative_path, ?) = 1",
                values: [.text(directory + "/")]
            )
        }
        return Array(articlesBySlug.values)
    }

    private func storedArticleSlugs() throws -> Set<String> {
        var result = Set<String>()
        try db().query("SELECT slug FROM articles") { row in
            if let slug = row.text(at: 0) { result.insert(slug) }
        }
        return result
    }

    private func deletedArticleSourceIdentities() throws -> (slugs: Set<String>, paths: Set<String>) {
        var slugs = Set<String>()
        var paths = Set<String>()
        try db().query(
            "SELECT slug, source_relative_path FROM articles WHERE deleted_at IS NOT NULL"
        ) { row in
            if let slug = row.text(at: 0) {
                slugs.insert(slug)
                paths.insert(row.text(at: 1) ?? "\(slug).md")
            }
        }
        return (slugs, paths)
    }

    func repairBacklinks(
        after moves: [(oldPath: String, newPath: String)]
    ) throws -> [NativeArticle] {
        guard !moves.isEmpty else { return [] }
        var changes: [(previous: NativeArticle, updated: NativeArticle)] = []
        for article in try allArticles() {
            var body = article.body
            for move in moves {
                body = NativeArticleLink.retargetingWikiLinks(
                    in: body,
                    from: move.oldPath,
                    to: move.newPath
                )
            }
            guard body != article.body else { continue }
            let changed = NativeArticle(
                banner: article.banner,
                body: body,
                category: article.category,
                excerpt: article.excerpt,
                media: article.media,
                slug: article.slug,
                status: article.status,
                tags: article.tags,
                title: article.title,
                updatedAt: nextTimestamp(after: article.updatedAt),
                publishedAt: article.publishedAt,
                wordCount: wordCount(body),
                pageViews: article.pageViews,
                properties: article.properties,
                sourceRelativePath: article.sourceRelativePath,
                sourceContentHash: article.sourceContentHash,
                sourceImportedAt: article.sourceImportedAt,
                isPrivate: article.isPrivate
            )
            let record = try MarkdownArticleSource.write(
                changed,
                relativePath: changed.sourceRelativePath,
                in: articlesURL
            )
            changes.append((article, applyingSourceRecord(record, to: changed)))
        }
        try db().transaction {
            for change in changes {
                _ = try insertArticleRevision(
                    draftKey: change.previous.slug,
                    articleSlug: change.previous.slug,
                    reason: .savedVersion,
                    snapshot: NativeArticleRevisionSnapshot(article: change.previous),
                    createdAt: change.updated.updatedAt,
                    updatedAt: change.updated.updatedAt
                )
                try insertArticle(change.updated, into: db())
            }
        }
        return changes.map(\.updated)
    }

    private func uniqueSourceSlug(
        for record: MarkdownArticleSourceRecord,
        knownSlugs: inout Set<String>
    ) -> String {
        let requested = record.slug.flatMap { try? requireSafeSegment($0, label: "文章 slug") }
        var base = requested ?? slugify(record.title)
        if Self.reservedMediaDirectories.contains(base) { base += "-note" }
        var candidate = base
        var suffix = 2
        while knownSlugs.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        knownSlugs.insert(candidate)
        return candidate
    }

    private func article(
        from record: MarkdownArticleSourceRecord,
        preserving previous: NativeArticle
    ) throws -> NativeArticle {
        let override = try db().integer(
            "SELECT privacy_override FROM articles WHERE slug = ?", values: [.text(previous.slug)]
        ).map { $0 == 1 }
        let updatedAt: String
        if let declared = record.declaredUpdatedAt,
           let declaredDate = NativeTimestamp.date(from: declared),
           let previousDate = NativeTimestamp.date(from: previous.updatedAt),
           declaredDate > previousDate {
            updatedAt = declared
        } else {
            updatedAt = nextTimestamp(after: previous.updatedAt)
        }
        return NativeArticle(
            banner: record.banner.map(normalizeBanner),
            body: normalizeBody(record.body),
            category: record.category,
            excerpt: record.excerpt,
            media: record.media.map(normalizeMedia),
            slug: previous.slug,
            status: record.status,
            tags: record.tags,
            title: record.title,
            updatedAt: updatedAt,
            publishedAt: record.publishedAt ?? (record.status == .published ? previous.publishedAt ?? updatedAt : nil),
            wordCount: wordCount(record.body),
            pageViews: previous.pageViews,
            properties: record.properties,
            sourceRelativePath: record.relativePath,
            sourceContentHash: record.contentHash,
            sourceImportedAt: timestamp(from: Date()),
            isPrivate: override ?? record.isPrivate ?? previous.isPrivate
        )
    }

    private func article(from record: MarkdownArticleSourceRecord, slug: String) -> NativeArticle {
        let updatedAt = record.declaredUpdatedAt.flatMap {
            NativeTimestamp.date(from: $0) == nil ? nil : $0
        } ?? record.modifiedAt
        return NativeArticle(
            banner: record.banner.map(normalizeBanner),
            body: normalizeBody(record.body),
            category: record.category,
            excerpt: record.excerpt,
            media: record.media.map(normalizeMedia),
            slug: slug,
            status: record.status,
            tags: record.tags,
            title: record.title,
            updatedAt: updatedAt,
            publishedAt: record.publishedAt ?? (record.status == .published ? updatedAt : nil),
            wordCount: wordCount(record.body),
            properties: record.properties,
            sourceRelativePath: record.relativePath,
            sourceContentHash: record.contentHash,
            sourceImportedAt: timestamp(from: Date()),
            isPrivate: record.isPrivate ?? false
        )
    }

    func applyingSourceRecord(
        _ record: MarkdownArticleSourceRecord,
        to article: NativeArticle
    ) -> NativeArticle {
        NativeArticle(
            banner: article.banner,
            body: article.body,
            category: article.category,
            excerpt: article.excerpt,
            media: article.media,
            slug: article.slug,
            status: article.status,
            tags: article.tags,
            title: article.title,
            updatedAt: article.updatedAt,
            publishedAt: article.publishedAt,
            wordCount: article.wordCount,
            pageViews: article.pageViews,
            properties: article.properties,
            sourceRelativePath: record.relativePath,
            sourceContentHash: record.contentHash,
            sourceImportedAt: timestamp(from: Date()),
            isPrivate: article.isPrivate
        )
    }
}
