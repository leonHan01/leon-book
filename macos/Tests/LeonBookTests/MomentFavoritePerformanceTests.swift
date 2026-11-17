import Foundation
@testable import LeonBook

private struct MomentFavoriteFailure: Error, CustomStringConvertible {
    let description: String
}

private extension LocalBlogStore {
    func holdMomentFavoriteQueue(entered: @Sendable () -> Void, release: DispatchSemaphore) -> Bool {
        entered()
        return release.wait(timeout: .now() + 5) == .success
    }
}

final class MomentFavoritePerformanceTests {
    @MainActor
    func testFavoritePreservesLoadedHistoryAndCursor() async throws {
        try await withFeed(favoritesOnly: false) { model, store in
            let ids = model.moments.map(\.id)
            let cursor = model.nextMomentCursor
            let generation = model.momentFeedGeneration
            let target = model.moments[60]
            await model.toggleMomentFavorite(target)?.value
            guard model.errorMessage == nil,
                  model.moments.map(\.id) == ids,
                  model.moments[60].isFavorite,
                  model.filteredMomentCount == 85,
                  model.totalMomentCount == 85,
                  model.nextMomentCursor == cursor, model.hasMoreMoments,
                  model.momentFeedGeneration == generation,
                  try await store.getMoment(id: target.id).isFavorite else {
                throw MomentFavoriteFailure(description: "favorite must update one row without reloading or losing loaded history")
            }
            await model.toggleMomentFavorite(model.moments[60])?.value
            guard model.moments.map(\.id) == ids, !model.moments[60].isFavorite,
                  model.nextMomentCursor == cursor, model.filteredMomentCount == 85 else {
                throw MomentFavoriteFailure(description: "unfavorite in the ordinary feed must preserve its rows and cursor")
            }
        }
    }

    @MainActor
    func testUnfavoritePreservesFilteredPagination() async throws {
        try await withFeed(favoritesOnly: true) { model, _ in
            let ids = model.moments.map(\.id)
            let cursor = model.nextMomentCursor
            let generation = model.momentFeedGeneration
            // Remove the row used by the existing cursor: its timestamp/id must
            // still work as the exclusive boundary for the next page.
            await model.toggleMomentFavorite(model.moments[79])?.value
            guard model.errorMessage == nil,
                  model.moments.map(\.id) == Array(ids.dropLast()),
                  model.filteredMomentCount == 84, model.totalMomentCount == 85,
                  model.nextMomentCursor == cursor, model.hasMoreMoments,
                  model.momentFeedGeneration == generation else {
                throw MomentFavoriteFailure(description: "unfavorite must remove only its row and adjust the filtered count")
            }
            model.loadMoreMoments()
            try await finishLoading(model)
            guard model.moments.count == 84, Set(model.moments.map(\.id)).count == 84,
                  !model.hasMoreMoments, model.nextMomentCursor == nil,
                  model.moments.allSatisfy(\.isFavorite),
                  !model.moments.contains(where: { $0.id == ids.last }) else {
                throw MomentFavoriteFailure(description: "pagination after removing the cursor row must not repeat or skip favorites")
            }
        }
    }

    @MainActor
    func testRemovingAllLoadedFavoritesRevealsNextPage() async throws {
        try await withFeed(favoritesOnly: true) { model, _ in
            let loaded = model.moments
            for moment in loaded { await model.toggleMomentFavorite(moment)?.value }
            try await finishLoading(model)
            guard model.errorMessage == nil, model.moments.count == 5,
                  model.filteredMomentCount == 5, !model.hasMoreMoments,
                  model.nextMomentCursor == nil,
                  Set(model.moments.map(\.id)).isDisjoint(with: loaded.map(\.id)) else {
                throw MomentFavoriteFailure(description: "removing every loaded favorite must reveal remaining history instead of stranding it behind an empty state")
            }
        }
    }

