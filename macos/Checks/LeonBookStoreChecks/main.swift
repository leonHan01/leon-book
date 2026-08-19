import Foundation
import LeonBook

var failures: [String] = []

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures.append(message) }
}

func fail(_ message: String) {
    failures.append(message)
}

func article(slug: String, title: String, body: String) -> NativeArticle {
    NativeArticle(
        banner: nil,
        body: body,
        category: "Notes",
        excerpt: body,
        media: [],
        slug: slug,
        status: .published,
        tags: [],
        title: title,
        updatedAt: "2026-08-01T00:00:00Z",
        publishedAt: "2026-08-01T00:00:00Z",
        wordCount: 1
    )
}

func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
}

func withWorkspace(_ body: (URL) async throws -> Void) async throws {
    let workspace = FileManager.default.temporaryDirectory
        .appendingPathComponent("leon-book-store-checks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    try await body(workspace)
}

func testPublishedMomentCanBeRestoredFromJSONExportAlone() async throws {
    try await withWorkspace { workspace in
        let source = workspace.appendingPathComponent("source", isDirectory: true)
        let backup = workspace.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let saved = try await LocalBlogStore(rootURL: source).saveMoment(
            text: "午后的一段记录",
            textRuns: [],
            images: []
        )

        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: source.appendingPathComponent("moments", isDirectory: true),
            to: backup.appendingPathComponent("moments", isDirectory: true)
        )

        let moments = try await LocalBlogStore(rootURL: backup).listMoments()
        expect(moments.map(\.id) == [saved.id], "moment JSON export should restore the published moment id")
        expect(moments.first?.text == "午后的一段记录", "moment JSON export should restore the published moment text")
    }
}

func testActivityJSONExportRestoresHeatmapWhenSQLiteIsMissing() async throws {
    try await withWorkspace { workspace in
        let source = workspace.appendingPathComponent("source", isDirectory: true)
        let backup = workspace.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        _ = try await LocalBlogStore(rootURL: source).saveMoment(
            text: "记一次活动",
            textRuns: [],
            images: []
        )

        let eventsURL = source.appendingPathComponent("activity/events.json")
        expect(
            FileManager.default.fileExists(atPath: eventsURL.path),
            "recording activity should write activity/events.json"
        )

        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: source.appendingPathComponent("activity", isDirectory: true),
            to: backup.appendingPathComponent("activity", isDirectory: true)
        )

        let days = try await LocalBlogStore(rootURL: backup).listActivity(
            since: Date().addingTimeInterval(-7 * 24 * 60 * 60)
        )
        expect(days.reduce(0) { $0 + $1.count } == 1, "activity JSON export should restore the heatmap count")
    }
}

func testArticlesListedOnlyInIndexJSONAreImported() async throws {
    try await withWorkspace { workspace in
        let root = workspace.appendingPathComponent("articles-index", isDirectory: true)
        let articlesURL = root.appendingPathComponent("articles", isDirectory: true)
        try FileManager.default.createDirectory(at: articlesURL, withIntermediateDirectories: true)
        try writeJSON(
            [
                article(slug: "morning-note", title: "晨记", body: "今天天气很好"),
                article(slug: "evening-note", title: "夜记", body: "继续写一段"),
            ],
            to: articlesURL.appendingPathComponent("index.json")
        )

        let summaries = try await LocalBlogStore(rootURL: root).listArticles()
        expect(
            Set(summaries.map(\.slug)) == ["morning-note", "evening-note"],
            "articles/index.json should import every listed article"
        )
        let evening = try await LocalBlogStore(rootURL: root).getArticle(slug: "evening-note")
        expect(evening.body == "继续写一段", "imported index article should keep its body")
    }
}

