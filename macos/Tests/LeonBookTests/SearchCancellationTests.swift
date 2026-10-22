import Foundation
@testable import LeonBook

private enum SearchCancellationFailure: Error {
    case expectation(String)
}

private final class SearchQueryProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false

    func markStarted() { lock.lock(); started = true; lock.unlock() }
    var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }
}

private extension LocalBlogStore {
    func seedSearchCancellationFixture() throws {
        try prepareForInteractiveUse()
        // Populate the real FTS schema directly to isolate query work from
        // article exports and index maintenance during fixture creation.
        try db().execute("""
            WITH RECURSIVE documents(n) AS (
                VALUES(0) UNION ALL SELECT n + 1 FROM documents WHERE n < 1599
            )
            INSERT INTO content_search(
                document_type, document_id, title, aliases, body, excerpt,
                tags, category, properties, status, created_at, updated_at
            ) SELECT 'article', 'note-' || n, 'unique' || n, '', ?, '',
                     '[]', '', '', 'published', '2026-10-23', '2026-10-23'
              FROM documents
            """, values: [.text(String(repeating: "needle swift sqlite ", count: 300))])
    }

    func searchWithProgress(_ progress: SearchQueryProgress) throws -> [NativeGlobalSearchResult] {
        progress.markStarted()
        return try search("needle")
    }
}

final class SearchCancellationTests {
    func testCancelledSearchSkipsStorePreparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let cancelled = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await store.search("obsolete query")
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }.value
        guard cancelled else { throw SearchCancellationFailure.expectation("obsolete search must throw CancellationError") }
        guard !FileManager.default.fileExists(atPath: root.path) else {
            throw SearchCancellationFailure.expectation("cancelled queued search must not initialize a workspace")
        }
        // Cancellation of one caller must not poison subsequent searches.
        guard try await store.search("current query").isEmpty else {
            throw SearchCancellationFailure.expectation("fresh search should succeed")
        }
    }

    func testSQLiteSearchCancellationInterruptsStepAndPreservesConnection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let progress = SearchQueryProgress()
        let task = Task.detached { () throws -> (Bool, Int) in
            let database = try SQLiteDatabase(url: root.appendingPathComponent("test.sqlite"))
            defer { database.close() }
            // The first row signals that SQL execution has started. The next
            // sqlite3_step computes an aggregate without yielding any rows.
            let sql = """
                WITH RECURSIVE numbers(n) AS (
                    VALUES(1) UNION ALL SELECT n + 1 FROM numbers WHERE n < ?
                )
                SELECT 0 UNION ALL SELECT sum(n) FROM numbers
                """
            var cancelled = false
            var rows = 0
            do {
                try database.query(sql, values: [.integer(5_000_000)], checkingCancellation: true) { _ in
                    rows += 1
                    progress.markStarted()
                }
            } catch is CancellationError { cancelled = true }

            // This task is still cancelled: ordinary writes/reads must remain
            // usable, including the statement that was interrupted above.
            try database.execute("CREATE TABLE saved(value INTEGER)")
            try database.transaction {
                try database.execute("INSERT INTO saved VALUES (?)", values: [.integer(42)])
            }
            guard try database.integer("SELECT value FROM saved") == 42 else {
                throw SearchCancellationFailure.expectation("search cancellation leaked into writes")
            }
            var values: [Int] = []
            try database.query(sql, values: [.integer(10)]) { values.append($0.integer(at: 0) ?? -1) }
            guard values == [0, 55] else {
                throw SearchCancellationFailure.expectation("connection or interrupted statement was not reusable")
            }
            return (cancelled, rows)
        }
        for _ in 0..<2_000 where !progress.hasStarted {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard progress.hasStarted else {
            task.cancel()
            _ = try? await task.value
            throw SearchCancellationFailure.expectation("query did not start")
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let start = DispatchTime.now().uptimeNanoseconds
        task.cancel()
        let result = try await task.value
        let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print("SEARCH_CANCELLATION activeStepCancelled=\(result.0) rows=\(result.1) releaseMS=\(elapsedMS)")
        guard result.0, result.1 == 1 else {
            throw SearchCancellationFailure.expectation("cancelled SQL must stop inside sqlite3_step before producing its aggregate")
        }
    }

    func testSearchCancellationReleasesStoreForNextQuery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        try await store.seedSearchCancellationFixture()
        let baselineStart = DispatchTime.now().uptimeNanoseconds
        guard try await store.search("needle").count == 60 else {
            throw SearchCancellationFailure.expectation("fixture must exercise ranked FTS results")
        }
        let baselineMS = Double(DispatchTime.now().uptimeNanoseconds - baselineStart) / 1_000_000
        let progress = SearchQueryProgress()
        let obsolete = Task.detached { try await store.searchWithProgress(progress) }
        for _ in 0..<2_000 where !progress.hasStarted {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard progress.hasStarted else {
            obsolete.cancel()
            _ = try? await obsolete.value
            throw SearchCancellationFailure.expectation("FTS search did not start")
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        let cancelStart = DispatchTime.now().uptimeNanoseconds
        obsolete.cancel()
        let current = try await store.search("unique1599", restrictingTo: [.article])
        let releasedMS = Double(DispatchTime.now().uptimeNanoseconds - cancelStart) / 1_000_000
        var cancelled = false
        do { _ = try await obsolete.value }
        catch is CancellationError { cancelled = true }
        print("FTS_CANCELLATION documents=1600 fullQueryMS=\(baselineMS) nextQueryMS=\(releasedMS) cancelled=\(cancelled)")
        guard cancelled, current.map(\.documentID) == ["note-1599"] else {
            throw SearchCancellationFailure.expectation("obsolete FTS must stop while the latest search still returns correct results")
        }
    }
}
