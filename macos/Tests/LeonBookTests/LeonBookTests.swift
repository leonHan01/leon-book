import Darwin
import Foundation
import LeonBook

private var failures: [String] = []

private func recordFailure(_ message: String) {
    failures.append(message)
}

private func XCTAssertTrue(_ condition: Bool, _ message: String = "") {
    if !condition { recordFailure(message.isEmpty ? "expected condition to be true" : message) }
}

private func XCTAssertFalse(_ condition: Bool, _ message: String = "") {
    if condition { recordFailure(message.isEmpty ? "expected condition to be false" : message) }
}

private func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "") {
    if lhs != rhs {
        recordFailure(message.isEmpty ? "expected \(rhs), got \(lhs)" : message)
    }
}

private func XCTAssertEqual(_ lhs: Double, _ rhs: Double, accuracy: Double, _ message: String = "") {
    if abs(lhs - rhs) > accuracy {
        recordFailure(message.isEmpty ? "expected \(rhs) ± \(accuracy), got \(lhs)" : message)
    }
}

private func XCTAssertNotNil<T>(_ value: T?, _ message: String = "") {
    if value == nil { recordFailure(message.isEmpty ? "expected a non-nil value" : message) }
}

private func XCTAssertNil<T>(_ value: T?, _ message: String = "") {
    if value != nil { recordFailure(message.isEmpty ? "expected nil, got \(String(describing: value))" : message) }
}

private func XCTFail(_ message: String) {
    recordFailure(message)
}

final class NativeModelsTests {
    func testWritingMetricsAndTimestampRoundTrip() {
        XCTAssertEqual(NativeWritingMetrics.characterCount(of: "  hello\n\n"), 5)
        XCTAssertEqual(NativeWritingMetrics.characterCount(of: " 你好 "), 2)

        let date = Date(timeIntervalSince1970: 1_754_000_123.456)
        let timestamp = NativeTimestamp.string(from: date)
        XCTAssertEqual(NativeTimestamp.date(from: timestamp)?.timeIntervalSince1970 ?? 0, date.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNotNil(NativeTimestamp.date(from: "2026-08-22T12:00:00Z"))
        XCTAssertNil(NativeTimestamp.date(from: "not-a-timestamp"))
    }

    func testLegacyMediaJSONUsesSafeDefaults() throws {
        let media = try JSONDecoder().decode(
            NativeMedia.self,
            from: Data(#"{"url":"/media/note/photo.png"}"#.utf8)
        )

        XCTAssertEqual(media.kind, "image")
        XCTAssertEqual(media.name, "media")
        XCTAssertEqual(media.size, 0)
        XCTAssertEqual(media.url, "/media/note/photo.png")
        XCTAssertFalse(media.isVideo)
    }

    func testMomentTagsAreExtractedDeduplicatedAndRemovedFromDisplayContent() {
        let text = "今天 #Swift 很好 ＃swift"
        let runs = [
            NativeMomentTextRun(text: "今天", bold: true, color: nil),
            NativeMomentTextRun(text: " #Swift 很好 ＃swift", bold: false, color: .blue),
        ]

        XCTAssertEqual(NativeMomentTag.extract(from: text), ["Swift"])

        let content = NativeMomentTag.content(from: text, textRuns: runs)
        XCTAssertEqual(content.text, "今天 很好")
        XCTAssertEqual(content.runs.map(\.text), ["今天", " 很好"])
        XCTAssertEqual(content.runs.map(\.bold), [true, false])
        XCTAssertEqual(content.runs.map(\.color), [.none, .blue])
    }

    func testArticleHashtagsNormalizeAndPreserveLegacyCommaTags() {
        XCTAssertEqual(
            NativeArticleTag.parse("#Swift #swift，随笔, #macOS"),
            ["Swift", "随笔", "macOS"]
        )

        let article = NativeArticle(
            banner: nil,
            body: "正文",
            category: "Notes",
            excerpt: "",
            media: [],
            slug: "hashtags",
            status: .published,
            tags: ["#Swift #swift", "随笔, macOS"],
            title: "标签文章",
            updatedAt: "2026-08-23T00:00:00Z",
            publishedAt: nil,
            wordCount: nil
        )
        XCTAssertEqual(article.tags, ["Swift", "随笔", "macOS"])
    }

    func testArticleLinksExtractAndResolveTitlesOrSlugs() throws {
        XCTAssertEqual(
            NativeArticleLink.references(in: "先看 [[路线图]]，再看 [[hello-world]]。"),
            ["路线图", "hello-world"]
        )

        let articles = try JSONDecoder().decode(
            [NativeArticleSummary].self,
            from: Data("""
            [{
              "banner": null,
              "category": "Notes",
              "excerpt": "",
              "publishedAt": null,
              "slug": "roadmap",
              "status": "published",
              "tags": [],
              "title": "路线图",
              "updatedAt": "2026-08-23T00:00:00Z",
              "wordCount": 1
            }]
            """.utf8)
        )

        XCTAssertEqual(NativeArticleLink.resolve("路线图", in: articles)?.slug, "roadmap")
        XCTAssertEqual(NativeArticleLink.resolve("ROADMAP", in: articles)?.title, "路线图")
        XCTAssertNil(NativeArticleLink.resolve("不存在", in: articles))
    }

    func testMomentSearchAndFilterMatchTextTagsDatesAndFavorites() {
        let moment = NativeMoment(
            createdAt: "2026-08-20T10:00:00Z",
            id: "moment-1",
            images: [],
            isFavorite: true,
            tags: ["Swift"],
            text: "Ship it",
            textRuns: [NativeMomentTextRun(text: "Ship it", bold: false, color: nil)],
            updatedAt: "2026-08-20T10:00:00Z"
        )
        let filter = NativeMomentFilter(
            searchText: " 2026/8/20 ",
            tags: ["swift"],
            dateFilter: .month(year: 2026, month: 8),
            favoritesOnly: true
        )

        XCTAssertTrue(moment.matches(search: "ship"))
        XCTAssertTrue(filter.matches(moment))
        XCTAssertFalse(filter.matches(NativeMoment(
            createdAt: moment.createdAt,
            id: "moment-2",
            images: [],
            isFavorite: false,
            tags: moment.tags,
            text: moment.text,
            textRuns: moment.textRuns,
            updatedAt: moment.updatedAt
        )))
    }

    func testDateFiltersUseTheProvidedCalendarAndNow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let sameDay = "2025-08-22T12:00:00Z"
        let previousDay = "2025-08-21T23:59:59Z"
        let now = NativeTimestamp.date(from: sameDay)!

        XCTAssertTrue(NativeMomentDateFilter.today.includes(timestamp: sameDay, now: now, calendar: calendar))
        XCTAssertFalse(NativeMomentDateFilter.today.includes(timestamp: previousDay, now: now, calendar: calendar))
        XCTAssertTrue(NativeMomentDateFilter.month(year: 2025, month: 8).includes(timestamp: sameDay, now: now, calendar: calendar))
        XCTAssertTrue(NativeMomentDateFilter.year(2025).includes(timestamp: sameDay, now: now, calendar: calendar))
        XCTAssertFalse(NativeMomentDateFilter.year(2024).includes(timestamp: sameDay, now: now, calendar: calendar))
        XCTAssertTrue(NativeMomentDateFilter.all.includes(timestamp: "not-a-date", now: now, calendar: calendar))
    }
}

final class LocalBlogStoreTests {
    func testMomentLifecycleNormalizesInputFiltersAndRecordsActivity() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)