func testAlreadyMigratedWorkspaceBackfillsMissingJSONExports() async throws {
    try await withWorkspace { workspace in
        let root = workspace.appendingPathComponent("stale-export", isDirectory: true)
        let articlesURL = root.appendingPathComponent("articles", isDirectory: true)
        try FileManager.default.createDirectory(at: articlesURL, withIntermediateDirectories: true)
        try writeJSON(
            [
                article(slug: "morning-note", title: "晨记", body: "今天天气很好"),
                article(slug: "evening-note", title: "夜记", body: "继续写一段"),
            ],
            to: articlesURL.appendingPathComponent("index.json")
        )

        _ = try await LocalBlogStore(rootURL: root).listArticles()

        try FileManager.default.removeItem(at: articlesURL.appendingPathComponent("evening-note.json"))
        try writeJSON(
            [article(slug: "morning-note", title: "晨记", body: "今天天气很好")],
            to: articlesURL.appendingPathComponent("index.json")
        )
        let eventsURL = root.appendingPathComponent("activity/events.json")
        if FileManager.default.fileExists(atPath: eventsURL.path) {
            try FileManager.default.removeItem(at: eventsURL)
        }

        _ = try await LocalBlogStore(rootURL: root).listArticles()

        let backup = workspace.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: articlesURL,
            to: backup.appendingPathComponent("articles", isDirectory: true)
        )

        let restored = try await LocalBlogStore(rootURL: backup).listArticles()
        expect(
            Set(restored.map(\.slug)) == ["morning-note", "evening-note"],
            "already-migrated workspaces should rebuild article JSON so a later SQLite loss can restore every article"
        )
    }
}

func testPublishedWordCountCountsChineseCharacters() async throws {
    try await withWorkspace { workspace in
        let root = workspace.appendingPathComponent("word-count", isDirectory: true)
        let articlesURL = root.appendingPathComponent("articles", isDirectory: true)
        try FileManager.default.createDirectory(at: articlesURL, withIntermediateDirectories: true)
        try writeJSON(
            [article(slug: "morning-note", title: "晨记", body: "今天天气很好")],
            to: articlesURL.appendingPathComponent("index.json")
        )

        let summaries = try await LocalBlogStore(rootURL: root).listArticles()
        expect(summaries.first?.wordCount == 6, "Chinese article word count should be character count, not whitespace tokens")
    }
}

func savePayload(
    slug: String,
    title: String,
    body: String,
    media: [NativeMedia] = [],
    expectedUpdatedAt: String? = nil
) -> NativeSaveArticle {
    NativeSaveArticle(
        banner: nil,
        body: body,
        category: "Notes",
        excerpt: body,
        media: media,
        slug: slug,
        status: .published,
        tags: [],
        title: title,
        expectedUpdatedAt: expectedUpdatedAt
    )
}

func seedBackup(at root: URL) async throws -> (NativeArticle, NativeMoment) {
    let store = LocalBlogStore(rootURL: root)
    let savedArticle = try await store.saveArticle(
        savePayload(slug: "backup-note", title: "备份文章", body: "数据库中的正确正文")
    )
    let savedMoment = try await store.saveMoment(text: "数据库中的正确微博", textRuns: [], images: [])
    return (savedArticle, savedMoment)
}

func testDecodableButStaleJSONExportsAreRebuilt() async throws {
    try await withWorkspace { workspace in
        let root = workspace.appendingPathComponent("stale-json-export", isDirectory: true)
        let saved = try await seedBackup(at: root)

        try writeJSON(
            article(slug: saved.0.slug, title: saved.0.title, body: "过期正文"),
            to: root.appendingPathComponent("articles/\(saved.0.slug).json")
        )
        try writeJSON([NativeMoment](), to: root.appendingPathComponent("moments/index.json"))
        try writeJSON([[String: String]](), to: root.appendingPathComponent("activity/events.json"))

        let restored = LocalBlogStore(rootURL: root)
        _ = try await restored.listArticles()

        let articleData = try Data(contentsOf: root.appendingPathComponent("articles/\(saved.0.slug).json"))
        let exportedArticle = try JSONDecoder().decode(NativeArticle.self, from: articleData)
        expect(exportedArticle.body == saved.0.body, "stale article JSON should be rebuilt from SQLite")

        let momentData = try Data(contentsOf: root.appendingPathComponent("moments/index.json"))
        let exportedMoments = try JSONDecoder().decode([NativeMoment].self, from: momentData)
        expect(exportedMoments == [saved.1], "stale moment JSON should be rebuilt from SQLite")

        let eventData = try Data(contentsOf: root.appendingPathComponent("activity/events.json"))
        let exportedEvents = try JSONDecoder().decode([[String: String]].self, from: eventData)
        expect(!exportedEvents.isEmpty, "stale activity JSON should be rebuilt from SQLite")
    }
}

