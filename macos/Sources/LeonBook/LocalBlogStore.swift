import Foundation
import LeonBookBackupModule

/// Local SQLite store for structured data, with Markdown/JSON exports and file-based media.
public actor LocalBlogStore {
    static let trashRetentionDays = 30
    static let articleRevisionRetentionDays = 30
    static let articleAutosaveRevisionInterval: TimeInterval = 5 * 60
    static let maximumArticleRevisionsPerDraft = 100

    static let reservedMediaDirectories: Set<String> = ["inbox", "moments", "question-answers", "whiteboards", "canvases", "photo-library", "media-library", "dashboard"]

    let rootURL: URL
    let contentPrivacy: NativeContentPrivacy?
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
    var markdownWorkspaceSourceURL: URL {
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
    var momentsURL: URL { rootURL.appendingPathComponent("moments", isDirectory: true) }
    var momentsIndexURL: URL { momentsURL.appendingPathComponent("index.json") }
    var momentSidecarsMarkerURL: URL { momentsURL.appendingPathComponent(".sidecars-v1") }
    private var jsonExportStampURL: URL { rootURL.appendingPathComponent(".json-exports-v1") }
    private var activityURL: URL { rootURL.appendingPathComponent("activity", isDirectory: true) }
    private var trashURL: URL { rootURL.appendingPathComponent("trash", isDirectory: true) }
    private var trashIndexURL: URL { trashURL.appendingPathComponent("index.json") }

    // MARK: - Lifecycle

    public init(rootURL: URL = LocalBlogStore.defaultRootURL) {
        self.init(rootURL: rootURL, contentPrivacy: nil)
    }

    init(rootURL: URL, contentPrivacy: NativeContentPrivacy?) {
        self.contentPrivacy = contentPrivacy
        let standardizedRoot = rootURL.standardizedFileURL
        self.rootURL = standardizedRoot
        markdownWorkspaceSource = Self.loadMarkdownWorkspaceSource(from: standardizedRoot)
        WorkspaceStorageLifecycle.register(self, root: standardizedRoot)
    }

    public func prepareForBackup() throws {
        try prepare()
        if activityExportDirty { try writeActivityEvents() }
        try exportJsonBackupIfNeeded()
        try flushArticlePageViewExports()
        try exportPortableSidecarIfEnabled()
        try db().execute("PRAGMA wal_checkpoint(TRUNCATE)")
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
        try flushArticlePageViewExports()
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
        guard !changes.isEmpty else { return 0 }
        do {
            for change in changes { try writeArticleJSONSidecars(change.updated) }
            try rebuildIndex()
        } catch {
            markJSONBackupNeedsRebuild()
        }
        return changes.count
    }

    // MARK: - Article properties and bookmarks

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

    public func listBookmarks() throws -> [NativeBookmark] {
        try prepare()
        var bookmarks: [NativeBookmark] = []
        try db().query("SELECT bookmark_json FROM bookmarks ORDER BY position, created_at, id") { row in
            guard let json = row.text(at: 0) else {
                throw NativeStoreError.fileSystem(NativeLocalization.text("SQLite：收藏记录不完整"))
            }
            bookmarks.append(try decode(json))
        }
        guard !showsPrivateContent else { return bookmarks }
        var hiddenSlugs = Set<String>()
        try db().query("SELECT slug FROM articles WHERE is_private = 1") { row in
            if let slug = row.text(at: 0) { hiddenSlugs.insert(slug) }
        }
        return bookmarks.filter { bookmark in
            switch bookmark.target {
            case .article(let slug), .heading(let slug, _, _): return !hiddenSlugs.contains(slug)
            case .search, .graph: return true
            }
        }
    }

    @discardableResult
    public func saveBookmark(_ bookmark: NativeBookmark) throws -> NativeBookmark {
        try prepare()
        var saved = bookmark
        saved.title = saved.title.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.groupName = saved.groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved.title.isEmpty, saved.title.count <= 120, saved.groupName.count <= 80 else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("收藏标题或分组名称无效"))
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
        guard let article = try storedArticle(withSlug: safeSlug), permitsContent(isPrivate: article.isPrivate) else {
            throw NativeStoreError.notFound
        }
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
            sourceRelativePath: MarkdownArticleSource.defaultRelativePath(for: targetSlug),
            isPrivate: source.isPrivate
        )
        let saved = try persistArticleRefactor([
            (previous: source, updated: sourceUpdated),
            (previous: nil, updated: extracted),
        ])
        guard let primary = saved.first(where: { $0.slug == source.slug }),
              let created = saved.first(where: { $0.slug == targetSlug }) else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("文章提取结果不完整"))
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
                sourceRelativePath: MarkdownArticleSource.defaultRelativePath(for: target.slug),
                isPrivate: source.isPrivate
            )))
        }

        let saved = try persistArticleRefactor(changes)
        guard let primary = saved.first(where: { $0.slug == source.slug }) else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("文章拆分结果不完整"))
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
                media: media,
                isPrivate: article.isPrivate || (article.slug == destination.slug && source.isPrivate)
            )))
        }
        let saved = try persistArticleRefactor(changes, removing: source)
        guard let primary = saved.first(where: { $0.slug == destination.slug }) else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("文章合并结果不完整"))
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
        media: [NativeMedia]? = nil,
        isPrivate: Bool? = nil
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
            sourceImportedAt: article.sourceImportedAt,
            isPrivate: isPrivate ?? article.isPrivate
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
        try NativeArticleDirectoryPolicy.validateArticlePath(destination)
        let occupied = try db().integer(
            "SELECT COUNT(*) FROM articles WHERE source_relative_path = ? AND slug <> ?",
            values: [.text(destination), .text(article.slug)]
        ) ?? 0
        guard occupied == 0 else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("目标 Markdown 路径已被另一篇文章占用"))
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

    public func incrementArticlePageViewCount(slug: String) throws -> Int {
        try prepare()
        let safeSlug = try requireSafeSegment(slug, label: "文章 slug")
        let database = try db()
        var count = 0
        try database.transaction {
            try database.execute(
                "UPDATE articles SET page_views = page_views + 1 WHERE slug = ? AND deleted_at IS NULL",
                values: [.text(safeSlug)]
            )
            guard let value = try database.integer(
                "SELECT page_views FROM articles WHERE slug = ? AND deleted_at IS NULL",
                values: [.text(safeSlug)]
            ) else { throw NativeStoreError.notFound }
            count = value
            try database.execute(
                "INSERT OR REPLACE INTO metadata(key, value) VALUES(?, 'dirty')",
                values: [.text("article_page_views_dirty:" + safeSlug)]
            )
        }
        return count
    }

    public func incrementArticlePageViews(slug: String) throws -> NativeArticle {
        _ = try incrementArticlePageViewCount(slug: slug)
        guard let article = try storedArticle(withSlug: slug) else { throw NativeStoreError.notFound }
        return article
    }

    private func flushArticlePageViewExports() throws {
        let prefix = "article_page_views_dirty:"
        var keys: [String] = []
        try db().query("SELECT key FROM metadata WHERE key LIKE 'article_page_views_dirty:%'") { row in
            if let key = row.text(at: 0), key.hasPrefix(prefix) { keys.append(key) }
        }
        for key in keys {
            let slug = String(key.dropFirst(prefix.count))
            if let article = try storedArticle(withSlug: slug) {
                try writeArticleJSONSidecars(article)
            }
            try db().execute("DELETE FROM metadata WHERE key = ?", values: [.text(key)])
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
                throw NativeStoreError.fileSystem(NativeLocalization.text("无法为文章分配可用地址"))
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
            throw NativeStoreError.fileSystem(NativeLocalization.text("复制导入前请先将 Markdown 源切换为“复制导入”"))
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
                warnings.append(NativeLocalization.text("\(note.relativePath)：SQLite 中已存在 \(note.slug)，已跳过"))
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
                        warnings.append(NativeLocalization.text("\(note.relativePath)：附件 \(attachment.sourceURL.lastPathComponent) 导入失败：\(error.localizedDescription)"))
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
            warnings.append(NativeLocalization.text("Markdown 已导入，但部分 JSON 备份需要在下次启动时重建"))
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
        if let previous, !permitsContent(isPrivate: previous.isPrivate) { throw NativeStoreError.notFound }

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

        var sourceRelativePath: String
        if let previous {
            sourceRelativePath = previous.sourceRelativePath
        } else if let requestedPath = article.sourceRelativePath {
            sourceRelativePath = try MarkdownArticleSource.validatedRelativePath(requestedPath)
        } else {
            sourceRelativePath = MarkdownArticleSource.defaultRelativePath(for: slug, body: article.body)
        }
        if RichArticleDocument.isHTML(article.body) {
            sourceRelativePath = (sourceRelativePath as NSString).deletingPathExtension + ".html"
        }
        if previous == nil {
            try NativeArticleDirectoryPolicy.validateArticlePath(sourceRelativePath)
        }
        let migratesLegacyFile = previous.map { $0.sourceRelativePath != sourceRelativePath } ?? false
        if previous == nil || migratesLegacyFile,
           FileManager.default.fileExists(
               atPath: articlesURL.appendingPathComponent(sourceRelativePath).path
            ) {
            throw NativeStoreError.fileSystem(NativeLocalization.text("目标文章文件已存在"))
        }
        let originalFile = try MarkdownArticleSource.snapshot(relativePath: sourceRelativePath, in: articlesURL)
        let previousFile = try previous.map {
            try MarkdownArticleSource.snapshot(relativePath: $0.sourceRelativePath, in: articlesURL)
        }
        if let previous,
           previousFile?.data == nil || previousFile?.contentHash != previous.sourceContentHash {
            _ = try refreshMarkdownSources(changedRelativePaths: [previous.sourceRelativePath])
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
            sourceImportedAt: previous?.sourceImportedAt,
            isPrivate: article.isPrivate ?? previous?.isPrivate ?? false
        )
        var sourcedSaved = saved
        var writtenHash: String?
        var archivedLegacyURL: URL?

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
                    requiresMissingFile: previous == nil || migratesLegacyFile
                )
                writtenHash = sourceRecord.contentHash
                sourcedSaved = applyingSourceRecord(sourceRecord, to: saved)
                if migratesLegacyFile, let previous, let previousFile {
                    let current = try MarkdownArticleSource.snapshot(relativePath: previous.sourceRelativePath, in: articlesURL)
                    guard current.contentHash == previousFile.contentHash else { throw NativeStoreError.conflict }
                    let archive = articlesURL.appendingPathComponent(".legacy-markdown/\(UUID().uuidString)/\(previous.sourceRelativePath)")
                    try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: previousFile.url, to: archive)
                    archivedLegacyURL = archive
                }
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
                if article.isPrivate != nil {
                    try db().execute("UPDATE articles SET privacy_override = NULL WHERE slug = ?", values: [.text(slug)])
                }
                try insertArticle(sourcedSaved, into: db())
                if let activityType {
                    try recordActivityEvent(type: activityType, at: activityDate(from: updatedAt) ?? Date())
                }
                try trimArticleRevisions(draftKey: slug)
            }
        } catch {
            var rollbackError: Error?
            if let archivedLegacyURL, let previousFile {
                do { try FileManager.default.moveItem(at: archivedLegacyURL, to: previousFile.url) }
                catch { rollbackError = error }
            }
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
                    sourceImportedAt: previous.sourceImportedAt,
                    isPrivate: previous.isPrivate
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


    func decodeArticleRevision(_ row: SQLiteRow) throws -> NativeArticleRevision {
        guard let id = row.integer(at: 0),
              let syncID = row.text(at: 1),
              let draftKey = row.text(at: 2),
              let reasonValue = row.text(at: 4),
              let reason = NativeArticleRevisionReason(rawValue: reasonValue),
              let snapshotJSON = row.text(at: 5),
              let createdAt = row.text(at: 6),
              let updatedAt = row.text(at: 7) else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("SQLite：文章版本记录不完整"))
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

    func removeArticleJSONSidecars(for slug: String) {
        guard let safeSlug = try? requireSafeSegment(slug, label: "文章 slug") else { return }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: managedArticlesURL.appendingPathComponent("\(safeSlug).json"))
        try? fileManager.removeItem(at: draftsURL.appendingPathComponent("\(safeSlug).json"))
    }

    func writeArticleSidecars(_ article: NativeArticle) throws {
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

    func writeArticleJSONSidecars(_ article: NativeArticle) throws {
        let safeSlug = try requireSafeSegment(article.slug, label: "文章 slug")
        try writeJSON(article, to: managedArticlesURL.appendingPathComponent("\(safeSlug).json"))
        try writeJSON(article, to: draftsURL.appendingPathComponent("\(safeSlug).json"))
        if !FileManager.default.fileExists(atPath: articleSidecarsMarkerURL.path) {
            try Data().write(to: articleSidecarsMarkerURL, options: .atomic)
        }
    }

    func removeArticleFiles(for slug: String, sourceRelativePath: String? = nil) {
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
            // Media explicitly kept in a library has a stable public URL.
            if try db().integer("SELECT COUNT(*) FROM photo_library_items WHERE url = ?", values: [.text(normalized)]) == 1 {
                return normalized
            }
            if try db().integer("SELECT COUNT(*) FROM media_library_items WHERE url = ?", values: [.text(normalized)]) == 1 {
                return normalized
            }
            let filename = try requireSafeSegment(String(normalized[range.upperBound...]), label: "媒体文件")
            let source = mediaURL.appendingPathComponent("inbox").appendingPathComponent(filename)
            let destinationDirectory = mediaURL.appendingPathComponent(slug, isDirectory: true)
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            let destination = destinationDirectory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: source.path) {
                if FileManager.default.fileExists(atPath: destination.path) {
                    throw NativeStoreError.fileSystem(NativeLocalization.text("目标媒体文件已存在：\(filename)"))
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

    // MARK: - Database and compatibility exports

    func db() throws -> SQLiteDatabase {
        guard let database else { throw NativeStoreError.fileSystem(NativeLocalization.text("SQLite：数据库尚未准备好")) }
        return database
    }

    func markJSONBackupNeedsRebuild() {
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
                throw NativeStoreError.fileSystem(NativeLocalization.text("无法读取 \(indexURL.lastPathComponent)：\(error.localizedDescription)"))
            }

            var bySlug: [String: NativeArticle] = [:]
            for article in indexed where !article.slug.isEmpty {
                let slug = try requireSafeSegment(article.slug, label: "文章 slug")
                let file = managedArticlesURL.appendingPathComponent("\(slug).json")
                if FileManager.default.fileExists(atPath: file.path) {
                    let fromFile = try readArticle(at: file)
                    let fileSlug = try requireSafeSegment(fromFile.slug, label: "文章 slug")
                    guard fileSlug == slug else {
                        throw NativeStoreError.fileSystem(NativeLocalization.text("文章 JSON 的 slug 与 index.json 不一致"))
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
                throw NativeStoreError.fileSystem(NativeLocalization.text("无法读取 \(momentsIndexURL.lastPathComponent)：\(error.localizedDescription)"))
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
            throw NativeStoreError.fileSystem(NativeLocalization.text("无法读取 \(legacyURL.lastPathComponent)：\(error.localizedDescription)"))
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
                    throw NativeStoreError.fileSystem(NativeLocalization.text("回收站文章的时间戳无效"))
                }
                return NativeTrashedArticle(article: article, deletedAt: entry.deletedAt, expiresAt: entry.expiresAt)
            }
            let moments = try decoded.moments.map { entry -> NativeTrashedMoment in
                _ = try requireSafeSegment(entry.moment.id, label: "回收站微博 ID")
                guard NativeTimestamp.date(from: entry.deletedAt) != nil,
                      NativeTimestamp.date(from: entry.expiresAt) != nil else {
                    throw NativeStoreError.fileSystem(NativeLocalization.text("回收站微博的时间戳无效"))
                }
                return entry
            }
            return NativeTrashBackup(articles: articles, moments: moments)
        } catch let error as NativeStoreError {
            throw error
        } catch {
            throw NativeStoreError.fileSystem(NativeLocalization.text("无法读取 \(trashIndexURL.lastPathComponent)：\(error.localizedDescription)"))
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
            "\(articleSummarySelect) WHERE deleted_at IS NULL AND \(contentVisibility()) ORDER BY updated_at DESC"
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
    ) throws -> [(slug: String, body: String)] {
        let target = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard target.count >= 2 else { return [] }
        let predicate: String
        let values: [SQLiteValue]
        if target.count >= 3 {
            predicate = "article_mention_search MATCH ?"
            values = [.text("\"\(target.replacingOccurrences(of: "\"", with: "\"\""))\"")]
        } else if target.allSatisfy({ $0.isLetter || $0.isNumber }),
                  let token = shortSearchToken(for: target), token.count == 2 {
            // The short index includes the same visible body used by the
            // mention index; confirm the match to exclude metadata hits.
            predicate = """
            (candidate.slug IN (
                SELECT document_id FROM content_short_search
                WHERE document_type = 'article' AND content_short_search MATCH ?
            ) OR substr(ltrim(article_mention_search.body, char(9) || char(10) || char(13) || ' '), 1, 8) = '<article')
            AND instr(lower(article_mention_search.body), lower(?)) > 0
            """
            values = [.text("\"\(token.replacingOccurrences(of: "\"", with: "\"\""))\""), .text(target)]
        } else {
            predicate = "instr(lower(article_mention_search.body), lower(?)) > 0"
            values = [.text(target)]
        }
        var candidates: [(slug: String, body: String)] = []
        try db().query("""
        SELECT candidate.slug, candidate.body FROM articles AS candidate
        JOIN article_mention_search ON article_mention_search.source_slug = candidate.slug
        WHERE candidate.deleted_at IS NULL
          AND candidate.slug <> ?
          AND \(predicate)
        ORDER BY candidate.updated_at DESC, candidate.slug
        """, values: [.text(slug)] + values, checkingCancellation: true) { row in
            if let slug = row.text(at: 0), let body = row.text(at: 1) {
                candidates.append((slug: slug, body: body))
            }
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
            properties_json, source_relative_path, source_content_hash, source_imported_at, is_private
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            source_imported_at = excluded.source_imported_at,
            is_private = COALESCE(articles.privacy_override, excluded.is_private)
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
            .integer(article.isPrivate ? 1 : 0),
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
        if RichArticleDocument.isHTML(article.body) {
            let visibleText = RichArticleDocument.plainText(article.body)
            try database.execute(
                "UPDATE content_search SET body = ? WHERE document_type = 'article' AND document_id = ?",
                values: [.text(visibleText), .text(article.slug)]
            )
            try database.execute(
                "UPDATE article_mention_search SET body = ? WHERE source_slug = ?",
                values: [.text(visibleText), .text(article.slug)]
            )
        }
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

    func decodeArticle(_ row: SQLiteRow) throws -> NativeArticle {
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
            throw NativeStoreError.fileSystem(NativeLocalization.text("SQLite：文章记录不完整"))
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
            sourceImportedAt: row.text(at: 18),
            isPrivate: row.integer(at: 19) == 1
        )
    }

    func decodeArticleSummary(_ row: SQLiteRow) throws -> NativeArticleSummary {
        guard let slug = row.text(at: 0),
              let title = row.text(at: 1),
              let category = row.text(at: 2),
              let excerpt = row.text(at: 3),
              let statusValue = row.text(at: 5),
              let status = NativeArticleStatus(rawValue: statusValue),
              let tagsJSON = row.text(at: 6),
              let updatedAt = row.text(at: 7) else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("SQLite：文章摘要记录不完整"))
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
            wordCount: row.integer(at: 9) ?? 0,
            isPrivate: row.integer(at: 13) == 1
        )
    }

    private func trashBackup() throws -> NativeTrashBackup {
        var articles: [NativeTrashedArticle] = []
        try db().query(articleSelect + " WHERE deleted_at IS NOT NULL AND delete_expires_at IS NOT NULL ORDER BY slug") { row in
            guard let deletedAt = row.text(at: 13), let expiresAt = row.text(at: 14) else {
                throw NativeStoreError.fileSystem(NativeLocalization.text("SQLite：回收站文章记录不完整"))
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
                throw NativeStoreError.fileSystem(NativeLocalization.text("SQLite：回收站微博记录不完整"))
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
                throw NativeStoreError.fileSystem(NativeLocalization.text("SQLite：活动记录不完整"))
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

    func recordActivityEvent(type: String, at date: Date) throws {
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

    func recordActivity(type: String, at date: Date) throws {
        try recordActivityEvent(type: type, at: date)
        try? writeActivityEventsAfterMutation()
    }

    func writeActivityEventsAfterMutation() throws {
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

    func writeTrashBackup() throws {
        try writeJSON(try trashBackup(), to: trashIndexURL)
    }

    private func rebuildArticleExports() throws {
        for article in try allArticles() {
            try writeArticleJSONSidecars(article)
        }
        try rebuildIndex()
    }

    func rebuildIndex() throws {
        if !FileManager.default.fileExists(atPath: articleSidecarsMarkerURL.path) {
            try Data().write(to: articleSidecarsMarkerURL, options: .atomic)
        }
    }

    private func readArticle(at url: URL) throws -> NativeArticle {
        do {
            let data = try Data(contentsOf: url)
            return normalize(try JSONDecoder().decode(NativeArticle.self, from: data))
        } catch {
            throw NativeStoreError.fileSystem(NativeLocalization.text("无法读取 \(url.lastPathComponent)：\(error.localizedDescription)"))
        }
    }

    func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(value).write(to: url, options: .atomic)
            // This stamp lets the next process detect missing or externally
            // modified compatibility exports using metadata only, without
            // decoding every article body to compare it with SQLite.
            try Data().write(to: jsonExportStampURL, options: .atomic)
        } catch {
            throw NativeStoreError.fileSystem(NativeLocalization.text("无法写入 \(url.lastPathComponent)：\(error.localizedDescription)"))
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
            sourceImportedAt: article.sourceImportedAt,
            isPrivate: article.isPrivate
        )
    }

    func normalizeBanner(_ banner: NativeBanner) -> NativeBanner {
        NativeBanner(alt: banner.alt, name: banner.name, size: banner.size, url: normalizeMediaURL(banner.url))
    }

    func normalizeMedia(_ media: NativeMedia) -> NativeMedia {
        NativeMedia(kind: media.kind, name: media.name, size: media.size, url: normalizeMediaURL(media.url))
    }

    func normalizeBody(_ body: String) -> String {
        body
            .replacingOccurrences(of: "http://localhost:8787/media/", with: "/media/")
            .replacingOccurrences(of: "http://127.0.0.1:8787/media/", with: "/media/")
    }

    func compactSearchSnippet(_ source: String) -> String {
        let compact = RichArticleDocument.plainText(source)
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

    func wordCount(_ body: String) -> Int {
        NativeWritingMetrics.characterCount(of: body)
    }

    func jsonString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        guard let result = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("无法编码 SQLite JSON 字段"))
        }
        return result
    }

    func decode<T: Decodable>(_ value: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(value.utf8))
        } catch {
            throw NativeStoreError.fileSystem(NativeLocalization.text("无法解析 SQLite JSON 字段：\(error.localizedDescription)"))
        }
    }

    private func decodeOptional<T: Decodable>(_ value: String?) throws -> T? {
        guard let value else { return nil }
        return try decode(value)
    }

    func activityDate(from timestamp: String) -> Date? {
        NativeTimestamp.date(from: timestamp)
    }

    private func activityDateKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    func nextTimestamp(after previous: String?) -> String {
        let now = Date()
        if let previous, let date = NativeTimestamp.date(from: previous), date >= now {
            return timestamp(from: date.addingTimeInterval(0.001))
        }
        return timestamp(from: now)
    }

    func timestamp(from date: Date) -> String {
        NativeTimestamp.string(from: date)
    }

    func slugify(_ title: String) -> String {
        let value = title.folding(options: .diacriticInsensitive, locale: .current).lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let slug = String(value).split(separator: "-").joined(separator: "-")
        return slug.isEmpty ? "draft-\(Int(Date().timeIntervalSince1970))" : String(slug.prefix(80))
    }

    func timestamp(afterDays days: Int) -> String {
        timestamp(from: Date().addingTimeInterval(TimeInterval(days) * 24 * 60 * 60))
    }

    func requireSafeSegment(_ value: String, label: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.hasPrefix("."),
              value.rangeOfCharacter(from: allowed.inverted) == nil else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("\(NativeLocalization.string(label, language: NativeLocalization.currentLanguage)) 无效"))
        }
        return value
    }

}