        let images = (1...10).map { index in
            NativeMedia(kind: "image", name: "image-\(index).png", size: index, url: "media/moment/image-\(index).png")
        } + [
            NativeMedia(kind: "video", name: "clip.mp4", size: 1, url: "/media/moment/clip.mp4"),
            NativeMedia(kind: "image", name: "missing.png", size: 1, url: ""),
        ]
        let saved = try await store.saveMoment(
            text: "  first note #Swift ",
            textRuns: [NativeMomentTextRun(text: "  first note #Swift ", bold: false, color: nil)],
            images: images
        )

        XCTAssertEqual(saved.text, "first note")
        XCTAssertEqual(saved.tags, ["Swift"])
        XCTAssertEqual(saved.images.count, 9)
        XCTAssertTrue(saved.images.allSatisfy { !$0.isVideo && $0.url.hasPrefix("/") })
        XCTAssertEqual(try await store.listMoments().map(\.id), [saved.id])

        let favorited = try await store.setMomentFavorite(id: saved.id, isFavorite: true)
        XCTAssertTrue(favorited.isFavorite)

        let page = try await store.listMomentPage(
            matching: NativeMomentFilter(tags: ["swift"], favoritesOnly: true),
            limit: 10
        )
        XCTAssertEqual(page.moments.map(\.id), [saved.id])
        XCTAssertEqual(try await store.countMoments(matching: NativeMomentFilter(tags: ["SWIFT"])), 1)
        XCTAssertEqual(try await store.listMomentFacetRecords().first?.tags, ["Swift"])