func testDefaultDataDirectoryDoesNotProbeT7() {
    let configured = ProcessInfo.processInfo.environment["LEON_BOOK_WORKDIR"]?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard configured.isEmpty else { return }
    expect(
        LocalBlogStore.defaultRootURL.path != "/Volumes/T7Shield/myblog",
        "default data directory should not silently use the T7 probe path"
    )
    expect(
        LocalBlogStore.defaultRootURL.path.contains("Application Support/leon-book"),
        "default data directory should be Application Support"
    )
}

func testAllocateSlugReservesInboxAndMomentsAndAvoidsCollisions() async throws {
    try await withWorkspace { workspace in
        let store = LocalBlogStore(rootURL: workspace)
        let momentsSlug = try await store.allocateSlug(from: "moments")
        expect(momentsSlug != "moments", "moments must stay reserved for moment images")
        let inboxSlug = try await store.allocateSlug(from: "Inbox")
        expect(inboxSlug != "inbox", "inbox must stay reserved for unsaved uploads")

        let first = try await store.saveArticle(savePayload(slug: "same-title", title: "Same Title", body: "第一篇"))
        let secondSlug = try await store.allocateSlug(from: "Same Title")
        expect(secondSlug != first.slug, "a second article with the same title should get a new slug")
        expect(secondSlug.hasPrefix("same-title"), "derived slugs should keep the title stem")
    }
}

func testReservedSlugCannotBeSavedAndInboxMediaMovesOnFirstSave() async throws {
    try await withWorkspace { workspace in
        let store = LocalBlogStore(rootURL: workspace)
        var reservedFailed = false
        do {
            _ = try await store.saveArticle(savePayload(slug: "moments", title: "moments", body: "不能占用动态目录"))
        } catch {
            reservedFailed = true
        }
        expect(reservedFailed, "saving an article as moments should fail")

        let inboxDir = workspace.appendingPathComponent("media/inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        let filename = "paste-one.png"
        try Data("png".utf8).write(to: inboxDir.appendingPathComponent(filename))
        let inboxURL = "/media/inbox/\(filename)"
        let saved = try await store.saveArticle(
            savePayload(
                slug: "morning-note",
                title: "晨记",
                body: "见图 \(inboxURL)",
                media: [NativeMedia(kind: "image", name: "paste-one.png", size: 3, url: inboxURL)]
            )
        )
        expect(saved.media.first?.url == "/media/morning-note/\(filename)", "first save should move inbox media onto the article slug")
        expect(saved.body.contains("/media/morning-note/\(filename)"), "article body should rewrite inbox media URLs")
        expect(
            FileManager.default.fileExists(atPath: workspace.appendingPathComponent("media/morning-note/\(filename)").path),
            "inbox file should be moved into media/{slug}"
        )
        expect(
            !FileManager.default.fileExists(atPath: inboxDir.appendingPathComponent(filename).path),
            "original inbox file should no longer exist after relocate"
        )
        expect(saved.updatedAt.contains("."), "saved updatedAt should include fractional seconds")
    }
}

func testMediaURLRejectsInvalidPaths() async {
    let store = LocalBlogStore(rootURL: FileManager.default.temporaryDirectory)
    let valid = await store.mediaURL(for: "/media/inbox/photo.png")
    let rejectedAbsolute = await store.mediaURL(for: "/etc/passwd")
    let rejectedEscape = await store.mediaURL(for: "/media/../secret")
    expect(valid?.lastPathComponent == "photo.png", "valid media URLs should resolve under media/")
    expect(rejectedAbsolute == nil, "paths outside /media should be rejected")
    expect(rejectedEscape == nil, "path escape attempts should be rejected")
}

func testActivityIsBucketedInLocalTimeZone() async throws {
    try await withWorkspace { workspace in
        _ = try await LocalBlogStore(rootURL: workspace).saveMoment(text: "本地日期", textRuns: [], images: [])
        let days = try await LocalBlogStore(rootURL: workspace).listActivity(
            since: Date().addingTimeInterval(-24 * 60 * 60)
        )
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: Date())
        let today = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        expect(
            days.contains { $0.date == today && $0.count >= 1 },
            "activity should land on the local calendar day"
        )
    }
}

