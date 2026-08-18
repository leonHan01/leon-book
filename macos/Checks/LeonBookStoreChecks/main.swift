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
        try writeJSON(
            article(slug: "kept-note", title: "保留", body: "来自文件的甲"),
            to: articlesURL.appendingPathComponent("kept-note.json")
        )
        try Data("{not-json".utf8).write(to: articlesURL.appendingPathComponent("broken.json"))

        let store = LocalBlogStore(rootURL: root)
        var firstImportFailed = false
        do {
            _ = try await store.listArticles()
        } catch {
            firstImportFailed = true
        }
        expect(firstImportFailed, "corrupt article JSON should fail the first import")

        try FileManager.default.removeItem(at: articlesURL.appendingPathComponent("broken.json"))

        let summaries = try await store.listArticles()
        expect(
            Set(summaries.map(\.slug)) == ["kept-note", "index-only"],
            "retry after removing the corrupt file should import remaining articles including index-only records"
        )
        let indexOnly = try await store.getArticle(slug: "index-only")
        expect(indexOnly.body == "来自 index 的乙", "index-only article body should survive a retried import")
    }
}

let checks: [(String, () async throws -> Void)] = [
    ("published moment can be restored from JSON export", testPublishedMomentCanBeRestoredFromJSONExportAlone),
    ("activity JSON export restores the heatmap", testActivityJSONExportRestoresHeatmapWhenSQLiteIsMissing),
    ("articles listed only in index.json are imported", testArticlesListedOnlyInIndexJSONAreImported),
    ("corrupt article file does not finalize migration", testCorruptArticleFileDoesNotFinalizeMigrationOrDropIndexRecords),
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
