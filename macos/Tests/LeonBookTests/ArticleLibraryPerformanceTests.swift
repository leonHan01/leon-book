import Foundation
@testable import LeonBook

private struct ArticleLibraryFailure: Error, CustomStringConvertible {
    let description: String
}

private func libraryExpect(_ value: Bool, _ message: String) throws {
    if !value { throw ArticleLibraryFailure(description: message) }
}

final class ArticleLibraryPerformanceTests {
    func testCalendarCivilDatesAndTimeZones() throws {
        for zone in ["Asia/Shanghai", "America/Los_Angeles"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            let date = NativeArticleCalendarProjection.propertyDate("2026-11-01", timeZone: calendar.timeZone)!
            let articles = [
                summary("scheduled", properties: ["Due": .date("2026-11-01")]),
                summary("missing"),
                summary("invalid", properties: ["due": .date("2026-02-30")]),
            ]
            let projection = NativeArticleCalendarProjection(snapshot: .init(
                articles: articles, datePropertyKey: "due", calendar: calendar
            ))
            let days = projection.days(in: date, calendar: calendar)
            try libraryExpect(days.count == 42, "calendar must retain a six-week grid across DST")
            try libraryExpect(days.first { calendar.isDate($0.date, inSameDayAs: date) }?.articles.map(\.slug) == ["scheduled"],
                              "date-only properties must stay on the selected civil day in either time zone")
            try libraryExpect(projection.unscheduledArticles.map(\.slug) == ["missing", "invalid"],
                              "only missing and invalid dates belong in the unscheduled section")
            try libraryExpect(projection.availableDatePropertyKeys.count == 1,
                              "property keys must be deduplicated case insensitively")
            try libraryExpect(NativeArticleCalendarProjection.propertyDateString(for: date, timeZone: calendar.timeZone) == "2026-11-01",
                              "drag/drop date serialization must round-trip without UTC day shifts")
        }
        try libraryExpect(NativeArticleCalendarProjection.propertyDate("2024-02-29", timeZone: .gmt) != nil,
                          "valid leap dates must parse")
        try libraryExpect(NativeArticleCalendarProjection.propertyDate("2026-02-29", timeZone: .gmt) == nil,
                          "invalid leap dates must not be normalized into March")
    }

