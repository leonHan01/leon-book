import Darwin
import AppKit
import Foundation
@testable import LeonBook

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

    func testAutomationURLsParseActionsAndEncodedParameters() throws {
        XCTAssertEqual(
            try NativeAutomationURL.route(from: URL(
                string: "leonbook://new?title=Web%20Clip&content=hello%20world&url=https%3A%2F%2Fexample.com%2Fa%3Fb%3D1"
            )!),
            .newArticle(
                title: "Web Clip",
                content: "hello world",
                sourceURL: "https://example.com/a?b=1"
            )
        )
        XCTAssertEqual(
            try NativeAutomationURL.route(from: URL(string: "leonbook://open?slug=road-map")!),
            .openArticle(slug: "road-map")
        )
        XCTAssertEqual(
            try NativeAutomationURL.route(from: URL(string: "leonbook://search?q=Swift%20SQLite")!),
            .search(query: "Swift SQLite")
        )
        XCTAssertEqual(
            try NativeAutomationURL.route(from: URL(string: "leonbook://today")!),
            .today
        )
        XCTAssertEqual(
            try NativeAutomationURL.route(from: URL(string: "leonbook://search")!),
            .search(query: "")
        )
        XCTAssertEqual(
            try NativeAutomationURL.command(from: URL(string: "leonbook://search?q=统一命令")!),
            .search(query: "统一命令")
        )

        do {
            _ = try NativeAutomationURL.route(from: URL(string: "leonbook://open")!)
            XCTFail("open automation should require a slug")
        } catch let error as NativeAutomationURLError {
            XCTAssertEqual(error, .missingParameter("slug"))
        }
        do {
            _ = try NativeAutomationURL.route(from: URL(string: "https://example.com")!)
            XCTFail("automation parser should reject foreign URL schemes")
        } catch let error as NativeAutomationURLError {
            XCTAssertEqual(error, .unsupportedScheme)
        }

        _ = NativeAutomationInbox.drain()
        NativeAutomationInbox.enqueue(.today)
        NativeAutomationInbox.enqueue(.search(query: "queued"))
        XCTAssertEqual(NativeAutomationInbox.drain(), [.today, .search(query: "queued")])
        XCTAssertTrue(NativeAutomationInbox.drain().isEmpty)
    }

    func testCommandRegistryFuzzyMatchingRankingAndAvailability() {
        let registry = NativeCommandRegistry.builtIn
        let regularContext = NativeCommandContext(storageReady: true)
        let matches = registry.matches("快速文", on: .palette, context: regularContext)
        XCTAssertEqual(matches.first?.id, .quickOpen)
        XCTAssertEqual(registry.definition(for: .backupNow)?.title, "立即备份")
        XCTAssertEqual(registry.definition(for: .backupNow)?.surfaces, [.palette])
        XCTAssertEqual(
            registry.definition(for: .globalSearch)?.defaultShortcut,
            NativeCommandShortcut(key: "f", modifiers: [.command, .shift])
        )

        let ranked = registry.matches(
            "",
            on: .palette,
            context: regularContext,
            ranking: NativeCommandRanking(
                pinned: [.settings],
                recent: [.newArticle, .globalSearch]
            )
        )
        XCTAssertEqual(ranked.first?.id, .settings)
        XCTAssertEqual(ranked.dropFirst().first?.id, .newArticle)

        XCTAssertFalse(ranked.contains(where: { $0.id == .saveDraft }))
        let editorMatches = registry.matches(
            "保存",
            on: .palette,
            context: NativeCommandContext(storageReady: true, isArticleEditor: true)
        )
        XCTAssertEqual(editorMatches.first?.id, .saveDraft)

        let slashMatches = registry.matches(
            "todo",
            on: .editorSlash,
            context: NativeCommandContext(storageReady: true, isArticleEditor: true)
        )
        XCTAssertEqual(slashMatches.first?.id, .insertTask)
        XCTAssertEqual(
            registry.definition(for: .insertWikiLink)?.textInsertion,
            NativeCommandTextInsertion(text: "[[]]", cursorOffset: 2)
        )
    }

    func testCommandPreferencesPersistPinsRecentsAndRejectConflicts() async {
        await MainActor.run {
            let suiteName = "leon-book-command-tests-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                XCTFail("expected isolated defaults suite")
                return
            }
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let key = "command-preferences"
            let preferences = NativeCommandPreferences(defaults: defaults, defaultsKey: key)
            let custom = NativeCommandShortcut(key: "g", modifiers: [.command, .option])
            XCTAssertNil(preferences.setShortcut(custom, for: .globalSearch))
            XCTAssertEqual(preferences.shortcut(for: .globalSearch), custom)
            XCTAssertEqual(preferences.setShortcut(custom, for: .quickOpen), .globalSearch)

            preferences.togglePinned(.globalSearch)
            preferences.recordUse(.newArticle)

            let restored = NativeCommandPreferences(defaults: defaults, defaultsKey: key)
            XCTAssertEqual(restored.shortcut(for: .globalSearch), custom)
            XCTAssertTrue(restored.isPinned(.globalSearch))
            XCTAssertEqual(restored.ranking.recent.first, .newArticle)

            XCTAssertNil(restored.setShortcut(nil, for: .globalSearch))
            XCTAssertNil(restored.shortcut(for: .globalSearch))
            restored.resetShortcut(for: .globalSearch)
            XCTAssertEqual(
                restored.shortcut(for: .globalSearch),
                NativeCommandShortcut(key: "f", modifiers: [.command, .shift])
            )
        }
    }

    func testMomentFeedTimestampBatchStaysResponsive() {
        let timestamps = (0..<48).map { second in
            String(format: "2026-08-23T10:00:%02d.123Z", second)
        }
        let start = ProcessInfo.processInfo.systemUptime

        for _ in 0..<12 {
            for timestamp in timestamps {
                guard let date = NativeTimestamp.date(from: timestamp) else {
                    XCTFail("expected a valid timestamp")
                    return
                }
                _ = NativeTimestamp.string(from: date)
            }
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertTrue(
            elapsed < 0.12,
            "moment-feed timestamp derivation took \(elapsed) seconds"
        )
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
            NativeArticleLink.references(in: "先看 [[路线图#目标|规划]]，再看 [[hello-world]]，忽略 ![[图片.png]]。"),
            ["路线图", "hello-world"]
        )

        let articles = try JSONDecoder().decode(
            [NativeArticleSummary].self,
            from: Data("""
            [{
              "aliases": ["Road Map"],
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

        XCTAssertEqual(articles.first?.pageViews, 0)
        XCTAssertEqual(articles.first?.aliases, ["Road Map"])
        XCTAssertEqual(
            NativeArticleLink.Reference(rawValue: "路线图#目标|规划"),
            NativeArticleLink.Reference(rawValue: " 路线图#目标 | 规划 ")
        )
        XCTAssertEqual(NativeArticleLink.resolve("路线图", in: articles)?.slug, "roadmap")
        XCTAssertEqual(NativeArticleLink.resolve("路线图#目标|规划", in: articles)?.slug, "roadmap")
        XCTAssertEqual(NativeArticleLink.resolve("ROADMAP", in: articles)?.title, "路线图")
        XCTAssertEqual(NativeArticleLink.resolve("road map#目标", in: articles)?.slug, "roadmap")
        XCTAssertNil(NativeArticleLink.resolve("不存在", in: articles))
        XCTAssertEqual(
            NativeArticleLink.destination(for: "不存在#开端|新文", in: articles),
            NativeArticleLinkDestination(
                target: "不存在",
                resolvedSlug: nil,
                heading: "开端",
                label: "新文"
            )
        )
        XCTAssertEqual(
            NativeArticleLink.destination(for: "#目标", in: articles)?.heading,
            "目标"
        )

        let converted = NativeArticleLink.linkingUnlinkedMentions(
            of: "基础",
            to: "foundation",
            in: "基础正文；[[基础]]、`基础` 和 [基础](https://example.com) 不变。\n```\n基础\n```"
        )
        XCTAssertEqual(converted.count, 1)
        XCTAssertTrue(converted.body.hasPrefix("[[foundation|基础]]正文"))
        XCTAssertTrue(converted.body.contains("[[基础]]、`基础`"))
        XCTAssertTrue(converted.body.contains("[基础](https://example.com)"))
    }

    func testArticleEmbedsSelectWholeNotesHeadingsAndBlocks() {
        let body = """
        导言

        ## 方案

        第一段 ^decision

        - 条目一
        - 条目二
        ^list-block

        ## 结论

        完成
        """
        XCTAssertEqual(NativeArticleEmbed.fragment(in: body), body)
        XCTAssertEqual(
            NativeArticleEmbed.fragment(in: body, selector: "方案"),
            "第一段 ^decision\n\n- 条目一\n- 条目二\n^list-block"
        )
        XCTAssertEqual(NativeArticleEmbed.fragment(in: body, selector: "^decision"), "第一段")
        XCTAssertEqual(NativeArticleEmbed.fragment(in: body, selector: "^list-block"), "- 条目一\n- 条目二")
        XCTAssertNil(NativeArticleEmbed.fragment(in: body, selector: "^missing"))
    }

    func testArticleTabMaintainsIndependentBackAndForwardHistory() throws {
        var tab = NativeArticleTab(slug: "one", isPinned: true)
        tab.navigate(to: "two")
        tab.navigate(to: "three")

        XCTAssertTrue(tab.canGoBack)
        XCTAssertFalse(tab.canGoForward)
        XCTAssertEqual(tab.goBack(), "two")
        XCTAssertEqual(tab.slug, "two")
        XCTAssertTrue(tab.canGoForward)
        XCTAssertEqual(tab.goForward(), "three")

        XCTAssertEqual(tab.goBack(), "two")
        tab.navigate(to: "four")
        XCTAssertEqual(tab.slug, "four")
        XCTAssertFalse(tab.canGoForward, "a new navigation should clear forward history")

        let restored = try JSONDecoder().decode(
            NativeArticleTab.self,
            from: JSONEncoder().encode(tab)
        )
        XCTAssertEqual(restored, tab)
        XCTAssertTrue(restored.isPinned)
    }

    func testArticleCommentSelectionAnchorsToNearestHeading() {
        let markdown = """
        开场内容。

        ## 第一节
        这里有 **需要讨论** 的结论。

        ## 第二节
        其他内容。
        """
        let selection = NativeArticleCommentAnchor.selection(for: "需要讨论", in: markdown)
        XCTAssertEqual(selection?.quote, "需要讨论")
        XCTAssertEqual(selection?.anchorID, "markdown-heading-0")

        let introduction = NativeArticleCommentAnchor.selection(for: "开场内容", in: markdown)
        XCTAssertEqual(introduction?.anchorID, NativeArticleCommentAnchor.articleTopID)
        XCTAssertNil(NativeArticleCommentAnchor.selection(for: "   ", in: markdown))
    }

    func testArticleLineDiffMarksAddedAndRemovedLines() {
        let diff = NativeArticleLineDiff(
            previous: "第一行\n旧内容\n保留",
            current: "第一行\n新内容\n保留\n新增"
        )

        XCTAssertEqual(diff.removedLineOffsets, [1])
        XCTAssertEqual(diff.addedLineOffsets, [1, 3])
        XCTAssertFalse(diff.isEmpty)
        XCTAssertTrue(NativeArticleLineDiff(previous: "相同", current: "相同").isEmpty)
    }

    func testLegacyRevisionSnapshotDefaultsObsidianProperties() throws {
        let snapshot = try JSONDecoder().decode(
            NativeArticleRevisionSnapshot.self,
            from: Data(#"{"body":"旧正文","category":"Notes","excerpt":"","media":[],"status":"draft","tags":[],"title":"旧版本","articleUpdatedAt":null}"#.utf8)
        )
        XCTAssertEqual(snapshot.properties, [:])
        XCTAssertEqual(snapshot.body, "旧正文")
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

    func testGlobalSearchQueryParsesPhrasesAndFilters() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let query = NativeGlobalSearchQuery(
            #""离线 知识库" tag:#Swift status:草稿 type:文章 date:2026-08-23"#,
            calendar: calendar
        )

        XCTAssertEqual(query.textTerms, ["离线 知识库"])
        XCTAssertEqual(query.tags, ["Swift"])
        XCTAssertEqual(query.status, .draft)
        XCTAssertEqual(query.types, [.article])
        XCTAssertTrue(query.propertyFilters.isEmpty)
        XCTAssertEqual(query.after, calendar.date(from: DateComponents(year: 2026, month: 8, day: 23)))
        XCTAssertEqual(query.before, calendar.date(from: DateComponents(year: 2026, month: 8, day: 24)))

        let fallback = NativeGlobalSearchQuery("unknown:value")
        XCTAssertEqual(fallback.textTerms, ["unknown:value"])
        XCTAssertEqual(NativeGlobalSearchQuery("date:2026-02-31").textTerms, ["date:2026-02-31"])

        let propertyQuery = NativeGlobalSearchQuery(#"[review status:in progress] [rating:4.5]"#)
        XCTAssertEqual(propertyQuery.propertyFilters, [
            NativeArticlePropertyFilter(key: "review status", value: "in progress"),
            NativeArticlePropertyFilter(key: "rating", value: "4.5"),
        ])
        XCTAssertTrue(propertyQuery.textTerms.isEmpty)
    }

    func testTypedArticlePropertiesDecodeLegacyValuesValidateAndRename() throws {
        let legacy = #"{"aliases":"[\"Idea Board\"]","rating":"4.5","reviewed":"true","due":"2026-08-24"}"#
        let decoded = try JSONDecoder().decode(
            [String: NativeArticlePropertyValue].self,
            from: Data(legacy.utf8)
        )
        XCTAssertEqual(decoded["aliases"]?.kind, .list)
        XCTAssertEqual(decoded["aliases"]?.listValues, ["Idea Board"])
        XCTAssertEqual(decoded["rating"]?.kind, .number)
        XCTAssertEqual(decoded["reviewed"]?.kind, .checkbox)
        XCTAssertEqual(decoded["due"]?.kind, .date)
        XCTAssertEqual(
            NativeArticlePropertyValue.fromYAML(#"[alpha, "beta gamma"]"#).listValues,
            ["alpha", "beta gamma"]
        )

        let properties: [String: NativeArticlePropertyValue] = [
            "rating": .number(4.5),
            "topics": .tags(["Swift", "SQLite"]),
            "published": .checkbox(true),
        ]
        let renamed = try NativeArticleProperties.renaming("topics", to: "技术标签", in: properties)
        XCTAssertNil(renamed["topics"])
        XCTAssertEqual(renamed["技术标签"]?.listValues, ["Swift", "SQLite"])
        do {
            _ = try NativeArticleProperties.renaming("rating", to: "published", in: properties)
            XCTFail("renaming onto a different existing value should fail")
        } catch {
            XCTAssertEqual(error as? NativeArticlePropertyError, .destinationExists("published"))
        }

        let roundTrip = try JSONDecoder().decode(
            [String: NativeArticlePropertyValue].self,
            from: JSONEncoder().encode(renamed)
        )
        XCTAssertEqual(roundTrip, renamed)
    }

    func testSmartCollectionCombinesPropertiesDatesAndMultiSort() {
        let source = [
            smartCollectionArticle(
                slug: "older",
                title: "Alpha",
                status: .published,
                category: "Research",
                updatedAt: "2026-08-10T00:00:00Z",
                pageViews: 30,
                properties: ["rating": "5"]
            ),
            smartCollectionArticle(
                slug: "newer",
                title: "Beta",
                status: .published,
                category: "Research",
                updatedAt: "2026-08-20T00:00:00Z",
                pageViews: 50,
                properties: ["rating": "5"]
            ),
            smartCollectionArticle(
                slug: "draft",
                title: "Gamma",
                status: .draft,
                category: "Research",
                updatedAt: "2026-08-22T00:00:00Z",
                pageViews: 80,
                properties: ["rating": "5"]
            ),
        ]
        let collection = NativeSmartCollection(
            name: "近期研究",
            rules: [
                NativeSmartCollectionRule(field: .status, comparison: .equals, value: "published"),
                NativeSmartCollectionRule(field: .category, comparison: .equals, value: "research"),
                NativeSmartCollectionRule(field: .property, comparison: .equals, value: "5", propertyKey: "rating"),
                NativeSmartCollectionRule(field: .updatedAt, comparison: .after, value: "2026-08-01"),
            ],
            sorts: [
                NativeArticleSortDescriptor(field: .pageViews, ascending: false),
                NativeArticleSortDescriptor(field: .title, ascending: true),
            ],
            groupBy: .category,
            layout: .table
        )

        let result = NativeSmartCollectionEvaluator.articles(from: source, matching: collection)
        XCTAssertEqual(result.map(\.slug), ["newer", "older"])
    }

    func testBaseFormulasCalculatePropertiesDatesAndSummaries() {
        let now = NativeTimestamp.date(from: "2026-08-24T12:00:00Z")!
        let first = NativeArticleSummary(
            banner: nil,
            category: "Books",
            excerpt: "",
            properties: [
                "price": .number(12.5),
                "months": .number(4),
                "due date": .date("2026-08-20"),
            ],
            publishedAt: nil,
            slug: "first",
            status: .draft,
            tags: [],
            title: "第一本",
            updatedAt: "2026-08-24T00:00:00Z",
            wordCount: 10
        )
        let second = NativeArticleSummary(
            banner: nil,
            category: "Books",
            excerpt: "",
            properties: ["price": .number(7.5), "months": .number(2)],
            publishedAt: nil,
            slug: "second",
            status: .draft,
            tags: [],
            title: "第二本",
            updatedAt: "2026-08-23T00:00:00Z",
            wordCount: 10
        )
        let collection = NativeSmartCollection(
            name: "阅读",
            columns: [
                NativeSmartCollectionColumn(source: .formula, key: "cost", title: "总价", summary: .sum),
                NativeSmartCollectionColumn(source: .formula, key: "overdue", title: "逾期天数"),
                NativeSmartCollectionColumn(source: .formula, key: "state", title: "状态"),
            ],
            formulas: [
                NativeSmartCollectionFormula(key: "cost", name: "总价", expression: "price * months"),
                NativeSmartCollectionFormula(key: "overdue", name: "逾期", expression: "today() - prop(\"due date\")"),
                NativeSmartCollectionFormula(key: "state", name: "状态", expression: "if(formula.overdue > 0, \"late\", \"ok\")"),
            ]
        )
        XCTAssertEqual(
            NativeSmartCollectionFormulaEngine.formulaValue("cost", article: first, collection: collection, now: now),
            .number(50)
        )
        XCTAssertEqual(
            NativeSmartCollectionFormulaEngine.formulaValue("overdue", article: first, collection: collection, now: now),
            .number(4)
        )
        XCTAssertEqual(
            NativeSmartCollectionFormulaEngine.formulaValue("state", article: first, collection: collection, now: now),
            .string("late")
        )
        XCTAssertEqual(
            NativeSmartCollectionFormulaEngine.summary(
                .sum,
                column: collection.columns[0],
                articles: [first, second],
                collection: collection,
                now: now
            ),
            .number(65)
        )
    }

    func testArticleGraphProjectionFiltersOrphansAndClipsByDegree() {
        var nodes: [NativeArticleSummary] = []
        for index in 0..<12 {
            let title = index == 0 ? "Roadmap" : "Note \(index)"
            let status: NativeArticleStatus = index == 11 ? .draft : .published
            let aliases = index == 0 ? ["路线图"] : []
            nodes.append(graphArticle(
                slug: "note-\(index)",
                title: title,
                status: status,
                aliases: aliases,
                updatedAt: String(format: "2026-08-%02dT00:00:00Z", index + 1)
            ))
        }
        let edges = (1..<11).map { NativeArticleGraphEdge(sourceSlug: "note-0", targetSlug: "note-\($0)") }
        let source = NativeArticleGraph(nodes: nodes, edges: edges)

        let connected = NativeArticleGraphProjector.project(
            source,
            query: NativeArticleGraphQuery(includesOrphans: false, nodeLimit: 10)
        )
        XCTAssertEqual(connected.matchingNodeCount, 11)
        XCTAssertEqual(connected.graph.nodes.count, 10)
        XCTAssertEqual(connected.graph.nodes.first?.slug, "note-0")
        XCTAssertEqual(connected.clippedNodeCount, 1)
        let visibleSlugs = Set(connected.graph.nodes.map { $0.slug })
        XCTAssertTrue(connected.graph.edges.allSatisfy {
            visibleSlugs.contains($0.sourceSlug) && visibleSlugs.contains($0.targetSlug)
        })

        let aliasMatch = NativeArticleGraphProjector.project(
            source,
            query: NativeArticleGraphQuery(searchText: "路线图", status: .published)
        )
        XCTAssertEqual(aliasMatch.graph.nodes.map { $0.slug }, ["note-0"])

        let drafts = NativeArticleGraphProjector.project(
            source,
            query: NativeArticleGraphQuery(status: .draft)
        )
        XCTAssertEqual(drafts.graph.nodes.map { $0.slug }, ["note-11"])
    }
}

private final class NativeImageDecodeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var invocationCount = 0
    private var activeCount = 0
    private var peakActiveCount = 0

    func decode(url: URL, mode: NativeImageLoadMode) -> NSImage? {
        lock.lock()
        invocationCount += 1
        activeCount += 1
        peakActiveCount = max(peakActiveCount, activeCount)
        lock.unlock()

        usleep(35_000)

        lock.lock()
        activeCount -= 1
        lock.unlock()
        return NSImage(size: NSSize(width: 32, height: 32))
    }

    var counts: (invocations: Int, peakActive: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (invocationCount, peakActiveCount)
    }
}

final class PerformanceRegressionTests {
    @MainActor
    func testEditorSessionOwnsHighFrequencyDraftState() {
        let session = NativeEditorSessionState()

        session.draft.body = "typed without invalidating the whole app model"
        session.bodySelection = NSRange(location: 5, length: 3)
        session.autosaveStatus = "等待自动保存…"

        XCTAssertEqual(session.draft.body, "typed without invalidating the whole app model")
        XCTAssertEqual(session.bodySelection, NSRange(location: 5, length: 3))
        XCTAssertEqual(session.autosaveStatus, "等待自动保存…")
    }

    func testMarkdownRefreshPlanSkipsUnrelatedDomains() {
        let update = NativeMarkdownSyncResult(
            updatedCount: 1,
            affectedArticleSlugs: ["first-note"]
        )
        let updatePlan = NativeMarkdownRefreshPlan(
            result: update,
            selectedArticleSlug: "first-note"
        )

        XCTAssertTrue(updatePlan.reloadsArticleList)
        XCTAssertTrue(updatePlan.reloadsSelectedArticle)
        XCTAssertTrue(updatePlan.reloadsSelectedSmartCollection)
        XCTAssertTrue(updatePlan.reloadsKnowledgeGraph)
        XCTAssertFalse(updatePlan.reloadsTrash)
        XCTAssertFalse(updatePlan.reloadsMoments)
        XCTAssertFalse(updatePlan.reloadsQuestions)
        XCTAssertFalse(updatePlan.reloadsActivity)

        let deletionPlan = NativeMarkdownRefreshPlan(
            result: NativeMarkdownSyncResult(
                deletedCount: 1,
                affectedArticleSlugs: ["deleted-note"]
            ),
            selectedArticleSlug: nil
        )
        XCTAssertTrue(deletionPlan.reloadsTrash)
        XCTAssertFalse(deletionPlan.reloadsSelectedArticle)
    }

    func testMarkdownLiveStylingLimitsOrdinaryEditsToNearbyParagraphs() {
        let source = (0..<1_000).map { "paragraph \($0) with **markdown**" }
            .joined(separator: "\n")
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        let editRange = (source as NSString).range(of: "paragraph 500")
        let styledRange = NativeMarkdownLiveStyler.stylingRange(
            in: source,
            editedRange: editRange
        )

        XCTAssertTrue(NSIntersectionRange(styledRange, editRange).length == editRange.length)
        XCTAssertTrue(styledRange.length < fullRange.length / 20)
        XCTAssertEqual(
            NativeMarkdownLiveStyler.stylingRange(in: source, editedRange: nil),
            fullRange
        )

        let fencedSource = """
        before
        ```swift
        let first = 1
        let second = 2
        let third = 3
        let fourth = 4
        let fifth = 5
        ```
        after
        """
        let fencedEdit = (fencedSource as NSString).range(of: "let third = 3")
        let fencedRange = NativeMarkdownLiveStyler.stylingRange(
            in: fencedSource,
            editedRange: fencedEdit
        )
        XCTAssertTrue((fencedSource as NSString).substring(with: fencedRange).contains("```swift"))
        XCTAssertTrue((fencedSource as NSString).substring(with: fencedRange).contains("let fifth = 5"))
    }

    func testArticleMarkdownAnalysisIsCachedAndSharedAcrossConsumers() {
        let markdown = """
        # Overview

        ![Cover](/media/cover.png)

        ## Details

        ![[assets/diagram.jpg]]
        """
        let first = NativeMarkdownArticleDocumentCache.shared.document(for: markdown)
        let second = NativeMarkdownArticleDocumentCache.shared.document(for: markdown)

        XCTAssertTrue(first === second)
        XCTAssertEqual(first.outline.map(\.title), ["Overview", "Details"])
        XCTAssertEqual(first.imageURLs, ["/media/cover.png", "assets/diagram.jpg"])
    }

    func testSharedImagePipelineCoalescesRequestsAndCapsDecodeConcurrency() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let duplicateURL = root.appendingPathComponent("duplicate.png")
        try Data([0]).write(to: duplicateURL)
        let duplicateProbe = NativeImageDecodeProbe()
        let duplicatePipeline = NativeImagePipeline(
            maximumConcurrentDecodes: 2,
            decoder: { [duplicateProbe] url, mode in
                duplicateProbe.decode(url: url, mode: mode)
            }
        )

        async let first = duplicatePipeline.image(
            from: duplicateURL,
            mode: .thumbnail(maxPixelSize: 480)
        )
        async let second = duplicatePipeline.image(
            from: duplicateURL,
            mode: .thumbnail(maxPixelSize: 480)
        )
        let duplicateResults = await (first, second)
        XCTAssertNotNil(duplicateResults.0.image)
        XCTAssertNotNil(duplicateResults.1.image)
        XCTAssertEqual(duplicateProbe.counts.invocations, 1)

        let concurrencyProbe = NativeImageDecodeProbe()
        let concurrencyPipeline = NativeImagePipeline(
            maximumConcurrentDecodes: 2,
            decoder: { [concurrencyProbe] url, mode in
                concurrencyProbe.decode(url: url, mode: mode)
            }
        )
        let urls = try (0..<6).map { index -> URL in
            let url = root.appendingPathComponent("image-\(index).png")
            try Data([UInt8(index)]).write(to: url)
            return url
        }
        let loadedCount = await withTaskGroup(of: Bool.self) { group -> Int in
            for url in urls {
                group.addTask {
                    await concurrencyPipeline.image(
                        from: url,
                        mode: .thumbnail(maxPixelSize: 480)
                    ).image != nil
                }
            }
            var loaded = 0
            for await didLoad in group where didLoad { loaded += 1 }
            return loaded
        }

        XCTAssertEqual(loadedCount, urls.count)
        XCTAssertEqual(concurrencyProbe.counts.invocations, urls.count)
        XCTAssertTrue(concurrencyProbe.counts.peakActive <= 2)
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

    func testQuestionAnswersAndTagSearchPersistInSQLite() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)

        let first = try await store.saveQuestion(
            title: "如何设计 SwiftUI 本地应用？",
            body: "希望数据保存在 SQLite 中。",
            tags: [" SwiftUI ", "macOS", "swiftui"]
        )
        let second = try await store.saveQuestion(
            title: "SQLite 索引如何选择？",
            body: "需要支持标签检索。",
            tags: ["SQLite", "性能"]
        )

        XCTAssertEqual(first.tags, ["SwiftUI", "macOS"])
        XCTAssertEqual(try await store.countQuestions(), 2)
        XCTAssertEqual(
            try await store.listQuestions(tag: "MACOS").map(\.id),
            [first.id]
        )
        XCTAssertEqual(
            try await store.listQuestions(searchText: "sqlite").map(\.id),
            [second.id, first.id]
        )
        XCTAssertEqual(
            try await store.listQuestions(searchText: "性能").map(\.id),
            [second.id]
        )

        let answer = try await store.saveQuestionAnswer(
            questionID: first.id,
            body: "先划清状态和持久化边界，再设计界面。",
            images: [NativeMedia(
                kind: "image",
                name: "diagram.png",
                size: 128,
                url: "media/question-answers/diagram.png"
            )]
        )
        XCTAssertEqual(answer.images.map(\.url), ["/media/question-answers/diagram.png"])
        let imageOnlyAnswer = try await store.saveQuestionAnswer(
            questionID: first.id,
            body: "  ",
            images: [NativeMedia(
                kind: "image",
                name: "screenshot.png",
                size: 256,
                url: "/media/question-answers/screenshot.png"
            )]
        )
        let editedAnswer = try await store.updateQuestionAnswer(
            id: answer.id,
            body: "## 更新后的回答\n\n- 支持 **Markdown**\n- 支持图片",
            images: [NativeMedia(
                kind: "image",
                name: "edited.png",
                size: 512,
                url: "/media/question-answers/edited.png"
            )],
            expectedUpdatedAt: answer.updatedAt
        )
        XCTAssertEqual(editedAnswer.id, answer.id)
        XCTAssertEqual(editedAnswer.createdAt, answer.createdAt)
        XCTAssertTrue(editedAnswer.body.contains("**Markdown**"))
        XCTAssertEqual(editedAnswer.images.map(\.name), ["edited.png"])
        XCTAssertEqual(
            try await store.listQuestionAnswers(questionID: first.id),
            [editedAnswer, imageOnlyAnswer]
        )
        XCTAssertEqual(try await store.getQuestion(id: first.id).answerCount, 2)

        do {
            _ = try await store.updateQuestionAnswer(
                id: answer.id,
                body: "过期修改",
                expectedUpdatedAt: answer.updatedAt
            )
            XCTFail("updating an answer with a stale timestamp should fail")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "这条回答已在其他窗口中更新，请重新载入后再编辑。"
            )
        }
        XCTAssertEqual(try await store.listQuestions().first?.id, first.id)
        XCTAssertTrue(try await store.listQuestionTagFacets().contains {
            $0.tag == "SwiftUI" && $0.count == 1
        })
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

    func testSavingImportedMarkdownPreservesUnchangedFrontmatterSource() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let articlesURL = root.appendingPathComponent("articles", isDirectory: true)
        try FileManager.default.createDirectory(at: articlesURL, withIntermediateDirectories: true)
        let sourceURL = articlesURL.appendingPathComponent("lossless-note.md")
        let source = """
        ---
        # identity comment
        title: 'Original title' # keep title comment
        aliases:
          - "First Alias" # keep list comment
          - Second Alias
        cssclasses: [wide-page] # keep property comment
        rating: 5
        slug: lossless-note
        status: draft
        ---
        Original body
        """
        try Data(source.utf8).write(to: sourceURL, options: .atomic)

        let store = LocalBlogStore(rootURL: root)
        _ = try await store.refreshMarkdownSources()
        let imported = try await store.getArticle(slug: "lossless-note")
        _ = try await store.saveArticle(NativeSaveArticle(
            banner: imported.banner,
            body: "Changed body",
            category: imported.category,
            excerpt: imported.excerpt,
            media: imported.media,
            slug: imported.slug,
            status: imported.status,
            tags: imported.tags,
            title: "Changed title",
            expectedUpdatedAt: imported.updatedAt,
            properties: imported.properties
        ))

        let savedSource = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(savedSource.contains("# identity comment"))
        XCTAssertTrue(savedSource.contains("title: 'Changed title' # keep title comment"))
        XCTAssertTrue(savedSource.contains("""
        aliases:
          - "First Alias" # keep list comment
          - Second Alias
        cssclasses: [wide-page] # keep property comment
        rating: 5
        slug: lossless-note
        status: draft
        """))
        XCTAssertTrue(savedSource.hasSuffix("---\nChanged body"))
    }

    func testSavingObsidianFixturePreservesBlockListStyleAndLineEndings() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let articlesURL = root.appendingPathComponent("articles", isDirectory: true)
        try FileManager.default.createDirectory(at: articlesURL, withIntermediateDirectories: true)
        guard let fixturesURL = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            XCTFail("Obsidian compatibility fixtures should be bundled")
            return
        }
        let fixtureURL = fixturesURL.appendingPathComponent("ObsidianVault/Round Trip Styles.md")
        let fixture = try String(contentsOf: fixtureURL, encoding: .utf8)
        let windowsFixture = "\u{feff}" + fixture.replacingOccurrences(of: "\n", with: "\r\n")
        let sourceURL = articlesURL.appendingPathComponent("round-trip-styles.md")
        try Data(windowsFixture.utf8).write(to: sourceURL, options: .atomic)

        let store = LocalBlogStore(rootURL: root)
        _ = try await store.refreshMarkdownSources()
        let imported = try await store.getArticle(slug: "round-trip-styles")
        _ = try await store.saveArticle(NativeSaveArticle(
            banner: imported.banner,
            body: "Changed fixture body",
            category: imported.category,
            excerpt: imported.excerpt,
            media: imported.media,
            slug: imported.slug,
            status: imported.status,
            tags: ["swift", "pkm"],
            title: imported.title,
            expectedUpdatedAt: imported.updatedAt,
            properties: imported.properties
        ))

        let savedData = try Data(contentsOf: sourceURL)
        guard let savedSource = String(data: savedData, encoding: .utf8) else {
            XCTFail("saved Obsidian fixture should remain UTF-8")
            return
        }
        XCTAssertEqual(
            Array(savedData.prefix(3)),
            [0xEF, 0xBB, 0xBF],
            "UTF-8 BOM should survive"
        )
        XCTAssertFalse(
            savedSource.replacingOccurrences(of: "\r\n", with: "").contains("\n"),
            "CRLF line endings should survive"
        )
        let normalized = savedSource
            .replacingOccurrences(of: "\u{feff}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
        XCTAssertTrue(normalized.contains("""
        tags:
          - swift
          - pkm # subject
        aliases:
          - "Knowledge Base"
        """), "changed tags should retain Obsidian block-list source style")
        XCTAssertTrue(normalized.contains("""
        cssclasses: [wide-page] # layout
        summary: >-
          First summary line.
          Second summary line.
        slug: round-trip-styles
        status: draft
        """), "unchanged folded properties and comments should survive")
        XCTAssertTrue(normalized.contains("\n...\n"), "the YAML document-end marker should survive")
        XCTAssertTrue(normalized.hasSuffix("Changed fixture body\n"), "trailing newline should survive")
    }

    func testEditingObsidianFoldedPropertyPreservesBlockScalarStyle() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let articlesURL = root.appendingPathComponent("articles", isDirectory: true)
        try FileManager.default.createDirectory(at: articlesURL, withIntermediateDirectories: true)
        guard let fixturesURL = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            XCTFail("Obsidian compatibility fixtures should be bundled")
            return
        }
        let fixtureURL = fixturesURL.appendingPathComponent("ObsidianVault/Round Trip Styles.md")
        let sourceURL = articlesURL.appendingPathComponent("round-trip-styles.md")
        try Data(contentsOf: fixtureURL).write(to: sourceURL, options: .atomic)

        let store = LocalBlogStore(rootURL: root)
        _ = try await store.refreshMarkdownSources()
        let imported = try await store.getArticle(slug: "round-trip-styles")
        var properties = imported.properties
        properties["summary"] = .text("Changed first line.\nChanged second line.")
        _ = try await store.saveArticle(NativeSaveArticle(
            banner: imported.banner,
            body: imported.body,
            category: imported.category,
            excerpt: imported.excerpt,
            media: imported.media,
            slug: imported.slug,
            status: imported.status,
            tags: imported.tags,
            title: imported.title,
            expectedUpdatedAt: imported.updatedAt,
            properties: properties
        ))

        let savedSource = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(savedSource.contains("""
        summary: >-
          Changed first line.
          Changed second line.
        slug: round-trip-styles
        """), "edited folded properties should retain their YAML block-scalar style")
    }

    func testIncrementalMarkdownRefreshReadsChangedFilesAndHandlesDeletion() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let first = try await store.saveArticle(article(
            slug: "first-note",
            status: .draft,
            expectedUpdatedAt: nil,
            body: "first body",
            title: "First"
        ))
        let second = try await store.saveArticle(article(
            slug: "second-note",
            status: .draft,
            expectedUpdatedAt: nil,
            body: "second body",
            title: "Second"
        ))
        let articlesURL = root.appendingPathComponent("articles", isDirectory: true)
        let externalFirst = """
        ---
        title: First externally edited
        slug: first-note
        status: draft
        ---
        changed body
        """
        try Data(externalFirst.utf8).write(
            to: articlesURL.appendingPathComponent(first.sourceRelativePath),
            options: .atomic
        )

        let updated = try await store.refreshMarkdownSources(
            changedRelativePaths: [first.sourceRelativePath]
        )
        XCTAssertEqual(updated.updatedCount, 1)
        XCTAssertEqual(updated.affectedArticleSlugs, [first.slug])
        XCTAssertEqual(try await store.getArticle(slug: first.slug).body, "changed body")
        XCTAssertEqual(try await store.getArticle(slug: second.slug).body, "second body")

        let inboxURL = articlesURL.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        try Data("# New nested note\n\nnested body".utf8).write(
            to: inboxURL.appendingPathComponent("nested.md")
        )
        let inserted = try await store.refreshMarkdownSources(
            changedRelativePaths: [],
            changedDirectoryPrefixes: ["inbox"]
        )
        XCTAssertEqual(inserted.insertedCount, 1)
        XCTAssertEqual(inserted.affectedArticleSlugs.count, 1)
        XCTAssertTrue(try await store.listArticles().contains {
            guard $0.sourceRelativePath == "inbox/nested.md" else { return false }
            XCTAssertEqual(inserted.affectedArticleSlugs, [$0.slug])
            return true
        })

        try FileManager.default.removeItem(
            at: articlesURL.appendingPathComponent(second.sourceRelativePath)
        )
        let deleted = try await store.refreshMarkdownSources(
            changedRelativePaths: [second.sourceRelativePath]
        )
        XCTAssertEqual(deleted.deletedCount, 1)
        XCTAssertEqual(deleted.affectedArticleSlugs, [second.slug])
        XCTAssertFalse(try await store.listArticles().contains { $0.slug == second.slug })
    }

    func testIncrementalMarkdownRefreshPreservesIdentityAcrossRename() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let saved = try await store.saveArticle(article(
            slug: "rename-me",
            status: .draft,
            expectedUpdatedAt: nil,
            body: "stable content",
            title: "Rename me"
        ))
        let articlesURL = root.appendingPathComponent("articles", isDirectory: true)
        let destinationPath = "archive/renamed.md"
        let destinationURL = articlesURL.appendingPathComponent(destinationPath)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(
            at: articlesURL.appendingPathComponent(saved.sourceRelativePath),
            to: destinationURL
        )

        let result = try await store.refreshMarkdownSources(
            changedRelativePaths: [saved.sourceRelativePath, destinationPath]
        )
        XCTAssertEqual(result.movedCount, 1)
        XCTAssertEqual(try await store.getArticle(slug: saved.slug).sourceRelativePath, destinationPath)
        XCTAssertEqual(try await store.listArticles().map(\.slug), [saved.slug])
    }

    func testArticleAutosavesRollWithinFiveMinutesAndCreateHistoryBuckets() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let start = Date(timeIntervalSince1970: 1_787_450_000)

        let first = try await store.saveArticleAutosave(
            draftKey: "draft-recovery",
            articleSlug: nil,
            snapshot: revisionSnapshot(body: "第一版"),
            at: start
        )
        let rolled = try await store.saveArticleAutosave(
            draftKey: "draft-recovery",
            articleSlug: nil,
            snapshot: revisionSnapshot(body: "第二版"),
            at: start.addingTimeInterval(20)
        )
        let nextBucket = try await store.saveArticleAutosave(
            draftKey: "draft-recovery",
            articleSlug: nil,
            snapshot: revisionSnapshot(body: "第三版"),
            at: start.addingTimeInterval(301)
        )

        XCTAssertEqual(first.id, rolled.id)
        XCTAssertFalse(nextBucket.id == first.id)
        let orphan = try await store.latestUnsavedArticleAutosave()
        XCTAssertEqual(orphan?.snapshot.body, "第三版")

        try await store.attachArticleRevisions(draftKey: "draft-recovery", toArticleSlug: "saved-note")
        let history = try await store.listArticleRevisions(
            articleSlug: "saved-note",
            draftKey: "draft-recovery"
        )
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.map(\.snapshot.body), ["第三版", "第二版"])
        XCTAssertEqual(try await store.latestArticleAutosave(articleSlug: "saved-note")?.snapshot.body, "第三版")
    }

    func testManualArticleSaveKeepsThePreviousVersion() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let original = try await store.saveArticle(article(
            slug: "versioned",
            status: .draft,
            expectedUpdatedAt: nil,
            body: "保存前"
        ))

        _ = try await store.saveArticle(article(
            slug: original.slug,
            status: .draft,
            expectedUpdatedAt: original.updatedAt,
            body: "保存后"
        ))

        let history = try await store.listArticleRevisions(
            articleSlug: original.slug,
            draftKey: original.slug
        )
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.reason, .savedVersion)
        XCTAssertEqual(history.first?.snapshot.body, "保存前")
    }

    func testArticleRelationsResolveAndDeduplicateWikiLinks() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)

        let linked = try await store.saveArticle(NativeSaveArticle(
            banner: nil,
            body: "## 目标\n想法正文",
            category: "Notes",
            excerpt: "",
            media: [],
            slug: "idea",
            status: .published,
            tags: [],
            title: "想法",
            expectedUpdatedAt: nil,
            properties: ["aliases": .list(["Idea Board"])]
        ))
        let current = try await store.saveArticle(article(
            slug: "foundation",
            status: .published,
            expectedUpdatedAt: nil,
            body: "参见 [[想法]]、[[idea]]、[[Idea Board#目标|计划]] 和 [[不存在]]。",
            title: "基础"
        ))
        let titleBacklink = try await store.saveArticle(article(
            slug: "by-title",
            status: .draft,
            expectedUpdatedAt: nil,
            body: "来自 [[基础]] 的引用",
            title: "按标题引用"
        ))
        let slugBacklink = try await store.saveArticle(article(
            slug: "by-slug",
            status: .published,
            expectedUpdatedAt: nil,
            body: "来自 [[foundation]] 的引用",
            title: "按地址引用"
        ))
        let unlinkedMention = try await store.saveArticle(article(
            slug: "plain-mention",
            status: .published,
            expectedUpdatedAt: nil,
            body: "这里直接讨论基础的设计原则，`基础` 与 [基础](https://example.com) 不计；稍后还会继续补充基础内容。",
            title: "未链接讨论"
        ))

        let relations = try await store.articleRelations(for: current.slug)
        XCTAssertEqual(relations.outgoing.map(\.slug), [linked.slug])
        XCTAssertEqual(Set(relations.incoming.map(\.slug)), Set([titleBacklink.slug, slugBacklink.slug]))
        XCTAssertEqual(relations.unlinkedMentions.map(\.article.slug), [unlinkedMention.slug])
        XCTAssertEqual(relations.unlinkedMentions.first?.count, 2)
        XCTAssertTrue(relations.unlinkedMentions.first?.snippet.contains("基础") == true)
        XCTAssertEqual(
            try await store.articleRelations(for: linked.slug).incoming.map(\.slug),
            [current.slug],
            "indexed backlink candidates should deduplicate title, slug, and alias references"
        )

        let graph = try await store.articleGraph()
        XCTAssertEqual(
            Set(graph.nodes.map(\.slug)),
            Set([linked.slug, current.slug, titleBacklink.slug, slugBacklink.slug, unlinkedMention.slug])
        )
        XCTAssertEqual(
            Set(graph.edges.map(\.id)),
            Set(["foundation->idea", "by-title->foundation", "by-slug->foundation"])
        )

        let converted = try await store.convertUnlinkedMention(
            sourceSlug: unlinkedMention.slug,
            targetSlug: current.slug,
            expectedUpdatedAt: unlinkedMention.updatedAt
        )
        XCTAssertEqual(converted.body.components(separatedBy: "[[foundation|基础]]").count - 1, 2)
        XCTAssertTrue(converted.body.contains("`基础`"))
        XCTAssertTrue(converted.body.contains("[基础](https://example.com)"))
        XCTAssertTrue(try await store.articleRelations(for: current.slug).unlinkedMentions.isEmpty)
        XCTAssertTrue(
            try await store.articleGraph().edges.contains(where: {
                $0.sourceSlug == unlinkedMention.slug && $0.targetSlug == current.slug
            }),
            "saving one changed body should update its graph edges without rebuilding the vault"
        )
        do {
            _ = try await store.convertUnlinkedMention(
                sourceSlug: unlinkedMention.slug,
                targetSlug: current.slug,
                expectedUpdatedAt: unlinkedMention.updatedAt
            )
            XCTFail("a stale unlinked-mention conversion should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("其他窗口中更新"))
        }

        _ = try await store.saveArticle(NativeSaveArticle(
            banner: current.banner,
            body: "链接已经移除。",
            category: current.category,
            excerpt: current.excerpt,
            media: current.media,
            slug: current.slug,
            status: current.status,
            tags: current.tags,
            title: current.title,
            expectedUpdatedAt: current.updatedAt,
            properties: current.properties
        ))
        XCTAssertFalse(
            try await store.articleGraph().edges.contains(where: { $0.id == "foundation->idea" }),
            "changing one body should remove its stale indexed links"
        )
    }

    func testObsidianVaultImportPreservesPropertiesLinksAndAttachments() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("vault", isDirectory: true)
        let attachments = vault.appendingPathComponent("Assets", isDirectory: true)
        let storeRoot = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: attachments.appendingPathComponent("图.png"))
        try Data("PDF".utf8).write(to: attachments.appendingPathComponent("资料.pdf"))
        try Data("""
        ---
        title: 路线图
        aliases:
          - Road Map
        tags: [Swift, "知识管理"]
        category: Research
        status: published
        date: 2026-08-20
        cssclasses:
          - wide-page
        ---
        参见 [[第二篇#细节|详情]]。

        ![[Assets/图.png]]
        ![[Assets/资料.pdf]]
        """.utf8).write(to: vault.appendingPathComponent("路线图.md"))
        try Data("""
        ---
        title: 第二篇
        ---
        ## 细节
        内容。
        """.utf8).write(to: vault.appendingPathComponent("第二篇.md"))

        let preview = try NativeObsidianVaultImporter.scan(vaultURL: vault)
        XCTAssertEqual(preview.notes.count, 2)
        XCTAssertEqual(preview.importableCount, 2)
        XCTAssertEqual(preview.attachmentCount, 2)
        guard let roadmap = preview.notes.first(where: { $0.title == "路线图" }) else {
            XCTFail("expected the roadmap note")
            return
        }
        XCTAssertEqual(roadmap.tags, ["Swift", "知识管理"])
        XCTAssertEqual(roadmap.category, "Research")
        XCTAssertEqual(roadmap.status, .published)
        XCTAssertTrue(roadmap.properties["aliases"]?.contains("Road Map") == true)
        XCTAssertTrue(roadmap.properties["cssclasses"]?.contains("wide-page") == true)
        guard let secondNote = preview.notes.first(where: { $0.title == "第二篇" }) else {
            XCTFail("expected the second note")
            return
        }
        XCTAssertTrue(roadmap.body.contains("[[\(secondNote.slug)#细节|详情]]"))

        let store = LocalBlogStore(rootURL: storeRoot)
        let result = try await store.importObsidianVault(preview)
        XCTAssertEqual(result.importedCount, 2)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.attachmentCount, 2)

        let imported = try await store.getArticle(slug: roadmap.slug)
        XCTAssertEqual(imported.properties, roadmap.properties)
        XCTAssertEqual(imported.media.map(\.kind).sorted(), ["file", "image"])
        XCTAssertTrue(imported.body.contains("/media/\(roadmap.slug)/"))
        let markdown = try String(
            contentsOf: storeRoot.appendingPathComponent("articles/\(roadmap.slug).md"),
            encoding: .utf8
        )
        XCTAssertTrue(markdown.contains("aliases: [\"Road Map\"]"))
        XCTAssertTrue(markdown.contains("cssclasses: [\"wide-page\"]"))
        XCTAssertEqual(try await store.listArticles().first(where: { $0.slug == roadmap.slug })?.aliases, ["Road Map"])
        XCTAssertEqual(
            try await store.search("Road Map", restrictingTo: [.article]).map(\.documentID),
            [roadmap.slug]
        )

        let conflicting = try NativeObsidianVaultImporter.scan(
            vaultURL: vault,
            existingSlugs: [roadmap.slug]
        )
        XCTAssertEqual(conflicting.conflictCount, 1)
        XCTAssertTrue(conflicting.notes.first(where: { $0.slug == roadmap.slug })?.canImport == false)
    }

    func testArticleCommentsPersistQuotesRepliesAndCascadeDeletion() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let saved = try await store.saveArticle(article(
            slug: "commented",
            status: .published,
            expectedUpdatedAt: nil,
            body: "## 结论\n值得讨论的原文"
        ))
        let selection = NativeArticleCommentSelection(
            quote: "值得讨论的原文",
            anchorID: "markdown-heading-0"
        )
        let parent = try await store.createArticleComment(
            articleSlug: saved.slug,
            authorName: "leon",
            text: "这里需要补充证据。",
            selection: selection,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let reply = try await store.createArticleComment(
            articleSlug: saved.slug,
            authorName: "reader",
            text: "已经补充。",
            parentID: parent.id,
            at: Date(timeIntervalSince1970: 1_700_000_010)
        )

        let comments = try await store.listArticleComments(articleSlug: saved.slug)
        XCTAssertEqual(comments.map(\.id), [parent.id, reply.id])
        XCTAssertEqual(comments.first?.selection, selection)
        XCTAssertEqual(comments.last?.parentID, parent.id)

        try await store.deleteArticleComment(id: parent.id, articleSlug: saved.slug)
        XCTAssertTrue(try await store.listArticleComments(articleSlug: saved.slug).isEmpty)
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

    func testSmartCollectionsAndBookmarksPersistInSQLite() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let savedArticle = try await store.saveArticle(article(
            slug: "saved-note",
            status: .published,
            expectedUpdatedAt: nil,
            body: "collection body",
            title: "收藏文章"
        ))
        let collection = NativeSmartCollection(
            id: "published-base",
            name: "已发布",
            rules: [NativeSmartCollectionRule(field: .status, comparison: .equals, value: "published")],
            layout: .cards,
            columns: [
                .system(.title, width: 240),
                NativeSmartCollectionColumn(
                    source: .property,
                    key: "rating",
                    title: "评分",
                    width: 110,
                    propertyKind: .number,
                    summary: .average
                ),
                NativeSmartCollectionColumn(source: .formula, key: "double_rating", title: "双倍评分"),
            ],
            formulas: [
                NativeSmartCollectionFormula(
                    key: "double_rating",
                    name: "双倍评分",
                    expression: "rating * 2"
                ),
            ]
        )
        let savedCollection = try await store.saveSmartCollection(collection)
        XCTAssertEqual(try await store.listSmartCollections(), [savedCollection])
        XCTAssertEqual(try await store.listArticles(in: savedCollection).map(\.slug), ["saved-note"])
        let baseURL = root.appendingPathComponent("bases/published-base.base")
        let baseSource = try String(contentsOf: baseURL, encoding: .utf8)
        XCTAssertTrue(baseSource.contains("formulas:"))
        XCTAssertTrue(baseSource.contains("double_rating"))
        XCTAssertTrue(baseSource.contains("summaries:"))
        XCTAssertTrue(baseSource.contains("leonBookColumnWidths:"))
        let externallyEditedBase = baseSource
            .replacingOccurrences(of: "double_rating: 'rating * 2'", with: "double_rating: 'rating * 3'")
            .replacingOccurrences(of: "note.rating: 110", with: "note.rating: 180")
        try Data(externallyEditedBase.utf8).write(to: baseURL, options: .atomic)
        let externallyReloaded = try await store.listSmartCollections().first
        XCTAssertEqual(externallyReloaded?.formulas.first?.expression, "rating * 3")
        XCTAssertEqual(
            externallyReloaded?.columns.first(where: { $0.key == "rating" })?.width,
            180
        )

        let propertyUpdated = try await store.setArticleProperty(
            slug: savedArticle.slug,
            expectedUpdatedAt: savedArticle.updatedAt,
            key: "rating",
            value: .number(4.5)
        )
        XCTAssertEqual(propertyUpdated.properties["rating"], .number(4.5))
        XCTAssertEqual(
            try await store.listArticles(in: savedCollection).first?.properties["rating"],
            .number(4.5)
        )
        let markdown = try String(
            contentsOf: root.appendingPathComponent("articles/saved-note.md"),
            encoding: .utf8
        )
        XCTAssertTrue(markdown.contains("rating: 4.5"))

        let bookmarks = [
            NativeBookmark(title: "收藏文章", target: .article(slug: "saved-note")),
            NativeBookmark(
                title: "收藏标题",
                target: .heading(slug: "saved-note", heading: "结论", anchorID: "markdown-heading-0")
            ),
            NativeBookmark(title: "待办搜索", target: .search(query: "tag:todo")),
            NativeBookmark(title: "关系图", target: .graph),
        ]
        for bookmark in bookmarks { _ = try await store.saveBookmark(bookmark) }
        XCTAssertEqual(try await store.listBookmarks().map(\.target), bookmarks.map(\.target))

        try await store.deleteBookmark(id: bookmarks[1].id)
        XCTAssertEqual(try await store.listBookmarks().count, 3)
        try await store.deleteSmartCollection(id: savedCollection.id)
        XCTAssertTrue(try await store.listSmartCollections().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: baseURL.path))
    }

    func testSmartCollectionSQLMatchesTheInMemoryEvaluator() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)

        func payload(
            slug: String,
            title: String,
            body: String,
            status: NativeArticleStatus,
            tags: [String],
            properties: [String: NativeArticlePropertyValue]
        ) -> NativeSaveArticle {
            NativeSaveArticle(
                banner: nil,
                body: body,
                category: status == .published ? "Engineering" : "Notes",
                excerpt: "摘要 \(body)",
                media: [],
                slug: slug,
                status: status,
                tags: tags,
                title: title,
                expectedUpdatedAt: nil,
                properties: properties
            )
        }

        var articles = [
            try await store.saveArticle(payload(
                slug: "alpha",
                title: "Alpha",
                body: "SQLite roadmap and query plan",
                status: .published,
                tags: ["Swift", "Database"],
                properties: [
                    "topics": .list(["SQLite", "FTS"]),
                    "featured": .checkbox(true),
                ]
            )),
            try await store.saveArticle(payload(
                slug: "beta",
                title: "Beta",
                body: "Small release note",
                status: .published,
                tags: ["Release"],
                properties: ["topics": .list(["Shipping"])]
            )),
            try await store.saveArticle(payload(
                slug: "gamma",
                title: "Gamma",
                body: "UI roadmap draft",
                status: .draft,
                tags: ["Swift"],
                properties: ["topics": .list(["Design"])]
            )),
        ]
        articles[0] = try await store.incrementArticlePageViews(slug: articles[0].slug)
        articles[0] = try await store.incrementArticlePageViews(slug: articles[0].slug)
        articles[1] = try await store.incrementArticlePageViews(slug: articles[1].slug)

        let collections = [
            NativeSmartCollection(
                name: "全部条件",
                rules: [
                    NativeSmartCollectionRule(field: .content, comparison: .contains, value: "ROADMAP"),
                    NativeSmartCollectionRule(field: .tag, comparison: .equals, value: "swift"),
                    NativeSmartCollectionRule(
                        field: .property,
                        comparison: .contains,
                        value: "sql",
                        propertyKey: "TOPICS"
                    ),
                    NativeSmartCollectionRule(field: .wordCount, comparison: .greaterThan, value: "5"),
                ],
                sorts: [
                    NativeArticleSortDescriptor(field: .pageViews, ascending: false),
                    NativeArticleSortDescriptor(field: .title, ascending: true),
                ]
            ),
            NativeSmartCollection(
                name: "任一条件",
                matchMode: .any,
                rules: [
                    NativeSmartCollectionRule(field: .title, comparison: .equals, value: "beta"),
                    NativeSmartCollectionRule(
                        field: .property,
                        comparison: .equals,
                        value: "true",
                        propertyKey: "featured"
                    ),
                ],
                sorts: [NativeArticleSortDescriptor(field: .title, ascending: true)]
            ),
            NativeSmartCollection(
                name: "日期与数值",
                rules: [
                    NativeSmartCollectionRule(field: .publishedAt, comparison: .isNotEmpty, value: ""),
                    NativeSmartCollectionRule(field: .updatedAt, comparison: .after, value: "2020-01-01"),
                    NativeSmartCollectionRule(field: .pageViews, comparison: .greaterThan, value: "0"),
                ],
                sorts: [
                    NativeArticleSortDescriptor(field: .pageViews, ascending: false),
                    NativeArticleSortDescriptor(field: .wordCount, ascending: true),
                ]
            ),
            NativeSmartCollection(
                name: "缺少属性",
                rules: [
                    NativeSmartCollectionRule(
                        field: .property,
                        comparison: .isEmpty,
                        value: "",
                        propertyKey: "featured"
                    ),
                ],
                sorts: [NativeArticleSortDescriptor(field: .title, ascending: true)]
            ),
        ]

        for collection in collections {
            let expected = NativeSmartCollectionEvaluator
                .articles(from: articles, matching: collection)
                .map(\.slug)
            XCTAssertEqual(
                try await store.listArticles(in: collection).map(\.slug),
                expected,
                "SQLite collection query should preserve evaluator semantics for \(collection.name)"
            )
        }
    }

    func testStandardObsidianBaseImportsMultipleViewsAndPreservesUnknownFields() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)

        func payload(
            slug: String,
            status: NativeArticleStatus,
            category: String
        ) -> NativeSaveArticle {
            NativeSaveArticle(
                banner: nil,
                body: "\(slug) body",
                category: category,
                excerpt: "",
                media: [],
                slug: slug,
                status: status,
                tags: ["Swift"],
                title: slug.capitalized,
                expectedUpdatedAt: nil,
                properties: ["rating": .number(status == .published ? 5 : 3)]
            )
        }

        _ = try await store.saveArticle(payload(slug: "published-note", status: .published, category: "Guide"))
        _ = try await store.saveArticle(payload(slug: "draft-note", status: .draft, category: "Notes"))
        let bases = root.appendingPathComponent("bases", isDirectory: true)
        try FileManager.default.createDirectory(at: bases, withIntermediateDirectories: true)
        let baseURL = bases.appendingPathComponent("standard.base")
        let source = """
        filters:
          and:
            - 'file.hasTag("Swift")'
            - or:
                - 'note.status == "published"'
                - not:
                    - 'note.category == "Archived"'
        formulas:
          doubled: 'note.rating * 2'
        properties:
          note.rating:
            displayName: Rating
            icon: star
        customTopLevel:
          plugin: enabled
        views:
          - type: table
            name: Published
            limit: 10
            filters:
              and:
                - 'note.status == "published"'
            order:
              - file.name
              - note.rating
              - formula.doubled
            summaries:
              note.rating: Median
            pluginViewState:
              color: blue
          - type: cards
            name: Drafts
            filters:
              and:
                - 'note.status == "draft"'
            order:
              - file.name
        """
        try Data(source.utf8).write(to: baseURL, options: .atomic)

        let imported = try await store.listSmartCollections()
        XCTAssertEqual(imported.count, 1)
        guard var collection = imported.first else { return XCTFail("standard Base should load") }
        XCTAssertEqual(collection.id, "standard")
        XCTAssertEqual(collection.views.map(\.name), ["Published", "Drafts"])
        XCTAssertEqual(collection.formulas.first?.expression, "note.rating * 2")
        XCTAssertEqual(collection.columns.first(where: { $0.key == "rating" })?.title, "Rating")

        let published = collection.materialized(viewID: collection.views[0].id)
        XCTAssertEqual(try await store.listArticles(in: published).map(\.slug), ["published-note"])
        let drafts = collection.materialized(viewID: collection.views[1].id)
        XCTAssertEqual(try await store.listArticles(in: drafts).map(\.slug), ["draft-note"])

        collection = published
        collection.layout = .cards
        _ = try await store.saveSmartCollection(collection)
        let rewritten = try String(contentsOf: baseURL, encoding: .utf8)
        XCTAssertTrue(rewritten.contains("customTopLevel:"))
        XCTAssertTrue(rewritten.contains("plugin: enabled"))
        XCTAssertTrue(rewritten.contains("icon: star"))
        XCTAssertTrue(rewritten.contains("pluginViewState:"))
        XCTAssertTrue(rewritten.contains("color: blue"))
        XCTAssertTrue(rewritten.contains("note.rating: Median"))
        XCTAssertFalse(rewritten.contains("leonBookConfig"))
        let reloaded = try await store.listSmartCollections().first
        XCTAssertEqual(reloaded?.views.count, 2)
        XCTAssertEqual(reloaded?.views.first?.layout, .cards)
    }

    func testTwoWindowStoresCanShareOneWorkspaceInTheSameProcess() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstWindowStore = LocalBlogStore(rootURL: root)
        let secondWindowStore = LocalBlogStore(rootURL: root)

        let saved = try await firstWindowStore.saveArticle(article(
            slug: "shared-window-note",
            status: .draft,
            expectedUpdatedAt: nil,
            body: "shared body",
            title: "多窗口笔记"
        ))

        XCTAssertEqual(try await secondWindowStore.listArticles().map(\.slug), [saved.slug])
    }

    func testArticleRefactorsPersistMarkdownAndRepairIncomingLinks() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let source = try await store.saveArticle(article(
            slug: "source-note",
            status: .published,
            expectedUpdatedAt: nil,
            body: "开头\n\n## 第一节\n\n要提取的内容 ^idea\n\n## 第二节\n\n- [ ] 待办",
            title: "来源文章"
        ))
        let extractText = "要提取的内容 ^idea"
        let extractRange = (source.body as NSString).range(of: extractText)
        let extraction = try await store.extractArticleSelection(
            sourceSlug: source.slug,
            expectedUpdatedAt: source.updatedAt,
            sourceBody: source.body,
            selectedRange: extractRange,
            newTitle: "提取结果",
            replacement: .embed
        )
        XCTAssertEqual(extraction.createdArticles.count, 1)
        XCTAssertTrue(extraction.primaryArticle.body.contains("![[\(extraction.createdArticles[0].slug)]]"))
        XCTAssertEqual(extraction.createdArticles[0].body, extractText)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("articles/\(extraction.createdArticles[0].slug).md").path
        ))

        let split = try await store.splitArticleByLevel2Headings(
            sourceSlug: source.slug,
            expectedUpdatedAt: extraction.primaryArticle.updatedAt,
            sourceBody: extraction.primaryArticle.body,
            replacement: .link
        )
        XCTAssertEqual(split.createdArticles.map(\.title), ["第一节", "第二节"])
        XCTAssertTrue(split.primaryArticle.body.contains("[["))

        let mergeSource = split.createdArticles[0]
        let mergeDestination = split.createdArticles[1]
        let backlink = try await store.saveArticle(article(
            slug: "incoming-link",
            status: .draft,
            expectedUpdatedAt: nil,
            body: "[[\(mergeSource.slug)#标题|别名]]\n\n![[\(mergeSource.slug)#^idea]]",
            title: "入链"
        ))
        let merge = try await store.mergeArticle(
            sourceSlug: mergeSource.slug,
            destinationSlug: mergeDestination.slug,
            expectedSourceUpdatedAt: mergeSource.updatedAt,
            expectedDestinationUpdatedAt: mergeDestination.updatedAt,
            position: .end
        )
        XCTAssertTrue(merge.primaryArticle.body.contains("## \(mergeSource.title)"))
        let repaired = try await store.getArticle(slug: backlink.slug)
        XCTAssertTrue(repaired.body.contains("[[\(mergeDestination.slug)#标题|别名]]"))
        XCTAssertTrue(repaired.body.contains("![[\(mergeDestination.slug)#^idea]]"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("articles/\(mergeSource.slug).md").path
        ))

        let taskLine = merge.primaryArticle.body.components(separatedBy: .newlines)
            .firstIndex(where: { $0.contains("[ ] 待办") })
        XCTAssertNotNil(taskLine)
        if let taskLine {
            let toggled = try await store.toggleArticleTask(
                slug: merge.primaryArticle.slug,
                expectedUpdatedAt: merge.primaryArticle.updatedAt,
                lineIndex: taskLine,
                completed: true
            )
            XCTAssertTrue(toggled.body.contains("[x] 待办"))
        }
    }

    func testReadOnlyMarkdownMountIndexesExternalChangesWithoutWritingVault() async throws {
        let root = try makeTemporaryDirectory()
        let vault = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: vault)
        }
        let noteURL = vault.appendingPathComponent("folder/mounted-note.md")
        try FileManager.default.createDirectory(
            at: noteURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = """
        ---
        slug: mounted-note
        title: Mounted note
        # keep this Obsidian comment
        tags: [vault]
        ---
        Original body
        """
        try Data(original.utf8).write(to: noteURL)
        let attachmentURL = vault.appendingPathComponent("folder/assets/pixel.png")
        try FileManager.default.createDirectory(
            at: attachmentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: attachmentURL)

        let store = LocalBlogStore(rootURL: root)
        _ = try await store.configureMarkdownWorkspaceSource(
            mode: .readOnlyMount,
            directoryURL: vault
        )
        let mounted = try await store.getArticle(slug: "mounted-note")
        XCTAssertEqual(mounted.body, "Original body")
        XCTAssertEqual(try await store.markdownWorkspaceSourceState().mode, .readOnlyMount)
        XCTAssertEqual(try await store.markdownSourceDirectoryURL(), vault.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(
            await store.mediaURL(
                for: "assets/pixel.png",
                relativeToMarkdownSource: "folder/mounted-note.md"
            ),
            attachmentURL.standardizedFileURL.resolvingSymlinksInPath()
        )
        XCTAssertNil(await store.mediaURL(
            for: "../../outside.png",
            relativeToMarkdownSource: "folder/mounted-note.md"
        ))

        do {
            _ = try await store.saveArticle(article(
                slug: mounted.slug,
                status: mounted.status,
                expectedUpdatedAt: mounted.updatedAt,
                body: "LeonBook must not write this",
                title: mounted.title
            ))
            XCTFail("read-only mount should reject article saves")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("只读"))
        }
        XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.appendingPathComponent(".sidecars-v1").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.appendingPathComponent("mounted-note.json").path))

        let externallyEdited = original.replacingOccurrences(of: "Original body", with: "Edited in Obsidian")
        try Data(externallyEdited.utf8).write(to: noteURL, options: .atomic)
        _ = try await store.refreshMarkdownSources(changedRelativePaths: ["folder/mounted-note.md"])
        XCTAssertEqual(try await store.getArticle(slug: "mounted-note").body, "Edited in Obsidian")

        let reopened = LocalBlogStore(rootURL: root)
        XCTAssertEqual(try await reopened.markdownWorkspaceSourceState().mode, .readOnlyMount)
        XCTAssertEqual(try await reopened.markdownSourceDirectoryURL(), vault.standardizedFileURL.resolvingSymlinksInPath())
    }

    func testDirectEditMarkdownMountWritesBackInPlace() async throws {
        let root = try makeTemporaryDirectory()
        let vault = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: vault)
        }
        let noteURL = vault.appendingPathComponent("direct-note.md")
        let source = """
        ---
        slug: direct-note
        # preserve me
        title: Direct note
        custom_plugin_key: yes
        ---
        Before
        """
        try Data(source.utf8).write(to: noteURL)

        let store = LocalBlogStore(rootURL: root)
        _ = try await store.configureMarkdownWorkspaceSource(mode: .directEdit, directoryURL: vault)
        let mounted = try await store.getArticle(slug: "direct-note")
        _ = try await store.saveArticle(article(
            slug: mounted.slug,
            status: mounted.status,
            expectedUpdatedAt: mounted.updatedAt,
            body: "After",
            title: "Direct note renamed",
            properties: mounted.properties
        ))

        let written = try String(contentsOf: noteURL, encoding: .utf8)
        XCTAssertTrue(written.contains("# preserve me"), "direct edit should preserve YAML comments; got: \(written)")
        XCTAssertTrue(written.contains("custom_plugin_key: yes"), "direct edit should preserve unknown YAML; got: \(written)")
        XCTAssertTrue(written.contains("Direct note renamed"), "direct edit should update the title; got: \(written)")
        XCTAssertTrue(written.hasSuffix("After"), "direct edit should update the body; got: \(written)")
        XCTAssertEqual(try await store.markdownWorkspaceSourceState().mode, .directEdit)
    }

    func testSwitchingBackToManagedMarkdownRevivesWorkspaceArticles() async throws {
        let root = try makeTemporaryDirectory()
        let vault = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: vault)
        }
        let store = LocalBlogStore(rootURL: root)
        _ = try await store.saveArticle(article(
            slug: "managed-note",
            status: .draft,
            expectedUpdatedAt: nil,
            body: "Managed body"
        ))
        let mountedSource = """
        ---
        slug: mounted-note
        title: Mounted note
        ---
        Mounted body
        """
        try Data(mountedSource.utf8).write(to: vault.appendingPathComponent("mounted.md"))

        _ = try await store.configureMarkdownWorkspaceSource(mode: .readOnlyMount, directoryURL: vault)
        XCTAssertEqual(try await store.listArticles().map(\.slug), ["mounted-note"])

        _ = try await store.configureMarkdownWorkspaceSource(mode: .copyImport)
        XCTAssertEqual(try await store.listArticles().map(\.slug), ["managed-note"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("articles/managed-note.md").path))
        XCTAssertEqual(try String(contentsOf: vault.appendingPathComponent("mounted.md"), encoding: .utf8), mountedSource)
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

    func testTwoWindowRegistriesCanShareTheDataRootInTheSameProcess() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstWindowStore = UserWorkspaceStore(rootURL: root)
        let secondWindowStore = UserWorkspaceStore(rootURL: root)

        let first = try await firstWindowStore.prepare()
        let second = try await secondWindowStore.prepare()

        XCTAssertEqual(first.activeUser, second.activeUser)
        XCTAssertEqual(first.workspaceURL, second.workspaceURL)
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

    func testManagedSnapshotsReuseUnchangedFilesAndValidateChecksums() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("articles"), withIntermediateDirectories: true)
        try Data("database".utf8).write(to: source.appendingPathComponent("leon-book.sqlite"))
        try Data("hello".utf8).write(to: source.appendingPathComponent("articles/note.md"))

        let policy = NativeBackupPolicy(
            automaticInterval: 60,
            retentionDays: 30,
            maximumSnapshotCount: 10,
            minimumFreeSpaceBytes: 0
        )
        let first = try LocalBackupManager.createManagedSnapshot(
            source: source,
            destination: destination,
            policy: policy
        )
        let second = try LocalBackupManager.createManagedSnapshot(
            source: source,
            destination: destination,
            policy: policy
        )

        XCTAssertTrue(second.reusedFileCount >= 2, "unchanged files should be reused from the preceding snapshot")
        XCTAssertEqual(try LocalBackupManager.validateSnapshot(at: first.snapshot.url).checkedFileCount, 2)
        XCTAssertEqual(try LocalBackupManager.validateSnapshot(at: second.snapshot.url).checkedFileCount, 2)

        try Data("corrupt".utf8).write(to: second.snapshot.url.appendingPathComponent("articles/note.md"))
        do {
            _ = try LocalBackupManager.validateSnapshot(at: second.snapshot.url)
            XCTFail("checksum validation should reject modified snapshot content")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("校验失败"))
        }
    }

    func testRetentionKeepsNewestSnapshotsWithinCountLimit() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("database".utf8).write(to: source.appendingPathComponent("leon-book.sqlite"))
        let policy = NativeBackupPolicy(
            automaticInterval: 60,
            retentionDays: 365,
            maximumSnapshotCount: 2,
            minimumFreeSpaceBytes: 0
        )

        for value in ["one", "two", "three"] {
            try Data(value.utf8).write(to: source.appendingPathComponent("value.txt"))
            _ = try LocalBackupManager.createManagedSnapshot(
                source: source,
                destination: destination,
                policy: policy
            )
        }

        let snapshots = try LocalBackupManager.listSnapshots(in: destination)
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(
            try String(contentsOf: snapshots[0].url.appendingPathComponent("value.txt"), encoding: .utf8),
            "three"
        )
    }

    func testRestoreReplacesWholeDataRootWithoutRestoringBackupMetadata() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("live", isDirectory: true)
        let destination = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: live.appendingPathComponent("workspaces/leon"), withIntermediateDirectories: true)
        try Data("original".utf8).write(to: live.appendingPathComponent("leon-book.sqlite"))
        try Data("article".utf8).write(to: live.appendingPathComponent("workspaces/leon/note.md"))
        let snapshot = try LocalBackupManager.createManagedSnapshot(
            source: live,
            destination: destination,
            policy: NativeBackupPolicy(minimumFreeSpaceBytes: 0)
        ).snapshot

        try Data("changed".utf8).write(to: live.appendingPathComponent("leon-book.sqlite"))
        try Data("extra".utf8).write(to: live.appendingPathComponent("extra.txt"))
        try LocalBackupManager.restoreSnapshot(
            at: snapshot.url,
            to: live,
            minimumFreeSpaceBytes: 0
        )

        XCTAssertEqual(
            try String(contentsOf: live.appendingPathComponent("leon-book.sqlite"), encoding: .utf8),
            "original"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.appendingPathComponent("extra.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.appendingPathComponent("backup-manifest.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.appendingPathComponent(".leon-book.lock").path))
    }

    func testCapacityGuardPreservesConfiguredFreeSpace() throws {
        do {
            try LocalBackupManager.ensureSufficientCapacity(
                availableBytes: 12_000,
                estimatedAdditionalBytes: 5_000,
                minimumFreeSpaceBytes: 8_000
            )
            XCTFail("backup should not consume the configured free-space reserve")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("剩余空间"))
        }

        do {
            try LocalBackupManager.ensureSufficientCapacity(
                availableBytes: 12_000,
                estimatedAdditionalBytes: 3_000,
                minimumFreeSpaceBytes: 8_000
            )
        } catch {
            XCTFail("backup should fit while preserving the configured reserve")
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
            ("NativeModelsTests.testAutomationURLsParseActionsAndEncodedParameters", { try NativeModelsTests().testAutomationURLsParseActionsAndEncodedParameters() }),
            ("NativeModelsTests.testCommandRegistryFuzzyMatchingRankingAndAvailability", { NativeModelsTests().testCommandRegistryFuzzyMatchingRankingAndAvailability() }),
            ("NativeModelsTests.testCommandPreferencesPersistPinsRecentsAndRejectConflicts", { await NativeModelsTests().testCommandPreferencesPersistPinsRecentsAndRejectConflicts() }),
            ("NativeModelsTests.testMomentFeedTimestampBatchStaysResponsive", { NativeModelsTests().testMomentFeedTimestampBatchStaysResponsive() }),
            ("NativeModelsTests.testLegacyMediaJSONUsesSafeDefaults", { try NativeModelsTests().testLegacyMediaJSONUsesSafeDefaults() }),
            ("NativeModelsTests.testMomentTagsAreExtractedDeduplicatedAndRemovedFromDisplayContent", { NativeModelsTests().testMomentTagsAreExtractedDeduplicatedAndRemovedFromDisplayContent() }),
            ("NativeModelsTests.testArticleHashtagsNormalizeAndPreserveLegacyCommaTags", { NativeModelsTests().testArticleHashtagsNormalizeAndPreserveLegacyCommaTags() }),
            ("NativeModelsTests.testArticleLinksExtractAndResolveTitlesOrSlugs", { try NativeModelsTests().testArticleLinksExtractAndResolveTitlesOrSlugs() }),
            ("NativeModelsTests.testArticleEmbedsSelectWholeNotesHeadingsAndBlocks", { NativeModelsTests().testArticleEmbedsSelectWholeNotesHeadingsAndBlocks() }),
            ("NativeModelsTests.testArticleTabMaintainsIndependentBackAndForwardHistory", { try NativeModelsTests().testArticleTabMaintainsIndependentBackAndForwardHistory() }),
            ("NativeModelsTests.testArticleCommentSelectionAnchorsToNearestHeading", { NativeModelsTests().testArticleCommentSelectionAnchorsToNearestHeading() }),
            ("NativeModelsTests.testArticleLineDiffMarksAddedAndRemovedLines", { NativeModelsTests().testArticleLineDiffMarksAddedAndRemovedLines() }),
            ("NativeModelsTests.testLegacyRevisionSnapshotDefaultsObsidianProperties", { try NativeModelsTests().testLegacyRevisionSnapshotDefaultsObsidianProperties() }),
            ("NativeModelsTests.testMomentSearchAndFilterMatchTextTagsDatesAndFavorites", { NativeModelsTests().testMomentSearchAndFilterMatchTextTagsDatesAndFavorites() }),
            ("NativeModelsTests.testDateFiltersUseTheProvidedCalendarAndNow", { NativeModelsTests().testDateFiltersUseTheProvidedCalendarAndNow() }),
            ("NativeModelsTests.testGlobalSearchQueryParsesPhrasesAndFilters", { NativeModelsTests().testGlobalSearchQueryParsesPhrasesAndFilters() }),
            ("NativeModelsTests.testTypedArticlePropertiesDecodeLegacyValuesValidateAndRename", { try NativeModelsTests().testTypedArticlePropertiesDecodeLegacyValuesValidateAndRename() }),
            ("NativeModelsTests.testSmartCollectionCombinesPropertiesDatesAndMultiSort", { NativeModelsTests().testSmartCollectionCombinesPropertiesDatesAndMultiSort() }),
            ("NativeModelsTests.testBaseFormulasCalculatePropertiesDatesAndSummaries", { NativeModelsTests().testBaseFormulasCalculatePropertiesDatesAndSummaries() }),
            ("NativeModelsTests.testArticleGraphProjectionFiltersOrphansAndClipsByDegree", { NativeModelsTests().testArticleGraphProjectionFiltersOrphansAndClipsByDegree() }),
            ("PerformanceRegressionTests.testEditorSessionOwnsHighFrequencyDraftState", { PerformanceRegressionTests().testEditorSessionOwnsHighFrequencyDraftState() }),
            ("PerformanceRegressionTests.testMarkdownRefreshPlanSkipsUnrelatedDomains", { PerformanceRegressionTests().testMarkdownRefreshPlanSkipsUnrelatedDomains() }),
            ("PerformanceRegressionTests.testMarkdownLiveStylingLimitsOrdinaryEditsToNearbyParagraphs", { PerformanceRegressionTests().testMarkdownLiveStylingLimitsOrdinaryEditsToNearbyParagraphs() }),
            ("PerformanceRegressionTests.testArticleMarkdownAnalysisIsCachedAndSharedAcrossConsumers", { PerformanceRegressionTests().testArticleMarkdownAnalysisIsCachedAndSharedAcrossConsumers() }),
            ("PerformanceRegressionTests.testSharedImagePipelineCoalescesRequestsAndCapsDecodeConcurrency", { try await PerformanceRegressionTests().testSharedImagePipelineCoalescesRequestsAndCapsDecodeConcurrency() }),
            ("LocalBlogStoreTests.testMomentLifecycleNormalizesInputFiltersAndRecordsActivity", { try await LocalBlogStoreTests().testMomentLifecycleNormalizesInputFiltersAndRecordsActivity() }),
            ("LocalBlogStoreTests.testMomentUpdatePreservesIdentityAndDeleteHidesIt", { try await LocalBlogStoreTests().testMomentUpdatePreservesIdentityAndDeleteHidesIt() }),
            ("LocalBlogStoreTests.testQuestionAnswersAndTagSearchPersistInSQLite", { try await LocalBlogStoreTests().testQuestionAnswersAndTagSearchPersistInSQLite() }),
            ("LocalBlogStoreTests.testArticleLifecycleSupportsDraftPublishingAndConflictProtection", { try await LocalBlogStoreTests().testArticleLifecycleSupportsDraftPublishingAndConflictProtection() }),
            ("LocalBlogStoreTests.testArticleDeleteHidesRecord", { try await LocalBlogStoreTests().testArticleDeleteHidesRecord() }),
            ("LocalBlogStoreTests.testArticleHashtagsPersistAsNormalizedTags", { try await LocalBlogStoreTests().testArticleHashtagsPersistAsNormalizedTags() }),
            ("LocalBlogStoreTests.testSavingImportedMarkdownPreservesUnchangedFrontmatterSource", { try await LocalBlogStoreTests().testSavingImportedMarkdownPreservesUnchangedFrontmatterSource() }),
            ("LocalBlogStoreTests.testSavingObsidianFixturePreservesBlockListStyleAndLineEndings", { try await LocalBlogStoreTests().testSavingObsidianFixturePreservesBlockListStyleAndLineEndings() }),
            ("LocalBlogStoreTests.testEditingObsidianFoldedPropertyPreservesBlockScalarStyle", { try await LocalBlogStoreTests().testEditingObsidianFoldedPropertyPreservesBlockScalarStyle() }),
            ("LocalBlogStoreTests.testIncrementalMarkdownRefreshReadsChangedFilesAndHandlesDeletion", { try await LocalBlogStoreTests().testIncrementalMarkdownRefreshReadsChangedFilesAndHandlesDeletion() }),
            ("LocalBlogStoreTests.testIncrementalMarkdownRefreshPreservesIdentityAcrossRename", { try await LocalBlogStoreTests().testIncrementalMarkdownRefreshPreservesIdentityAcrossRename() }),
            ("LocalBlogStoreTests.testArticleAutosavesRollWithinFiveMinutesAndCreateHistoryBuckets", { try await LocalBlogStoreTests().testArticleAutosavesRollWithinFiveMinutesAndCreateHistoryBuckets() }),
            ("LocalBlogStoreTests.testManualArticleSaveKeepsThePreviousVersion", { try await LocalBlogStoreTests().testManualArticleSaveKeepsThePreviousVersion() }),
            ("LocalBlogStoreTests.testArticleRelationsResolveAndDeduplicateWikiLinks", { try await LocalBlogStoreTests().testArticleRelationsResolveAndDeduplicateWikiLinks() }),
            ("LocalBlogStoreTests.testObsidianVaultImportPreservesPropertiesLinksAndAttachments", { try await LocalBlogStoreTests().testObsidianVaultImportPreservesPropertiesLinksAndAttachments() }),
            ("LocalBlogStoreTests.testArticleCommentsPersistQuotesRepliesAndCascadeDeletion", { try await LocalBlogStoreTests().testArticleCommentsPersistQuotesRepliesAndCascadeDeletion() }),
            ("LocalBlogStoreTests.testMediaURLNormalizesLocalhostAndRejectsUnsafeSegments", { try await LocalBlogStoreTests().testMediaURLNormalizesLocalhostAndRejectsUnsafeSegments() }),
            ("LocalBlogStoreTests.testSmartCollectionsAndBookmarksPersistInSQLite", { try await LocalBlogStoreTests().testSmartCollectionsAndBookmarksPersistInSQLite() }),
            ("LocalBlogStoreTests.testSmartCollectionSQLMatchesTheInMemoryEvaluator", { try await LocalBlogStoreTests().testSmartCollectionSQLMatchesTheInMemoryEvaluator() }),
            ("LocalBlogStoreTests.testStandardObsidianBaseImportsMultipleViewsAndPreservesUnknownFields", { try await LocalBlogStoreTests().testStandardObsidianBaseImportsMultipleViewsAndPreservesUnknownFields() }),
            ("LocalBlogStoreTests.testTwoWindowStoresCanShareOneWorkspaceInTheSameProcess", { try await LocalBlogStoreTests().testTwoWindowStoresCanShareOneWorkspaceInTheSameProcess() }),
            ("LocalBlogStoreTests.testArticleRefactorsPersistMarkdownAndRepairIncomingLinks", { try await LocalBlogStoreTests().testArticleRefactorsPersistMarkdownAndRepairIncomingLinks() }),
            ("LocalBlogStoreTests.testReadOnlyMarkdownMountIndexesExternalChangesWithoutWritingVault", { try await LocalBlogStoreTests().testReadOnlyMarkdownMountIndexesExternalChangesWithoutWritingVault() }),
            ("LocalBlogStoreTests.testDirectEditMarkdownMountWritesBackInPlace", { try await LocalBlogStoreTests().testDirectEditMarkdownMountWritesBackInPlace() }),
            ("LocalBlogStoreTests.testSwitchingBackToManagedMarkdownRevivesWorkspaceArticles", { try await LocalBlogStoreTests().testSwitchingBackToManagedMarkdownRevivesWorkspaceArticles() }),
            ("UserWorkspaceStoreTests.testWorkspacePreparationCreatesAndPersistsDefaultUser", { try await UserWorkspaceStoreTests().testWorkspacePreparationCreatesAndPersistsDefaultUser() }),
            ("UserWorkspaceStoreTests.testTwoWindowRegistriesCanShareTheDataRootInTheSameProcess", { try await UserWorkspaceStoreTests().testTwoWindowRegistriesCanShareTheDataRootInTheSameProcess() }),
            ("LocalBackupManagerTests.testSnapshotCopiesDataWritesManifestAndSkipsLockFile", { try LocalBackupManagerTests().testSnapshotCopiesDataWritesManifestAndSkipsLockFile() }),
            ("LocalBackupManagerTests.testBackupDestinationCannotBeTheSourceOrInsideIt", { try LocalBackupManagerTests().testBackupDestinationCannotBeTheSourceOrInsideIt() }),
            ("LocalBackupManagerTests.testManagedSnapshotsReuseUnchangedFilesAndValidateChecksums", { try LocalBackupManagerTests().testManagedSnapshotsReuseUnchangedFilesAndValidateChecksums() }),
            ("LocalBackupManagerTests.testRetentionKeepsNewestSnapshotsWithinCountLimit", { try LocalBackupManagerTests().testRetentionKeepsNewestSnapshotsWithinCountLimit() }),
            ("LocalBackupManagerTests.testRestoreReplacesWholeDataRootWithoutRestoringBackupMetadata", { try LocalBackupManagerTests().testRestoreReplacesWholeDataRootWithoutRestoringBackupMetadata() }),
            ("LocalBackupManagerTests.testCapacityGuardPreservesConfiguredFreeSpace", { try LocalBackupManagerTests().testCapacityGuardPreservesConfiguredFreeSpace() }),
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
    body: String,
    title: String = "Test article",
    properties: [String: NativeArticlePropertyValue] = [:]
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
        title: title,
        expectedUpdatedAt: expectedUpdatedAt,
        properties: properties
    )
}

private func graphArticle(
    slug: String,
    title: String,
    status: NativeArticleStatus,
    aliases: [String] = [],
    updatedAt: String
) -> NativeArticleSummary {
    NativeArticleSummary(
        aliases: aliases,
        banner: nil,
        category: "Notes",
        excerpt: "",
        publishedAt: status == .published ? updatedAt : nil,
        slug: slug,
        status: status,
        tags: ["Knowledge"],
        title: title,
        updatedAt: updatedAt,
        wordCount: 10
    )
}

private func revisionSnapshot(body: String) -> NativeArticleRevisionSnapshot {
    NativeArticleRevisionSnapshot(
        banner: nil,
        body: body,
        category: "Notes",
        excerpt: "",
        media: [],
        status: .draft,
        tags: [],
        title: "恢复草稿",
        articleUpdatedAt: nil
    )
}

private func smartCollectionArticle(
    slug: String,
    title: String,
    status: NativeArticleStatus,
    category: String,
    updatedAt: String,
    pageViews: Int,
    properties: [String: NativeArticlePropertyValue]
) -> NativeArticle {
    NativeArticle(
        banner: nil,
        body: "正文",
        category: category,
        excerpt: "",
        media: [],
        slug: slug,
        status: status,
        tags: ["Knowledge"],
        title: title,
        updatedAt: updatedAt,
        publishedAt: status == .published ? updatedAt : nil,
        wordCount: 2,
        pageViews: pageViews,
        properties: properties
    )
}