    @MainActor
    func testFavoriteReconcilesConcurrentFeedReload() async throws {
        for refreshStartsFirst in [true, false] {
            try await withFeed(favoritesOnly: true) { model, store in
                let target = model.moments[20]
                let release = DispatchSemaphore(value: 0)
                var blocker: Task<Bool, Never>!
                await withCheckedContinuation { continuation in
                    blocker = Task {
                        await store.holdMomentFavoriteQueue(
                            entered: { continuation.resume() }, release: release
                        )
                    }
                }
                defer { release.signal() }

                let favorite: Task<Void, Never>?
                let refresh: Task<Void, Error>
                if refreshStartsFirst {
                    refresh = Task { try await model.reloadMomentFeed() }
                    try await waitForLoadingToStart(model)
                    favorite = model.toggleMomentFavorite(target)
                } else {
                    favorite = model.toggleMomentFavorite(target)
                    refresh = Task { try await model.reloadMomentFeed() }
                    try await waitForLoadingToStart(model)
                }
                let overlappingGeneration = model.momentFeedGeneration
                release.signal()
                guard await blocker.value else {
                    throw MomentFavoriteFailure(description: "store gate timed out before concurrent feed operations were queued")
                }
                try await refresh.value
                await favorite?.value
                try await finishLoading(model)
                let persisted = try await store.getMoment(id: target.id)

                guard model.errorMessage == nil,
                      model.momentFeedGeneration > overlappingGeneration,
                      model.filteredMomentCount == 84, model.totalMomentCount == 85,
                      model.moments.allSatisfy(\.isFavorite),
                      !model.moments.contains(where: { $0.id == target.id }),
                      !persisted.isFavorite else {
                    throw MomentFavoriteFailure(description: "overlapping refresh must be invalidated so its pre-write count/page cannot overwrite the favorite change")
                }

                for _ in 0..<3 where model.hasMoreMoments {
                    model.loadMoreMoments()
                    try await finishLoading(model)
                }
                let expected = try await store.listMoments().filter(\.isFavorite).map(\.id)
                guard !model.hasMoreMoments, model.nextMomentCursor == nil,
                      model.moments.map(\.id) == expected,
                      Set(model.moments.map(\.id)).count == 84 else {
                    throw MomentFavoriteFailure(description: "reconciled favorites must retain correct counts and paginate without duplicates or omissions")
                }
            }
        }
    }

    @MainActor
    private func withFeed(
        favoritesOnly: Bool,
        run: (NativeAppModel, LocalBlogStore) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("moment-favorite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        for index in 0..<85 {
            let moment = try await store.saveMoment(text: "record \(index) #performance", textRuns: [], images: [])
            if favoritesOnly { _ = try await store.setMomentFavorite(id: moment.id, isFavorite: true) }
        }
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false, store: store)
        // No delayed backup/export work should outlive this temporary fixture.
        model.backupDirectoryPath = ""
        defer {
            model.compatibilityExportTask?.cancel()
            model.backupTask?.cancel()
        }
        model.showsOnlyFavoriteMoments = favoritesOnly
        try await model.reloadMomentFeed(refreshesFacets: true)
        model.loadMoreMoments()
        try await finishLoading(model)
        guard model.moments.count == 80, model.hasMoreMoments else {
            throw MomentFavoriteFailure(description: "fixture must load two real pages and retain a third page")
        }
        try await run(model, store)
    }

    @MainActor
    private func finishLoading(_ model: NativeAppModel) async throws {
        for _ in 0..<400 {
            if !model.isLoadingMoreMoments { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw MomentFavoriteFailure(description: "timed out loading the next moment page")
    }

    @MainActor
    private func waitForLoadingToStart(_ model: NativeAppModel) async throws {
        for _ in 0..<400 {
            if model.isLoadingMoreMoments { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw MomentFavoriteFailure(description: "feed refresh did not reach the blocked store")
    }
}
