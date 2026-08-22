import Foundation

/// Local SQLite store for structured data, with Markdown/JSON exports and file-based media.
public actor LocalBlogStore {
    private static let trashRetentionDays = 30
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
            try exportJsonBackupIfNeeded()
            try purgeExpiredTrash()
        } catch let error as NativeStoreError {
            throw error
        } catch {
            throw NativeStoreError.fileSystem(error.localizedDescription)
        }
    }

    public func listArticles(includeDrafts: Bool = true) throws -> [NativeArticleSummary] {
        try prepare()
        let sql = """
        SELECT slug, title, body, category, excerpt, banner_json, media_json, status,
               tags_json, updated_at, published_at, word_count
        FROM articles
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

    public func listMoments() throws -> [NativeMoment] {
        try prepare()
        return try allMoments().sorted { left, right in
            left.createdAt == right.createdAt ? left.id > right.id : left.createdAt > right.createdAt
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
            .filter { !$0.isVideo && !$0.url.isEmpty }
            .map(normalizeMedia)
            .prefix(9))
        guard !normalizedText.text.isEmpty || !normalizedImages.isEmpty else {
            throw NativeStoreError.invalidMoment
        }

        let latestCreatedAt = try allMoments().map(\.createdAt).max()
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
            try rebuildMomentsIndex()
            try writeActivityEvents()
        } catch {
            jsonBackupVerified = false
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
            updatedAt: nextTimestamp(after: previous.updatedAt)
        )

        try db().transaction {
            try insertMoment(updated, into: db())
            try recordActivityEvent(type: "moment_edited", at: activityDate(from: updated.updatedAt) ?? Date())
        }
        do {
            try rebuildMomentsIndex()
            try writeActivityEvents()
        } catch {
            jsonBackupVerified = false
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
            try rebuildMomentsIndex()
        } catch {
            jsonBackupVerified = false
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
        try rebuildMomentsIndex()
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
            tags: Array(Array(Set(article.tags.filter { !$0.isEmpty })).prefix(12)),
            title: article.title,
            updatedAt: updatedAt,
            publishedAt: publishedAt,
            wordCount: wordCount(relocated.body)
        )

        let activityType = saved.status == .published && previous?.status != .published
            ? "article_published"
            : article.expectedUpdatedAt == nil
                ? nil
                : "article_edited"

        try db().transaction {
            try insertArticle(saved, into: db())
            if let activityType {
                try recordActivityEvent(type: activityType, at: activityDate(from: updatedAt) ?? Date())
            }
        }

        do {
            try writeArticleSidecars(saved)
            try rebuildIndex()
            try writeActivityEvents()
        } catch {
            jsonBackupVerified = false
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
        jsonBackupVerified = false
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
            jsonBackupVerified = false
        case .moment:
            guard try moment(withID: safeKey, includingDeleted: true) != nil else {
                throw NativeStoreError.notFound
            }
            try db().execute(
                "UPDATE moments SET deleted_at = NULL, delete_expires_at = NULL WHERE id = ? AND deleted_at IS NOT NULL",
                values: [.text(safeKey)]
            )
            try rebuildMomentsIndex()
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
            try db().execute("DELETE FROM articles WHERE slug = ? AND deleted_at IS NOT NULL", values: [.text(safeKey)])
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
            try rebuildMomentsIndex()
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
        }
        for slug in articleSlugs { removeArticleFiles(for: slug) }
        for moment in momentsToDelete { try removeUnreferencedMomentImages(moment.images, includingDeleted: true) }
        try rebuildIndex()
        try rebuildMomentsIndex()
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
        }
        for slug in articleSlugs { removeArticleFiles(for: slug) }
        for moment in momentsToDelete {
            try removeUnreferencedMomentImages(moment.images, includingDeleted: true)
        }
        try rebuildIndex()
        try rebuildMomentsIndex()
        try writeTrashBackup()
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
            deleted_at TEXT,
            delete_expires_at TEXT
        );
        CREATE INDEX IF NOT EXISTS articles_updated_at_idx ON articles(updated_at DESC);
        CREATE TABLE IF NOT EXISTS moments (
            id TEXT PRIMARY KEY NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            text TEXT NOT NULL,
            text_runs_json TEXT NOT NULL,
            images_json TEXT NOT NULL,
            tags_json TEXT NOT NULL,
            is_favorite INTEGER NOT NULL DEFAULT 0,
            deleted_at TEXT,
            delete_expires_at TEXT
        );
        CREATE INDEX IF NOT EXISTS moments_created_at_idx ON moments(created_at DESC);
        CREATE TABLE IF NOT EXISTS activity_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            type TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS activity_created_at_idx ON activity_events(created_at);
        """)
        try ensureColumn("deleted_at", in: "articles", database: database)
        try ensureColumn("delete_expires_at", in: "articles", database: database)
        try ensureColumn("deleted_at", in: "moments", database: database)
        try ensureColumn("delete_expires_at", in: "moments", database: database)
        try ensureColumn("tags_json", in: "moments", database: database)
        try ensureColumn("is_favorite", in: "moments", database: database, definition: "INTEGER NOT NULL DEFAULT 0")
        try database.execute("""
        CREATE INDEX IF NOT EXISTS articles_trash_expiry_idx ON articles(delete_expires_at);
        CREATE INDEX IF NOT EXISTS moments_trash_expiry_idx ON moments(delete_expires_at);
        """)
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

    private func exportJsonBackupIfNeeded() throws {
        if jsonBackupVerified { return }
        let database = try db()
        let exportMarkedDone = try database.text("SELECT value FROM metadata WHERE key = 'json_export_v1'") == "done"
        if exportMarkedDone, try jsonBackupIsComplete() {
            jsonBackupVerified = true
            return
        }

        try rebuildArticleExports()
        try rebuildMomentsIndex()
        try writeActivityEvents()
        try writeTrashBackup()
        try database.execute("INSERT OR REPLACE INTO metadata(key, value) VALUES('json_export_v1', 'done')")
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

        let moments = try allMoments()
        guard let momentsData = try? Data(contentsOf: momentsIndexURL),
              let indexedMoments = try? JSONDecoder().decode([NativeMoment].self, from: momentsData),
              indexedMoments.count == moments.count,
              Set(indexedMoments) == Set(moments) else {
            return false
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
        if FileManager.default.fileExists(atPath: momentsIndexURL.path) {
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
            tags_json, updated_at, published_at, word_count, deleted_at, delete_expires_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            wordCount: wordCount(body)
        )
    }

    private func moment(withID id: String, includingDeleted: Bool = false) throws -> NativeMoment? {
        var result: NativeMoment?
        let whereClause = includingDeleted ? "id = ?" : "deleted_at IS NULL AND id = ?"
        try db().query(
            "SELECT id, created_at, updated_at, text, text_runs_json, images_json, tags_json, is_favorite FROM moments WHERE \(whereClause)",
            values: [.text(id)]
        ) { row in
            result = try decodeMoment(row)
        }
        return result
    }

    private func allMoments(includingDeleted: Bool = false) throws -> [NativeMoment] {
        var moments: [NativeMoment] = []
        let whereClause = includingDeleted ? "" : "WHERE deleted_at IS NULL"
        try db().query("""
        SELECT id, created_at, updated_at, text, text_runs_json, images_json, tags_json, is_favorite
        FROM moments \(whereClause) ORDER BY created_at DESC, id DESC
        """) { row in
            moments.append(try decodeMoment(row))
        }
        return moments
    }

    private func insertMoment(
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

    private func trashBackup() throws -> NativeTrashBackup {
        var articles: [NativeTrashedArticle] = []
        try db().query(articleSelect + " WHERE deleted_at IS NOT NULL AND delete_expires_at IS NOT NULL ORDER BY slug") { row in
            guard let deletedAt = row.text(at: 12), let expiresAt = row.text(at: 13) else {
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
        SELECT id, created_at, updated_at, text, text_runs_json, images_json, tags_json, is_favorite, deleted_at, delete_expires_at
        FROM moments
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
        try writeJSON(try allMoments(), to: momentsIndexURL)
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
            wordCount: article.wordCount ?? wordCount(body)
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
        "SELECT slug, title, body, category, excerpt, banner_json, media_json, status, tags_json, updated_at, published_at, word_count, deleted_at, delete_expires_at FROM articles"
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