func testRootContentDatabaseMovesIntoLeonWorkspace() async throws {
    try await withWorkspace { workspace in
        let rootDB = workspace.appendingPathComponent("leon-book.sqlite")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            rootDB.path,
            "CREATE TABLE articles(slug TEXT PRIMARY KEY NOT NULL); INSERT INTO articles(slug) VALUES('legacy-note');",
        ]
        try process.run()
        process.waitUntilExit()
        expect(process.terminationStatus == 0, "should create a legacy content sqlite file")

        _ = try await UserWorkspaceStore(rootURL: workspace).prepare()

        let moved = workspace.appendingPathComponent("workspaces/leon/leon-book.sqlite")
        expect(FileManager.default.fileExists(atPath: moved.path), "content sqlite should move into workspaces/leon")

        let inspect = Process()
        inspect.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        inspect.arguments = [workspace.appendingPathComponent("leon-book.sqlite").path, "SELECT name FROM sqlite_master WHERE type='table' AND name='articles';"]
        let pipe = Pipe()
        inspect.standardOutput = pipe
        try inspect.run()
        inspect.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        expect(!output.contains("articles"), "root sqlite should no longer be a content database")
    }
}

func testTrashedArticleJSONIsNotImportedAsLive() async throws {
    try await withWorkspace { workspace in
        let store = LocalBlogStore(rootURL: workspace)
        let kept = try await store.saveArticle(savePayload(slug: "kept-note", title: "保留", body: "还在"))
        let trashed = try await store.saveArticle(savePayload(slug: "trashed-note", title: "丢掉", body: "进回收站"))
        try await store.deleteArticle(slug: trashed.slug, expectedUpdatedAt: trashed.updatedAt)

        expect(
            !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("articles/trashed-note.json").path),
            "soft-deleted articles should not keep a live JSON export"
        )

        let backup = workspace.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: workspace.appendingPathComponent("articles", isDirectory: true),
            to: backup.appendingPathComponent("articles", isDirectory: true)
        )

        let restored = try await LocalBlogStore(rootURL: backup).listArticles()
        expect(Set(restored.map(\.slug)) == [kept.slug], "JSON restore should not resurrect trashed articles")
    }
}

func testFractionalISO8601TimestampsParse() {
    expect(
        NativeTimestamp.date(from: "2026-08-02T17:06:49.910Z") != nil,
        "timestamps with fractional seconds should parse"
    )
    expect(
        NativeTimestamp.date(from: "2026-08-02T17:06:49Z") != nil,
        "timestamps without fractional seconds should still parse"
    )
}

func testCorruptArticleFileDoesNotFinalizeMigrationOrDropIndexRecords() async throws {
    try await withWorkspace { workspace in
        let root = workspace.appendingPathComponent("partial-import", isDirectory: true)
        let articlesURL = root.appendingPathComponent("articles", isDirectory: true)
        try FileManager.default.createDirectory(at: articlesURL, withIntermediateDirectories: true)
        try writeJSON(
            [
                article(slug: "kept-note", title: "保留", body: "来自 index 的甲"),
                article(slug: "index-only", title: "仅索引", body: "来自 index 的乙"),
            ],
            to: articlesURL.appendingPathComponent("index.json")
        )
        try Data("{not-json".utf8).write(to: articlesURL.appendingPathComponent("kept-note.json"))

        let store = LocalBlogStore(rootURL: root)
        var firstImportFailed = false
        do {
            _ = try await store.listArticles()
        } catch {
            firstImportFailed = true
        }
        expect(firstImportFailed, "corrupt article JSON should fail the first import")

        try FileManager.default.removeItem(at: articlesURL.appendingPathComponent("kept-note.json"))

        let summaries = try await store.listArticles()
        expect(
            Set(summaries.map(\.slug)) == ["kept-note", "index-only"],
            "retry after removing the corrupt file should import remaining articles including index-only records"
        )
        let indexOnly = try await store.getArticle(slug: "index-only")
        expect(indexOnly.body == "来自 index 的乙", "index-only article body should survive a retried import")
    }
}