        let activity = try await store.listActivity(since: Date().addingTimeInterval(-60))
        XCTAssertEqual(activity.reduce(0) { $0 + $1.count }, 1)
    }

    func testMomentUpdatePreservesIdentityAndDeleteHidesIt() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)

        let saved = try await store.saveMoment(text: "before", textRuns: [], images: [])
        let favorited = try await store.setMomentFavorite(id: saved.id, isFavorite: true)
        let updated = try await store.updateMoment(
            id: favorited.id,
            text: "after #edited",
            textRuns: [],
            images: []
        )

        XCTAssertEqual(updated.id, saved.id)
        XCTAssertEqual(updated.createdAt, saved.createdAt)
        XCTAssertTrue(updated.isFavorite)
        XCTAssertEqual(updated.text, "after")
        XCTAssertEqual(updated.tags, ["edited"])

        try await store.deleteMoment(id: updated.id)
        XCTAssertTrue(try await store.listMoments().isEmpty)
    }

    func testArticleLifecycleSupportsDraftPublishingAndConflictProtection() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)

        let draft = try await store.saveArticle(article(
            slug: "hello-world",
            status: .draft,
            expectedUpdatedAt: nil,
            body: "hello\nworld"
        ))
        XCTAssertEqual(draft.wordCount, 11)
        XCTAssertTrue(try await store.listArticles(includeDrafts: false).isEmpty)

        let published = try await store.saveArticle(article(
            slug: draft.slug,
            status: .published,
            expectedUpdatedAt: draft.updatedAt,
            body: "http://localhost:8787/media/hello/image.png"
        ))
        XCTAssertEqual(published.status, .published)
        XCTAssertNotNil(published.publishedAt)
        XCTAssertEqual(published.body, "/media/hello/image.png")
        XCTAssertEqual(try await store.listArticles(includeDrafts: false).map(\.slug), ["hello-world"])
        XCTAssertEqual(try await store.getArticle(slug: "hello-world"), published)

        do {
            _ = try await store.saveArticle(article(
                slug: draft.slug,
                status: .draft,
                expectedUpdatedAt: draft.updatedAt,
                body: "stale"
            ))
            XCTFail("saving with a stale timestamp should fail")
        } catch let error {
            XCTAssertTrue(error.localizedDescription.contains("其他窗口中更新"))
        }

        XCTAssertEqual(try await store.allocateSlug(from: "Hello World"), "hello-world-2")
        XCTAssertEqual(try await store.allocateSlug(from: "Moments"), "moments-note")
    }

    func testArticleDeleteHidesRecord() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let saved = try await store.saveArticle(article(
            slug: "to-delete",
            status: .published,
            expectedUpdatedAt: nil,
            body: "content"
        ))

        try await store.deleteArticle(slug: saved.slug, expectedUpdatedAt: saved.updatedAt)
        XCTAssertTrue(try await store.listArticles().isEmpty)
    }

    func testArticleHashtagsPersistAsNormalizedTags() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let saved = try await store.saveArticle(NativeSaveArticle(
            banner: nil,
            body: "正文内容",
            category: "Notes",
            excerpt: "",
            media: [],
            slug: "tagged-article",
            status: .published,
            tags: ["#Swift #swift", "随笔, macOS"],
            title: "标签文章",
            expectedUpdatedAt: nil
        ))

        XCTAssertEqual(saved.tags, ["Swift", "随笔", "macOS"])
        XCTAssertEqual(try await store.getArticle(slug: saved.slug).tags, ["Swift", "随笔", "macOS"])
    }

    func testMediaURLNormalizesLocalhostAndRejectsUnsafeSegments() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)

        XCTAssertEqual(
            await store.mediaURL(for: "http://localhost:8787/media/notes/photo.png")?.path,
            root.appendingPathComponent("media/notes/photo.png").path
        )
        XCTAssertNil(await store.mediaURL(for: "/media/notes/../secret.png"))
        XCTAssertNil(await store.mediaURL(for: "/other/notes/photo.png"))
    }
}

final class UserWorkspaceStoreTests {
    func testWorkspacePreparationCreatesAndPersistsDefaultUser() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UserWorkspaceStore(rootURL: root)

        let initial = try await store.prepare()
        XCTAssertEqual(initial.activeUser, .leon)
        XCTAssertTrue(FileManager.default.fileExists(atPath: initial.workspaceURL.path))

        let persisted = try await store.prepare()
        XCTAssertEqual(persisted.activeUser, initial.activeUser)
        XCTAssertEqual(persisted.users, initial.users)
        XCTAssertEqual(persisted.workspaceURL, initial.workspaceURL)
    }
}

