import Foundation

/// Local SQLite store for structured data, with Markdown/JSON exports and file-based media.
public actor LocalBlogStore {
    private static let trashRetentionDays = 30
    private static let articleRevisionRetentionDays = 30
    private static let articleAutosaveRevisionInterval: TimeInterval = 5 * 60
    private static let maximumArticleRevisionsPerDraft = 100
    private static let savedWorkDirectoryKey = "leonBook.workDirectoryPath"
    private static let savedBackupDirectoryKey = "leonBook.backupDirectoryPath"

    public static let defaultWorkDirectoryURL = URL(
        fileURLWithPath: "/Volumes/T7Shield/myblog",
        isDirectory: true
    )

    static let reservedMediaDirectories: Set<String> = ["inbox", "moments"]

    static var applicationSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("leon-book", isDirectory: true)
    }

    public static var defaultRootURL: URL {
        if let configured = ProcessInfo.processInfo.environment["LEON_BOOK_WORKDIR"],
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        if let saved = UserDefaults.standard.string(forKey: savedWorkDirectoryKey),
           !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: saved, isDirectory: true)
        }
        return defaultWorkDirectoryURL
    }

    public static var needsWorkDirectorySelection: Bool {
        let hasConfiguredDirectory = ProcessInfo.processInfo.environment["LEON_BOOK_WORKDIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard !hasConfiguredDirectory else { return false }
        return !FileManager.default.fileExists(atPath: defaultRootURL.path)
    }

    public static func rememberWorkDirectory(_ url: URL) {
        UserDefaults.standard.set(url.standardizedFileURL.path, forKey: savedWorkDirectoryKey)
    }

    public static var savedBackupDirectoryURL: URL? {
        guard let saved = UserDefaults.standard.string(forKey: savedBackupDirectoryKey),
              !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: saved, isDirectory: true)
    }

    public static func rememberBackupDirectory(_ url: URL) {
        UserDefaults.standard.set(url.standardizedFileURL.path, forKey: savedBackupDirectoryKey)
    }

    public static func clearBackupDirectory() {
        UserDefaults.standard.removeObject(forKey: savedBackupDirectoryKey)
    }

    let rootURL: URL
    private var database: SQLiteDatabase?
    private var jsonBackupVerified = false
    private var directoryLock: ExclusiveDirectoryLock?

    private var databaseURL: URL { rootURL.appendingPathComponent("leon-book.sqlite") }
    private var articlesURL: URL { rootURL.appendingPathComponent("articles", isDirectory: true) }
    private var draftsURL: URL { rootURL.appendingPathComponent("drafts", isDirectory: true) }
    private var mediaURL: URL { rootURL.appendingPathComponent("media", isDirectory: true) }
    private var momentsURL: URL { rootURL.appendingPathComponent("moments", isDirectory: true) }
    private var momentsIndexURL: URL { momentsURL.appendingPathComponent("index.json") }
    private var momentSidecarsMarkerURL: URL { momentsURL.appendingPathComponent(".sidecars-v1") }
    private var activityURL: URL { rootURL.appendingPathComponent("activity", isDirectory: true) }
    private var trashURL: URL { rootURL.appendingPathComponent("trash", isDirectory: true) }
    private var trashIndexURL: URL { trashURL.appendingPathComponent("index.json") }

    public init(rootURL: URL = LocalBlogStore.defaultRootURL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public func prepareForBackup() throws {
        try prepare()
        try db().execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try exportJsonBackupIfNeeded()
    }

    func prepare() throws {
        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: articlesURL, withIntermediateDirectories: true)
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
            try exportJsonBackupIfNeeded()
            try purgeExpiredTrash()
            try purgeExpiredArticleRevisions()
        } catch let error as NativeStoreError {
            throw error
        } catch {
            throw NativeStoreError.fileSystem(error.localizedDescription)
        }
    }

    public func listArticles(includeDrafts: Bool = true) throws -> [NativeArticleSummary] {
        try prepare()
        let sql = """
        \(articleSelect)
        WHERE deleted_at IS NULL
        \(includeDrafts ? "" : "AND status = 'published'")
        ORDER BY updated_at DESC
        """
        var articles: [NativeArticleSummary] = []
        try db().query(sql) { row in
            articles.append(summary(for: try decodeArticle(row)))
        }
        return articles
    }

    public func search(
        _ rawQuery: String,
        restrictingTo forcedTypes: Set<NativeSearchDocumentType> = [],
        limit: Int = 60
    ) throws -> [NativeGlobalSearchResult] {
        try prepare()
        let query = NativeGlobalSearchQuery(rawQuery)
        let effectiveTypes: Set<NativeSearchDocumentType>
        if forcedTypes.isEmpty {
            effectiveTypes = query.types
        } else if query.types.isEmpty {
            effectiveTypes = forcedTypes
        } else {
            effectiveTypes = forcedTypes.intersection(query.types)
        }
        if !forcedTypes.isEmpty, !query.types.isEmpty, effectiveTypes.isEmpty {
            return []
        }

        var predicates: [String] = []
        var values: [SQLiteValue] = []
        let indexedTerms = query.textTerms.filter { $0.count >= 3 }
        let shortTerms = query.textTerms.filter { $0.count < 3 }

        if !indexedTerms.isEmpty {
            let expression = indexedTerms
                .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
                .joined(separator: " AND ")
            predicates.append("content_search MATCH ?")
            values.append(.text(expression))
        }

        for term in shortTerms {
            predicates.append("""
            (instr(lower(title), lower(?)) > 0
             OR instr(lower(body), lower(?)) > 0
             OR instr(lower(excerpt), lower(?)) > 0
             OR instr(lower(tags), lower(?)) > 0
             OR instr(lower(category), lower(?)) > 0)
            """)
            values.append(contentsOf: Array(repeating: .text(term), count: 5))
        }

        for tag in query.tags {
            predicates.append("instr(lower(tags), lower(?)) > 0")
            values.append(.text("\"\(tag)\""))
        }

        if !effectiveTypes.isEmpty {
            let orderedTypes = effectiveTypes.sorted { $0.rawValue < $1.rawValue }
            predicates.append("document_type IN (\(orderedTypes.map { _ in "?" }.joined(separator: ", ")))")
            values.append(contentsOf: orderedTypes.map { .text($0.rawValue) })
        }

        if let status = query.status {
            predicates.append("status = ?")
            values.append(.text(status.rawValue))
        }
        if let after = query.after {
            predicates.append("created_at >= ?")
            values.append(.text(NativeTimestamp.string(from: after)))
        }
        if let before = query.before {
            predicates.append("created_at < ?")
            values.append(.text(NativeTimestamp.string(from: before)))
        }

        let whereClause = predicates.isEmpty ? "" : "WHERE \(predicates.joined(separator: " AND "))"
        let ordering = indexedTerms.isEmpty
            ? "updated_at DESC"
            : "bm25(content_search, 0.0, 0.0, 8.0, 3.0, 4.0, 2.0, 2.0) ASC, updated_at DESC"
        values.append(.integer(min(max(limit, 1), 200)))

        var results: [NativeGlobalSearchResult] = []
        try db().query(
            """
            SELECT document_type, document_id, title,
                   snippet(content_search, -1, '⟦', '⟧', ' … ', 28),
                   body, excerpt, tags, category, status, created_at, updated_at
            FROM content_search
            \(whereClause)
            ORDER BY \(ordering)
            LIMIT ?
            """,
            values: values
        ) { row in
            guard let typeValue = row.text(at: 0),
                  let documentType = NativeSearchDocumentType(rawValue: typeValue),
                  let documentID = row.text(at: 1),
                  let storedTitle = row.text(at: 2),
                  let body = row.text(at: 4),
                  let excerpt = row.text(at: 5),
                  let tagsJSON = row.text(at: 6),
                  let updatedAt = row.text(at: 10) else {
                throw NativeStoreError.fileSystem("SQLite：全文搜索结果不完整")
            }

            let highlighted = row.text(at: 3) ?? ""
            let fallback = excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? body : excerpt
            let snippet = compactSearchSnippet(
                highlighted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? fallback : highlighted
            )
            results.append(NativeGlobalSearchResult(
                documentType: documentType,
                documentID: documentID,
                title: storedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? (documentType == .moment ? "图片微博" : "未命名文章")
                    : storedTitle,
                snippet: snippet,
                tags: (try? decode(tagsJSON)) ?? [],
                category: row.text(at: 7).flatMap { $0.isEmpty ? nil : $0 },
                status: row.text(at: 8).flatMap(NativeArticleStatus.init(rawValue:)),
                timestamp: row.text(at: 9) ?? updatedAt
            ))
        }
        return results
    }

    /// Derives wiki-style article links from the current article bodies, so title
    /// changes and edits are reflected immediately without a second link index.
    public func articleRelations(for slug: String) throws -> NativeArticleRelations {
        try prepare()
        let safeSlug = try requireSafeSegment(slug, label: "文章 slug")
        let allArticles = try allArticles()
        guard let article = allArticles.first(where: { $0.slug == safeSlug }) else {
            throw NativeStoreError.notFound
        }

        let graph = articleGraph(from: allArticles)
        let summariesBySlug = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.slug, $0) })
        let outgoing = graph.edges.compactMap { edge in
            edge.sourceSlug == article.slug ? summariesBySlug[edge.targetSlug] : nil
        }
        let incoming = graph.edges.compactMap { edge in
            edge.targetSlug == article.slug && edge.sourceSlug != article.slug
                ? summariesBySlug[edge.sourceSlug]
                : nil
        }

        return NativeArticleRelations(outgoing: outgoing, incoming: incoming)
    }

    public func articleGraph() throws -> NativeArticleGraph {
        try prepare()
        return articleGraph(from: try allArticles())
    }

    public func listMoments() throws -> [NativeMoment] {
        try prepare()
        return try allMoments()
    }

    public func getMoment(id: String) throws -> NativeMoment {
        try prepare()
        guard let moment = try moment(withID: id) else { throw NativeStoreError.notFound }
        return moment
    }

    public func incrementMomentPageViews(id: String) throws -> NativeMoment {
        try prepare()
        let safeID = try requireSafeSegment(id, label: "微博 ID")
        try db().execute(
            "UPDATE moments SET page_views = page_views + 1 WHERE id = ? AND deleted_at IS NULL",
            values: [.text(safeID)]
        )
        guard let updated = try moment(withID: safeID) else { throw NativeStoreError.notFound }
        do {
            try writeMomentSidecar(updated)
        } catch {
            markJSONBackupNeedsRebuild()
        }
        return updated
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
        if filter.searchText.isEmpty {
            return try momentCandidateCount(matching: filter)
        }

        var cursor: NativeMomentCursor?
        var count = 0
        while true {
            let batch = try momentCandidates(matching: filter, before: cursor, limit: 200)
            guard !batch.isEmpty else { return count }
            count += batch.filter(filter.matches).count
            guard batch.count == 200, let last = batch.last else { return count }
            cursor = NativeMomentCursor(createdAt: last.createdAt, id: last.id)
        }
    }

    public func listMomentFacetRecords() throws -> [NativeMomentFacetRecord] {
        try prepare()
        var records: [NativeMomentFacetRecord] = []
        try db().query("""
        SELECT created_at, text, tags_json
        FROM moments
        WHERE deleted_at IS NULL
        """) { row in
            guard let createdAt = row.text(at: 0), let text = row.text(at: 1) else {
                throw NativeStoreError.fileSystem("SQLite：微博筛选记录不完整")
            }
            let tags: [String]
            if let tagsJSON = row.text(at: 2) {
                tags = try decode(tagsJSON)
            } else {
                tags = NativeMomentTag.extract(from: text)
            }
            records.append(NativeMomentFacetRecord(createdAt: createdAt, tags: tags))
        }
        return records
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
            .filter { !$0.isVideo && !$0.url.isEmpty }
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
            try writeActivityEvents()
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
            .filter { !$0.isVideo && !$0.url.isEmpty }
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
            updatedAt: nextTimestamp(after: previous.updatedAt),
            pageViews: previous.pageViews
        )

        try db().transaction {
            try insertMoment(updated, into: db())
            try recordActivityEvent(type: "moment_edited", at: activityDate(from: updated.updatedAt) ?? Date())
        }
        do {
            try writeMomentSidecar(updated)
            try writeActivityEvents()
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
            updatedAt: previous.updatedAt,
            pageViews: previous.pageViews
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

    private func removeUnreferencedMomentImages(
        _ images: [NativeMedia],
        includingDeleted: Bool = true
    ) throws {
        try removeUnreferencedMediaFiles(images, includingDeleted: includingDeleted)
    }

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

    public func incrementArticlePageViews(slug: String) throws -> NativeArticle {
        try prepare()
        let safeSlug = try requireSafeSegment(slug, label: "文章 slug")
        try db().execute(
            "UPDATE articles SET page_views = page_views + 1 WHERE slug = ? AND deleted_at IS NULL",
            values: [.text(safeSlug)]
        )
        guard let updated = try storedArticle(withSlug: safeSlug) else { throw NativeStoreError.notFound }
        do {
            try writeArticleSidecars(updated)
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

    public func saveArticle(_ article: NativeSaveArticle) throws -> NativeArticle {
        try prepare()
        let slug = try requireSafeSegment(article.slug, label: "文章 slug")
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
            pageViews: previous?.pageViews ?? 0
        )

        let activityType = saved.status == .published && previous?.status != .published
            ? "article_published"
            : article.expectedUpdatedAt == nil
                ? nil
                : "article_edited"

        try db().transaction {
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
            try insertArticle(saved, into: db())
            if let activityType {
                try recordActivityEvent(type: activityType, at: activityDate(from: updatedAt) ?? Date())
            }
        }
        try trimArticleRevisions(draftKey: slug)

        do {
            try writeArticleSidecars(saved)
            try rebuildIndex()
            try writeActivityEvents()
        } catch {
            markJSONBackupNeedsRebuild()
        }
        return saved
    }

    public func deleteArticle(slug: String, expectedUpdatedAt: String) throws {
        let article = try getArticle(slug: slug)
        guard article.updatedAt == expectedUpdatedAt else { throw NativeStoreError.conflict }
        let safeSlug = try requireSafeSegment(slug, label: "文章 slug")
        let deletedAt = timestamp(from: Date())
        let expiresAt = timestamp(afterDays: Self.trashRetentionDays)
        try db().execute(
            "UPDATE articles SET deleted_at = ?, delete_expires_at = ? WHERE slug = ?",
            values: [.text(deletedAt), .text(expiresAt), .text(safeSlug)]
        )
        removeArticleExportFiles(for: safeSlug)
        try rebuildIndex()
        try writeTrashBackup()
        markJSONBackupNeedsRebuild()
    }

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
            guard try storedArticle(withSlug: safeKey, includingDeleted: true) != nil else {
                throw NativeStoreError.notFound
            }
            try db().execute(
                "UPDATE articles SET deleted_at = NULL, delete_expires_at = NULL WHERE slug = ? AND deleted_at IS NOT NULL",
                values: [.text(safeKey)]
            )
            if let restored = try storedArticle(withSlug: safeKey) {
                try? writeArticleSidecars(restored)
            }
            try rebuildIndex()
            try writeTrashBackup()
            markJSONBackupNeedsRebuild()
        case .moment:
            guard try moment(withID: safeKey, includingDeleted: true) != nil else {
                throw NativeStoreError.notFound
            }
            try db().execute(
                "UPDATE moments SET deleted_at = NULL, delete_expires_at = NULL WHERE id = ? AND deleted_at IS NOT NULL",
                values: [.text(safeKey)]
            )
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
            guard try storedArticle(withSlug: safeKey, includingDeleted: true) != nil,
                  try db().text("SELECT deleted_at FROM articles WHERE slug = ?", values: [.text(safeKey)]) != nil else {
                throw NativeStoreError.notFound
            }
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
        var articleSlugs: [String] = []
        var momentsToDelete: [(id: String, images: [NativeMedia])] = []

        try db().query("SELECT slug FROM articles WHERE deleted_at IS NOT NULL") { row in
            if let slug = row.text(at: 0) { articleSlugs.append(slug) }
        }
        try db().query("SELECT id, images_json FROM moments WHERE deleted_at IS NOT NULL") { row in
            guard let id = row.text(at: 0), let imagesJSON = row.text(at: 1) else { return }
            momentsToDelete.append((id: id, images: try decode(imagesJSON)))
        }

        try db().transaction {
            try db().execute("DELETE FROM articles WHERE deleted_at IS NOT NULL")
            try db().execute("DELETE FROM moments WHERE deleted_at IS NOT NULL")
            for slug in articleSlugs {
                try db().execute(
                    "DELETE FROM article_revisions WHERE article_slug = ? OR draft_key = ?",
                    values: [.text(slug), .text(slug)]
                )
            }
        }
        for slug in articleSlugs { removeArticleFiles(for: slug) }
        for moment in momentsToDelete {
            try removeUnreferencedMomentImages(moment.images, includingDeleted: true)
            removeMomentSidecar(id: moment.id)
        }
        try rebuildIndex()
        try writeTrashBackup()
    }

    private func purgeExpiredTrash() throws {
        let now = timestamp(from: Date())
        var articleSlugs: [String] = []
        var momentsToDelete: [(id: String, images: [NativeMedia])] = []

        try db().query(
            "SELECT slug FROM articles WHERE deleted_at IS NOT NULL AND delete_expires_at <= ?",
            values: [.text(now)]
        ) { row in
            if let slug = row.text(at: 0) { articleSlugs.append(slug) }
        }
        try db().query(
            "SELECT id, images_json FROM moments WHERE deleted_at IS NOT NULL AND delete_expires_at <= ?",
            values: [.text(now)]
        ) { row in
            guard let id = row.text(at: 0), let imagesJSON = row.text(at: 1) else { return }
            momentsToDelete.append((id: id, images: try decode(imagesJSON)))
        }
        guard !articleSlugs.isEmpty || !momentsToDelete.isEmpty else { return }

        try db().transaction {
            try db().execute(
                "DELETE FROM articles WHERE deleted_at IS NOT NULL AND delete_expires_at <= ?",
                values: [.text(now)]
            )
            try db().execute(
                "DELETE FROM moments WHERE deleted_at IS NOT NULL AND delete_expires_at <= ?",
                values: [.text(now)]
            )
            for slug in articleSlugs {
                try db().execute(
                    "DELETE FROM article_revisions WHERE article_slug = ? OR draft_key = ?",
                    values: [.text(slug), .text(slug)]
                )
            }
        }
        for slug in articleSlugs { removeArticleFiles(for: slug) }
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

    private func insertArticleRevision(
        draftKey: String,
        articleSlug: String?,
        reason: NativeArticleRevisionReason,
        snapshot: NativeArticleRevisionSnapshot,
        createdAt: String,
        updatedAt: String
    ) throws -> NativeArticleRevision {
        try db().execute(
            """
            INSERT INTO article_revisions(
                draft_key, article_slug, reason, snapshot_json, created_at, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?)
            """,
            values: [
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

    private func decodeArticleRevision(_ row: SQLiteRow) throws -> NativeArticleRevision {
        guard let id = row.integer(at: 0),
              let draftKey = row.text(at: 1),
              let reasonValue = row.text(at: 3),
              let reason = NativeArticleRevisionReason(rawValue: reasonValue),
              let snapshotJSON = row.text(at: 4),
              let createdAt = row.text(at: 5),
              let updatedAt = row.text(at: 6) else {
            throw NativeStoreError.fileSystem("SQLite：文章版本记录不完整")
        }
        let snapshot: NativeArticleRevisionSnapshot = try decode(snapshotJSON)
        return NativeArticleRevision(
            id: id,
            draftKey: draftKey,
            articleSlug: row.text(at: 2),
            reason: reason,
            snapshot: snapshot,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func removeArticleExportFiles(for slug: String) {
        guard let safeSlug = try? requireSafeSegment(slug, label: "文章 slug") else { return }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: articlesURL.appendingPathComponent("\(safeSlug).json"))
        try? fileManager.removeItem(at: articlesURL.appendingPathComponent("\(safeSlug).md"))
        try? fileManager.removeItem(at: draftsURL.appendingPathComponent("\(safeSlug).json"))
    }

    private func writeArticleSidecars(_ article: NativeArticle) throws {
        let safeSlug = try requireSafeSegment(article.slug, label: "文章 slug")
        try writeJSON(article, to: articlesURL.appendingPathComponent("\(safeSlug).json"))
        try writeJSON(article, to: draftsURL.appendingPathComponent("\(safeSlug).json"))
        try writeMarkdown(article, to: articlesURL.appendingPathComponent("\(safeSlug).md"))
    }

    private func removeArticleFiles(for slug: String) {
        guard let safeSlug = try? requireSafeSegment(slug, label: "文章 slug") else { return }
        removeArticleExportFiles(for: safeSlug)
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
    ) throws -> (body: String, banner: NativeBanner?, media: [NativeMedia]) {
        var nextBody = body
        var nextBanner = banner
        var nextMedia: [NativeMedia] = []

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
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: source, to: destination)
            }
            return "/media/\(slug)/\(filename)"
        }

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
        return (nextBody, nextBanner, nextMedia)
    }

    func uploadMedia(fileURL: URL, kind: String, slug: String? = nil) throws -> NativeUploadedMedia {
        try prepare()
        let targetSlug = try requireSafeSegment(slug?.isEmpty == false ? slug! : "inbox", label: "媒体目录")
        let targetDirectory = mediaURL.appendingPathComponent(targetSlug, isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

        let originalName = fileURL.lastPathComponent.isEmpty ? "media" : fileURL.lastPathComponent
        let extensionName = fileURL.pathExtension.isEmpty ? "bin" : fileURL.pathExtension.lowercased()
        let filename = "\(UUID().uuidString.lowercased()).\(extensionName)"
        let targetURL = targetDirectory.appendingPathComponent(filename)
        do {
            try FileManager.default.copyItem(at: fileURL, to: targetURL)
            let size = try FileManager.default.attributesOfItem(atPath: targetURL.path)[.size] as? Int ?? 0
            let mediaKind = kind == "video" ? "video" : "image"
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

    public func mediaURL(for storedPath: String) -> URL? {
        let normalized = normalizeMediaURL(storedPath)
        guard let range = normalized.range(of: "/media/") else { return nil }
        let parts = normalized[range.upperBound...].split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2,
              let slug = try? requireSafeSegment(String(parts[0]), label: "媒体目录"),
              let filename = try? requireSafeSegment(String(parts[1]), label: "媒体文件") else {
            return nil
        }
        return mediaURL.appendingPathComponent(slug).appendingPathComponent(filename)
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
        let articles = try allArticles(includingDeleted: includingDeleted)
        let moments = try allMoments(includingDeleted: includingDeleted)
        let referencedURLs = Set(
            articles.flatMap { article in
                article.media.map { normalizeMediaURL($0.url) }
                    + (article.banner.map { [normalizeMediaURL($0.url)] } ?? [])
            } + moments.flatMap { $0.images.map { normalizeMediaURL($0.url) } }
        )

        for item in media {
            let normalizedURL = normalizeMediaURL(item.url)
            guard !referencedURLs.contains(normalizedURL),
                  !articles.contains(where: { $0.body.contains(normalizedURL) }),
                  let fileURL = mediaURL(for: normalizedURL) else {
                continue
            }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func db() throws -> SQLiteDatabase {
        guard let database else { throw NativeStoreError.fileSystem("SQLite：数据库尚未准备好") }
        return database
    }

    private func markJSONBackupNeedsRebuild() {
        jsonBackupVerified = false
        try? database?.execute("DELETE FROM metadata WHERE key = 'json_export_v2'")
    }

    private func createSchema(in database: SQLiteDatabase) throws {
        try database.execute("""
        CREATE TABLE IF NOT EXISTS metadata (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS articles (
            slug TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL,
            body TEXT NOT NULL,
            category TEXT NOT NULL,
            excerpt TEXT NOT NULL,
            banner_json TEXT,
            media_json TEXT NOT NULL,
            status TEXT NOT NULL,
            tags_json TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            published_at TEXT,
            word_count INTEGER NOT NULL,
            page_views INTEGER NOT NULL DEFAULT 0,
            deleted_at TEXT,
            delete_expires_at TEXT
        );
        CREATE INDEX IF NOT EXISTS articles_updated_at_idx ON articles(updated_at DESC);
        CREATE TABLE IF NOT EXISTS article_revisions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            draft_key TEXT NOT NULL,
            article_slug TEXT,
            reason TEXT NOT NULL,
            snapshot_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS article_revisions_article_idx
            ON article_revisions(article_slug, updated_at DESC);
        CREATE INDEX IF NOT EXISTS article_revisions_draft_idx
            ON article_revisions(draft_key, updated_at DESC);
        CREATE TABLE IF NOT EXISTS moments (
            id TEXT PRIMARY KEY NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            text TEXT NOT NULL,
            text_runs_json TEXT NOT NULL,
            images_json TEXT NOT NULL,
            tags_json TEXT NOT NULL,
            is_favorite INTEGER NOT NULL DEFAULT 0,
            page_views INTEGER NOT NULL DEFAULT 0,
            deleted_at TEXT,
            delete_expires_at TEXT
        );
        CREATE INDEX IF NOT EXISTS moments_created_at_idx ON moments(created_at DESC);
        CREATE INDEX IF NOT EXISTS moments_feed_active_idx ON moments(created_at DESC, id DESC)
            WHERE deleted_at IS NULL;
        CREATE TABLE IF NOT EXISTS activity_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            type TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS activity_created_at_idx ON activity_events(created_at);
        """)
        try ensureColumn("deleted_at", in: "articles", database: database)
        try ensureColumn("delete_expires_at", in: "articles", database: database)
        try ensureColumn("page_views", in: "articles", database: database, definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn("deleted_at", in: "moments", database: database)
        try ensureColumn("delete_expires_at", in: "moments", database: database)
        try ensureColumn("tags_json", in: "moments", database: database)
        try ensureColumn("is_favorite", in: "moments", database: database, definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn("page_views", in: "moments", database: database, definition: "INTEGER NOT NULL DEFAULT 0")
        try database.execute("""
        CREATE INDEX IF NOT EXISTS articles_trash_expiry_idx ON articles(delete_expires_at);
        CREATE INDEX IF NOT EXISTS moments_trash_expiry_idx ON moments(delete_expires_at);
        """)
        try createSearchSchema(in: database)
    }

    private func createSearchSchema(in database: SQLiteDatabase) throws {
        try database.execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS content_search USING fts5(
            document_type UNINDEXED,
            document_id UNINDEXED,
            title,
            body,
            excerpt,
            tags,
            category,
            status UNINDEXED,
            created_at UNINDEXED,
            updated_at UNINDEXED,
            tokenize = 'trigram'
        );

        DROP TRIGGER IF EXISTS content_search_articles_insert;
        DROP TRIGGER IF EXISTS content_search_articles_update;
        DROP TRIGGER IF EXISTS content_search_articles_delete;
        DROP TRIGGER IF EXISTS content_search_moments_insert;
        DROP TRIGGER IF EXISTS content_search_moments_update;
        DROP TRIGGER IF EXISTS content_search_moments_delete;

        CREATE TRIGGER content_search_articles_insert
        AFTER INSERT ON articles WHEN new.deleted_at IS NULL BEGIN
            DELETE FROM content_search
            WHERE document_type = 'article' AND document_id = new.slug;
            INSERT INTO content_search(
                document_type, document_id, title, body, excerpt, tags,
                category, status, created_at, updated_at
            ) VALUES (
                'article', new.slug, new.title, new.body, new.excerpt,
                new.tags_json, new.category, new.status,
                COALESCE(new.published_at, new.updated_at), new.updated_at
            );
        END;
        CREATE TRIGGER content_search_articles_update
        AFTER UPDATE OF slug, title, body, category, excerpt, tags_json, status,
                        updated_at, published_at, deleted_at ON articles BEGIN
            DELETE FROM content_search
            WHERE document_type = 'article' AND document_id = old.slug;
            INSERT INTO content_search(
                document_type, document_id, title, body, excerpt, tags,
                category, status, created_at, updated_at
            )
            SELECT 'article', new.slug, new.title, new.body, new.excerpt,
                   new.tags_json, new.category, new.status,
                   COALESCE(new.published_at, new.updated_at), new.updated_at
            WHERE new.deleted_at IS NULL;
        END;
        CREATE TRIGGER content_search_articles_delete
        AFTER DELETE ON articles BEGIN
            DELETE FROM content_search
            WHERE document_type = 'article' AND document_id = old.slug;
        END;

        CREATE TRIGGER content_search_moments_insert
        AFTER INSERT ON moments WHEN new.deleted_at IS NULL BEGIN
            DELETE FROM content_search
            WHERE document_type = 'moment' AND document_id = new.id;
            INSERT INTO content_search(
                document_type, document_id, title, body, excerpt, tags,
                category, status, created_at, updated_at
            ) VALUES (
                'moment', new.id,
                CASE WHEN trim(new.text) = '' THEN '图片微博'
                     ELSE substr(replace(replace(new.text, char(10), ' '), char(13), ' '), 1, 80) END,
                new.text, '', COALESCE(new.tags_json, '[]'), '', '',
                new.created_at, new.updated_at
            );
        END;
        CREATE TRIGGER content_search_moments_update
        AFTER UPDATE OF id, created_at, updated_at, text, tags_json, deleted_at ON moments BEGIN
            DELETE FROM content_search
            WHERE document_type = 'moment' AND document_id = old.id;
            INSERT INTO content_search(
                document_type, document_id, title, body, excerpt, tags,
                category, status, created_at, updated_at
            )
            SELECT 'moment', new.id,
                   CASE WHEN trim(new.text) = '' THEN '图片微博'
                        ELSE substr(replace(replace(new.text, char(10), ' '), char(13), ' '), 1, 80) END,
                   new.text, '', COALESCE(new.tags_json, '[]'), '', '',
                   new.created_at, new.updated_at
            WHERE new.deleted_at IS NULL;
        END;
        CREATE TRIGGER content_search_moments_delete
        AFTER DELETE ON moments BEGIN
            DELETE FROM content_search
            WHERE document_type = 'moment' AND document_id = old.id;
        END;
        """)

        let activeCount = try database.integer("""
        SELECT (SELECT COUNT(*) FROM articles WHERE deleted_at IS NULL)
             + (SELECT COUNT(*) FROM moments WHERE deleted_at IS NULL)
        """) ?? 0
        let indexedCount = try database.integer("SELECT COUNT(*) FROM content_search") ?? 0
        let version = try database.text(
            "SELECT value FROM metadata WHERE key = 'content_search_v1'"
        )
        guard version != "trigram-v1" || activeCount != indexedCount else { return }

        try database.transaction {
            try database.execute("DELETE FROM content_search")
            try database.execute("""
            INSERT INTO content_search(
                document_type, document_id, title, body, excerpt, tags,
                category, status, created_at, updated_at
            )
            SELECT 'article', slug, title, body, excerpt, tags_json,
                   category, status, COALESCE(published_at, updated_at), updated_at
            FROM articles WHERE deleted_at IS NULL;

            INSERT INTO content_search(
                document_type, document_id, title, body, excerpt, tags,
                category, status, created_at, updated_at
            )
            SELECT 'moment', id,
                   CASE WHEN trim(text) = '' THEN '图片微博'
                        ELSE substr(replace(replace(text, char(10), ' '), char(13), ' '), 1, 80) END,
                   text, '', COALESCE(tags_json, '[]'), '', '', created_at, updated_at
            FROM moments WHERE deleted_at IS NULL;

            INSERT OR REPLACE INTO metadata(key, value)
            VALUES('content_search_v1', 'trigram-v1');
            """)
        }
    }

    private func ensureColumn(
        _ column: String,
        in table: String,
        database: SQLiteDatabase,
        definition: String = "TEXT"
    ) throws {
        var exists = false
        try database.query("PRAGMA table_info(\(table))") { row in
            if row.text(at: 1) == column { exists = true }
        }
        if !exists {
            try database.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
        }
    }

    private func migrateLegacyDataIfNeeded() throws {
        let database = try db()
        guard try database.text("SELECT value FROM metadata WHERE key = 'legacy_migration_v1'") != "done" else { return }

        let articles = try loadLegacyArticles()
        let moments = try loadLegacyMoments()
        let events = try loadLegacyActivityEvents()
        let trash = try loadLegacyTrashBackup()

        try database.transaction {
            try importArticles(articles, into: database)
            try importMoments(moments, into: database)
            try importActivityEvents(events, into: database)
            try importTrashedArticles(trash.articles, into: database)
            try importTrashedMoments(trash.moments, into: database)
            try database.execute("INSERT OR REPLACE INTO metadata(key, value) VALUES('legacy_migration_v1', 'done')")
        }
    }

    private func migrateMomentTagsIfNeeded() throws {
        let database = try db()
        guard try database.text("SELECT value FROM metadata WHERE key = 'moment_tags_v1'") != "done" else {
            return
        }

        var legacyMoments: [(id: String, text: String)] = []
        try database.query("SELECT id, text FROM moments WHERE tags_json IS NULL") { row in
            guard let id = row.text(at: 0), let text = row.text(at: 1) else {
                throw NativeStoreError.fileSystem("SQLite：微博记录不完整")
            }
            legacyMoments.append((id, text))
        }

        try database.transaction {
            for moment in legacyMoments {
                try database.execute(
                    "UPDATE moments SET tags_json = ? WHERE id = ?",
                    values: [
                        .text(try jsonString(NativeMomentTag.extract(from: moment.text))),
                        .text(moment.id),
                    ]
                )
            }
            try database.execute("INSERT OR REPLACE INTO metadata(key, value) VALUES('moment_tags_v1', 'done')")
        }
    }

    private func exportJsonBackupIfNeeded() throws {
        if jsonBackupVerified { return }
        let database = try db()
        let exportMarkedDone = try database.text("SELECT value FROM metadata WHERE key = 'json_export_v2'") == "done"
        if exportMarkedDone, try jsonBackupIsComplete() {
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

    private func jsonBackupIsComplete() throws -> Bool {
        let fileManager = FileManager.default
        let articles = try allArticles()
        for article in articles {
            let jsonURL = articlesURL.appendingPathComponent("\(article.slug).json")
            guard let data = try? Data(contentsOf: jsonURL),
                  let exported = try? JSONDecoder().decode(NativeArticle.self, from: data),
                  normalize(exported) == article else {
                return false
            }
        }

        let indexURL = articlesURL.appendingPathComponent("index.json")
        guard fileManager.fileExists(atPath: indexURL.path),
              let indexData = try? Data(contentsOf: indexURL),
              let indexed = try? JSONDecoder().decode([NativeArticle].self, from: indexData),
              indexed.count == articles.count,
              Set(indexed.map(normalize)) == Set(articles) else {
            return false
        }

        let eventsURL = activityURL.appendingPathComponent("events.json")
        guard let eventData = try? Data(contentsOf: eventsURL),
              let exportedEvents = try? JSONDecoder().decode([NativeActivityEvent].self, from: eventData),
              exportedEvents == (try allActivityEvents()) else {
            return false
        }

        if !fileManager.fileExists(atPath: momentSidecarsMarkerURL.path) {
            let moments = try allMoments()
            guard let momentsData = try? Data(contentsOf: momentsIndexURL),
                  let indexedMoments = try? JSONDecoder().decode([NativeMoment].self, from: momentsData),
                  indexedMoments.count == moments.count,
                  Set(indexedMoments) == Set(moments) else {
                return false
            }
        }

        guard let trashData = try? Data(contentsOf: trashIndexURL),
              let exportedTrash = try? JSONDecoder().decode(NativeTrashBackup.self, from: trashData),
              exportedTrash == (try trashBackup()) else {
            return false
        }
        return true
    }

    private func loadLegacyArticles() throws -> [NativeArticle] {
        let indexURL = articlesURL.appendingPathComponent("index.json")
        if FileManager.default.fileExists(atPath: indexURL.path) {
            let indexed: [NativeArticle]
            do {
                indexed = try JSONDecoder().decode([NativeArticle].self, from: Data(contentsOf: indexURL))
            } catch {
                throw NativeStoreError.fileSystem("无法读取 \(indexURL.lastPathComponent)：\(error.localizedDescription)")
            }

            var bySlug: [String: NativeArticle] = [:]
            for article in indexed where !article.slug.isEmpty {
                let slug = try requireSafeSegment(article.slug, label: "文章 slug")
                let file = articlesURL.appendingPathComponent("\(slug).json")
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
            at: articlesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for file in files where file.pathExtension.lowercased() == "json" {
            let article = try readArticle(at: file)
            if !article.slug.isEmpty {
                let slug = try requireSafeSegment(article.slug, label: "文章 slug")
                bySlug[slug] = article
            }
        }
        return Array(bySlug.values)
    }

    private func loadLegacyMoments() throws -> [NativeMoment] {
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

    private func loadLegacyActivityEvents() throws -> [NativeActivityEvent] {
        let legacyURL = activityURL.appendingPathComponent("events.json")
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return [] }
        do {
            return try JSONDecoder().decode([NativeActivityEvent].self, from: Data(contentsOf: legacyURL))
        } catch {
            throw NativeStoreError.fileSystem("无法读取 \(legacyURL.lastPathComponent)：\(error.localizedDescription)")
        }
    }

    private func loadLegacyTrashBackup() throws -> NativeTrashBackup {
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

    private func importArticles(_ articles: [NativeArticle], into database: SQLiteDatabase) throws {
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

    private func importMoments(_ moments: [NativeMoment], into database: SQLiteDatabase) throws {
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

    private func importActivityEvents(_ events: [NativeActivityEvent], into database: SQLiteDatabase) throws {
        guard try database.integer("SELECT COUNT(*) FROM activity_events") == 0 else { return }
        for event in events { try insertActivity(event, into: database) }
    }

    private func importTrashedArticles(_ articles: [NativeTrashedArticle], into database: SQLiteDatabase) throws {
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

    private func importTrashedMoments(_ moments: [NativeTrashedMoment], into database: SQLiteDatabase) throws {
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

    private func storedArticle(withSlug slug: String, includingDeleted: Bool = false) throws -> NativeArticle? {
        var result: NativeArticle?
        let whereClause = includingDeleted ? "slug = ?" : "deleted_at IS NULL AND slug = ?"
        try db().query(articleSelect + " WHERE \(whereClause)", values: [.text(slug)]) { row in
            result = try decodeArticle(row)
        }
        return result
    }

    private func allArticles(includingDeleted: Bool = false) throws -> [NativeArticle] {
        var articles: [NativeArticle] = []
        let whereClause = includingDeleted ? "" : "WHERE deleted_at IS NULL"
        try db().query(articleSelect + " \(whereClause) ORDER BY updated_at DESC") { row in
            articles.append(try decodeArticle(row))
        }
        return articles
    }

    private func articleGraph(from articles: [NativeArticle]) -> NativeArticleGraph {
        let nodes = articles.map(summary)
        var edges: [NativeArticleGraphEdge] = []

        for article in articles {
            var targetSlugs = Set<String>()
            for reference in NativeArticleLink.references(in: article.body) {
                guard let target = NativeArticleLink.resolve(reference, in: nodes),
                      targetSlugs.insert(target.slug).inserted else {
                    continue
                }
                edges.append(NativeArticleGraphEdge(sourceSlug: article.slug, targetSlug: target.slug))
            }
        }

        return NativeArticleGraph(nodes: nodes, edges: edges)
    }

    private func insertArticle(
        _ article: NativeArticle,
        deletedAt: String? = nil,
        deleteExpiresAt: String? = nil,
        into database: SQLiteDatabase
    ) throws {
        let bannerJSON: SQLiteValue
        if let banner = article.banner {
            bannerJSON = .text(try jsonString(banner))
        } else {
            bannerJSON = .null
        }
        try database.execute("""
        INSERT OR REPLACE INTO articles(
            slug, title, body, category, excerpt, banner_json, media_json, status,
            tags_json, updated_at, published_at, word_count, page_views, deleted_at, delete_expires_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            .integer(article.wordCount ?? wordCount(article.body)),
            .integer(article.pageViews),
            deletedAt.map(SQLiteValue.text) ?? .null,
            deleteExpiresAt.map(SQLiteValue.text) ?? .null,
        ])
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
            wordCount: wordCount(body),
            pageViews: row.integer(at: 12) ?? 0
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

    private func allMoments(includingDeleted: Bool = false) throws -> [NativeMoment] {
        var moments: [NativeMoment] = []
        let whereClause = includingDeleted ? "" : "WHERE deleted_at IS NULL"
        try db().query(momentSelect + " \(whereClause) ORDER BY created_at DESC, id DESC") { row in
            moments.append(try decodeMoment(row))
        }
        return moments
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
            let tagPredicates = filter.tags.map { _ in "instr(lower(tags_json), ?) > 0" }
            predicates.append("(\(tagPredicates.joined(separator: " OR ")))")
            values.append(contentsOf: filter.tags.map { tag in
                .text("\"\(tag.lowercased())\"")
            })
        }

        if let cursor {
            predicates.append("(created_at < ? OR (created_at = ? AND id < ?))")
            values.append(.text(cursor.createdAt))
            values.append(.text(cursor.createdAt))
            values.append(.text(cursor.id))
        }

        return (predicates.joined(separator: " AND "), values)
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

    private func insertMoment(
        _ moment: NativeMoment,
        deletedAt: String? = nil,
        deleteExpiresAt: String? = nil,
        into database: SQLiteDatabase
    ) throws {
        try database.execute("""
        INSERT OR REPLACE INTO moments(id, created_at, updated_at, text, text_runs_json, images_json, tags_json, is_favorite, page_views, deleted_at, delete_expires_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, values: [
            .text(moment.id),
            .text(moment.createdAt),
            .text(moment.updatedAt),
            .text(moment.text),
            .text(try jsonString(moment.textRuns)),
            .text(try jsonString(moment.images)),
            .text(try jsonString(moment.tags)),
            .integer(moment.isFavorite ? 1 : 0),
            .integer(moment.pageViews),
            deletedAt.map(SQLiteValue.text) ?? .null,
            deleteExpiresAt.map(SQLiteValue.text) ?? .null,
        ])
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
            updatedAt: updatedAt,
            pageViews: row.integer(at: 8) ?? 0
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
            guard let deletedAt = row.text(at: 9), let expiresAt = row.text(at: 10) else {
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
        try? writeActivityEvents()
    }

    private func writeActivityEvents() throws {
        try writeJSON(try allActivityEvents(), to: activityURL.appendingPathComponent("events.json"))
    }

    private func writeTrashBackup() throws {
        try writeJSON(try trashBackup(), to: trashIndexURL)
    }

    private func rebuildArticleExports() throws {
        for article in try allArticles() {
            try writeArticleSidecars(article)
        }
        try rebuildIndex()
    }

    private func rebuildIndex() throws {
        try writeJSON(try allArticles(), to: articlesURL.appendingPathComponent("index.json"))
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
        } catch {
            throw NativeStoreError.fileSystem("无法写入 \(url.lastPathComponent)：\(error.localizedDescription)")
        }
    }

    private func writeMarkdown(_ article: NativeArticle, to url: URL) throws {
        let encoder = JSONEncoder()
        func quoted(_ value: String) -> String {
            (try? String(data: encoder.encode(value), encoding: .utf8)) ?? "\"\""
        }
        var lines = [
            "---",
            "title: \(quoted(article.title))",
            "category: \(quoted(article.category))",
            "tags: \(quoted(article.tags.joined(separator: ",")))",
            "slug: \(article.slug)",
            "status: \(article.status.rawValue)",
            "updatedAt: \(article.updatedAt)",
        ]
        if let publishedAt = article.publishedAt { lines.append("publishedAt: \(publishedAt)") }
        if let banner = article.banner {
            lines.append("banner: \(quoted(banner.url))")
            lines.append("bannerAlt: \(quoted(banner.alt))")
        }
        lines.append(contentsOf: ["---", "", article.body, ""])
        if !article.media.isEmpty {
            lines.append("## Media")
            lines.append(contentsOf: article.media.map { "- [\($0.name)](\($0.url))" })
            lines.append("")
        }
        do {
            try lines.joined(separator: "\n").data(using: .utf8)?.write(to: url, options: .atomic)
        } catch {
            throw NativeStoreError.fileSystem("无法写入 \(url.lastPathComponent)：\(error.localizedDescription)")
        }
    }

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
            pageViews: article.pageViews
        )
    }

    private func normalizeBanner(_ banner: NativeBanner) -> NativeBanner {
        NativeBanner(alt: banner.alt, name: banner.name, size: banner.size, url: normalizeMediaURL(banner.url))
    }

    private func normalizeMedia(_ media: NativeMedia) -> NativeMedia {
        NativeMedia(kind: media.kind, name: media.name, size: media.size, url: normalizeMediaURL(media.url))
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

    private func compactSearchSnippet(_ source: String) -> String {
        let compact = source
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard compact.count > 240 else { return compact }
        return String(compact.prefix(240)) + "…"
    }

    private func normalizeMediaURL(_ value: String) -> String {
        guard let url = URL(string: value),
              let host = url.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1"].contains(host),
              url.path.hasPrefix("/media/") else {
            return value.hasPrefix("media/") ? "/\(value)" : value
        }
        return url.path
    }

    private func summary(for article: NativeArticle) -> NativeArticleSummary {
        NativeArticleSummary(
            banner: article.banner,
            category: article.category,
            excerpt: article.excerpt,
            pageViews: article.pageViews,
            publishedAt: article.publishedAt,
            slug: article.slug,
            status: article.status,
            tags: article.tags,
            title: article.title,
            updatedAt: article.updatedAt,
            wordCount: article.wordCount ?? wordCount(article.body)
        )
    }

    private func wordCount(_ body: String) -> Int {
        NativeWritingMetrics.characterCount(of: body)
    }

    private func jsonString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        guard let result = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw NativeStoreError.fileSystem("无法编码 SQLite JSON 字段")
        }
        return result
    }

    private func decode<T: Decodable>(_ value: String) throws -> T {
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

    private func requireSafeSegment(_ value: String, label: String) throws -> String {
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

    private var articleSelect: String {
        "SELECT slug, title, body, category, excerpt, banner_json, media_json, status, tags_json, updated_at, published_at, word_count, page_views, deleted_at, delete_expires_at FROM articles"
    }

    private var momentSelect: String {
        "SELECT id, created_at, updated_at, text, text_runs_json, images_json, tags_json, is_favorite, page_views, deleted_at, delete_expires_at FROM moments"
    }

    private var revisionSelect: String {
        "SELECT id, draft_key, article_slug, reason, snapshot_json, created_at, updated_at FROM article_revisions"
    }
}

private struct NativeActivityEvent: Codable, Equatable {
    let type: String
    let createdAt: String
}

private struct NativeTrashedArticle: Codable, Equatable {
    let article: NativeArticle
    let deletedAt: String
    let expiresAt: String
}

private struct NativeTrashedMoment: Codable, Equatable {
    let moment: NativeMoment
    let deletedAt: String
    let expiresAt: String
}

private struct NativeTrashBackup: Codable, Equatable {
    let articles: [NativeTrashedArticle]
    let moments: [NativeTrashedMoment]
}