func testLegacyArticleSlugCannotEscapeWorkspace() async throws {
    try await withWorkspace { workspace in
        let root = workspace.appendingPathComponent("unsafe-slug", isDirectory: true)
        let articlesURL = root.appendingPathComponent("articles", isDirectory: true)
        try FileManager.default.createDirectory(at: articlesURL, withIntermediateDirectories: true)
        try writeJSON(
            [article(slug: "../../escaped", title: "不安全", body: "不应导入")],
            to: articlesURL.appendingPathComponent("index.json")
        )

        var rejected = false
        do {
            _ = try await LocalBlogStore(rootURL: root).listArticles()
        } catch {
            rejected = true
        }

        expect(rejected, "legacy articles with path traversal slugs should be rejected")
        expect(
            !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("escaped.json").path),
            "unsafe legacy slugs must not write outside the workspace"
        )
    }
}

func testInvalidLegacyUserIDIsNotImported() async throws {
    try await withWorkspace { workspace in
        try writeJSON(
            [NativeUser(id: "../invalid", name: "不安全用户", createdAt: "2026-08-01T00:00:00Z")],
            to: workspace.appendingPathComponent("users.json")
        )

        let store = UserWorkspaceStore(rootURL: workspace)
        var rejected = false
        do {
            _ = try await store.prepare()
        } catch {
            rejected = true
        }

        expect(rejected, "legacy users with invalid workspace IDs should be rejected")
    }
}

let checks: [(String, () async throws -> Void)] = [
    ("published moment can be restored from JSON export", testPublishedMomentCanBeRestoredFromJSONExportAlone),
    ("activity JSON export restores the heatmap", testActivityJSONExportRestoresHeatmapWhenSQLiteIsMissing),
    ("articles listed only in index.json are imported", testArticlesListedOnlyInIndexJSONAreImported),
    ("corrupt article file does not finalize migration", testCorruptArticleFileDoesNotFinalizeMigrationOrDropIndexRecords),
    ("already-migrated workspace backfills missing JSON exports", testAlreadyMigratedWorkspaceBackfillsMissingJSONExports),
    ("decodable but stale JSON exports are rebuilt", testDecodableButStaleJSONExportsAreRebuilt),
    ("published word count counts Chinese characters", testPublishedWordCountCountsChineseCharacters),
    ("fractional ISO8601 timestamps parse", { testFractionalISO8601TimestampsParse() }),
    ("default data directory does not probe T7", { testDefaultDataDirectoryDoesNotProbeT7() }),
    ("allocateSlug reserves inbox/moments and avoids collisions", testAllocateSlugReservesInboxAndMomentsAndAvoidsCollisions),
    ("reserved slug is rejected and inbox media moves on first save", testReservedSlugCannotBeSavedAndInboxMediaMovesOnFirstSave),
    ("mediaURL rejects invalid paths", { await testMediaURLRejectsInvalidPaths() }),
    ("activity is bucketed in the local time zone", testActivityIsBucketedInLocalTimeZone),
    ("root content database moves into leon workspace", testRootContentDatabaseMovesIntoLeonWorkspace),
    ("trashed article JSON is not imported as live", testTrashedArticleJSONIsNotImportedAsLive),
    ("legacy article slug cannot escape workspace", testLegacyArticleSlugCannotEscapeWorkspace),
    ("invalid legacy user ID is not imported", testInvalidLegacyUserIDIsNotImported),
]

for (name, check) in checks {
    do {
        try await check()
    } catch {
        fail("\(name) threw \(error.localizedDescription)")
    }
}

if failures.isEmpty {
    print("LeonBook store checks passed")
} else {
    for failure in failures { fputs("Check failed: \(failure)\n", stderr) }
    exit(1)
}