    func testCalendarBucketsPreserveOrderAcrossMonths() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let articles = [
            summary("first", updatedAt: "2026-11-01T01:00:00Z"),
            summary("second", updatedAt: "2026-11-01T02:00:00Z"),
            summary("later", updatedAt: "2026-12-15T18:00:00Z"),
        ]
        let projection = NativeArticleCalendarProjection(snapshot: .init(
            articles: articles, datePropertyKey: nil, calendar: calendar
        ))
        let october = NativeArticleCalendarProjection.propertyDate("2026-10-31", timeZone: calendar.timeZone)!
        let december = NativeArticleCalendarProjection.propertyDate("2026-12-15", timeZone: calendar.timeZone)!
        try libraryExpect(projection.days(in: october, calendar: calendar)
            .first { calendar.isDate($0.date, inSameDayAs: october) }?.articles.map(\.slug) == ["first", "second"],
                          "timestamp grouping must use local days and preserve library ordering")
        try libraryExpect(projection.days(in: december, calendar: calendar)
            .first { calendar.isDate($0.date, inSameDayAs: december) }?.articles.map(\.slug) == ["later"],
                          "one projection must support another month without rescanning articles")
        try libraryExpect(projection.unscheduledArticles.isEmpty, "updated-at mode does not expose unscheduled articles")
    }

    @MainActor
    func testMetadataBatchMergesSummariesAndRefreshesAliases() async throws {
        try await withLibrary { model, store, saved in
            model.selectedArticle = saved[0]
            var rebuilds = 0
            model.projectionRebuildWillBuild = { kind in
                if kind == .articleLibrary { rebuilds += 1 }
            }
            await model.updateArticleProperties(
                articles: [saved[0].summary, saved[1].summary], key: "Due", kind: .date, text: "2026-11-07"
            )?.value
            try libraryExpect(model.errorMessage == nil && rebuilds == 1,
                              "one drop batch should publish one library projection")
            for article in saved.prefix(2) {
                try libraryExpect(model.articleSummary(for: article.slug)?.properties["Due"] == .date("2026-11-07"),
                                  "every updated summary must be retained")
            }
            let target = model.articleSummary(for: saved[0].slug)!
            try libraryExpect(model.selectedArticle?.updatedAt == target.updatedAt &&
                model.articleSelectionCache.article(matching: target, workspaceGeneration: model.workspaceGeneration)?.properties["Due"] == .date("2026-11-07"),
                              "selection and reopen cache must contain the saved article")

            await model.updateArticleProperty(article: target, key: "aliases", kind: .list, text: "TargetAlias")?.value
            try libraryExpect(model.articleGraph.edges.contains { $0.sourceSlug == "source" && $0.targetSlug == target.slug },
                              "metadata refresh must resolve new alias links")
            let beforeMove = rebuilds
            let moving = [model.articleSummary(for: "one")!, model.articleSummary(for: "two")!]
            await model.moveArticles(moving, toGroup: "Projects", field: .category)?.value
            try libraryExpect(rebuilds == beforeMove + 1 && moving.allSatisfy {
                model.articleSummary(for: $0.slug)?.category == "Projects"
            }, "multi-card moves must merge every summary in one refresh")
            try libraryExpect(model.articleGraph == (try await store.articleGraph()),
                              "batched graph refresh must preserve the store's full resolution semantics")
        }
    }

    @MainActor
    func testConcurrentMetadataUpdatesKeepBothSummaries() async throws {
        try await withLibrary { model, _, saved in
            let first = model.updateArticleProperty(article: saved[0].summary, key: "Due", kind: .date, text: "2026-11-07")
            let second = model.updateArticleProperty(article: saved[1].summary, key: "Due", kind: .date, text: "2026-11-08")
            await first?.value
            await second?.value
            try libraryExpect(model.articleSummary(for: "one")?.properties["Due"] == .date("2026-11-07") &&
                              model.articleSummary(for: "two")?.properties["Due"] == .date("2026-11-08"),
                              "overlapping updates must not publish snapshots that lose another mutation")
        }
    }

    @MainActor
    func testBoardMoveReevaluatesDuplicateTitleLinks() async throws {
        try await withLibrary { model, store, saved in
            for article in saved {
                _ = try await store.saveArticle(NativeSaveArticle(
                    banner: article.banner, body: article.slug == "source" ? "[[Duplicate]]" : article.body,
                    category: article.category, excerpt: article.excerpt, media: article.media,
                    slug: article.slug, status: article.status, tags: article.tags,
                    title: article.slug == "source" ? article.title : "Duplicate", expectedUpdatedAt: article.updatedAt
                ))
            }
            await model.replaceArticleSummaries(try await store.listArticles())
            let before = try await store.articleGraph()
            try libraryExpect(before.edges.contains { $0.sourceSlug == "source" && $0.targetSlug == "two" },
                              "the more recently updated duplicate title must initially win resolution")
            await model.moveArticle(model.articleSummary(for: "one")!, toGroup: "Projects", field: .category)?.value
            try libraryExpect(model.articleGraph.edges.contains { $0.sourceSlug == "source" && $0.targetSlug == "one" },
                              "changing updated-at ordering must refresh ambiguous-title graph edges even when only a category changed")
        }
    }

    @MainActor
    func testMetadataRefreshDoesNotWriteIntoAnotherWorkspace() async throws {
        try await withLibrary { model, store, saved in
            let gate = ArticleLibraryTestGate()
            model.projectionRebuildWillBuild = { kind in
                if kind == .articleLibrary { await gate.suspend() }
            }
            let refresh = model.articleLibraryUpdateCoordinator.enqueue(
                [saved[0].summary], model: model, store: store, workspaceGeneration: model.workspaceGeneration
            )
            await gate.waitUntilSuspended()
            model.workspaceGeneration += 1
            await model.replaceArticleSummaries([])
            model.articleGraph = .empty
            await gate.release()
            await refresh.value
            try libraryExpect(model.articles.isEmpty && model.articleGraph == .empty,
                              "a pending old-workspace projection or graph must never repopulate the new workspace")
        }
    }

    @MainActor
    func testMetadataMergePreservesConcurrentReloadAndPageViews() async throws {
        try await withLibrary { model, store, saved in
            let updated = try await store.setArticleProperty(
                slug: saved[0].slug, expectedUpdatedAt: saved[0].updatedAt,
                key: "Due", value: .date("2026-11-07")
            )
            let gate = ArticleLibraryTestGate()
            model.projectionRebuildWillBuild = { kind in
                if kind == .articleLibrary { await gate.suspend() }
            }
            let workspace = model.workspaceGeneration
            let merge = Task {
                await model.mergeArticleSummaries([updated.summary], workspaceGeneration: workspace)
            }
            await gate.waitUntilSuspended()
            model.projectionRebuildWillBuild = nil
            // A later reload removes another record and publishes a newer PV
            // while the original merge is still building its old snapshot.
            model.updateArticleSummaryPageViews(slug: updated.slug, pageViews: 42)
            await model.replaceArticleSummaries([saved[0].summary, saved[2].summary])
            await gate.release()
            await merge.value
            try libraryExpect(model.articleSummary(for: "two") == nil && model.articles.count == 2,
                              "a metadata merge must not resurrect a concurrently removed summary")
            try libraryExpect(model.articleSummary(for: "one")?.properties["Due"] == .date("2026-11-07") &&
                              model.articleSummary(for: "one")?.pageViews == 42,
                              "a retried metadata merge must preserve both its change and newer page views")
        }
    }

    private func summary(
        _ slug: String,
        updatedAt: String = "2026-11-07T01:00:00Z",
        properties: [String: NativeArticlePropertyValue] = [:]
    ) -> NativeArticleSummary {
        NativeArticleSummary(banner: nil, category: "Notes", excerpt: "", properties: properties,
                             publishedAt: nil, slug: slug, status: .draft, tags: [], title: slug,
                             updatedAt: updatedAt, wordCount: 1)
    }

    @MainActor
    private func withLibrary(
        run: (NativeAppModel, LocalBlogStore, [NativeArticle]) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("article-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        var saved: [NativeArticle] = []
        for slug in ["one", "two", "source"] {
            saved.append(try await store.saveArticle(NativeSaveArticle(
                banner: nil, body: slug == "source" ? "[[TargetAlias]]" : "body", category: "Notes", excerpt: "",
                media: [], slug: slug, status: .draft, tags: [], title: slug, expectedUpdatedAt: nil
            )))
        }
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false, store: store)
        let suite = "ArticleLibraryPerformanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        model.firstPartyModuleRuntime = NativeFirstPartyModules.loadRuntime(defaults: defaults)
        model.backupDirectoryPath = ""
        defer {
            model.articleLibraryUpdateCoordinator.cancel()
            model.compatibilityExportTask?.cancel()
            model.backupTask?.cancel()
            model.projectionRebuildWillBuild = nil
        }
        await model.replaceArticleSummaries(try await store.listArticles())
        try await run(model, store, saved)
        await store.closeForRestore()
    }
}

private actor ArticleLibraryTestGate {
    private var suspended = false
    private var released = false
    private var entered: CheckedContinuation<Void, Never>?
    private var resume: CheckedContinuation<Void, Never>?

    func suspend() async {
        suspended = true
        entered?.resume()
        entered = nil
        if !released { await withCheckedContinuation { resume = $0 } }
    }

    func waitUntilSuspended() async {
        if !suspended { await withCheckedContinuation { entered = $0 } }
    }

    func release() {
        released = true
        resume?.resume()
        resume = nil
    }
}
