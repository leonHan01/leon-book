import Foundation

/// Local SQLite store for structured data, with Markdown/JSON exports and file-based media.
actor LocalBlogStore {
    static let legacyRootURL = URL(fileURLWithPath: "/Volumes/T7Shield/myblog", isDirectory: true)

    static var applicationSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("leon-book", isDirectory: true)
    }

    static var defaultRootURL: URL {
        let fileManager = FileManager.default
        if let configured = ProcessInfo.processInfo.environment["LEON_BOOK_WORKDIR"],
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        if fileManager.fileExists(atPath: legacyRootURL.path) { return legacyRootURL }
        return applicationSupportURL
    }

    let rootURL: URL
    private var database: SQLiteDatabase?

    private var databaseURL: URL { rootURL.appendingPathComponent("leon-book.sqlite") }
    private var articlesURL: URL { rootURL.appendingPathComponent("articles", isDirectory: true) }
    private var draftsURL: URL { rootURL.appendingPathComponent("drafts", isDirectory: true) }
    private var mediaURL: URL { rootURL.appendingPathComponent("media", isDirectory: true) }
    private var momentsURL: URL { rootURL.appendingPathComponent("moments", isDirectory: true) }
    private var momentsIndexURL: URL { momentsURL.appendingPathComponent("index.json") }
    private var activityURL: URL { rootURL.appendingPathComponent("activity", isDirectory: true) }

    init(rootURL: URL = LocalBlogStore.defaultRootURL) {
        self.rootURL = rootURL.standardizedFileURL
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

            if database == nil {
                let nextDatabase = try SQLiteDatabase(url: databaseURL)
                try createSchema(in: nextDatabase)
                database = nextDatabase
                try migrateLegacyDataIfNeeded()
            }
        } catch let error as NativeStoreError {
            throw error
        } catch {
            throw NativeStoreError.fileSystem(error.localizedDescription)
        }
    }

    func listArticles(includeDrafts: Bool = true) throws -> [NativeArticleSummary] {
        try prepare()
        let sql = """
        SELECT slug, title, body, category, excerpt, banner_json, media_json, status,
               tags_json, updated_at, published_at, word_count
        FROM articles
        \(includeDrafts ? "" : "WHERE status = 'published'")
        ORDER BY updated_at DESC
        """
        var articles: [NativeArticleSummary] = []
        try db().query(sql) { row in
            articles.append(summary(for: try decodeArticle(row)))
        }
        return articles
    }

    func listMoments() throws -> [NativeMoment] {
        try prepare()
        return try allMoments().sorted { left, right in
            left.createdAt == right.createdAt ? left.id > right.id : left.createdAt > right.createdAt
        }
    }

    func saveMoment(
        text: String,
        textRuns: [NativeMomentTextRun],
        images: [NativeMedia]
    ) throws -> NativeMoment {
        try prepare()
        let normalizedText = normalizedMomentText(text, textRuns: textRuns)
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
            text: normalizedText.text,
            textRuns: normalizedText.runs,
            updatedAt: createdAt
        )

        try insertMoment(saved, into: db())
        try recordActivity(type: "moment_published", at: activityDate(from: createdAt) ?? Date())
        try rebuildMomentsIndex()
        return saved
    }

    func deleteMoment(id: String) throws {
        try prepare()
        let safeID = try requireSafeSegment(id, label: "微博 ID")
        guard let deletedMoment = try moment(withID: safeID) else { throw NativeStoreError.notFound }

        try db().execute("DELETE FROM moments WHERE id = ?", values: [.text(safeID)])
        try rebuildMomentsIndex()

        let referencedImageURLs = Set(try allMoments().flatMap { $0.images.map(\.url) })
        let momentsMediaDirectory = mediaURL.appendingPathComponent("moments", isDirectory: true).standardizedFileURL
        for image in deletedMoment.images where !referencedImageURLs.contains(image.url) {
            let imageURL = mediaURL(for: image.url).standardizedFileURL
            guard imageURL.deletingLastPathComponent().standardizedFileURL == momentsMediaDirectory else { continue }
            try? FileManager.default.removeItem(at: imageURL)
        }
    }

    func listActivity(since: Date) throws -> [NativeActivityDay] {
        try prepare()
        let calendar = utcCalendar()
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

    func getArticle(slug: String) throws -> NativeArticle {
        try prepare()
        let safeSlug = try requireSafeSegment(slug, label: "文章 slug")
        guard let article = try storedArticle(withSlug: safeSlug) else { throw NativeStoreError.notFound }
        return article
    }

    func saveArticle(_ article: NativeSaveArticle) throws -> NativeArticle {
        try prepare()
        let slug = try requireSafeSegment(article.slug, label: "文章 slug")
        let previous = try storedArticle(withSlug: slug)

        if let expected = article.expectedUpdatedAt {
            guard previous?.updatedAt == expected else { throw NativeStoreError.conflict }
        } else if previous != nil {
            throw NativeStoreError.conflict
        }

        let updatedAt = nextTimestamp(after: previous?.updatedAt)
        let publishedAt: String?
        if article.status == .published {
            publishedAt = previous?.publishedAt ?? updatedAt
        } else {
            publishedAt = previous?.publishedAt
        }

        let normalizedBody = normalizeBody(article.body)
        let normalizedMedia = article.media.map(normalizeMedia)
        let saved = NativeArticle(
            banner: article.banner.map(normalizeBanner),
            body: normalizedBody,
            category: article.category.isEmpty ? "Uncategorized" : article.category,
            excerpt: article.excerpt,
            media: normalizedMedia,
            slug: slug,
            status: article.status,
            tags: Array(Array(Set(article.tags.filter { !$0.isEmpty })).prefix(12)),
            title: article.title,
            updatedAt: updatedAt,
            publishedAt: publishedAt,
            wordCount: wordCount(normalizedBody)
        )

        try insertArticle(saved, into: db())
        try writeJSON(saved, to: articlesURL.appendingPathComponent("\(slug).json"))
        try writeJSON(saved, to: draftsURL.appendingPathComponent("\(slug).json"))
        try writeMarkdown(saved, to: articlesURL.appendingPathComponent("\(slug).md"))
        try rebuildIndex()

        let activityType = saved.status == .published && previous?.status != .published
            ? "article_published"
            : article.expectedUpdatedAt == nil
                ? nil
                : "article_edited"
        if let activityType {
            try recordActivity(type: activityType, at: activityDate(from: updatedAt) ?? Date())
        }
        return saved
    }

    func deleteArticle(slug: String, expectedUpdatedAt: String) throws {
        let article = try getArticle(slug: slug)
        guard article.updatedAt == expectedUpdatedAt else { throw NativeStoreError.conflict }
        let safeSlug = try requireSafeSegment(slug, label: "文章 slug")
        try db().execute("DELETE FROM articles WHERE slug = ?", values: [.text(safeSlug)])

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: articlesURL.appendingPathComponent("\(safeSlug).json"))
        try? fileManager.removeItem(at: articlesURL.appendingPathComponent("\(safeSlug).md"))
        try? fileManager.removeItem(at: draftsURL.appendingPathComponent("\(safeSlug).json"))
        try? fileManager.removeItem(at: mediaURL.appendingPathComponent(safeSlug, isDirectory: true))
        try rebuildIndex()
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

    func mediaURL(for storedPath: String) -> URL {
        let normalized = normalizeMediaURL(storedPath)
        guard let range = normalized.range(of: "/media/") else { return rootURL }
        let parts = normalized[range.upperBound...].split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2,
              let slug = try? requireSafeSegment(String(parts[0]), label: "媒体目录"),
              let filename = try? requireSafeSegment(String(parts[1]), label: "媒体文件") else {
            return rootURL
        }
        return mediaURL.appendingPathComponent(slug).appendingPathComponent(filename)
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
            word_count INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS articles_updated_at_idx ON articles(updated_at DESC);
        CREATE TABLE IF NOT EXISTS moments (
            id TEXT PRIMARY KEY NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            text TEXT NOT NULL,
            text_runs_json TEXT NOT NULL,
            images_json TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS moments_created_at_idx ON moments(created_at DESC);
        CREATE TABLE IF NOT EXISTS activity_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            type TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS activity_created_at_idx ON activity_events(created_at);
        """)
    }

    private func migrateLegacyDataIfNeeded() throws {
        let database = try db()
        guard try database.text("SELECT value FROM metadata WHERE key = 'legacy_migration_v1'") != "done" else { return }

        if try database.integer("SELECT COUNT(*) FROM articles") == 0 {
            let files = try FileManager.default.contentsOfDirectory(
                at: articlesURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for file in files where file.pathExtension.lowercased() == "json" && file.lastPathComponent != "index.json" {
                try insertArticle(readArticle(at: file), into: database)
            }
        }

        if try database.integer("SELECT COUNT(*) FROM moments") == 0 {
            let files = try FileManager.default.contentsOfDirectory(
                at: momentsURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for file in files where file.pathExtension.lowercased() == "json" && file.lastPathComponent != "index.json" {
                try insertMoment(readMoment(at: file), into: database)
            }
        }

        if try database.integer("SELECT COUNT(*) FROM activity_events") == 0 {
            let legacyURL = activityURL.appendingPathComponent("events.json")
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                let events = try JSONDecoder().decode([NativeActivityEvent].self, from: Data(contentsOf: legacyURL))
                for event in events { try insertActivity(event, into: database) }
            }
        }

        try database.execute("INSERT OR REPLACE INTO metadata(key, value) VALUES('legacy_migration_v1', 'done')")
    }

    private func storedArticle(withSlug slug: String) throws -> NativeArticle? {
        var result: NativeArticle?
        try db().query(articleSelect + " WHERE slug = ?", values: [.text(slug)]) { row in
            result = try decodeArticle(row)
        }
        return result
    }

    private func allArticles() throws -> [NativeArticle] {
        var articles: [NativeArticle] = []
        try db().query(articleSelect + " ORDER BY updated_at DESC") { row in
            articles.append(try decodeArticle(row))
        }
        return articles
    }

    private func insertArticle(_ article: NativeArticle, into database: SQLiteDatabase) throws {
        let bannerJSON: SQLiteValue
        if let banner = article.banner {
            bannerJSON = .text(try jsonString(banner))
        } else {
            bannerJSON = .null
        }
        try database.execute("""
        INSERT OR REPLACE INTO articles(
            slug, title, body, category, excerpt, banner_json, media_json, status,
            tags_json, updated_at, published_at, word_count
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            wordCount: row.integer(at: 11) ?? wordCount(body)
        )
    }

    private func moment(withID id: String) throws -> NativeMoment? {
        var result: NativeMoment?
        try db().query(
            "SELECT id, created_at, updated_at, text, text_runs_json, images_json FROM moments WHERE id = ?",
            values: [.text(id)]
        ) { row in
            result = try decodeMoment(row)
        }
        return result
    }

    private func allMoments() throws -> [NativeMoment] {
        var moments: [NativeMoment] = []
        try db().query("""
        SELECT id, created_at, updated_at, text, text_runs_json, images_json
        FROM moments ORDER BY created_at DESC, id DESC
        """) { row in
            moments.append(try decodeMoment(row))
        }
        return moments
    }

    private func insertMoment(_ moment: NativeMoment, into database: SQLiteDatabase) throws {
        try database.execute("""
        INSERT OR REPLACE INTO moments(id, created_at, updated_at, text, text_runs_json, images_json)
        VALUES (?, ?, ?, ?, ?, ?)
        """, values: [
            .text(moment.id),
            .text(moment.createdAt),
            .text(moment.updatedAt),
            .text(moment.text),
            .text(try jsonString(moment.textRuns)),
            .text(try jsonString(moment.images)),
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
        return NativeMoment(
            createdAt: createdAt,
            id: id,
            images: try decode(imagesJSON),
            text: text,
            textRuns: try decode(textRunsJSON),
            updatedAt: updatedAt
        )
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

    private func recordActivity(type: String, at date: Date) throws {
        let timestamp = ISO8601DateFormatter().string(from: date)
        try db().execute(
            "DELETE FROM activity_events WHERE created_at < ?",
            values: [.text(ISO8601DateFormatter().string(from: Date().addingTimeInterval(-366 * 24 * 60 * 60)))]
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
        body.split { $0.isWhitespace || $0.isNewline }.count
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
        let standardFormatter = ISO8601DateFormatter()
        if let date = standardFormatter.date(from: timestamp) { return date }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions.insert(.withFractionalSeconds)
        return fractionalFormatter.date(from: timestamp)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    private func activityDateKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func nextTimestamp(after previous: String?) -> String {
        let now = Date()
        if let previous, let date = ISO8601DateFormatter().date(from: previous), date >= now {
            return ISO8601DateFormatter().string(from: date.addingTimeInterval(0.001))
        }
        return ISO8601DateFormatter().string(from: now)
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
        "SELECT slug, title, body, category, excerpt, banner_json, media_json, status, tags_json, updated_at, published_at, word_count FROM articles"
    }
}

private struct NativeActivityEvent: Codable {
    let type: String
    let createdAt: String
}
