import Foundation

/// Native on-disk store for leon-book JSON, Markdown, and media files.
actor LocalBlogStore {
    static let legacyRootURL = URL(fileURLWithPath: "/Volumes/T7Shield/myblog", isDirectory: true)

    static var legacyApplicationSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notebook 36", isDirectory: true)
    }

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
        if let configured = ProcessInfo.processInfo.environment["NOTEBOOK36_WORKDIR"],
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        if fileManager.fileExists(atPath: legacyRootURL.path) { return legacyRootURL }
        if fileManager.fileExists(atPath: legacyApplicationSupportURL.path) {
            return legacyApplicationSupportURL
        }
        return applicationSupportURL
    }

    let rootURL: URL

    private var articlesURL: URL { rootURL.appendingPathComponent("articles", isDirectory: true) }
    private var draftsURL: URL { rootURL.appendingPathComponent("drafts", isDirectory: true) }
    private var mediaURL: URL { rootURL.appendingPathComponent("media", isDirectory: true) }
    private var momentsURL: URL { rootURL.appendingPathComponent("moments", isDirectory: true) }
    private var momentsIndexURL: URL { momentsURL.appendingPathComponent("index.json") }
    private var activityURL: URL { rootURL.appendingPathComponent("activity", isDirectory: true) }
    private var activityEventsURL: URL { activityURL.appendingPathComponent("events.json") }

    init(rootURL: URL = LocalBlogStore.defaultRootURL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    func prepare() throws {
        do {
            try FileManager.default.createDirectory(at: articlesURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: draftsURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: momentsURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: activityURL, withIntermediateDirectories: true)
        } catch {
            throw NativeStoreError.fileSystem(error.localizedDescription)
        }
    }

    func listArticles(includeDrafts: Bool = true) throws -> [NativeArticleSummary] {
        try prepare()
        let files = try FileManager.default.contentsOfDirectory(
            at: articlesURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return try files
            .filter { $0.pathExtension.lowercased() == "json" && $0.lastPathComponent != "index.json" && !$0.lastPathComponent.hasPrefix(".") }
            .map { try readArticle(at: $0) }
            .filter { includeDrafts || $0.status == .published }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(summary(for:))
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

        let latestCreatedAt = try allMoments()
            .map(\.createdAt)
            .max()
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

        try writeJSON(saved, to: momentsURL.appendingPathComponent("\(id).json"))
        try rebuildMomentsIndex(with: saved)
        try recordActivity(type: "moment_published", at: activityDate(from: createdAt) ?? Date())
        return saved
    }

    func deleteMoment(id: String) throws {
        try prepare()
        let safeID = try requireSafeSegment(id, label: "微博 ID")
        let momentURL = momentsURL.appendingPathComponent("\(safeID).json")
        guard FileManager.default.fileExists(atPath: momentURL.path) else { throw NativeStoreError.notFound }

        let deletedMoment = try readMoment(at: momentURL)
        let fileManager = FileManager.default
        try fileManager.removeItem(at: momentURL)
        try rebuildMomentsIndex()

        let referencedImageURLs = Set(try allMoments().flatMap { $0.images.map(\.url) })
        let momentsMediaDirectory = mediaURL.appendingPathComponent("moments", isDirectory: true).standardizedFileURL
        for image in deletedMoment.images where !referencedImageURLs.contains(image.url) {
            let imageURL = mediaURL(for: image.url).standardizedFileURL
            guard imageURL.deletingLastPathComponent().standardizedFileURL == momentsMediaDirectory else { continue }
            try? fileManager.removeItem(at: imageURL)
        }
    }

    func listActivity(since: Date) throws -> [NativeActivityDay] {
        let calendar = utcCalendar()
        let firstDay = calendar.startOfDay(for: since)
        var counts: [String: Int] = [:]

        for event in try readActivityEvents() {
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
        let articleURL = articlesURL.appendingPathComponent("\(safeSlug).json")
        guard FileManager.default.fileExists(atPath: articleURL.path) else { throw NativeStoreError.notFound }
        return try readArticle(at: articleURL)
    }

    func saveArticle(_ article: NativeSaveArticle) throws -> NativeArticle {
        try prepare()
        let slug = try requireSafeSegment(article.slug, label: "文章 slug")
        let articleURL = articlesURL.appendingPathComponent("\(slug).json")
        let previous = FileManager.default.fileExists(atPath: articleURL.path) ? try readArticle(at: articleURL) : nil

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

        try writeJSON(saved, to: articleURL)
        try writeJSON(saved, to: draftsURL.appendingPathComponent("\(slug).json"))
        try writeMarkdown(saved, to: articlesURL.appendingPathComponent("\(slug).md"))
        try rebuildIndex(with: saved)
        let activityType = saved.status == .published && previous?.status != .published
            ? "article_published"
            : article.expectedUpdatedAt == nil
                ? nil
                : "article_edited"
        if let activityType { try recordActivity(type: activityType, at: activityDate(from: updatedAt) ?? Date()) }
        return saved
    }

    func deleteArticle(slug: String, expectedUpdatedAt: String) throws {
        let article = try getArticle(slug: slug)
        guard article.updatedAt == expectedUpdatedAt else { throw NativeStoreError.conflict }
        let safeSlug = try requireSafeSegment(slug, label: "文章 slug")
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

    private func readArticle(at url: URL) throws -> NativeArticle {
        do {
            let data = try Data(contentsOf: url)
            return normalize(try JSONDecoder().decode(NativeArticle.self, from: data))
        } catch let error as NativeStoreError {
            throw error
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

    private func allArticles() throws -> [NativeArticle] {
        let files = try FileManager.default.contentsOfDirectory(at: articlesURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return try files
            .filter { $0.pathExtension.lowercased() == "json" && $0.lastPathComponent != "index.json" && !$0.lastPathComponent.hasPrefix(".") }
            .map { try readArticle(at: $0) }
    }

    private func allMoments() throws -> [NativeMoment] {
        let files = try FileManager.default.contentsOfDirectory(at: momentsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return try files
            .filter { $0.pathExtension.lowercased() == "json" && $0.lastPathComponent != "index.json" && !$0.lastPathComponent.hasPrefix(".") }
            .map { try readMoment(at: $0) }
    }

    private func rebuildIndex(with saved: NativeArticle? = nil) throws {
        var articles = try allArticles().filter { $0.slug != saved?.slug }
        if let saved { articles.append(saved) }
        articles.sort { $0.updatedAt > $1.updatedAt }
        try writeJSON(articles, to: articlesURL.appendingPathComponent("index.json"))
    }

    private func rebuildMomentsIndex(with saved: NativeMoment? = nil) throws {
        var moments = try allMoments().filter { $0.id != saved?.id }
        if let saved { moments.append(saved) }
        moments.sort { left, right in
            left.createdAt == right.createdAt ? left.id > right.id : left.createdAt > right.createdAt
        }
        try writeJSON(moments, to: momentsIndexURL)
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

        guard !normalizedText.isEmpty,
              textRuns.map(\.text).joined() == text else {
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

    private func readActivityEvents() throws -> [NativeActivityEvent] {
        guard FileManager.default.fileExists(atPath: activityEventsURL.path) else { return [] }
        do {
            return try JSONDecoder().decode([NativeActivityEvent].self, from: Data(contentsOf: activityEventsURL))
        } catch {
            throw NativeStoreError.fileSystem("无法读取 \(activityEventsURL.lastPathComponent)：\(error.localizedDescription)")
        }
    }

    private func recordActivity(type: String, at date: Date) throws {
        let cutoff = Date().addingTimeInterval(-366 * 24 * 60 * 60)
        let timestamp = ISO8601DateFormatter().string(from: date)
        let events = (try readActivityEvents() + [NativeActivityEvent(type: type, createdAt: timestamp)])
            .filter { event in
                guard let createdAt = activityDate(from: event.createdAt) else { return false }
                return createdAt >= cutoff
            }
            .suffix(10_000)
        try writeJSON(Array(events), to: activityEventsURL)
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
}

private struct NativeActivityEvent: Codable {
    let type: String
    let createdAt: String
}
