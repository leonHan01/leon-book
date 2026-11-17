import Foundation
@testable import LeonBook

private struct MomentPaginationFailure: Error, CustomStringConvertible {
    let description: String
}

private extension LocalBlogStore {
    func seedMomentPaginationFixture() throws -> [NativeMoment] {
        try prepareForInteractiveUse()
        let timestamps = [
            "2026-09-15T12:00:00.000Z",
            "2026-10-15T12:00:00.000Z",
            "2026-11-15T12:00:00.000Z",
        ]
        var active: [NativeMoment] = []
        try db().transaction {
            for index in 0..<240 {
                // Each timestamp spans two default-sized pages. IDs must be
                // the tie-breaker even when filters leave gaps within a group.
                let timestamp = timestamps[index / 80]
                let moment = NativeMoment(
                    createdAt: timestamp,
                    id: String(format: "pagination-%04d", index),
                    images: [],
                    isFavorite: index.isMultiple(of: 3),
                    tags: [index.isMultiple(of: 2) ? "Swift" : "Other"],
                    text: index.isMultiple(of: 5) ? "needle fixture" : "ordinary fixture",
                    textRuns: [],
                    updatedAt: timestamp
                )
                let deletedAt = index.isMultiple(of: 29) ? timestamp : nil
                try insertMoment(moment, deletedAt: deletedAt, into: db())
                if deletedAt == nil { active.append(moment) }
            }
        }
        return active.sorted {
            $0.createdAt == $1.createdAt ? $0.id > $1.id : $0.createdAt > $1.createdAt
        }
    }

    func momentPaginationQueryPlan(before cursor: NativeMomentCursor) throws -> [String] {
        // Exercise the production predicate and bound values, rather than a
        // separately hard-coded equivalent that could miss a SQL regression.
        let query = momentCandidateQuery(matching: .all, before: cursor)
        var details: [String] = []
        try db().query("""
            EXPLAIN QUERY PLAN
            \(momentSelect)
            WHERE \(query.whereClause)
            ORDER BY created_at DESC, id DESC
            LIMIT ?
            """, values: query.values + [.integer(80)]) { row in
            if let detail = row.text(at: 3) { details.append(detail) }
        }
        return details
    }
}

final class MomentPaginationPerformanceTests {
    func testMomentPagesPreserveTimestampTiesAndFilters() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("moment-pagination-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let fixture = try await store.seedMomentPaginationFixture()
        let filters: [NativeMomentFilter] = [
            .all,
            NativeMomentFilter(tags: ["swift"]),
            NativeMomentFilter(searchText: "needle"),
            NativeMomentFilter(favoritesOnly: true),
            NativeMomentFilter(dateFilter: .month(year: 2026, month: 10)),
            NativeMomentFilter(
                searchText: "needle", tags: ["SWIFT"],
                dateFilter: .month(year: 2026, month: 10), favoritesOnly: true
            ),
        ]

        for filter in filters {
            let expected = fixture.filter { filter.matches($0) }.map(\.id)
            for limit in [1, 7, 40, 100] {
                var cursor: NativeMomentCursor?
                var actual: [String] = []
                repeat {
                    let page = try await store.listMomentPage(matching: filter, before: cursor, limit: limit)
                    guard page.moments.count <= limit,
                          page.nextCursor == nil || (!page.moments.isEmpty && page.nextCursor != cursor) else {
                        throw MomentPaginationFailure(description: "page must respect its limit and advance its cursor")
                    }
                    actual.append(contentsOf: page.moments.map(\.id))
                    guard actual.count <= expected.count else {
                        throw MomentPaginationFailure(description: "pagination repeated records or included filtered/deleted records")
                    }
                    cursor = page.nextCursor
                } while cursor != nil
                guard actual == expected, Set(actual).count == actual.count else {
                    throw MomentPaginationFailure(description: "pagination must preserve descending timestamp/ID order without duplicates or omissions (limit \(limit))")
                }
            }
        }
        await store.closeForRestore()
    }

    func testMomentCursorUsesIndexedRangeSearch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("moment-pagination-plan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let fixture = try await store.seedMomentPaginationFixture()
        for moment in [fixture[40], fixture[180]] {
            let plan = try await store.momentPaginationQueryPlan(
                before: NativeMomentCursor(createdAt: moment.createdAt, id: moment.id)
            )
            guard plan.contains(where: {
                $0.contains("SEARCH moments USING INDEX moments_feed_active_idx") && $0.contains("created_at")
            }), !plan.contains(where: { $0.contains("SCAN moments") || $0.contains("USE TEMP B-TREE FOR ORDER BY") }) else {
                throw MomentPaginationFailure(description: "cursor must seek into the ordered feed index rather than rescan earlier pages: \(plan)")
            }
        }
        await store.closeForRestore()
    }
}