final class LocalBackupManagerTests {
    func testSnapshotCopiesDataWritesManifestAndSkipsLockFile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: source.appendingPathComponent("nested/note.txt"))
        try Data().write(to: source.appendingPathComponent(".leon-book.lock"))

        let snapshot = try LocalBackupManager.createSnapshot(source: source, destination: destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("nested/note.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent(".leon-book.lock").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("backup-manifest.json").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).count, 1)
    }

    func testBackupDestinationCannotBeTheSourceOrInsideIt() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        do {
            try LocalBackupManager.validateDestination(source: source, destination: source)
            XCTFail("the source itself is not a valid backup destination")
        } catch let error {
            XCTAssertTrue(error.localizedDescription.contains("不能位于源数据目录内部"))
        }

        do {
            try LocalBackupManager.validateDestination(
                source: source,
                destination: source.appendingPathComponent("nested", isDirectory: true)
            )
            XCTFail("a child of the source is not a valid backup destination")
        } catch {
            // Expected recursive-destination validation.
        }
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("leon-book-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@main
struct LeonBookUnitTests {
    static func main() async {
        let tests: [(String, () async throws -> Void)] = [
            ("NativeModelsTests.testWritingMetricsAndTimestampRoundTrip", { NativeModelsTests().testWritingMetricsAndTimestampRoundTrip() }),
            ("NativeModelsTests.testLegacyMediaJSONUsesSafeDefaults", { try NativeModelsTests().testLegacyMediaJSONUsesSafeDefaults() }),
            ("NativeModelsTests.testMomentTagsAreExtractedDeduplicatedAndRemovedFromDisplayContent", { NativeModelsTests().testMomentTagsAreExtractedDeduplicatedAndRemovedFromDisplayContent() }),
            ("NativeModelsTests.testArticleHashtagsNormalizeAndPreserveLegacyCommaTags", { NativeModelsTests().testArticleHashtagsNormalizeAndPreserveLegacyCommaTags() }),
            ("NativeModelsTests.testArticleLinksExtractAndResolveTitlesOrSlugs", { try NativeModelsTests().testArticleLinksExtractAndResolveTitlesOrSlugs() }),
            ("NativeModelsTests.testMomentSearchAndFilterMatchTextTagsDatesAndFavorites", { NativeModelsTests().testMomentSearchAndFilterMatchTextTagsDatesAndFavorites() }),
            ("NativeModelsTests.testDateFiltersUseTheProvidedCalendarAndNow", { NativeModelsTests().testDateFiltersUseTheProvidedCalendarAndNow() }),
            ("LocalBlogStoreTests.testMomentLifecycleNormalizesInputFiltersAndRecordsActivity", { try await LocalBlogStoreTests().testMomentLifecycleNormalizesInputFiltersAndRecordsActivity() }),
            ("LocalBlogStoreTests.testMomentUpdatePreservesIdentityAndDeleteHidesIt", { try await LocalBlogStoreTests().testMomentUpdatePreservesIdentityAndDeleteHidesIt() }),
            ("LocalBlogStoreTests.testArticleLifecycleSupportsDraftPublishingAndConflictProtection", { try await LocalBlogStoreTests().testArticleLifecycleSupportsDraftPublishingAndConflictProtection() }),
            ("LocalBlogStoreTests.testArticleDeleteHidesRecord", { try await LocalBlogStoreTests().testArticleDeleteHidesRecord() }),
            ("LocalBlogStoreTests.testArticleHashtagsPersistAsNormalizedTags", { try await LocalBlogStoreTests().testArticleHashtagsPersistAsNormalizedTags() }),
            ("LocalBlogStoreTests.testMediaURLNormalizesLocalhostAndRejectsUnsafeSegments", { try await LocalBlogStoreTests().testMediaURLNormalizesLocalhostAndRejectsUnsafeSegments() }),
            ("UserWorkspaceStoreTests.testWorkspacePreparationCreatesAndPersistsDefaultUser", { try await UserWorkspaceStoreTests().testWorkspacePreparationCreatesAndPersistsDefaultUser() }),
            ("LocalBackupManagerTests.testSnapshotCopiesDataWritesManifestAndSkipsLockFile", { try LocalBackupManagerTests().testSnapshotCopiesDataWritesManifestAndSkipsLockFile() }),
            ("LocalBackupManagerTests.testBackupDestinationCannotBeTheSourceOrInsideIt", { try LocalBackupManagerTests().testBackupDestinationCannotBeTheSourceOrInsideIt() }),
        ]

        for (name, test) in tests {
            let failureCount = failures.count
            do {
                try await test()
                if failures.count == failureCount {
                    print("PASS \(name)")
                }
            } catch {
                recordFailure("\(name) threw \(error)")
            }
        }

        if failures.isEmpty {
            print("LeonBook unit tests passed (\(tests.count) tests)")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            exit(1)
        }
    }
}

private func article(
    slug: String,
    status: NativeArticleStatus,
    expectedUpdatedAt: String?,
    body: String
) -> NativeSaveArticle {
    NativeSaveArticle(
        banner: nil,
        body: body,
        category: "",
        excerpt: "excerpt",
        media: [],
        slug: slug,
        status: status,
        tags: ["swift", "swift", "notes"],
        title: "Test article",
        expectedUpdatedAt: expectedUpdatedAt
    )
}
