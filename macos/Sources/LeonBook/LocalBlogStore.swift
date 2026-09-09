import Foundation
import LeonBookBackupModule

/// Local SQLite store for structured data, with Markdown/JSON exports and file-based media.
public actor LocalBlogStore {
    private static let trashRetentionDays = 30
    private static let articleRevisionRetentionDays = 30
    private static let articleAutosaveRevisionInterval: TimeInterval = 5 * 60
    private static let maximumArticleRevisionsPerDraft = 100

    static let reservedMediaDirectories: Set<String> = ["inbox", "moments", "question-answers"]

    let rootURL: URL
    private var database: SQLiteDatabase?
    private var isPrepared = false
    private var jsonBackupVerified = false
    private var defersCompatibilityExportVerification = false
    private var activityExportDirty = false
    private var isPreparingForRestore = false
    var portableSidecarLastError: String?
    private var directoryLock: ExclusiveDirectoryLock?
    var markdownWorkspaceSource: NativeMarkdownWorkspaceSource

    private var databaseURL: URL { rootURL.appendingPathComponent("leon-book.sqlite") }
    private var markdownWorkspaceSourceURL: URL {
        rootURL.appendingPathComponent("markdown-source.json")
    }
    private var managedArticlesURL: URL { rootURL.appendingPathComponent("articles", isDirectory: true) }
    var articlesURL: URL {
        guard markdownWorkspaceSource.mode.isMounted,
              let path = markdownWorkspaceSource.directoryPath else {
            return managedArticlesURL
        }
        return URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }
    private var articleSidecarsMarkerURL: URL { managedArticlesURL.appendingPathComponent(".sidecars-v1") }
    private var draftsURL: URL { rootURL.appendingPathComponent("drafts", isDirectory: true) }
    var mediaURL: URL { rootURL.appendingPathComponent("media", isDirectory: true) }
    private var momentsURL: URL { rootURL.appendingPathComponent("moments", isDirectory: true) }
    private var basesURL: URL { rootURL.appendingPathComponent("bases", isDirectory: true) }
    private var basesMarkerURL: URL { basesURL.appendingPathComponent(".files-v1") }
    private var momentsIndexURL: URL { momentsURL.appendingPathComponent("index.json") }
    private var momentSidecarsMarkerURL: URL { momentsURL.appendingPathComponent(".sidecars-v1") }
    private var jsonExportStampURL: URL { rootURL.appendingPathComponent(".json-exports-v1") }
    private var activityURL: URL { rootURL.appendingPathComponent("activity", isDirectory: true) }
    private var trashURL: URL { rootURL.appendingPathComponent("trash", isDirectory: true) }
    private var trashIndexURL: URL { trashURL.appendingPathComponent("index.json") }

    // MARK: - Lifecycle

    public init(rootURL: URL = LocalBlogStore.defaultRootURL) {
        let standardizedRoot = rootURL.standardizedFileURL
        self.rootURL = standardizedRoot
        markdownWorkspaceSource = Self.loadMarkdownWorkspaceSource(from: standardizedRoot)
        WorkspaceStorageLifecycle.register(self, root: standardizedRoot)
    }

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
                throw NativeStoreError.fileSystem("挂载模式需要选择 Markdown 文件夹")
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

    public func prepareForBackup() throws {
        try prepare()
        try db().execute("PRAGMA wal_checkpoint(TRUNCATE)")
        if activityExportDirty { try writeActivityEvents() }
        try exportJsonBackupIfNeeded()
        try exportPortableSidecarIfEnabled()
    }

    /// Prepares only the database state required for the first interactive
    /// frame. Compatibility JSON verification is scheduled after startup.
    public func prepareForInteractiveUse() throws {
        defersCompatibilityExportVerification = true
        try prepare()
    }

    public func verifyCompatibilityExports() throws {
        try prepare()
        if activityExportDirty { try writeActivityEvents() }
        try exportJsonBackupIfNeeded()
        try exportPortableSidecarIfEnabled()
    }

    /// Runs low-frequency retention work without putting it on every storage API.
    public func performMaintenance() throws {
        try WorkspaceStorageLifecycle.requireAvailable(rootURL)
        guard isPrepared else {
            try prepare()
            return
        }
        try runMaintenance()
    }

    public func closeForRestore() {
        database?.close()
        database = nil
        directoryLock = nil
        isPrepared = false
        jsonBackupVerified = false
        defersCompatibilityExportVerification = false
        activityExportDirty = false
    }

    func prepareAndCloseForRestore() throws {
        isPreparingForRestore = true
        defer {
            closeForRestore()
            isPreparingForRestore = false
        }
        // Unused stores may point at the user registry rather than an article
        // workspace. Only flush connections that have actually been opened.
        if database != nil { try prepareForBackup() }
    }

    func prepare() throws {
        if !isPreparingForRestore { try WorkspaceStorageLifecycle.requireAvailable(rootURL) }
        try reloadMarkdownWorkspaceSource()
        guard !isPrepared else { return }
        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: managedArticlesURL, withIntermediateDirectories: true)
            if markdownWorkspaceSource.mode.isMounted {
                try validateMarkdownSourceDirectory(
                    articlesURL,
                    requiresWriteAccess: !markdownWorkspaceSource.mode.isReadOnly
                )
            }
            try fileManager.createDirectory(at: draftsURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: mediaURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: momentsURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: basesURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: activityURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: trashURL, withIntermediateDirectories: true)

            if directoryLock == nil {
                directoryLock = try ExclusiveDirectoryLock(directory: rootURL)
            }

            if database == nil {
                let nextDatabase = try SQLiteDatabase(url: databaseURL)
                try createSchema(in: nextDatabase)
                database = nextDatabase
            }
            try migrateLegacyDataIfNeeded()
            try migrateMomentTagsIfNeeded()
            try migrateMarkdownSourcesIfNeeded()
            try migrateArticleDerivedIndexesIfNeeded()
            try migrateSearchAccelerationIndexesIfNeeded()
            try migrateMediaReferencesIfNeeded()
            importPortableSidecarDuringPreparation()
            if !defersCompatibilityExportVerification {
                try exportJsonBackupIfNeeded()
            }
            try runMaintenance()
            isPrepared = true
        } catch let error as NativeStoreError {
            throw error
        } catch {
            throw NativeStoreError.fileSystem(error.localizedDescription)
        }
    }

    private func runMaintenance() throws {
        try purgeExpiredTrash()
        try purgeExpiredArticleRevisions()
    }

    private static func loadMarkdownWorkspaceSource(from rootURL: URL) -> NativeMarkdownWorkspaceSource {
        let url = rootURL.appendingPathComponent("markdown-source.json")
        guard let data = try? Data(contentsOf: url),
              let source = try? JSONDecoder().decode(NativeMarkdownWorkspaceSource.self, from: data),
              source.mode.isMounted == (source.directoryPath != nil) else {
            return .managed
        }
        return source
    }

    private func reloadMarkdownWorkspaceSource() throws {
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
                throw NativeStoreError.fileSystem("Markdown 工作区配置无效")
            }
            markdownWorkspaceSource = source
        } catch {
            throw NativeStoreError.fileSystem("无法读取 Markdown 工作区配置：\(error.localizedDescription)")
        }
    }

    private func persistMarkdownWorkspaceSource() throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(markdownWorkspaceSource)
                .write(to: markdownWorkspaceSourceURL, options: .atomic)
        } catch {
            throw NativeStoreError.fileSystem("无法保存 Markdown 工作区配置：\(error.localizedDescription)")
        }
    }

    private func validateMarkdownSourceDirectory(
        _ url: URL,
        requiresWriteAccess: Bool
    ) throws {
        var isDirectory: ObjCBool = false
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NativeStoreError.fileSystem("Markdown 文件夹不存在：\(url.path)")
        }
        guard fileManager.isReadableFile(atPath: url.path) else {
            throw NativeStoreError.fileSystem("没有 Markdown 文件夹的读取权限：\(url.path)")
        }
        if requiresWriteAccess, !fileManager.isWritableFile(atPath: url.path) {
            throw NativeStoreError.fileSystem("没有 Markdown 文件夹的写入权限：\(url.path)")
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
        WHERE deleted_at IS NULL
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
            WHERE deleted_at IS NULL AND slug IN (\(placeholders))
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
        let allStoredArticles = try allArticles(includingDeleted: true)
        let activeSlugs = Set(activeArticles.map(\.slug))
        let deletedArticles = allStoredArticles.filter { article in
            !activeSlugs.contains(article.slug)
        }
        return try reconcileMarkdownSources(
            records: records,
            activeArticles: activeArticles,
            knownSlugs: Set(allStoredArticles.map(\.slug)),
            deletedSlugs: Set(deletedArticles.map(\.slug)),
            deletedPaths: Set(deletedArticles.map(\.sourceRelativePath)),
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
                warnings.append("\(record.relativePath)：对应文章仍在回收站，已跳过")
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
                let updated = article(from: record, preserving: matched)
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
            warnings.append("检测到 Markdown 文件移动；只读挂载不会自动改写其他文件中的双链")
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
                warnings.append("Markdown 已同步，但 JSON 备份需要稍后重建")
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
            if let slug = row.text(at: 0) { slugs.insert(slug) }
            if let path = row.text(at: 1) { paths.insert(path) }
        }
        return (slugs, paths)
    }

    private func repairBacklinks(
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
                sourceImportedAt: article.sourceImportedAt
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
    ) -> NativeArticle {
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
            sourceImportedAt: timestamp(from: Date())
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
            sourceImportedAt: timestamp(from: Date())
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
            sourceImportedAt: timestamp(from: Date())
        )
    }

    /// Renames one property key across every active article as a single SQLite transaction.
    /// A destination with a different value aborts the whole operation instead of losing data.
    @discardableResult
    public func renameArticleProperty(from oldKey: String, to newKey: String) throws -> Int {
        try prepare()
        try requireWritableArticleSource()
        let sourceKey = oldKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let destinationKey = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NativeArticleProperties.isValidKey(sourceKey) else {
            throw NativeArticlePropertyError.invalidKey(oldKey)
        }

        var changes: [(previous: NativeArticle, updated: NativeArticle)] = []
        for article in try allArticles() {
            let properties = try NativeArticleProperties.renaming(
                sourceKey,
                to: destinationKey,
                in: article.properties
            )
            guard properties != article.properties else { continue }
            let updatedAt = nextTimestamp(after: article.updatedAt)
            let changed = NativeArticle(
                    banner: article.banner,
                    body: article.body,
                    category: article.category,
                    excerpt: article.excerpt,
                    media: article.media,
                    slug: article.slug,
                    status: article.status,
                    tags: article.tags,
                    title: article.title,
                    updatedAt: updatedAt,
                    publishedAt: article.publishedAt,
                    wordCount: article.wordCount,
                    pageViews: article.pageViews,
                    properties: properties,
                    sourceRelativePath: article.sourceRelativePath,
                    sourceContentHash: article.sourceContentHash,
                    sourceImportedAt: article.sourceImportedAt
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
        guard !changes.isEmpty else { return 0 }
        do {
            for change in changes { try writeArticleJSONSidecars(change.updated) }
            try rebuildIndex()
        } catch {
            markJSONBackupNeedsRebuild()
        }
        return changes.count
    }

    // MARK: - Smart collections and bookmarks

    public func listArticles(in collection: NativeSmartCollection) throws -> [NativeArticleSummary] {
        try prepare()
        let query = NativeSmartCollectionSQLCompiler.compile(collection)
        let limit = collection.selectedView?.limit
        let limitClause = limit == nil ? "" : " LIMIT ?"
        let values = query.values + (limit.map { [.integer($0)] } ?? [])
        var articles: [NativeArticleSummary] = []
        try db().query(
            "\(qualifiedArticleSummarySelect("a")) \(query.whereClause) \(query.orderClause)\(limitClause)",
            values: values
        ) { row in
            articles.append(try decodeArticleSummary(row))
        }
        return articles
    }

    public func setArticleProperty(
        slug: String,
        expectedUpdatedAt: String,
        key: String,
        value: NativeArticlePropertyValue?
    ) throws -> NativeArticle {
        try prepare()
        let article = try getArticle(slug: slug)
        guard article.updatedAt == expectedUpdatedAt else { throw NativeStoreError.conflict }
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NativeArticleProperties.isValidKey(normalizedKey) else {
            throw NativeArticlePropertyError.invalidKey(key)
        }
        var properties = article.properties
        if let existing = properties.keys.first(where: {
            $0.caseInsensitiveCompare(normalizedKey) == .orderedSame
        }) {
            properties.removeValue(forKey: existing)
        }
        if let value { properties[normalizedKey] = value }
        properties = try NativeArticleProperties.validated(properties)
        return try saveArticle(NativeSaveArticle(
            banner: article.banner,
            body: article.body,
            category: article.category,
            excerpt: article.excerpt,
            media: article.media,
            slug: article.slug,
            status: article.status,
            tags: article.tags,
            title: article.title,
            expectedUpdatedAt: expectedUpdatedAt,
            properties: properties
        ))
    }

    public func listSmartCollections() throws -> [NativeSmartCollection] {
        try prepare()
        try migrateSmartCollectionFilesIfNeeded()
        let collections = try NativeSmartCollectionFile.readAll(in: basesURL)
        try db().transaction {
            try db().execute("DELETE FROM smart_collections")
            for collection in collections {
                try db().execute(
                    "INSERT INTO smart_collections(id, config_json, updated_at) VALUES (?, ?, ?)",
                    values: [
                        .text(collection.id),
                        .text(try jsonString(collection)),
                        .text(collection.updatedAt),
                    ]
                )
            }
        }
        return collections.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        }
    }

    @discardableResult
    public func saveSmartCollection(_ collection: NativeSmartCollection) throws -> NativeSmartCollection {
        try prepare()
        var candidate = collection
        candidate.synchronizeActiveView()
        let name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let formulaKeys = candidate.formulas.map {
            $0.key.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        let columnsAreValid: ([NativeSmartCollectionColumn]) -> Bool = { columns in columns.allSatisfy { column in
            switch column.source {
            case .system: return NativeSmartCollectionSystemField(rawValue: column.key) != nil
            case .property: return NativeArticleProperties.isValidKey(column.key)
            case .formula:
                return candidate.formulas.contains {
                    $0.key.caseInsensitiveCompare(column.key) == .orderedSame
                }
            }
        } }
        let filters = [candidate.filter].compactMap { $0 } + candidate.views.compactMap(\.filter)
        guard !name.isEmpty, name.count <= 80,
              candidate.rules.count <= 20,
              candidate.rules.allSatisfy(\.isValid),
              filters.reduce(0, { $0 + $1.ruleCount + $1.expressionCount }) <= 100,
              filters.allSatisfy(\.allRulesAreValid),
              candidate.views.count <= 50,
              candidate.sorts.count <= 3,
              candidate.views.allSatisfy({ $0.sorts.count <= 3 && $0.columns.count <= 30 }),
              candidate.columns.count <= 30,
              candidate.formulas.count <= 20,
              candidate.formulas.allSatisfy(\.isValid),
              Set(formulaKeys).count == formulaKeys.count,
              columnsAreValid(candidate.columns),
              candidate.views.allSatisfy({ columnsAreValid($0.columns) }) else {
            throw NativeStoreError.fileSystem("智能集合名称、筛选或排序数量无效")
        }
        try migrateSmartCollectionFilesIfNeeded()
        var saved = candidate
        saved.name = name
        saved.sorts = Array(saved.sorts.prefix(3))
        saved.columns = Array(saved.columns.prefix(30)).map { column in
            var normalized = column
            normalized.key = column.key.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.title = column.title.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.width = min(max(column.width, 80), 480)
            return normalized
        }
        saved.formulas = Array(saved.formulas.prefix(20))
        saved.updatedAt = timestamp(from: Date())
        let previous = try NativeSmartCollectionFile.readAll(in: basesURL).first(where: { $0.id == saved.id })
        _ = try NativeSmartCollectionFile.write(saved, in: basesURL)
        guard let persisted = try NativeSmartCollectionFile.readAll(in: basesURL)
            .first(where: { $0.id == saved.id }) else {
            throw NativeStoreError.fileSystem("智能集合写入后无法重新读取")
        }
        saved = persisted
        do {
            try db().execute(
                """
                INSERT OR REPLACE INTO smart_collections(id, config_json, updated_at)
                VALUES (?, ?, ?)
                """,
                values: [.text(saved.id), .text(try jsonString(saved)), .text(saved.updatedAt)]
            )
        } catch {
            if let previous { _ = try? NativeSmartCollectionFile.write(previous, in: basesURL) }
            else { try? NativeSmartCollectionFile.remove(id: saved.id, in: basesURL) }
            throw error
        }
        return saved
    }

    public func deleteSmartCollection(id: String) throws {
        try prepare()
        try migrateSmartCollectionFilesIfNeeded()
        let previous = try NativeSmartCollectionFile.readAll(in: basesURL).first(where: { $0.id == id })
        try NativeSmartCollectionFile.remove(id: id, in: basesURL)
        do {
            try db().execute("DELETE FROM smart_collections WHERE id = ?", values: [.text(id)])
        } catch {
            if let previous { _ = try? NativeSmartCollectionFile.write(previous, in: basesURL) }
            throw error
        }
    }

    private func migrateSmartCollectionFilesIfNeeded() throws {
        guard !FileManager.default.fileExists(atPath: basesMarkerURL.path) else { return }
        var collections: [NativeSmartCollection] = []
        try db().query("SELECT config_json FROM smart_collections ORDER BY updated_at DESC, id") { row in
            guard let json = row.text(at: 0) else {
                throw NativeStoreError.fileSystem("SQLite：智能集合记录不完整")
            }
            collections.append(try decode(json))
        }
        for collection in collections { _ = try NativeSmartCollectionFile.write(collection, in: basesURL) }
        try Data().write(to: basesMarkerURL, options: .atomic)
    }

    public func listBookmarks() throws -> [NativeBookmark] {
        try prepare()
        var bookmarks: [NativeBookmark] = []
        try db().query("SELECT bookmark_json FROM bookmarks ORDER BY position, created_at, id") { row in
            guard let json = row.text(at: 0) else {
                throw NativeStoreError.fileSystem("SQLite：收藏记录不完整")
            }
            bookmarks.append(try decode(json))
        }
        return bookmarks
    }

    @discardableResult
    public func saveBookmark(_ bookmark: NativeBookmark) throws -> NativeBookmark {
        try prepare()
        var saved = bookmark
        saved.title = saved.title.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.groupName = saved.groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved.title.isEmpty, saved.title.count <= 120, saved.groupName.count <= 80 else {
            throw NativeStoreError.fileSystem("收藏标题或分组名称无效")
        }
        let nextPosition = (try db().integer("SELECT COALESCE(MAX(position), -1) + 1 FROM bookmarks")) ?? 0
        try db().execute(
            """
            INSERT INTO bookmarks(id, bookmark_json, position, created_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET bookmark_json = excluded.bookmark_json
            """,
            values: [
                .text(saved.id),
                .text(try jsonString(saved)),
                .integer(nextPosition),
                .text(saved.createdAt),
            ]
        )
        try db().execute(
            "DELETE FROM portable_sidecar_tombstones WHERE kind = 'bookmark' AND record_id = ?",
            values: [.text(saved.id)]
        )
        return saved
    }

    public func deleteBookmark(id: String) throws {
        try prepare()
        let safeID = try requireSafeSegment(id, label: "收藏标识")
        try db().execute("DELETE FROM bookmarks WHERE id = ?", values: [.text(safeID)])
        try recordPortableSidecarTombstone(kind: "bookmark", id: safeID)
    }

    // MARK: - Moments

    public func listMoments() throws -> [NativeMoment] {
        try prepare()
        return try allMoments()
    }

    public func getMoment(id: String) throws -> NativeMoment {
        try prepare()
        guard let moment = try moment(withID: id) else { throw NativeStoreError.notFound }
        return moment
    }

    public func listMomentPage(
        matching filter: NativeMomentFilter = .all,
        before cursor: NativeMomentCursor? = nil,
        limit: Int = 40
    ) throws -> NativeMomentPage {
        try prepare()
        let pageSize = min(max(limit, 1), 100)
        let batchSize = max(pageSize * 2, 64)
        var scanCursor = cursor
        var matches: [NativeMoment] = []

        while matches.count <= pageSize {
            let batch = try momentCandidates(
                matching: filter,
                before: scanCursor,
                limit: batchSize
            )
            guard !batch.isEmpty else { break }

            for moment in batch {
                if filter.matches(moment) {
                    matches.append(moment)
                    if matches.count > pageSize { break }
                }
                scanCursor = NativeMomentCursor(createdAt: moment.createdAt, id: moment.id)
            }

            if matches.count > pageSize || batch.count < batchSize { break }
        }

        let hasMore = matches.count > pageSize
        let page = Array(matches.prefix(pageSize))
        return NativeMomentPage(
            moments: page,
            nextCursor: hasMore ? page.last.map { NativeMomentCursor(createdAt: $0.createdAt, id: $0.id) } : nil
        )
    }

    public func countMoments(matching filter: NativeMomentFilter = .all) throws -> Int {
        try prepare()
        return try momentCandidateCount(matching: filter)
    }

    public func listMomentFacetRecords() throws -> [NativeMomentFacetRecord] {
        try prepare()
        var order: [String] = []
        var records: [String: (createdAt: String, tags: [String])] = [:]
        try db().query("""
        SELECT moment.id, moment.created_at, tag.tag
        FROM moments AS moment
        LEFT JOIN moment_tags AS tag ON tag.moment_id = moment.id
        WHERE moment.deleted_at IS NULL
        ORDER BY moment.created_at DESC, moment.id DESC, tag.normalized_tag
        """) { row in
            guard let id = row.text(at: 0), let createdAt = row.text(at: 1) else {
                throw NativeStoreError.fileSystem("SQLite：微博筛选记录不完整")
            }
            if records[id] == nil {
                order.append(id)
                records[id] = (createdAt, [])
            }
            if let tag = row.text(at: 2) {
                records[id]?.tags.append(tag)
            }
        }
        return order.compactMap { id in
            records[id].map { NativeMomentFacetRecord(createdAt: $0.createdAt, tags: $0.tags) }
        }
    }

    public func saveMoment(
        text: String,
        textRuns: [NativeMomentTextRun],
        images: [NativeMedia]
    ) throws -> NativeMoment {
        try prepare()
        let normalizedInput = normalizedMomentText(text, textRuns: textRuns)
        let normalizedText = NativeMomentTag.content(
            from: normalizedInput.text,
            textRuns: normalizedInput.runs
        )
        let normalizedImages = Array(images
            .filter(isSupportedMomentMedia)
            .map(normalizeMedia)
            .prefix(9))
        guard !normalizedText.text.isEmpty || !normalizedImages.isEmpty else {
            throw NativeStoreError.invalidMoment
        }

        let latestCreatedAt = try latestMomentCreatedAt()
        let createdAt = nextTimestamp(after: latestCreatedAt)
        let id = "moment-\(Int(Date().timeIntervalSince1970 * 1_000))-\(UUID().uuidString.lowercased().prefix(8))"
        let saved = NativeMoment(
            createdAt: createdAt,
            id: id,
            images: normalizedImages,
            isFavorite: false,
            tags: normalizedText.tags,
            text: normalizedText.text,
            textRuns: normalizedText.runs,
            updatedAt: createdAt
        )

        try db().transaction {
            try insertMoment(saved, into: db())
            try recordActivityEvent(type: "moment_published", at: activityDate(from: createdAt) ?? Date())
        }
        do {
            try writeMomentSidecar(saved)
            try writeActivityEventsAfterMutation()
        } catch {
            markJSONBackupNeedsRebuild()
        }
        return saved
    }

    public func updateMoment(
        id: String,
        text: String,
        textRuns: [NativeMomentTextRun],
        images: [NativeMedia]
    ) throws -> NativeMoment {
        try prepare()
        let safeID = try requireSafeSegment(id, label: "微博 ID")
        guard let previous = try moment(withID: safeID) else { throw NativeStoreError.notFound }

        let normalizedInput = normalizedMomentText(text, textRuns: textRuns)
        let normalizedText = NativeMomentTag.content(
            from: normalizedInput.text,
            textRuns: normalizedInput.runs
        )
        let normalizedImages = Array(images
            .filter(isSupportedMomentMedia)
            .map(normalizeMedia)
            .prefix(9))
        guard !normalizedText.text.isEmpty || !normalizedImages.isEmpty else {
            throw NativeStoreError.invalidMoment
        }

        let updated = NativeMoment(
            createdAt: previous.createdAt,
            id: previous.id,
            images: normalizedImages,
            isFavorite: previous.isFavorite,
            tags: normalizedText.tags,
            text: normalizedText.text,
            textRuns: normalizedText.runs,
            updatedAt: nextTimestamp(after: previous.updatedAt)
        )

        try db().transaction {
            try insertMoment(updated, into: db())
            try recordActivityEvent(type: "moment_edited", at: activityDate(from: updated.updatedAt) ?? Date())
        }
        do {
            try writeMomentSidecar(updated)
            try writeActivityEventsAfterMutation()
        } catch {
            markJSONBackupNeedsRebuild()
        }
        try removeUnreferencedMomentImages(previous.images)
        return updated
    }

    public func setMomentFavorite(id: String, isFavorite: Bool) throws -> NativeMoment {
        try prepare()
        let safeID = try requireSafeSegment(id, label: "微博 ID")
        guard let previous = try moment(withID: safeID) else { throw NativeStoreError.notFound }

        try db().execute(
            "UPDATE moments SET is_favorite = ? WHERE id = ?",
            values: [.integer(isFavorite ? 1 : 0), .text(safeID)]
        )
        let updated = NativeMoment(
            createdAt: previous.createdAt,
            id: previous.id,
            images: previous.images,
            isFavorite: isFavorite,
            tags: previous.tags,
            text: previous.text,
            textRuns: previous.textRuns,
            updatedAt: previous.updatedAt
        )
        do {
            try writeMomentSidecar(updated)
        } catch {
            markJSONBackupNeedsRebuild()
        }
        return updated
    }

    public func deleteMoment(id: String) throws {
        try prepare()
        let safeID = try requireSafeSegment(id, label: "微博 ID")
        guard try moment(withID: safeID) != nil else { throw NativeStoreError.notFound }

        let deletedAt = timestamp(from: Date())
        let expiresAt = timestamp(afterDays: Self.trashRetentionDays)
        try db().execute(
            "UPDATE moments SET deleted_at = ?, delete_expires_at = ? WHERE id = ?",
            values: [.text(deletedAt), .text(expiresAt), .text(safeID)]
        )
        removeMomentSidecar(id: safeID)
        try writeTrashBackup()
    }

    // MARK: - Questions and answers

    public func listQuestions(
        searchText: String = "",
        tag: String? = nil
    ) throws -> [NativeQuestion] {
        try prepare()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawSelectedTag = tag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectedTag = rawSelectedTag.isEmpty ? nil : NativeQuestionTag.identifier(rawSelectedTag)
        var predicates: [String] = []
        var values: [SQLiteValue] = []

        if query.count >= 3 {
            predicates.append("""
            q.id IN (
                SELECT question_id FROM question_search
                WHERE question_search MATCH ?
            )
            """)
            values.append(.text("\"\(query.replacingOccurrences(of: "\"", with: "\"\""))\""))
        } else if let token = shortSearchToken(for: query) {
            predicates.append("""
            q.id IN (
                SELECT document_id FROM content_short_search
                WHERE content_short_search MATCH ? AND document_type = 'question'
            )
            """)
            values.append(.text("\"\(token.replacingOccurrences(of: "\"", with: "\"\""))\""))
        }
        if let selectedTag {
            predicates.append("""
            EXISTS (
                SELECT 1 FROM question_tags AS selected_tag
                WHERE selected_tag.question_id = q.id
                  AND selected_tag.normalized_tag = ?
            )
            """)
            values.append(.text(selectedTag))
        }

        let whereClause = predicates.isEmpty ? "" : "WHERE " + predicates.joined(separator: " AND ")
        var questions: [NativeQuestion] = []
        try db().query(
            """
            \(questionSelect)
            \(whereClause)
            ORDER BY q.updated_at DESC, q.id DESC
            """,
            values: values
        ) { row in
            questions.append(try decodeQuestion(row))
        }
        return questions
    }

    public func countQuestions() throws -> Int {
        try prepare()
        return try db().integer("SELECT COUNT(*) FROM questions") ?? 0
    }

    public func listQuestionTagFacets() throws -> [NativeQuestionTagFacet] {
        try prepare()
        var facets: [NativeQuestionTagFacet] = []
        try db().query("""
        SELECT MIN(tag), COUNT(*)
        FROM question_tags
        GROUP BY normalized_tag
        ORDER BY COUNT(*) DESC, normalized_tag ASC
        """) { row in
            guard let tag = row.text(at: 0) else {
                throw NativeStoreError.fileSystem("SQLite：问题标签记录不完整")
            }
            facets.append(NativeQuestionTagFacet(tag: tag, count: row.integer(at: 1) ?? 0))
        }
        return facets
    }

    public func getQuestion(id: String) throws -> NativeQuestion {
        try prepare()
        let safeID = try requireSafeSegment(id, label: "问题 ID")
        var result: NativeQuestion?
        try db().query(
            questionSelect + " WHERE q.id = ?",
            values: [.text(safeID)]
        ) { row in
            result = try decodeQuestion(row)
        }
        guard let result else { throw NativeStoreError.notFound }
        return result
    }

    public func saveQuestion(
        title: String,
        body: String,
        tags: [String]
    ) throws -> NativeQuestion {
        try prepare()
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTags = NativeQuestionTag.normalized(tags)
        guard (1...200).contains(normalizedTitle.count) else {
            throw NativeStoreError.invalidQuestion
        }

        let latestQuestionTimestamp = try db().text("SELECT MAX(updated_at) FROM questions")
        let createdAt = nextQuestionTimestamp(after: latestQuestionTimestamp)
        let id = "question-\(Int(Date().timeIntervalSince1970 * 1_000))-\(UUID().uuidString.lowercased().prefix(8))"
        try db().transaction {
            try db().execute("""
            INSERT INTO questions(id, title, body, tags_json, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """, values: [
                .text(id),
                .text(normalizedTitle),
                .text(normalizedBody),
                .text(try jsonString(normalizedTags)),
                .text(createdAt),
                .text(createdAt),
            ])
            try replaceQuestionTags(questionID: id, tags: normalizedTags)
            try replaceShortSearchDocument(
                type: "question",
                id: id,
                source: [normalizedTitle, normalizedBody, normalizedTags.joined(separator: " ")],
                isActive: true,
                in: db()
            )
        }
        return NativeQuestion(
            id: id,
            title: normalizedTitle,
            body: normalizedBody,
            tags: normalizedTags,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    public func listQuestionAnswers(questionID: String) throws -> [NativeQuestionAnswer] {
        try prepare()
        let safeQuestionID = try requireSafeSegment(questionID, label: "问题 ID")
        var answers: [NativeQuestionAnswer] = []
        try db().query(
            questionAnswerSelect + " WHERE question_id = ? ORDER BY created_at ASC, id ASC",
            values: [.text(safeQuestionID)]
        ) { row in
            answers.append(try decodeQuestionAnswer(row))
        }
        return answers
    }

    public func saveQuestionAnswer(
        questionID: String,
        body: String,
        images: [NativeMedia] = []
    ) throws -> NativeQuestionAnswer {
        try prepare()
        let safeQuestionID = try requireSafeSegment(questionID, label: "问题 ID")
        let question = try getQuestion(id: safeQuestionID)
        let content = try normalizedQuestionAnswerContent(body: body, images: images)

        let latestQuestionTimestamp = try db().text("SELECT MAX(updated_at) FROM questions")
        let timestampBaseline = latestQuestionTimestamp.map { max($0, question.updatedAt) } ?? question.updatedAt
        let createdAt = nextQuestionTimestamp(after: timestampBaseline)
        let id = "answer-\(Int(Date().timeIntervalSince1970 * 1_000))-\(UUID().uuidString.lowercased().prefix(8))"
        try db().transaction {
            try db().execute("""
            INSERT INTO question_answers(id, question_id, body, images_json, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """, values: [
                .text(id),
                .text(safeQuestionID),
                .text(content.body),
                .text(try jsonString(content.images)),
                .text(createdAt),
                .text(createdAt),
            ])
            try db().execute(
                "UPDATE questions SET updated_at = ? WHERE id = ?",
                values: [.text(createdAt), .text(safeQuestionID)]
            )
            try replaceMediaReferences(
                ownerType: "answer",
                ownerID: id,
                urls: content.images.map(\.url) + embeddedMediaURLs(in: content.body),
                in: db()
            )
        }
        return NativeQuestionAnswer(
            id: id,
            questionID: safeQuestionID,
            body: content.body,
            images: content.images,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    public func updateQuestionAnswer(
        id: String,
        body: String,
        images: [NativeMedia] = [],
        expectedUpdatedAt: String
    ) throws -> NativeQuestionAnswer {
        try prepare()
        let safeID = try requireSafeSegment(id, label: "回答 ID")
        guard let previous = try questionAnswer(withID: safeID) else {
            throw NativeStoreError.notFound
        }
        guard previous.updatedAt == expectedUpdatedAt else {
            throw NativeStoreError.questionAnswerConflict
        }
        let content = try normalizedQuestionAnswerContent(body: body, images: images)
        let latestQuestionTimestamp = try db().text("SELECT MAX(updated_at) FROM questions")
        let timestampBaseline = latestQuestionTimestamp.map { max($0, previous.updatedAt) }
            ?? previous.updatedAt
        let updatedAt = nextQuestionTimestamp(after: timestampBaseline)
        let updated = NativeQuestionAnswer(
            id: previous.id,
            questionID: previous.questionID,
            body: content.body,
            images: content.images,
            createdAt: previous.createdAt,
            updatedAt: updatedAt
        )

        try db().transaction {
            try db().execute("""
            UPDATE question_answers
            SET body = ?, images_json = ?, updated_at = ?
            WHERE id = ? AND updated_at = ?
            """, values: [
                .text(updated.body),
                .text(try jsonString(updated.images)),
                .text(updated.updatedAt),
                .text(updated.id),
                .text(expectedUpdatedAt),
            ])
            guard try db().integer("SELECT changes()") == 1 else {
                throw NativeStoreError.questionAnswerConflict
            }
            try db().execute(
                "UPDATE questions SET updated_at = ? WHERE id = ?",
                values: [.text(updated.updatedAt), .text(updated.questionID)]
            )
            try replaceMediaReferences(
                ownerType: "answer",
                ownerID: updated.id,
                urls: updated.images.map(\.url) + embeddedMediaURLs(in: updated.body),
                in: db()
            )
        }
        try removeUnreferencedMediaFiles(previous.images, includingDeleted: true)
        return updated
    }

    private func removeUnreferencedMomentImages(
        _ images: [NativeMedia],
        includingDeleted: Bool = true
    ) throws {
        try removeUnreferencedMediaFiles(images, includingDeleted: includingDeleted)
    }

    // MARK: - Articles and refactoring workflows

    public func listActivity(since: Date) throws -> [NativeActivityDay] {
        try prepare()
        let calendar = Calendar.current
        let firstDay = calendar.startOfDay(for: since)
        var counts: [String: Int] = [:]

        for event in try allActivityEvents() {
            guard let date = activityDate(from: event.createdAt), date >= firstDay else { continue }
            let key = activityDateKey(for: date, calendar: calendar)
            counts[key, default: 0] += 1
        }

        return counts
            .map { NativeActivityDay(date: $0.key, count: $0.value) }
            .sorted { $0.date < $1.date }
    }

    public func getArticle(slug: String) throws -> NativeArticle {
        try prepare()
        let safeSlug = try requireSafeSegment(slug, label: "文章 slug")
        guard let article = try storedArticle(withSlug: safeSlug) else { throw NativeStoreError.notFound }
        return article
    }

    public func extractArticleSelection(
        sourceSlug: String,
        expectedUpdatedAt: String,
        sourceBody: String,
        selectedRange: NSRange,
        newTitle: String,
        replacement: NativeArticleExtractionReplacement
    ) throws -> NativeArticleRefactorResult {
        try prepare()
        let source = try getArticle(slug: sourceSlug)
        guard source.updatedAt == expectedUpdatedAt else { throw NativeStoreError.conflict }
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw NativeStoreError.invalidArticle }
        let targetSlug = try allocateSlug(from: title)
        let extraction = try ArticleKnowledgeComposer.extract(
            from: sourceBody,
            selectedRange: selectedRange,
            targetSlug: targetSlug,
            replacement: replacement
        )
        let sourceUpdated = refactoredArticle(
            source,
            body: extraction.sourceBody,
            updatedAt: nextTimestamp(after: source.updatedAt)
        )
        let createdAt = nextTimestamp(after: sourceUpdated.updatedAt)
        let extracted = NativeArticle(
            banner: nil,
            body: extraction.extractedBody,
            category: source.category,
            excerpt: "",
            media: [],
            slug: targetSlug,
            status: .draft,
            tags: source.tags,
            title: title,
            updatedAt: createdAt,
            publishedAt: nil,
            wordCount: wordCount(extraction.extractedBody),
            properties: [:],
            sourceRelativePath: MarkdownArticleSource.defaultRelativePath(for: targetSlug)
        )
        let saved = try persistArticleRefactor([
            (previous: source, updated: sourceUpdated),
            (previous: nil, updated: extracted),
        ])
        guard let primary = saved.first(where: { $0.slug == source.slug }),
              let created = saved.first(where: { $0.slug == targetSlug }) else {
            throw NativeStoreError.fileSystem("文章提取结果不完整")
        }
        return NativeArticleRefactorResult(primaryArticle: primary, createdArticles: [created])
    }

    public func splitArticleByLevel2Headings(
        sourceSlug: String,
        expectedUpdatedAt: String,
        sourceBody: String,
        replacement: NativeArticleExtractionReplacement
    ) throws -> NativeArticleRefactorResult {
        try prepare()
        let source = try getArticle(slug: sourceSlug)
        guard source.updatedAt == expectedUpdatedAt else { throw NativeStoreError.conflict }
        let split = ArticleKnowledgeComposer.level2Sections(in: sourceBody)
        guard !split.sections.isEmpty else { throw NativeStoreError.noLevel2Sections }

        var reservedSlugs = try existingArticleSlugs()
        var targets: [(title: String, slug: String)] = []
        for section in split.sections {
            var suffix = 1
            var slug = try allocateSlug(from: section.title)
            while reservedSlugs.contains(slug) {
                suffix += 1
                slug = try allocateSlug(from: "\(section.title)-\(suffix)")
            }
            reservedSlugs.insert(slug)
            targets.append((section.title, slug))
        }

        let indexBody = ArticleKnowledgeComposer.splitIndexBody(
            preamble: split.preamble,
            targets: targets,
            replacement: replacement
        )
        let sourceUpdated = refactoredArticle(
            source,
            body: indexBody,
            updatedAt: nextTimestamp(after: source.updatedAt)
        )
        var changes: [(previous: NativeArticle?, updated: NativeArticle)] = [
            (previous: source, updated: sourceUpdated),
        ]
        var previousTimestamp = sourceUpdated.updatedAt
        for (section, target) in zip(split.sections, targets) {
            let updatedAt = nextTimestamp(after: previousTimestamp)
            previousTimestamp = updatedAt
            changes.append((previous: nil, updated: NativeArticle(
                banner: nil,
                body: section.body.isEmpty ? "_本节暂无正文。_" : section.body,
                category: source.category,
                excerpt: "",
                media: [],
                slug: target.slug,
                status: .draft,
                tags: source.tags,
                title: target.title,
                updatedAt: updatedAt,
                publishedAt: nil,
                wordCount: wordCount(section.body),
                properties: [:],
                sourceRelativePath: MarkdownArticleSource.defaultRelativePath(for: target.slug)
            )))
        }

        let saved = try persistArticleRefactor(changes)
        guard let primary = saved.first(where: { $0.slug == source.slug }) else {
            throw NativeStoreError.fileSystem("文章拆分结果不完整")
        }
        let createdSlugs = Set(targets.map(\.slug))
        let created = saved.filter { createdSlugs.contains($0.slug) }
        return NativeArticleRefactorResult(primaryArticle: primary, createdArticles: created)
    }

    public func mergeArticle(
        sourceSlug: String,
        destinationSlug: String,
        expectedSourceUpdatedAt: String,
        expectedDestinationUpdatedAt: String,
        position: NativeArticleMergePosition
    ) throws -> NativeArticleRefactorResult {
        try prepare()
        guard sourceSlug != destinationSlug else { throw NativeStoreError.invalidArticleMerge }
        let source = try getArticle(slug: sourceSlug)
        let destination = try getArticle(slug: destinationSlug)
        guard source.updatedAt == expectedSourceUpdatedAt,
              destination.updatedAt == expectedDestinationUpdatedAt else {
            throw NativeStoreError.conflict
        }

        let mergedBody = ArticleKnowledgeComposer.mergedBody(
            source: source,
            destination: destination,
            position: position
        )
        var changes: [(previous: NativeArticle?, updated: NativeArticle)] = []
        for article in try allArticles() where article.slug != source.slug {
            let candidate = article.slug == destination.slug ? mergedBody : article.body
            let retargeted = ArticleKnowledgeComposer.retargetingArticleReferences(
                in: candidate,
                source: source,
                destinationSlug: destination.slug
            )
            guard retargeted != article.body || article.slug == destination.slug else { continue }
            let media: [NativeMedia]? = article.slug == destination.slug
                ? (destination.media + source.media).reduce(into: []) { result, item in
                    if !result.contains(where: { $0.url == item.url }) { result.append(item) }
                }
                : nil
            changes.append((previous: article, updated: refactoredArticle(
                article,
                body: retargeted,
                updatedAt: nextTimestamp(after: article.updatedAt),
                media: media
            )))
        }
        let saved = try persistArticleRefactor(changes, removing: source)
        guard let primary = saved.first(where: { $0.slug == destination.slug }) else {
            throw NativeStoreError.fileSystem("文章合并结果不完整")
        }
        return NativeArticleRefactorResult(
            primaryArticle: primary,
            updatedArticleCount: saved.count,
            removedSlugs: [source.slug]
        )
    }

    public func toggleArticleTask(
        slug: String,
        expectedUpdatedAt: String,
        lineIndex: Int,
        completed: Bool
    ) throws -> NativeArticle {
        try prepare()
        let article = try getArticle(slug: slug)
        guard article.updatedAt == expectedUpdatedAt else { throw NativeStoreError.conflict }
        let body = try ArticleKnowledgeComposer.toggleTask(
            in: article.body,
            lineIndex: lineIndex,
            completed: completed
        )
        let updated = refactoredArticle(
            article,
            body: body,
            updatedAt: nextTimestamp(after: article.updatedAt)
        )
        guard let saved = try persistArticleRefactor([
            (previous: article, updated: updated),
        ]).first else { throw NativeStoreError.notFound }
        return saved
    }

    private func refactoredArticle(
        _ article: NativeArticle,
        body: String,
        updatedAt: String,
        media: [NativeMedia]? = nil
    ) -> NativeArticle {
        NativeArticle(
            banner: article.banner,
            body: normalizeBody(body),
            category: article.category,
            excerpt: article.excerpt,
            media: media ?? article.media,
            slug: article.slug,
            status: article.status,
            tags: article.tags,
            title: article.title,
            updatedAt: updatedAt,
            publishedAt: article.publishedAt,
            wordCount: wordCount(body),
            pageViews: article.pageViews,
            properties: article.properties,
            sourceRelativePath: article.sourceRelativePath,
            sourceContentHash: article.sourceContentHash,
            sourceImportedAt: article.sourceImportedAt
        )
    }

    private func persistArticleRefactor(
        _ changes: [(previous: NativeArticle?, updated: NativeArticle)],
        removing removed: NativeArticle? = nil
    ) throws -> [NativeArticle] {
        try requireWritableArticleSource()
        var sourced: [(previous: NativeArticle?, updated: NativeArticle)] = []
        do {
            for change in changes {
                let record = try MarkdownArticleSource.write(
                    change.updated,
                    relativePath: change.updated.sourceRelativePath,
                    in: articlesURL
                )
                sourced.append((change.previous, applyingSourceRecord(record, to: change.updated)))
            }
            if let removed {
                try MarkdownArticleSource.remove(relativePath: removed.sourceRelativePath, in: articlesURL)
            }
        } catch {
            rollbackArticleRefactor(sourced, restoring: removed)
            throw error
        }

        do {
            try db().transaction {
                for change in sourced {
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
                if let removed {
                    let deletedAt = timestamp(from: Date())
                    let expiresAt = timestamp(afterDays: Self.trashRetentionDays)
                    try db().execute(
                        "UPDATE articles SET deleted_at = ?, delete_expires_at = ? WHERE slug = ?",
                        values: [.text(deletedAt), .text(expiresAt), .text(removed.slug)]
                    )
                }
            }
        } catch {
            rollbackArticleRefactor(sourced, restoring: removed)
            throw error
        }

        for change in sourced { try? trimArticleRevisions(draftKey: change.updated.slug) }
        do {
            for change in sourced { try writeArticleJSONSidecars(change.updated) }
            if let removed {
                removeArticleJSONSidecars(for: removed.slug)
                try writeTrashBackup()
            }
            try rebuildIndex()
        } catch {
            markJSONBackupNeedsRebuild()
        }
        return sourced.map(\.updated)
    }

    private func rollbackArticleRefactor(
        _ changes: [(previous: NativeArticle?, updated: NativeArticle)],
        restoring removed: NativeArticle?
    ) {
        for change in changes.reversed() {
            if let previous = change.previous {
                _ = try? MarkdownArticleSource.write(
                    previous,
                    relativePath: previous.sourceRelativePath,
                    in: articlesURL
                )
            } else {
                try? MarkdownArticleSource.remove(
                    relativePath: change.updated.sourceRelativePath,
                    in: articlesURL
                )
            }
        }
        if let removed {
            _ = try? MarkdownArticleSource.write(
                removed,
                relativePath: removed.sourceRelativePath,
                in: articlesURL
            )
        }
    }

    /// Moves or renames the source file without changing its stable slug, so
    /// comments, revisions, page views, and slug-based backlinks remain valid.
    public func moveArticleSource(
        slug: String,
        to relativePath: String,
        expectedUpdatedAt: String
    ) throws -> NativeArticle {
        try prepare()
        try requireWritableArticleSource()
        let article = try getArticle(slug: slug)
        guard article.updatedAt == expectedUpdatedAt else { throw NativeStoreError.conflict }
        let destination = try MarkdownArticleSource.validatedRelativePath(relativePath)
        guard destination != article.sourceRelativePath else { return article }
        let occupied = try db().integer(
            "SELECT COUNT(*) FROM articles WHERE source_relative_path = ? AND slug <> ?",
            values: [.text(destination), .text(article.slug)]
        ) ?? 0
        guard occupied == 0 else {
            throw NativeStoreError.fileSystem("目标 Markdown 路径已被另一篇文章占用")
        }

        let record = try MarkdownArticleSource.move(
            from: article.sourceRelativePath,
            to: destination,
            in: articlesURL
        )
        let moved = applyingSourceRecord(record, to: article)
        do {
            try insertArticle(moved, into: db())
        } catch {
            _ = try? MarkdownArticleSource.move(
                from: destination,
                to: article.sourceRelativePath,
                in: articlesURL
            )
            throw error
        }
        let repairedBacklinks = try repairBacklinks(after: [(
            oldPath: article.sourceRelativePath,
            newPath: destination,
        )])
        let finalMovedArticle = repairedBacklinks.first(where: { $0.slug == moved.slug }) ?? moved
        do {
            try writeArticleJSONSidecars(finalMovedArticle)
            for repaired in repairedBacklinks where repaired.slug != moved.slug {
                try writeArticleJSONSidecars(repaired)
            }
            try rebuildIndex()
        } catch {
            markJSONBackupNeedsRebuild()
        }
        return finalMovedArticle
    }

    public func incrementArticlePageViews(slug: String) throws -> NativeArticle {
        try prepare()
        let safeSlug = try requireSafeSegment(slug, label: "文章 slug")
        try db().execute(
            "UPDATE articles SET page_views = page_views + 1 WHERE slug = ? AND deleted_at IS NULL",
            values: [.text(safeSlug)]
        )
        guard let updated = try storedArticle(withSlug: safeSlug) else { throw NativeStoreError.notFound }
        do {
            try writeArticleJSONSidecars(updated)
            try rebuildIndex()
        } catch {
            markJSONBackupNeedsRebuild()
        }
        return updated
    }

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

    // MARK: - Article revisions and comments

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

    // MARK: - Import and persistence

    public func allocateSlug(from title: String) throws -> String {
        try prepare()
        var base = slugify(title)
        if Self.reservedMediaDirectories.contains(base) {
            base = "\(base)-note"
        }
        var candidate = base
        var suffix = 2
        while try storedArticle(withSlug: candidate, includingDeleted: true) != nil {
            candidate = "\(base)-\(suffix)"
            suffix += 1
            if suffix > 1_000 {
                throw NativeStoreError.fileSystem("无法为文章分配可用地址")
            }
        }
        return candidate
    }

    public func existingArticleSlugs() throws -> Set<String> {
        try prepare()
        var slugs = Set<String>()
        try db().query("SELECT slug FROM articles") { row in
            if let slug = row.text(at: 0) { slugs.insert(slug) }
        }
        return slugs
    }

    /// Conflict set for copy import. External mounted articles live in the
    /// same SQLite index, but should not block copying that source back into
    /// the managed `articles/` directory.
    public func existingManagedMarkdownSlugs() throws -> Set<String> {
        try prepare()
        return Set(try MarkdownArticleSource.scan(in: managedArticlesURL).compactMap(\.slug))
    }

    public func importObsidianVault(
        _ preview: NativeObsidianImportPreview
    ) async throws -> NativeObsidianImportResult {
        try prepare()
        let writeLease = try WorkspaceStorageLifecycle.beginAsyncWrite(in: rootURL)
        defer { withExtendedLifetime(writeLease) {} }
        guard markdownWorkspaceSource.mode == .copyImport else {
            throw NativeStoreError.fileSystem("复制导入前请先将 Markdown 源切换为“复制导入”")
        }
        var importedArticles: [NativeArticle] = []
        var copiedMediaURLs: [URL] = []
        var warnings = preview.warnings
        var skippedCount = preview.conflictCount
        var importedAttachmentPaths = Set<String>()

        for note in preview.importableNotes {
            let existingIsActive = try storedArticle(withSlug: note.slug, includingDeleted: false) != nil
            if existingIsActive {
                skippedCount += 1
                warnings.append("\(note.relativePath)：SQLite 中已存在 \(note.slug)，已跳过")
                continue
            }

            var body = note.body
            var media: [NativeMedia] = []
            var uploadedBySourcePath: [String: NativeMedia] = [:]
            for attachment in note.attachments {
                let sourcePath = attachment.sourceURL.standardizedFileURL.path
                let storedMedia: NativeMedia
                if let uploaded = uploadedBySourcePath[sourcePath] {
                    storedMedia = uploaded
                } else {
                    do {
                        let uploaded = try await uploadMedia(
                            fileURL: attachment.sourceURL,
                            kind: attachment.kind,
                            slug: note.slug
                        )
                        storedMedia = NativeMedia(
                            kind: uploaded.kind,
                            name: uploaded.name,
                            size: uploaded.size,
                            url: uploaded.url
                        )
                        uploadedBySourcePath[sourcePath] = storedMedia
                        if let copiedURL = mediaURL(for: uploaded.url) { copiedMediaURLs.append(copiedURL) }
                    } catch {
                        warnings.append("\(note.relativePath)：附件 \(attachment.sourceURL.lastPathComponent) 导入失败：\(error.localizedDescription)")
                        continue
                    }
                }
                if importedAttachmentPaths.insert("\(note.slug)\u{0}\(sourcePath)").inserted {
                    media.append(storedMedia)
                }
                let replacement: String
                let label = attachment.displayName
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "[", with: "\\[")
                    .replacingOccurrences(of: "]", with: "\\]")
                switch storedMedia.kind {
                case "image":
                    replacement = "![\(label)](\(storedMedia.url))"
                case "video":
                    replacement = "[视频：\(label)](\(storedMedia.url))"
                default:
                    replacement = "[附件：\(label)](\(storedMedia.url))"
                }
                body = body.replacingOccurrences(of: attachment.originalToken, with: replacement)
            }

            let updatedAt = note.updatedAt ?? timestamp(from: Date())
            let article = NativeArticle(
                banner: nil,
                body: body,
                category: note.category,
                excerpt: note.excerpt,
                media: media,
                slug: note.slug,
                status: note.status,
                tags: note.tags,
                title: note.title,
                updatedAt: updatedAt,
                publishedAt: note.status == .published ? note.publishedAt ?? updatedAt : nil,
                wordCount: wordCount(body),
                properties: try NativeArticleProperties.validated(note.properties)
            )
            importedArticles.append(article)
        }

        var sourcedImportedArticles: [NativeArticle] = []
        do {
            for article in importedArticles {
                let record = try MarkdownArticleSource.write(
                    article,
                    relativePath: article.sourceRelativePath,
                    in: articlesURL
                )
                sourcedImportedArticles.append(applyingSourceRecord(record, to: article))
            }
        } catch {
            for article in sourcedImportedArticles {
                try? MarkdownArticleSource.remove(relativePath: article.sourceRelativePath, in: articlesURL)
            }
            for url in copiedMediaURLs { try? FileManager.default.removeItem(at: url) }
            throw error
        }

        do {
            try db().transaction {
                for article in sourcedImportedArticles {
                    try insertArticle(article, into: db())
                    if article.status == .published {
                        try recordActivityEvent(
                            type: "article_published",
                            at: NativeTimestamp.date(from: article.publishedAt ?? article.updatedAt) ?? Date()
                        )
                    }
                }
            }
        } catch {
            for article in sourcedImportedArticles {
                try? MarkdownArticleSource.remove(relativePath: article.sourceRelativePath, in: articlesURL)
            }
            for url in copiedMediaURLs { try? FileManager.default.removeItem(at: url) }
            throw error
        }

        do {
            for article in sourcedImportedArticles { try writeArticleJSONSidecars(article) }
            try rebuildIndex()
            try writeActivityEventsAfterMutation()
        } catch {
            markJSONBackupNeedsRebuild()
            warnings.append("Markdown 已导入，但部分 JSON 备份需要在下次启动时重建")
        }

        return NativeObsidianImportResult(
            importedCount: sourcedImportedArticles.count,
            skippedCount: skippedCount,
            attachmentCount: importedAttachmentPaths.count,
            warnings: warnings
        )
    }

    public func saveArticle(_ article: NativeSaveArticle) throws -> NativeArticle {
        try prepare()
        try requireWritableArticleSource()
        let slug = try requireSafeSegment(article.slug, label: "文章 slug")
        let properties = try NativeArticleProperties.validated(article.properties)
        if Self.reservedMediaDirectories.contains(slug) {
            throw NativeStoreError.reservedSlug
        }
        let previous = try storedArticle(withSlug: slug)

        if let expected = article.expectedUpdatedAt {
            guard previous?.updatedAt == expected else { throw NativeStoreError.conflict }
        } else if previous != nil {
            throw NativeStoreError.slugTaken
        } else if try storedArticle(withSlug: slug, includingDeleted: true) != nil {
            throw NativeStoreError.slugTaken
        }

        let updatedAt = nextTimestamp(after: previous?.updatedAt)
        let publishedAt: String?
        if article.status == .published {
            publishedAt = previous?.publishedAt ?? updatedAt
        } else {
            publishedAt = previous?.publishedAt
        }

        let sourceRelativePath: String
        if let previous {
            sourceRelativePath = previous.sourceRelativePath
        } else if let requestedPath = article.sourceRelativePath {
            sourceRelativePath = try MarkdownArticleSource.validatedRelativePath(requestedPath)
        } else {
            sourceRelativePath = MarkdownArticleSource.defaultRelativePath(for: slug)
        }
        if previous == nil,
           FileManager.default.fileExists(
               atPath: articlesURL.appendingPathComponent(sourceRelativePath).path
            ) {
            throw NativeStoreError.fileSystem("目标 Markdown 文件已存在")
        }
        let originalFile = try MarkdownArticleSource.snapshot(relativePath: sourceRelativePath, in: articlesURL)
        if let previous,
           originalFile.data == nil || originalFile.contentHash != previous.sourceContentHash {
            _ = try refreshMarkdownSources(changedRelativePaths: [sourceRelativePath])
            throw NativeStoreError.conflict
        }
        let sourceBeforeSave = markdownWorkspaceSource
        let relocated = try relocateInboxMedia(
            slug: slug,
            body: normalizeBody(article.body),
            banner: article.banner.map(normalizeBanner),
            media: article.media.map(normalizeMedia)
        )
        let saved = NativeArticle(
            banner: relocated.banner,
            body: relocated.body,
            category: article.category.isEmpty ? "Uncategorized" : article.category,
            excerpt: article.excerpt,
            media: relocated.media,
            slug: slug,
            status: article.status,
            tags: NativeArticleTag.normalized(article.tags),
            title: article.title,
            updatedAt: updatedAt,
            publishedAt: publishedAt,
            wordCount: wordCount(relocated.body),
            pageViews: previous?.pageViews ?? 0,
            properties: properties,
            sourceRelativePath: sourceRelativePath,
            sourceContentHash: previous?.sourceContentHash,
            sourceImportedAt: previous?.sourceImportedAt
        )
        var sourcedSaved = saved
        var writtenHash: String?

        let activityType = saved.status == .published && previous?.status != .published
            ? "article_published"
            : article.expectedUpdatedAt == nil
                ? nil
                : "article_edited"

        do {
            try db().transaction {
                // Another window may have committed after our initial read.
                guard try storedArticle(withSlug: slug)?.updatedAt == previous?.updatedAt else {
                    throw NativeStoreError.conflict
                }
                try requireWritableArticleSource()
                guard markdownWorkspaceSource == sourceBeforeSave else { throw NativeStoreError.conflict }
                let sourceRecord = try MarkdownArticleSource.write(
                    saved,
                    relativePath: saved.sourceRelativePath,
                    in: articlesURL,
                    expectedContentHash: originalFile.contentHash,
                    requiresMissingFile: previous == nil
                )
                writtenHash = sourceRecord.contentHash
                sourcedSaved = applyingSourceRecord(sourceRecord, to: saved)
                if let previous {
                    _ = try insertArticleRevision(
                        draftKey: slug,
                        articleSlug: slug,
                        reason: .savedVersion,
                        snapshot: NativeArticleRevisionSnapshot(article: previous),
                        createdAt: updatedAt,
                        updatedAt: updatedAt
                    )
                }
                try insertArticle(sourcedSaved, into: db())
                if let activityType {
                    try recordActivityEvent(type: activityType, at: activityDate(from: updatedAt) ?? Date())
                }
                try trimArticleRevisions(draftKey: slug)
            }
        } catch {
            var rollbackError: Error?
            do { try rollbackInboxMedia(relocated.moves) } catch { rollbackError = error }
            if let writtenHash {
                do { try originalFile.restore(replacingContentHash: writtenHash) }
                catch { rollbackError = error }
            } else if let storeError = error as? NativeStoreError, case .conflict = storeError {
                _ = try refreshMarkdownSources(changedRelativePaths: [sourceRelativePath])
            }
            if let rollbackError { throw rollbackError }
            throw error
        }

        do {
            try writeArticleJSONSidecars(sourcedSaved)
            try rebuildIndex()
            try writeActivityEventsAfterMutation()
        } catch {
            markJSONBackupNeedsRebuild()
        }
        return sourcedSaved
    }

    /// Commits body-only changes to existing articles as one logical mutation.
    /// Markdown files are restored if a file write or the SQLite transaction fails.
    public func updateArticleBodiesAtomically(
        _ updates: [NativeArticleBodyUpdate]
    ) throws -> [NativeArticle] {
        try prepare()
        try requireWritableArticleSource()
        guard !updates.isEmpty else { return [] }

        var seen = Set<String>()
        var prepared: [(previous: NativeArticle, updated: NativeArticle)] = []
        for update in updates {
            let slug = try requireSafeSegment(update.slug, label: "文章 slug")
            guard seen.insert(slug).inserted,
                  let previous = try storedArticle(withSlug: slug),
                  previous.updatedAt == update.expectedUpdatedAt else {
                throw NativeStoreError.conflict
            }
            let updatedAt = nextTimestamp(after: previous.updatedAt)
            let body = normalizeBody(update.body)
            prepared.append((
                previous,
                NativeArticle(
                    banner: previous.banner,
                    body: body,
                    category: previous.category,
                    excerpt: previous.excerpt,
                    media: previous.media,
                    slug: previous.slug,
                    status: previous.status,
                    tags: previous.tags,
                    title: previous.title,
                    updatedAt: updatedAt,
                    publishedAt: previous.publishedAt,
                    wordCount: wordCount(body),
                    pageViews: previous.pageViews,
                    properties: previous.properties,
                    sourceRelativePath: previous.sourceRelativePath,
                    sourceContentHash: previous.sourceContentHash,
                    sourceImportedAt: previous.sourceImportedAt
                )
            ))
        }

        func restoreMarkdownFiles() {
            for item in prepared {
                _ = try? MarkdownArticleSource.write(
                    item.previous,
                    relativePath: item.previous.sourceRelativePath,
                    in: articlesURL
                )
            }
        }

        var sourcedUpdates: [NativeArticle] = []
        do {
            for item in prepared {
                let record = try MarkdownArticleSource.write(
                    item.updated,
                    relativePath: item.updated.sourceRelativePath,
                    in: articlesURL
                )
                sourcedUpdates.append(applyingSourceRecord(record, to: item.updated))
            }
        } catch {
            restoreMarkdownFiles()
            throw error
        }

        do {
            try db().transaction {
                for (index, item) in prepared.enumerated() {
                    let updated = sourcedUpdates[index]
                    _ = try insertArticleRevision(
                        draftKey: item.previous.slug,
                        articleSlug: item.previous.slug,
                        reason: .savedVersion,
                        snapshot: NativeArticleRevisionSnapshot(article: item.previous),
                        createdAt: updated.updatedAt,
                        updatedAt: updated.updatedAt
                    )
                    try insertArticle(updated, into: db())
                    try recordActivityEvent(
                        type: "article_edited",
                        at: activityDate(from: updated.updatedAt) ?? Date()
                    )
                }
            }
        } catch {
            restoreMarkdownFiles()
            throw error
        }

        for item in prepared { try trimArticleRevisions(draftKey: item.previous.slug) }
        do {
            for article in sourcedUpdates { try writeArticleJSONSidecars(article) }
            try rebuildIndex()
            try writeActivityEventsAfterMutation()
        } catch {
            markJSONBackupNeedsRebuild()
        }
        return sourcedUpdates
    }

    public func deleteArticle(slug: String, expectedUpdatedAt: String) throws {
        try requireWritableArticleSource()
        let article = try getArticle(slug: slug)
        guard article.updatedAt == expectedUpdatedAt else { throw NativeStoreError.conflict }
        let safeSlug = try requireSafeSegment(slug, label: "文章 slug")
        try MarkdownArticleSource.remove(
            relativePath: article.sourceRelativePath,
            in: articlesURL
        )
        let deletedAt = timestamp(from: Date())
        let expiresAt = timestamp(afterDays: Self.trashRetentionDays)
        try db().execute(
            "UPDATE articles SET deleted_at = ?, delete_expires_at = ? WHERE slug = ?",
            values: [.text(deletedAt), .text(expiresAt), .text(safeSlug)]
        )
        removeArticleJSONSidecars(for: safeSlug)
        try rebuildIndex()
        try writeTrashBackup()
        markJSONBackupNeedsRebuild()
    }

    // MARK: - Trash

    func listTrash() throws -> [NativeTrashItem] {
        try prepare()
        var items: [NativeTrashItem] = []

        try db().query("""
        SELECT slug, title, excerpt, deleted_at, delete_expires_at
        FROM articles
        WHERE deleted_at IS NOT NULL AND delete_expires_at IS NOT NULL
        """) { row in
            guard let slug = row.text(at: 0),
                  let title = row.text(at: 1),
                  let excerpt = row.text(at: 2),
                  let deletedAt = row.text(at: 3),
                  let expiresAt = row.text(at: 4) else {
                throw NativeStoreError.fileSystem("SQLite：回收站文章记录不完整")
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
        WHERE deleted_at IS NOT NULL AND delete_expires_at IS NOT NULL
        """) { row in
            guard let id = row.text(at: 0),
                  let text = row.text(at: 1),
                  let imagesJSON = row.text(at: 2),
                  let deletedAt = row.text(at: 3),
                  let expiresAt = row.text(at: 4) else {
                throw NativeStoreError.fileSystem("SQLite：回收站微博记录不完整")
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
            guard let restoring = try storedArticle(withSlug: safeKey, includingDeleted: true) else {
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
            guard let restoring = try moment(withID: safeKey, includingDeleted: true) else {
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
                  try db().text("SELECT deleted_at FROM articles WHERE slug = ?", values: [.text(safeKey)]) != nil else {
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
                  try db().text("SELECT deleted_at FROM moments WHERE id = ?", values: [.text(safeKey)]) != nil else {
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

        try db().query("SELECT slug, source_relative_path FROM articles WHERE deleted_at IS NOT NULL") { row in
            if let slug = row.text(at: 0) {
                articlesToDelete.append((slug, row.text(at: 1) ?? "\(slug).md"))
            }
        }
        try db().query("SELECT id, images_json FROM moments WHERE deleted_at IS NOT NULL") { row in
            guard let id = row.text(at: 0), let imagesJSON = row.text(at: 1) else { return }
            momentsToDelete.append((id: id, images: try decode(imagesJSON)))
        }

        try db().transaction {
            try db().execute("DELETE FROM articles WHERE deleted_at IS NOT NULL")
            try db().execute("DELETE FROM moments WHERE deleted_at IS NOT NULL")
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

    private func purgeExpiredTrash() throws {
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

    private func purgeExpiredArticleRevisions() throws {
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

    private func trimArticleRevisions(draftKey: String) throws {
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
            throw NativeStoreError.fileSystem("SQLite：无法读取文章版本编号")
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

    func decodeArticleRevision(_ row: SQLiteRow) throws -> NativeArticleRevision {
        guard let id = row.integer(at: 0),
              let syncID = row.text(at: 1),
              let draftKey = row.text(at: 2),
              let reasonValue = row.text(at: 4),
              let reason = NativeArticleRevisionReason(rawValue: reasonValue),
              let snapshotJSON = row.text(at: 5),
              let createdAt = row.text(at: 6),
              let updatedAt = row.text(at: 7) else {
            throw NativeStoreError.fileSystem("SQLite：文章版本记录不完整")
        }
        let snapshot: NativeArticleRevisionSnapshot = try decode(snapshotJSON)
        return NativeArticleRevision(
            id: id,
            syncID: syncID,
            draftKey: draftKey,
            articleSlug: row.text(at: 3),
            reason: reason,
            snapshot: snapshot,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func removeArticleJSONSidecars(for slug: String) {
        guard let safeSlug = try? requireSafeSegment(slug, label: "文章 slug") else { return }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: managedArticlesURL.appendingPathComponent("\(safeSlug).json"))
        try? fileManager.removeItem(at: draftsURL.appendingPathComponent("\(safeSlug).json"))
    }

    private func writeArticleSidecars(_ article: NativeArticle) throws {
        try requireWritableArticleSource()
        let record = try MarkdownArticleSource.write(
            article,
            relativePath: article.sourceRelativePath,
            in: articlesURL
        )
        let sourced = applyingSourceRecord(record, to: article)
        try db().execute(
            "UPDATE articles SET source_relative_path = ?, source_content_hash = ?, source_imported_at = ? WHERE slug = ?",
            values: [
                .text(sourced.sourceRelativePath),
                sourced.sourceContentHash.map(SQLiteValue.text) ?? .null,
                sourced.sourceImportedAt.map(SQLiteValue.text) ?? .null,
                .text(sourced.slug),
            ]
        )
        try writeArticleJSONSidecars(sourced)
    }

    private func writeArticleJSONSidecars(_ article: NativeArticle) throws {
        let safeSlug = try requireSafeSegment(article.slug, label: "文章 slug")
        try writeJSON(article, to: managedArticlesURL.appendingPathComponent("\(safeSlug).json"))
        try writeJSON(article, to: draftsURL.appendingPathComponent("\(safeSlug).json"))
        if !FileManager.default.fileExists(atPath: articleSidecarsMarkerURL.path) {
            try Data().write(to: articleSidecarsMarkerURL, options: .atomic)
        }
    }

    private func removeArticleFiles(for slug: String, sourceRelativePath: String? = nil) {
        guard let safeSlug = try? requireSafeSegment(slug, label: "文章 slug") else { return }
        removeArticleJSONSidecars(for: safeSlug)
        if let sourceRelativePath, !markdownWorkspaceSource.mode.isReadOnly {
            try? MarkdownArticleSource.remove(relativePath: sourceRelativePath, in: articlesURL)
        }
        guard !Self.reservedMediaDirectories.contains(safeSlug) else { return }
        let articleMediaURL = mediaURL.appendingPathComponent(safeSlug, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: articleMediaURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let candidates = files.compactMap { fileURL -> NativeMedia? in
            guard (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true,
                  let filename = try? requireSafeSegment(fileURL.lastPathComponent, label: "媒体文件") else {
                return nil
            }
            return NativeMedia(kind: "image", name: filename, size: 0, url: "/media/\(safeSlug)/\(filename)")
        }
        try? removeUnreferencedMediaFiles(candidates, includingDeleted: true)
        if (try? FileManager.default.contentsOfDirectory(atPath: articleMediaURL.path).isEmpty) == true {
            try? FileManager.default.removeItem(at: articleMediaURL)
        }
    }

    private func relocateInboxMedia(
        slug: String,
        body: String,
        banner: NativeBanner?,
        media: [NativeMedia]
    ) throws -> (body: String, banner: NativeBanner?, media: [NativeMedia], moves: [(source: URL, destination: URL)]) {
        var nextBody = body
        var nextBanner = banner
        var nextMedia: [NativeMedia] = []
        var moves: [(source: URL, destination: URL)] = []

        func relocate(_ storedPath: String) throws -> String {
            let normalized = normalizeMediaURL(storedPath)
            guard let range = normalized.range(of: "/media/inbox/") else { return normalized }
            let filename = try requireSafeSegment(String(normalized[range.upperBound...]), label: "媒体文件")
            let source = mediaURL.appendingPathComponent("inbox").appendingPathComponent(filename)
            let destinationDirectory = mediaURL.appendingPathComponent(slug, isDirectory: true)
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            let destination = destinationDirectory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: source.path) {
                if FileManager.default.fileExists(atPath: destination.path) {
                    throw NativeStoreError.fileSystem("目标媒体文件已存在：\(filename)")
                }
                try FileManager.default.moveItem(at: source, to: destination)
                moves.append((source, destination))
            }
            return "/media/\(slug)/\(filename)"
        }

        do {
            for item in media {
                let nextURL = try relocate(item.url)
                if nextURL != item.url {
                    nextBody = nextBody.replacingOccurrences(of: item.url, with: nextURL)
                }
                nextMedia.append(NativeMedia(kind: item.kind, name: item.name, size: item.size, url: nextURL))
            }
            if let banner {
                let nextURL = try relocate(banner.url)
                if nextURL != banner.url {
                    nextBody = nextBody.replacingOccurrences(of: banner.url, with: nextURL)
                }
                nextBanner = NativeBanner(alt: banner.alt, name: banner.name, size: banner.size, url: nextURL)
            }
        } catch {
            try rollbackInboxMedia(moves)
            throw error
        }
        return (nextBody, nextBanner, nextMedia, moves)
    }

    private func rollbackInboxMedia(_ moves: [(source: URL, destination: URL)]) throws {
        for move in moves.reversed() {
            try FileManager.default.moveItem(at: move.destination, to: move.source)
        }
    }

    // MARK: - Media

    func uploadMedia(fileURL: URL, kind: String, slug: String? = nil) async throws -> NativeUploadedMedia {
        try prepare()
        let writeLease = try WorkspaceStorageLifecycle.beginAsyncWrite(in: rootURL)
        defer { withExtendedLifetime(writeLease) {} }
        let targetSlug = try requireSafeSegment(slug?.isEmpty == false ? slug! : "inbox", label: "媒体目录")
        if kind == "video", targetSlug == "moments",
           fileURL.pathExtension.caseInsensitiveCompare("mp4") != .orderedSame {
            throw NativeStoreError.fileSystem("微博视频仅支持 MP4 格式")
        }
        let targetDirectory = mediaURL.appendingPathComponent(targetSlug, isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

        let originalName = fileURL.lastPathComponent.isEmpty ? "media" : fileURL.lastPathComponent
        let extensionName = fileURL.pathExtension.isEmpty ? "bin" : fileURL.pathExtension.lowercased()
        let filename = "\(UUID().uuidString.lowercased()).\(extensionName)"
        let targetURL = targetDirectory.appendingPathComponent(filename)
        do {
            // Large videos can take seconds to copy. Suspending on a detached
            // utility task keeps the LocalBlogStore actor responsive for reads,
            // search, and unrelated saves while the filesystem does the work.
            let size = try await Task.detached(priority: .utility) {
                try FileManager.default.copyItem(at: fileURL, to: targetURL)
                return (try FileManager.default.attributesOfItem(atPath: targetURL.path)[.size] as? NSNumber)?
                    .intValue ?? 0
            }.value
            let mediaKind = ["image", "video", "file"].contains(kind) ? kind : "file"
            if mediaKind == "image" { try recordActivity(type: "image_published", at: Date()) }
            return NativeUploadedMedia(
                key: "\(targetSlug)/\(filename)",
                kind: mediaKind,
                name: originalName,
                size: size,
                url: "/media/\(targetSlug)/\(filename)"
            )
        } catch {
            try? FileManager.default.removeItem(at: targetURL)
            throw NativeStoreError.fileSystem(error.localizedDescription)
        }
    }

    public func mediaURL(
        for storedPath: String,
        relativeToMarkdownSource sourceRelativePath: String? = nil
    ) -> URL? {
        let normalized = normalizeMediaURL(storedPath)
        if let range = normalized.range(of: "/media/") {
            let parts = normalized[range.upperBound...].split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count == 2,
                  let slug = try? requireSafeSegment(String(parts[0]), label: "媒体目录"),
                  let filename = try? requireSafeSegment(String(parts[1]), label: "媒体文件") else {
                return nil
            }
            return mediaURL.appendingPathComponent(slug).appendingPathComponent(filename)
        }

        guard let sourceRelativePath,
              URL(string: storedPath)?.scheme == nil else { return nil }
        let decoded = (storedPath.removingPercentEncoding ?? storedPath)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .replacingOccurrences(of: "\\", with: "/")
        guard !decoded.isEmpty else { return nil }
        let root = articlesURL.standardizedFileURL.resolvingSymlinksInPath()
        let noteURL = root.appendingPathComponent(sourceRelativePath).standardizedFileURL
        let candidate = decoded.hasPrefix("/")
            ? root.appendingPathComponent(String(decoded.dropFirst()))
            : noteURL.deletingLastPathComponent().appendingPathComponent(decoded)
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved.path.hasPrefix(rootPrefix),
              FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        return resolved
    }

    func discardUnreferencedMedia(_ media: [NativeMedia]) throws {
        try prepare()
        guard !media.isEmpty else { return }

        try removeUnreferencedMediaFiles(media, includingDeleted: true)
    }

    private func removeUnreferencedMediaFiles(
        _ media: [NativeMedia],
        includingDeleted: Bool
    ) throws {
        for item in media {
            let normalizedURL = normalizeMediaURL(item.url)
            let referenceCount = try db().integer(
                "SELECT COUNT(*) FROM media_references WHERE normalized_url = ?",
                values: [.text(normalizedURL)]
            ) ?? 0
            guard referenceCount == 0, let fileURL = mediaURL(for: normalizedURL) else {
                continue
            }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Database and compatibility exports

    func db() throws -> SQLiteDatabase {
        guard let database else { throw NativeStoreError.fileSystem("SQLite：数据库尚未准备好") }
        return database
    }

    private func markJSONBackupNeedsRebuild() {
        jsonBackupVerified = false
        try? database?.execute("DELETE FROM metadata WHERE key = 'json_export_v2'")
    }

    private func exportJsonBackupIfNeeded() throws {
        if jsonBackupVerified { return }
        let database = try db()
        let exportMarkedDone = try database.text("SELECT value FROM metadata WHERE key = 'json_export_v2'") == "done"
        if exportMarkedDone, try jsonBackupFilesArePresent() {
            jsonBackupVerified = true
            return
        }

        try rebuildArticleExports()
        try rebuildMomentsIndex()
        try writeActivityEvents()
        try writeTrashBackup()
        try database.execute("INSERT OR REPLACE INTO metadata(key, value) VALUES('json_export_v1', 'done')")
        try database.execute("INSERT OR REPLACE INTO metadata(key, value) VALUES('json_export_v2', 'done')")
        jsonBackupVerified = true
    }

    /// JSON is a compatibility export, not an input source after migration.
    /// Check its shape without decoding every article body on each new store;
    /// a missing file or a failed prior write clears the metadata marker and
    /// takes the slower rebuild path below.
    private func jsonBackupFilesArePresent() throws -> Bool {
        let fileManager = FileManager.default
        guard let stampDate = try? jsonExportStampURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate else { return false }
        func isCurrentExport(_ url: URL) -> Bool {
            guard let modifiedAt = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate else { return false }
            return modifiedAt <= stampDate
        }

        var articleSlugs: [String] = []
        try db().query("SELECT slug FROM articles WHERE deleted_at IS NULL") { row in
            if let slug = row.text(at: 0) { articleSlugs.append(slug) }
        }
        for slug in articleSlugs {
            guard isCurrentExport(managedArticlesURL.appendingPathComponent("\(slug).json")) else {
                return false
            }
        }

        if !fileManager.fileExists(atPath: articleSidecarsMarkerURL.path) {
            let indexURL = managedArticlesURL.appendingPathComponent("index.json")
            guard isCurrentExport(indexURL) else { return false }
        }

        let eventsURL = activityURL.appendingPathComponent("events.json")
        guard isCurrentExport(eventsURL), isCurrentExport(momentsIndexURL) else { return false }

        if fileManager.fileExists(atPath: momentSidecarsMarkerURL.path) {
            var momentIDs: [String] = []
            try db().query("SELECT id FROM moments WHERE deleted_at IS NULL") { row in
                if let id = row.text(at: 0) { momentIDs.append(id) }
            }
            for id in momentIDs {
                guard isCurrentExport(momentsURL.appendingPathComponent("\(id).json")) else {
                    return false
                }
            }
        }

        return isCurrentExport(trashIndexURL)
    }

    func loadLegacyArticles() throws -> [NativeArticle] {
        let indexURL = managedArticlesURL.appendingPathComponent("index.json")
        let usesSidecars = FileManager.default.fileExists(atPath: articleSidecarsMarkerURL.path)
        if !usesSidecars, FileManager.default.fileExists(atPath: indexURL.path) {
            let indexed: [NativeArticle]
            do {
                indexed = try JSONDecoder().decode([NativeArticle].self, from: Data(contentsOf: indexURL))
            } catch {
                throw NativeStoreError.fileSystem("无法读取 \(indexURL.lastPathComponent)：\(error.localizedDescription)")
            }

            var bySlug: [String: NativeArticle] = [:]
            for article in indexed where !article.slug.isEmpty {
                let slug = try requireSafeSegment(article.slug, label: "文章 slug")
                let file = managedArticlesURL.appendingPathComponent("\(slug).json")
                if FileManager.default.fileExists(atPath: file.path) {
                    let fromFile = try readArticle(at: file)
                    let fileSlug = try requireSafeSegment(fromFile.slug, label: "文章 slug")
                    guard fileSlug == slug else {
                        throw NativeStoreError.fileSystem("文章 JSON 的 slug 与 index.json 不一致")
                    }
                    bySlug[slug] = fromFile
                } else {
                    bySlug[slug] = normalize(article)
                }
            }
            return Array(bySlug.values)
        }

        var bySlug: [String: NativeArticle] = [:]
        let files = try FileManager.default.contentsOfDirectory(
            at: managedArticlesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for file in files where file.pathExtension.lowercased() == "json"
            && file.lastPathComponent != "index.json" {
            let article = try readArticle(at: file)
            if !article.slug.isEmpty {
                let slug = try requireSafeSegment(article.slug, label: "文章 slug")
                bySlug[slug] = article
            }
        }
        return Array(bySlug.values)
    }

    func loadLegacyMoments() throws -> [NativeMoment] {
        var byID: [String: NativeMoment] = [:]
        let usesSidecars = FileManager.default.fileExists(atPath: momentSidecarsMarkerURL.path)
        if !usesSidecars, FileManager.default.fileExists(atPath: momentsIndexURL.path) {
            do {
                let indexed = try JSONDecoder().decode([NativeMoment].self, from: Data(contentsOf: momentsIndexURL))
                for moment in indexed where !moment.id.isEmpty {
                    let id = try requireSafeSegment(moment.id, label: "微博 ID")
                    byID[id] = moment
                }
            } catch {
                throw NativeStoreError.fileSystem("无法读取 \(momentsIndexURL.lastPathComponent)：\(error.localizedDescription)")
            }
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: momentsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for file in files where file.pathExtension.lowercased() == "json" && file.lastPathComponent != "index.json" {
            let moment = try readMoment(at: file)
            if !moment.id.isEmpty {
                let id = try requireSafeSegment(moment.id, label: "微博 ID")
                byID[id] = moment
            }
        }
        return Array(byID.values)
    }

    func loadLegacyActivityEvents() throws -> [NativeActivityEvent] {
        let legacyURL = activityURL.appendingPathComponent("events.json")
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return [] }
        do {
            return try JSONDecoder().decode([NativeActivityEvent].self, from: Data(contentsOf: legacyURL))
        } catch {
            throw NativeStoreError.fileSystem("无法读取 \(legacyURL.lastPathComponent)：\(error.localizedDescription)")
        }
    }

    func loadLegacyTrashBackup() throws -> NativeTrashBackup {
        guard FileManager.default.fileExists(atPath: trashIndexURL.path) else {
            return NativeTrashBackup(articles: [], moments: [])
        }
        do {
            let decoded = try JSONDecoder().decode(NativeTrashBackup.self, from: Data(contentsOf: trashIndexURL))
            let articles = try decoded.articles.map { entry -> NativeTrashedArticle in
                let article = normalize(entry.article)
                _ = try requireSafeSegment(article.slug, label: "回收站文章 slug")
                guard NativeTimestamp.date(from: entry.deletedAt) != nil,
                      NativeTimestamp.date(from: entry.expiresAt) != nil else {
                    throw NativeStoreError.fileSystem("回收站文章的时间戳无效")
                }
                return NativeTrashedArticle(article: article, deletedAt: entry.deletedAt, expiresAt: entry.expiresAt)
            }
            let moments = try decoded.moments.map { entry -> NativeTrashedMoment in
                _ = try requireSafeSegment(entry.moment.id, label: "回收站微博 ID")
                guard NativeTimestamp.date(from: entry.deletedAt) != nil,
                      NativeTimestamp.date(from: entry.expiresAt) != nil else {
                    throw NativeStoreError.fileSystem("回收站微博的时间戳无效")
                }
                return entry
            }
            return NativeTrashBackup(articles: articles, moments: moments)
        } catch let error as NativeStoreError {
            throw error
        } catch {
            throw NativeStoreError.fileSystem("无法读取 \(trashIndexURL.lastPathComponent)：\(error.localizedDescription)")
        }
    }

    func importArticles(_ articles: [NativeArticle], into database: SQLiteDatabase) throws {
        if try database.integer("SELECT COUNT(*) FROM articles") == 0 {
            for article in articles { try insertArticle(article, into: database) }
            return
        }
        for article in articles {
            let found = try database.integer(
                "SELECT COUNT(*) FROM articles WHERE slug = ?",
                values: [.text(article.slug)]
            ) ?? 0
            if found == 0 { try insertArticle(article, into: database) }
        }
    }

    func importMoments(_ moments: [NativeMoment], into database: SQLiteDatabase) throws {
        if try database.integer("SELECT COUNT(*) FROM moments") == 0 {
            for moment in moments { try insertMoment(moment, into: database) }
            return
        }
        for moment in moments {
            let found = try database.integer(
                "SELECT COUNT(*) FROM moments WHERE id = ?",
                values: [.text(moment.id)]
            ) ?? 0
            if found == 0 { try insertMoment(moment, into: database) }
        }
    }

    func importActivityEvents(_ events: [NativeActivityEvent], into database: SQLiteDatabase) throws {
        guard try database.integer("SELECT COUNT(*) FROM activity_events") == 0 else { return }
        for event in events { try insertActivity(event, into: database) }
    }

    func importTrashedArticles(_ articles: [NativeTrashedArticle], into database: SQLiteDatabase) throws {
        for entry in articles {
            let found = try database.integer(
                "SELECT COUNT(*) FROM articles WHERE slug = ?",
                values: [.text(entry.article.slug)]
            ) ?? 0
            guard found == 0 else { continue }
            try insertArticle(
                entry.article,
                deletedAt: entry.deletedAt,
                deleteExpiresAt: entry.expiresAt,
                into: database
            )
        }
    }

    func importTrashedMoments(_ moments: [NativeTrashedMoment], into database: SQLiteDatabase) throws {
        for entry in moments {
            let found = try database.integer(
                "SELECT COUNT(*) FROM moments WHERE id = ?",
                values: [.text(entry.moment.id)]
            ) ?? 0
            guard found == 0 else { continue }
            try insertMoment(
                entry.moment,
                deletedAt: entry.deletedAt,
                deleteExpiresAt: entry.expiresAt,
                into: database
            )
        }
    }

    func storedArticle(withSlug slug: String, includingDeleted: Bool = false) throws -> NativeArticle? {
        var result: NativeArticle?
        let whereClause = includingDeleted ? "slug = ?" : "deleted_at IS NULL AND slug = ?"
        try db().query(articleSelect + " WHERE \(whereClause)", values: [.text(slug)]) { row in
            result = try decodeArticle(row)
        }
        return result
    }

    func allArticles(includingDeleted: Bool = false) throws -> [NativeArticle] {
        var articles: [NativeArticle] = []
        let whereClause = includingDeleted ? "" : "WHERE deleted_at IS NULL"
        try db().query(articleSelect + " \(whereClause) ORDER BY updated_at DESC") { row in
            articles.append(try decodeArticle(row))
        }
        return articles
    }

    func allArticleSummaries() throws -> [NativeArticleSummary] {
        var articles: [NativeArticleSummary] = []
        try db().query(
            "\(articleSummarySelect) WHERE deleted_at IS NULL ORDER BY updated_at DESC"
        ) { row in
            articles.append(try decodeArticleSummary(row))
        }
        return articles
    }

    func indexedArticleGraph(nodes: [NativeArticleSummary]) throws -> NativeArticleGraph {
        let resolver = NativeArticleLinkIdentityIndex(nodes)
        let nodesBySlug = Dictionary(uniqueKeysWithValues: nodes.map { ($0.slug, $0) })
        var edges: [NativeArticleGraphEdge] = []
        var targetsBySource: [String: Set<String>] = [:]
        try db().query("""
        SELECT links.source_slug, links.target_reference
        FROM article_link_references AS links
        JOIN articles AS source ON source.slug = links.source_slug
        WHERE source.deleted_at IS NULL
        ORDER BY source.updated_at DESC, links.position, links.target_reference
        """) { row in
            guard let sourceSlug = row.text(at: 0),
                  nodesBySlug[sourceSlug] != nil,
                  let reference = row.text(at: 1),
                  let target = resolver.resolve(reference),
                  targetsBySource[sourceSlug, default: []].insert(target.slug).inserted else {
                return
            }
            edges.append(NativeArticleGraphEdge(sourceSlug: sourceSlug, targetSlug: target.slug))
        }
        return NativeArticleGraph(nodes: nodes, edges: edges)
    }

    func indexedOutgoingArticles(
        from sourceSlug: String,
        summariesBySlug: [String: NativeArticleSummary],
        resolver: NativeArticleLinkIdentityIndex
    ) throws -> [NativeArticleSummary] {
        var articles: [NativeArticleSummary] = []
        var seen = Set<String>()
        try db().query("""
        SELECT target_reference
        FROM article_link_references
        WHERE source_slug = ?
        ORDER BY position, target_reference
        """, values: [.text(sourceSlug)]) { row in
            guard let reference = row.text(at: 0),
                  let target = resolver.resolve(reference),
                  seen.insert(target.slug).inserted,
                  let summary = summariesBySlug[target.slug] else { return }
            articles.append(summary)
        }
        return articles
    }

    func indexedIncomingArticles(
        to target: NativeArticleSummary,
        summariesBySlug: [String: NativeArticleSummary],
        resolver: NativeArticleLinkIdentityIndex
    ) throws -> [NativeArticleSummary] {
        let identities = Set([target.title, target.slug] + target.aliases)
            .map(NativeArticleLinkIdentityIndex.folded)
            .filter { !$0.isEmpty }
            .sorted()
        guard !identities.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: identities.count).joined(separator: ", ")
        var values = identities.map(SQLiteValue.text)
        values.append(.text(NativeArticleLinkIdentityIndex.normalizedPath(target.sourceRelativePath)))
        values.append(.text(target.slug))

        var articles: [NativeArticleSummary] = []
        var seen = Set<String>()
        try db().query("""
        SELECT links.source_slug, links.target_reference
        FROM article_link_references AS links
        JOIN articles AS source ON source.slug = links.source_slug
        WHERE source.deleted_at IS NULL
          AND (links.target_identity IN (\(placeholders)) OR links.target_path = ?)
          AND links.source_slug <> ?
        ORDER BY source.updated_at DESC, links.position, links.target_reference
        """, values: values) { row in
            guard let sourceSlug = row.text(at: 0),
                  let reference = row.text(at: 1),
                  resolver.resolve(reference)?.slug == target.slug,
                  seen.insert(sourceSlug).inserted,
                  let summary = summariesBySlug[sourceSlug] else { return }
            articles.append(summary)
        }
        return articles
    }

    func mentionCandidates(
        containing title: String,
        excluding slug: String
    ) throws -> [NativeArticle] {
        let target = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard target.count >= 2 else { return [] }
        let predicate: String
        let value: SQLiteValue
        if target.count >= 3 {
            predicate = "article_mention_search MATCH ?"
            value = .text("\"\(target.replacingOccurrences(of: "\"", with: "\"\""))\"")
        } else {
            predicate = "instr(lower(article_mention_search.body), lower(?)) > 0"
            value = .text(target)
        }
        var candidates: [NativeArticle] = []
        try db().query("""
        \(qualifiedArticleSelect("candidate"))
        JOIN article_mention_search ON article_mention_search.source_slug = candidate.slug
        WHERE candidate.deleted_at IS NULL
          AND candidate.slug <> ?
          AND \(predicate)
        ORDER BY candidate.updated_at DESC, candidate.slug
        """, values: [.text(slug), value]) { row in
            candidates.append(try decodeArticle(row))
        }
        return candidates
    }

    func insertArticle(
        _ article: NativeArticle,
        deletedAt: String? = nil,
        deleteExpiresAt: String? = nil,
        into database: SQLiteDatabase
    ) throws {
        var previousIndexedBody: String?
        var previousWasActive = false
        try database.query(
            "SELECT body, deleted_at FROM articles WHERE slug = ?",
            values: [.text(article.slug)]
        ) { row in
            previousIndexedBody = row.text(at: 0)
            previousWasActive = row.text(at: 1) == nil
        }
        let bannerJSON: SQLiteValue
        if let banner = article.banner {
            bannerJSON = .text(try jsonString(banner))
        } else {
            bannerJSON = .null
        }
        try database.execute("""
        INSERT INTO articles(
            slug, title, body, category, excerpt, banner_json, media_json, status,
            tags_json, updated_at, published_at, word_count, page_views, deleted_at, delete_expires_at,
            properties_json, source_relative_path, source_content_hash, source_imported_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(slug) DO UPDATE SET
            title = excluded.title,
            body = excluded.body,
            category = excluded.category,
            excerpt = excluded.excerpt,
            banner_json = excluded.banner_json,
            media_json = excluded.media_json,
            status = excluded.status,
            tags_json = excluded.tags_json,
            updated_at = excluded.updated_at,
            published_at = excluded.published_at,
            word_count = excluded.word_count,
            page_views = excluded.page_views,
            deleted_at = excluded.deleted_at,
            delete_expires_at = excluded.delete_expires_at,
            properties_json = excluded.properties_json,
            source_relative_path = excluded.source_relative_path,
            source_content_hash = excluded.source_content_hash,
            source_imported_at = excluded.source_imported_at
        """, values: [
            .text(article.slug),
            .text(article.title),
            .text(article.body),
            .text(article.category),
            .text(article.excerpt),
            bannerJSON,
            .text(try jsonString(article.media)),
            .text(article.status.rawValue),
            .text(try jsonString(article.tags)),
            .text(article.updatedAt),
            article.publishedAt.map(SQLiteValue.text) ?? .null,
            // Word count is derived from the body. Imported sidecars may contain
            // an older cached value, so recompute it in the same transaction that
            // updates the article and its other derived indexes.
            .integer(wordCount(article.body)),
            .integer(article.pageViews),
            deletedAt.map(SQLiteValue.text) ?? .null,
            deleteExpiresAt.map(SQLiteValue.text) ?? .null,
            .text(try jsonString(article.properties)),
            .text(article.sourceRelativePath),
            article.sourceContentHash.map(SQLiteValue.text) ?? .null,
            article.sourceImportedAt.map(SQLiteValue.text) ?? .null,
        ])

        let isActive = deletedAt == nil
        try replaceArticleFilterIndexes(article, isActive: isActive, in: database)
        try replaceShortSearchDocument(
            type: "article",
            id: article.slug,
            source: articleSearchSource(article),
            isActive: isActive,
            in: database
        )
        try replaceMediaReferences(
            ownerType: "article",
            ownerID: article.slug,
            urls: article.media.map(\.url)
                + (article.banner.map { [$0.url] } ?? [])
                + embeddedMediaURLs(in: article.body),
            in: database
        )
        if previousIndexedBody == nil
            || previousIndexedBody != article.body
            || previousWasActive != isActive {
            try database.execute(
                "DELETE FROM article_link_references WHERE source_slug = ?",
                values: [.text(article.slug)]
            )
            if isActive {
                try insertArticleLinkReferences(
                    sourceSlug: article.slug,
                    body: article.body,
                    into: database
                )
            }
        }
    }

    func insertArticleLinkReferences(
        sourceSlug: String,
        body: String,
        into database: SQLiteDatabase
    ) throws {
        var seen = Set<String>()
        for (position, target) in NativeArticleLink.references(in: body).enumerated()
            where seen.insert(target).inserted {
            try database.execute(
                """
                INSERT INTO article_link_references(
                    source_slug, target_reference, target_identity, target_path, position
                ) VALUES(?, ?, ?, ?, ?)
                """,
                values: [
                    .text(sourceSlug),
                    .text(target),
                    .text(NativeArticleLinkIdentityIndex.folded(target)),
                    .text(NativeArticleLinkIdentityIndex.normalizedPath(target)),
                    .integer(position),
                ]
            )
        }
    }

    private func decodeArticle(_ row: SQLiteRow) throws -> NativeArticle {
        guard let slug = row.text(at: 0),
              let title = row.text(at: 1),
              let body = row.text(at: 2),
              let category = row.text(at: 3),
              let excerpt = row.text(at: 4),
              let mediaJSON = row.text(at: 6),
              let statusValue = row.text(at: 7),
              let tagsJSON = row.text(at: 8),
              let updatedAt = row.text(at: 9),
              let status = NativeArticleStatus(rawValue: statusValue) else {
            throw NativeStoreError.fileSystem("SQLite：文章记录不完整")
        }
        return NativeArticle(
            banner: try decodeOptional(row.text(at: 5)),
            body: body,
            category: category,
            excerpt: excerpt,
            media: try decode(mediaJSON),
            slug: slug,
            status: status,
            tags: try decode(tagsJSON),
            title: title,
            updatedAt: updatedAt,
            publishedAt: row.text(at: 10),
            wordCount: row.integer(at: 11) ?? wordCount(body),
            pageViews: row.integer(at: 12) ?? 0,
            properties: try decode(row.text(at: 15) ?? "{}"),
            sourceRelativePath: row.text(at: 16) ?? "\(slug).md",
            sourceContentHash: row.text(at: 17),
            sourceImportedAt: row.text(at: 18)
        )
    }

    private func decodeArticleSummary(_ row: SQLiteRow) throws -> NativeArticleSummary {
        guard let slug = row.text(at: 0),
              let title = row.text(at: 1),
              let category = row.text(at: 2),
              let excerpt = row.text(at: 3),
              let statusValue = row.text(at: 5),
              let status = NativeArticleStatus(rawValue: statusValue),
              let tagsJSON = row.text(at: 6),
              let updatedAt = row.text(at: 7) else {
            throw NativeStoreError.fileSystem("SQLite：文章摘要记录不完整")
        }
        let properties: [String: NativeArticlePropertyValue] = try decode(row.text(at: 11) ?? "{}")
        return NativeArticleSummary(
            aliases: NativeArticleAlias.values(from: properties),
            banner: try decodeOptional(row.text(at: 4)),
            category: category,
            excerpt: excerpt,
            pageViews: row.integer(at: 10) ?? 0,
            properties: properties,
            publishedAt: row.text(at: 8),
            slug: slug,
            sourceRelativePath: row.text(at: 12) ?? "\(slug).md",
            status: status,
            tags: try decode(tagsJSON),
            title: title,
            updatedAt: updatedAt,
            wordCount: row.integer(at: 9) ?? 0
        )
    }

    private func moment(withID id: String, includingDeleted: Bool = false) throws -> NativeMoment? {
        var result: NativeMoment?
        let whereClause = includingDeleted ? "id = ?" : "deleted_at IS NULL AND id = ?"
        try db().query(
            momentSelect + " WHERE \(whereClause)",
            values: [.text(id)]
        ) { row in
            result = try decodeMoment(row)
        }
        return result
    }

    func allMoments(includingDeleted: Bool = false) throws -> [NativeMoment] {
        var moments: [NativeMoment] = []
        let whereClause = includingDeleted ? "" : "WHERE deleted_at IS NULL"
        try db().query(momentSelect + " \(whereClause) ORDER BY created_at DESC, id DESC") { row in
            moments.append(try decodeMoment(row))
        }
        return moments
    }

    private func allQuestionAnswers() throws -> [NativeQuestionAnswer] {
        var answers: [NativeQuestionAnswer] = []
        try db().query(questionAnswerSelect) { row in
            answers.append(try decodeQuestionAnswer(row))
        }
        return answers
    }

    private func questionAnswer(withID id: String) throws -> NativeQuestionAnswer? {
        var answer: NativeQuestionAnswer?
        try db().query(
            questionAnswerSelect + " WHERE id = ?",
            values: [.text(id)]
        ) { row in
            answer = try decodeQuestionAnswer(row)
        }
        return answer
    }

    private func normalizedQuestionAnswerContent(
        body: String,
        images: [NativeMedia]
    ) throws -> (body: String, images: [NativeMedia]) {
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedImages = Array(images
            .filter { $0.isImage && !$0.url.isEmpty }
            .map(normalizeMedia)
            .prefix(9))
        guard normalizedBody.count <= 10_000,
              !normalizedBody.isEmpty || !normalizedImages.isEmpty else {
            throw NativeStoreError.invalidAnswer
        }
        return (normalizedBody, normalizedImages)
    }

    private func latestMomentCreatedAt() throws -> String? {
        try db().text("SELECT MAX(created_at) FROM moments WHERE deleted_at IS NULL")
    }

    private func momentCandidates(
        matching filter: NativeMomentFilter,
        before cursor: NativeMomentCursor?,
        limit: Int
    ) throws -> [NativeMoment] {
        let query = momentCandidateQuery(matching: filter, before: cursor)
        var moments: [NativeMoment] = []
        var values = query.values
        values.append(.integer(limit))
        try db().query(
            """
            \(momentSelect)
            WHERE \(query.whereClause)
            ORDER BY created_at DESC, id DESC
            LIMIT ?
            """,
            values: values
        ) { row in
            moments.append(try decodeMoment(row))
        }
        return moments
    }

    private func momentCandidateCount(matching filter: NativeMomentFilter) throws -> Int {
        let query = momentCandidateQuery(matching: filter, before: nil)
        return try db().integer(
            "SELECT COUNT(*) FROM moments WHERE \(query.whereClause)",
            values: query.values
        ) ?? 0
    }

    private func momentCandidateQuery(
        matching filter: NativeMomentFilter,
        before cursor: NativeMomentCursor?
    ) -> (whereClause: String, values: [SQLiteValue]) {
        var predicates = ["deleted_at IS NULL"]
        var values: [SQLiteValue] = []

        if filter.favoritesOnly {
            predicates.append("is_favorite = 1")
        }

        if let interval = momentDateInterval(for: filter.dateFilter) {
            predicates.append("created_at >= ?")
            values.append(.text(NativeTimestamp.string(from: interval.start)))
            predicates.append("created_at < ?")
            values.append(.text(NativeTimestamp.string(from: interval.end)))
        }

        if !filter.tags.isEmpty {
            let tagPredicates = filter.tags.map { _ in """
            EXISTS (
                SELECT 1 FROM moment_tags AS selected_moment_tag
                WHERE selected_moment_tag.moment_id = moments.id
                  AND selected_moment_tag.normalized_tag = ?
            )
            """ }
            predicates.append("(\(tagPredicates.joined(separator: " OR ")))")
            values.append(contentsOf: filter.tags.map { tag in
                .text(normalizedSearchIdentity(tag))
            })
        }

        if !filter.searchText.isEmpty {
            let search = momentSearchPredicate(filter.searchText)
            predicates.append(search.sql)
            values.append(contentsOf: search.values)
        }

        if let cursor {
            predicates.append("(created_at < ? OR (created_at = ? AND id < ?))")
            values.append(.text(cursor.createdAt))
            values.append(.text(cursor.createdAt))
            values.append(.text(cursor.id))
        }

        return (predicates.joined(separator: " AND "), values)
    }

    private func momentSearchPredicate(
        _ rawQuery: String
    ) -> (sql: String, values: [SQLiteValue]) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if isDateLikeMomentSearch(query) {
            let year = "CAST(substr(created_at, 1, 4) AS INTEGER)"
            let month = "CAST(substr(created_at, 6, 2) AS INTEGER)"
            let day = "CAST(substr(created_at, 9, 2) AS INTEGER)"
            return (
                """
                (instr(lower(text), lower(?)) > 0
                 OR instr(lower(tags_json), lower(?)) > 0
                 OR instr(lower(created_at), lower(?)) > 0
                 OR instr(\(year) || '-' || \(month) || '-' || \(day), ?) > 0
                 OR instr(\(year) || '/' || \(month) || '/' || \(day), ?) > 0
                 OR instr(\(year) || '年' || \(month) || '月' || \(day) || '日', ?) > 0)
                """,
                Array(repeating: .text(query), count: 6)
            )
        }

        if query.count >= 3 {
            let expression = "\"\(query.replacingOccurrences(of: "\"", with: "\"\""))\""
            return (
                """
                id IN (
                    SELECT document_id
                    FROM content_search
                    WHERE content_search MATCH ? AND document_type = 'moment'
                )
                """,
                [.text(expression)]
            )
        }

        if let token = shortSearchToken(for: query) {
            return (
                """
                id IN (
                    SELECT document_id
                    FROM content_short_search
                    WHERE content_short_search MATCH ? AND document_type = 'moment'
                )
                """,
                [.text("\"\(token.replacingOccurrences(of: "\"", with: "\"\""))\"")]
            )
        }

        return ("instr(lower(created_at), lower(?)) > 0", [.text(query)])
    }

    private func isDateLikeMomentSearch(_ query: String) -> Bool {
        !query.isEmpty && query.allSatisfy { character in
            character.isNumber || "-/年月日".contains(character)
        }
    }

    private func momentDateInterval(for filter: NativeMomentDateFilter) -> DateInterval? {
        let calendar = Calendar.current
        let now = Date()
        switch filter {
        case .all:
            return nil
        case .today:
            guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
                return nil
            }
            return DateInterval(start: calendar.startOfDay(for: now), end: end)
        case .thisWeek:
            return calendar.dateInterval(of: .weekOfYear, for: now)
        case let .month(year, month):
            guard let start = calendar.date(from: DateComponents(year: year, month: month)),
                  let end = calendar.date(byAdding: .month, value: 1, to: start) else {
                return nil
            }
            return DateInterval(start: start, end: end)
        case let .year(year):
            guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let end = calendar.date(byAdding: .year, value: 1, to: start) else {
                return nil
            }
            return DateInterval(start: start, end: end)
        }
    }

    func insertMoment(
        _ moment: NativeMoment,
        deletedAt: String? = nil,
        deleteExpiresAt: String? = nil,
        into database: SQLiteDatabase
    ) throws {
        try database.execute("""
        INSERT OR REPLACE INTO moments(id, created_at, updated_at, text, text_runs_json, images_json, tags_json, is_favorite, deleted_at, delete_expires_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, values: [
            .text(moment.id),
            .text(moment.createdAt),
            .text(moment.updatedAt),
            .text(moment.text),
            .text(try jsonString(moment.textRuns)),
            .text(try jsonString(moment.images)),
            .text(try jsonString(moment.tags)),
            .integer(moment.isFavorite ? 1 : 0),
            deletedAt.map(SQLiteValue.text) ?? .null,
            deleteExpiresAt.map(SQLiteValue.text) ?? .null,
        ])
        try replaceShortSearchDocument(
            type: "moment",
            id: moment.id,
            source: [moment.text, moment.tags.joined(separator: " "), moment.createdAt],
            isActive: deletedAt == nil,
            in: database
        )
        try replaceMomentFilterIndexes(moment, isActive: deletedAt == nil, in: database)
        try replaceMediaReferences(
            ownerType: "moment",
            ownerID: moment.id,
            urls: moment.images.map(\.url),
            in: database
        )
    }

    private func decodeMoment(_ row: SQLiteRow) throws -> NativeMoment {
        guard let id = row.text(at: 0),
              let createdAt = row.text(at: 1),
              let updatedAt = row.text(at: 2),
              let text = row.text(at: 3),
              let textRunsJSON = row.text(at: 4),
              let imagesJSON = row.text(at: 5) else {
            throw NativeStoreError.fileSystem("SQLite：动态记录不完整")
        }
        let tags: [String]
        if let tagsJSON = row.text(at: 6) {
            tags = try decode(tagsJSON)
        } else {
            tags = NativeMomentTag.extract(from: text)
        }
        let isFavorite = row.integer(at: 7) == 1
        return NativeMoment(
            createdAt: createdAt,
            id: id,
            images: try decode(imagesJSON),
            isFavorite: isFavorite,
            tags: tags,
            text: text,
            textRuns: try decode(textRunsJSON),
            updatedAt: updatedAt
        )
    }

    private func replaceQuestionTags(questionID: String, tags: [String]) throws {
        try db().execute(
            "DELETE FROM question_tags WHERE question_id = ?",
            values: [.text(questionID)]
        )
        for tag in tags {
            try db().execute("""
            INSERT INTO question_tags(question_id, tag, normalized_tag)
            VALUES (?, ?, ?)
            """, values: [
                .text(questionID),
                .text(tag),
                .text(NativeQuestionTag.identifier(tag)),
            ])
        }
    }

    private func decodeQuestion(_ row: SQLiteRow) throws -> NativeQuestion {
        guard let id = row.text(at: 0),
              let title = row.text(at: 1),
              let body = row.text(at: 2),
              let tagsJSON = row.text(at: 3),
              let createdAt = row.text(at: 4),
              let updatedAt = row.text(at: 5) else {
            throw NativeStoreError.fileSystem("SQLite：问题记录不完整")
        }
        return NativeQuestion(
            id: id,
            title: title,
            body: body,
            tags: try decode(tagsJSON),
            createdAt: createdAt,
            updatedAt: updatedAt,
            answerCount: row.integer(at: 6) ?? 0
        )
    }

    private func decodeQuestionAnswer(_ row: SQLiteRow) throws -> NativeQuestionAnswer {
        guard let id = row.text(at: 0),
              let questionID = row.text(at: 1),
              let body = row.text(at: 2),
              let imagesJSON = row.text(at: 3),
              let createdAt = row.text(at: 4),
              let updatedAt = row.text(at: 5) else {
            throw NativeStoreError.fileSystem("SQLite：问题回答记录不完整")
        }
        return NativeQuestionAnswer(
            id: id,
            questionID: questionID,
            body: body,
            images: try decode(imagesJSON),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func trashBackup() throws -> NativeTrashBackup {
        var articles: [NativeTrashedArticle] = []
        try db().query(articleSelect + " WHERE deleted_at IS NOT NULL AND delete_expires_at IS NOT NULL ORDER BY slug") { row in
            guard let deletedAt = row.text(at: 13), let expiresAt = row.text(at: 14) else {
                throw NativeStoreError.fileSystem("SQLite：回收站文章记录不完整")
            }
            articles.append(NativeTrashedArticle(
                article: try decodeArticle(row),
                deletedAt: deletedAt,
                expiresAt: expiresAt
            ))
        }

        var moments: [NativeTrashedMoment] = []
        try db().query("""
        \(momentSelect)
        WHERE deleted_at IS NOT NULL AND delete_expires_at IS NOT NULL
        ORDER BY id
        """) { row in
            guard let deletedAt = row.text(at: 8), let expiresAt = row.text(at: 9) else {
                throw NativeStoreError.fileSystem("SQLite：回收站微博记录不完整")
            }
            moments.append(NativeTrashedMoment(
                moment: try decodeMoment(row),
                deletedAt: deletedAt,
                expiresAt: expiresAt
            ))
        }
        return NativeTrashBackup(articles: articles, moments: moments)
    }

    private func allActivityEvents() throws -> [NativeActivityEvent] {
        var events: [NativeActivityEvent] = []
        try db().query("SELECT type, created_at FROM activity_events ORDER BY id") { row in
            guard let type = row.text(at: 0), let createdAt = row.text(at: 1) else {
                throw NativeStoreError.fileSystem("SQLite：活动记录不完整")
            }
            events.append(NativeActivityEvent(type: type, createdAt: createdAt))
        }
        return events
    }

    private func insertActivity(_ event: NativeActivityEvent, into database: SQLiteDatabase) throws {
        try database.execute(
            "INSERT INTO activity_events(type, created_at) VALUES(?, ?)",
            values: [.text(event.type), .text(event.createdAt)]
        )
    }

    private func recordActivityEvent(type: String, at date: Date) throws {
        let timestamp = NativeTimestamp.string(from: date)
        try db().execute(
            "DELETE FROM activity_events WHERE created_at < ?",
            values: [.text(NativeTimestamp.string(from: Date().addingTimeInterval(-366 * 24 * 60 * 60)))]
        )
        try db().execute(
            "INSERT INTO activity_events(type, created_at) VALUES(?, ?)",
            values: [.text(type), .text(timestamp)]
        )
        try db().execute("""
        DELETE FROM activity_events
        WHERE id NOT IN (SELECT id FROM activity_events ORDER BY id DESC LIMIT 10000)
        """)
    }

    private func recordActivity(type: String, at date: Date) throws {
        try recordActivityEvent(type: type, at: date)
        try? writeActivityEventsAfterMutation()
    }

    private func writeActivityEventsAfterMutation() throws {
        guard !defersCompatibilityExportVerification else {
            activityExportDirty = true
            return
        }
        try writeActivityEvents()
    }

    private func writeActivityEvents() throws {
        try writeJSON(try allActivityEvents(), to: activityURL.appendingPathComponent("events.json"))
        activityExportDirty = false
    }

    private func writeTrashBackup() throws {
        try writeJSON(try trashBackup(), to: trashIndexURL)
    }

    private func rebuildArticleExports() throws {
        for article in try allArticles() {
            try writeArticleJSONSidecars(article)
        }
        try rebuildIndex()
    }

    private func rebuildIndex() throws {
        if !FileManager.default.fileExists(atPath: articleSidecarsMarkerURL.path) {
            try Data().write(to: articleSidecarsMarkerURL, options: .atomic)
        }
    }

    private func rebuildMomentsIndex() throws {
        let moments = try allMoments()
        for moment in moments {
            try writeMomentSidecar(moment)
        }
        try Data().write(to: momentSidecarsMarkerURL, options: .atomic)
        try writeJSON(moments, to: momentsIndexURL)
    }

    private func writeMomentSidecar(_ moment: NativeMoment) throws {
        let safeID = try requireSafeSegment(moment.id, label: "微博 ID")
        try writeJSON(moment, to: momentsURL.appendingPathComponent("\(safeID).json"))
        if !FileManager.default.fileExists(atPath: momentSidecarsMarkerURL.path) {
            try Data().write(to: momentSidecarsMarkerURL, options: .atomic)
        }
    }

    private func removeMomentSidecar(id: String) {
        guard let safeID = try? requireSafeSegment(id, label: "微博 ID") else { return }
        try? FileManager.default.removeItem(at: momentsURL.appendingPathComponent("\(safeID).json"))
    }

    private func readArticle(at url: URL) throws -> NativeArticle {
        do {
            let data = try Data(contentsOf: url)
            return normalize(try JSONDecoder().decode(NativeArticle.self, from: data))
        } catch {
            throw NativeStoreError.fileSystem("无法读取 \(url.lastPathComponent)：\(error.localizedDescription)")
        }
    }

    private func readMoment(at url: URL) throws -> NativeMoment {
        do {
            return try JSONDecoder().decode(NativeMoment.self, from: Data(contentsOf: url))
        } catch {
            throw NativeStoreError.fileSystem("无法读取 \(url.lastPathComponent)：\(error.localizedDescription)")
        }
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(value).write(to: url, options: .atomic)
            // This stamp lets the next process detect missing or externally
            // modified compatibility exports using metadata only, without
            // decoding every article body to compare it with SQLite.
            try Data().write(to: jsonExportStampURL, options: .atomic)
        } catch {
            throw NativeStoreError.fileSystem("无法写入 \(url.lastPathComponent)：\(error.localizedDescription)")
        }
    }

    // MARK: - Normalization and decoding

    private func normalize(_ article: NativeArticle) -> NativeArticle {
        let body = normalizeBody(article.body)
        return NativeArticle(
            banner: article.banner.map(normalizeBanner),
            body: body,
            category: article.category,
            excerpt: article.excerpt,
            media: article.media.map(normalizeMedia),
            slug: article.slug,
            status: article.status,
            tags: article.tags,
            title: article.title,
            updatedAt: article.updatedAt,
            publishedAt: article.publishedAt,
            wordCount: article.wordCount ?? wordCount(body),
            pageViews: article.pageViews,
            properties: article.properties,
            sourceRelativePath: article.sourceRelativePath,
            sourceContentHash: article.sourceContentHash,
            sourceImportedAt: article.sourceImportedAt
        )
    }

    private func normalizeBanner(_ banner: NativeBanner) -> NativeBanner {
        NativeBanner(alt: banner.alt, name: banner.name, size: banner.size, url: normalizeMediaURL(banner.url))
    }

    private func normalizeMedia(_ media: NativeMedia) -> NativeMedia {
        NativeMedia(kind: media.kind, name: media.name, size: media.size, url: normalizeMediaURL(media.url))
    }

    private func isSupportedMomentMedia(_ media: NativeMedia) -> Bool {
        guard !media.url.isEmpty else { return false }
        if media.isImage { return true }
        return media.isVideo
            && (media.url as NSString).pathExtension.caseInsensitiveCompare("mp4") == .orderedSame
    }

    private func normalizedMomentText(
        _ text: String,
        textRuns: [NativeMomentTextRun]
    ) -> (text: String, runs: [NativeMomentTextRun]) {
        let characters = Array(text)
        let leadingWhitespace = characters.prefix { $0.isWhitespace }.count
        let trailingWhitespace = characters.reversed().prefix { $0.isWhitespace }.count
        let availableCount = max(0, characters.count - leadingWhitespace - trailingWhitespace)
        let retainedCount = min(500, availableCount)
        let normalizedText = String(characters.dropFirst(leadingWhitespace).prefix(retainedCount))

        guard !normalizedText.isEmpty, textRuns.map(\.text).joined() == text else {
            return normalizedText.isEmpty ? ("", []) : (normalizedText, [
                NativeMomentTextRun(text: normalizedText, bold: false, color: nil),
            ])
        }

        var position = 0
        var remaining = retainedCount
        var normalizedRuns: [NativeMomentTextRun] = []
        for run in textRuns where remaining > 0 {
            let runCharacters = Array(run.text)
            let runStart = position
            let runEnd = position + runCharacters.count
            position = runEnd

            let selectionStart = max(leadingWhitespace, runStart)
            let selectionEnd = min(leadingWhitespace + retainedCount, runEnd)
            guard selectionStart < selectionEnd else { continue }

            let startOffset = selectionStart - runStart
            let length = selectionEnd - selectionStart
            let segment = String(runCharacters.dropFirst(startOffset).prefix(length))
            appendMomentTextRun(
                NativeMomentTextRun(text: segment, bold: run.bold, color: run.color),
                to: &normalizedRuns
            )
            remaining -= length
        }

        return normalizedRuns.map(\.text).joined() == normalizedText
            ? (normalizedText, normalizedRuns)
            : (normalizedText, [NativeMomentTextRun(text: normalizedText, bold: false, color: nil)])
    }

    private func appendMomentTextRun(_ run: NativeMomentTextRun, to runs: inout [NativeMomentTextRun]) {
        guard !run.text.isEmpty else { return }
        guard let previous = runs.last,
              previous.bold == run.bold,
              previous.color == run.color else {
            runs.append(run)
            return
        }
        runs[runs.count - 1] = NativeMomentTextRun(
            text: previous.text + run.text,
            bold: run.bold,
            color: run.color
        )
    }

    private func normalizeBody(_ body: String) -> String {
        body
            .replacingOccurrences(of: "http://localhost:8787/media/", with: "/media/")
            .replacingOccurrences(of: "http://127.0.0.1:8787/media/", with: "/media/")
    }

    func compactSearchSnippet(_ source: String) -> String {
        let compact = source
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard compact.count > 240 else { return compact }
        return String(compact.prefix(240)) + "…"
    }

    func normalizeMediaURL(_ value: String) -> String {
        guard let url = URL(string: value),
              let host = url.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1"].contains(host),
              url.path.hasPrefix("/media/") else {
            return value.hasPrefix("media/") ? "/\(value)" : value
        }
        return url.path
    }

    private func wordCount(_ body: String) -> Int {
        NativeWritingMetrics.characterCount(of: body)
    }

    func jsonString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        guard let result = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw NativeStoreError.fileSystem("无法编码 SQLite JSON 字段")
        }
        return result
    }

    func decode<T: Decodable>(_ value: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(value.utf8))
        } catch {
            throw NativeStoreError.fileSystem("无法解析 SQLite JSON 字段：\(error.localizedDescription)")
        }
    }

    private func decodeOptional<T: Decodable>(_ value: String?) throws -> T? {
        guard let value else { return nil }
        return try decode(value)
    }

    private func activityDate(from timestamp: String) -> Date? {
        NativeTimestamp.date(from: timestamp)
    }

    private func activityDateKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func nextTimestamp(after previous: String?) -> String {
        let now = Date()
        if let previous, let date = NativeTimestamp.date(from: previous), date >= now {
            return timestamp(from: date.addingTimeInterval(0.001))
        }
        return timestamp(from: now)
    }

    private func nextQuestionTimestamp(after previous: String?) -> String {
        let candidate = nextTimestamp(after: previous)
        guard let previous, candidate <= previous,
              let previousDate = NativeTimestamp.date(from: previous) else {
            return candidate
        }
        return timestamp(from: previousDate.addingTimeInterval(0.001))
    }

    private func timestamp(from date: Date) -> String {
        NativeTimestamp.string(from: date)
    }

    private func slugify(_ title: String) -> String {
        let value = title.folding(options: .diacriticInsensitive, locale: .current).lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let slug = String(value).split(separator: "-").joined(separator: "-")
        return slug.isEmpty ? "draft-\(Int(Date().timeIntervalSince1970))" : String(slug.prefix(80))
    }

    private func timestamp(afterDays days: Int) -> String {
        timestamp(from: Date().addingTimeInterval(TimeInterval(days) * 24 * 60 * 60))
    }

    func requireSafeSegment(_ value: String, label: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.hasPrefix("."),
              value.rangeOfCharacter(from: allowed.inverted) == nil else {
            throw NativeStoreError.fileSystem("\(label) 无效")
        }
        return value
    }

}
