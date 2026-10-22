import Darwin
import AppKit
import Combine
import Foundation
import LeonBookExtensionKit
import SwiftUI
import WebKit
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
    @MainActor
    func testLanguagePreferencesPersistAndLocalizationsResolve() {
        let suiteName = "NativeLanguagePreferencesTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("expected isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let defaultsKey = "test.language"
        let preferences = NativeLanguagePreferences(
            defaults: defaults,
            defaultsKey: defaultsKey,
            preferredLanguages: ["en-US"]
        )
        XCTAssertEqual(preferences.language, .english)

        preferences.language = .simplifiedChinese
        XCTAssertEqual(defaults.string(forKey: defaultsKey), NativeAppLanguage.simplifiedChinese.rawValue)
        let restored = NativeLanguagePreferences(
            defaults: defaults,
            defaultsKey: defaultsKey,
            preferredLanguages: ["en-US"]
        )
        XCTAssertEqual(restored.language, .simplifiedChinese)

        defaults.set("unsupported", forKey: defaultsKey)
        let fallback = NativeLanguagePreferences(
            defaults: defaults,
            defaultsKey: defaultsKey,
            preferredLanguages: ["en-GB"]
        )
        XCTAssertEqual(fallback.language, .english)
        XCTAssertEqual(NativeLocalization.string("设置", language: .english), "Settings")
        XCTAssertEqual(NativeLocalization.string("设置", language: .simplifiedChinese), "设置")
    }

    func testEnglishCatalogCoversEditorSurface() {
        let editorKeys = [
            "正文",
            "写作",
            "隐藏右栏",
            "显示右栏",
            "发布状态",
            "分类与标签",
            "封面图",
            "附件",
            "文章概览",
            "字",
            "个附件",
            "正文出链",
            "反向链接",
            "未链接提及",
            "⌘点手柄/⇧连选 · 拖动搬运 · ⌥⌘↑↓ 键盘移动",
            "已自动保存：%@",
        ]

        for key in editorKeys {
            let localized = NativeLocalization.string(key, language: .english)
            XCTAssertFalse(
                localized.range(of: "\\p{Han}", options: .regularExpression) != nil,
                "missing English editor localization for \(key): \(localized)"
            )
        }
    }

    @MainActor
    func testVideoPlaybackFormatsAndPersistsResumePositions() {
        XCTAssertEqual(NativeInlineVideoPlayerModel.timeLabel(7), "00:07")
        XCTAssertEqual(NativeInlineVideoPlayerModel.timeLabel(3_661), "1:01:01")

        let suiteName = "NativeVideoPlaybackTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("expected isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let mediaID = "/media/note/demo.mp4"
        let coordinator = NativeVideoPlaybackCoordinator(defaults: defaults)
        coordinator.record(
            mediaID: mediaID,
            seconds: 42.5,
            duration: 180,
            forcePersistence: true
        )
        XCTAssertEqual(coordinator.resumePosition(for: mediaID, duration: 180) ?? 0, 42.5)

        let restored = NativeVideoPlaybackCoordinator(defaults: defaults)
        XCTAssertEqual(restored.resumePosition(for: mediaID, duration: 180) ?? 0, 42.5)
        restored.record(
            mediaID: mediaID,
            seconds: 178,
            duration: 180,
            forcePersistence: true
        )
        XCTAssertNil(restored.resumePosition(for: mediaID, duration: 180))
    }

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

    func testFrontmatterDocumentSharesScalarListAndBodySemantics() {
        let document = NativeFrontmatterDocument(source: """
        \u{feff}---
        "title": "标题 # 保留"
        tags:
          - Swift
          - 'C#'
        summary: value # ignored
        empty:
        custom: >-
          first # preserved
          second
        ---

        正文
        """)

        XCTAssertEqual(document.scalar(for: ["TITLE"]), "标题 # 保留")
        XCTAssertEqual(document.list(for: ["tags"]), ["Swift", "C#"])
        XCTAssertEqual(document.scalar(for: ["summary"]), "value")
        XCTAssertEqual(document.scalar(for: ["empty"]), "")
        XCTAssertTrue(document.values["custom"]?.contains("first # preserved") == true)
        XCTAssertEqual(document.body, "正文")
    }

    func testQuestionSessionKeepsSelectionAndAnswerDraftAligned() {
        let timestamp = "2026-09-03T00:00:00Z"
        let first = NativeQuestion(
            id: "first",
            title: "First",
            body: "",
            tags: [],
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let second = NativeQuestion(
            id: "second",
            title: "Second",
            body: "",
            tags: [],
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let draftImage = NativeMedia(kind: "image", name: "draft.png", size: 1, url: "/draft.png")
        var session = NativeQuestionSessionState()

        XCTAssertEqual(session.beginSelecting(first), [])
        session.answerDraft = NativeQuestionAnswerDraft(body: "draft", images: [draftImage])
        session.editingAnswerID = "answer"

        XCTAssertEqual(session.beginSelecting(second), [draftImage])
        XCTAssertEqual(session.selectedQuestion?.id, second.id)
        XCTAssertTrue(session.answerDraft.isEmpty)
        XCTAssertNil(session.editingAnswerID)
        XCTAssertTrue(session.isLoadingAnswers)

        session.searchText = "Swift"
        XCTAssertTrue(session.isFiltering)
        session.reset()
        XCTAssertFalse(session.isFiltering)
        XCTAssertNil(session.selectedQuestion)
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

    func testRichMarkdownEmbedsAndBlockLinkAnchors() {
        let body = """
        普通段落 ^decision

        - 第一项 ^first-item
        - 第二项
        ^whole-list

        ```swift
        let marker = "^not-a-block"
        ```
        """
        XCTAssertEqual(
            NativeArticleEmbed.blockReferences(in: body),
            [
                NativeArticleBlockReference(id: "decision", preview: "普通段落"),
                NativeArticleBlockReference(id: "first-item", preview: "- 第一项"),
                NativeArticleBlockReference(id: "whole-list", preview: "- 第一项 - 第二项"),
            ]
        )
        XCTAssertEqual(
            NativeArticleBlockReference.scrollAnchorID(for: "decision"),
            "markdown-block-decision"
        )
        XCTAssertEqual(EditorBlockLinkQuery("笔记#^dec")?.target, "笔记")
        XCTAssertEqual(EditorBlockLinkQuery("笔记#^dec")?.searchText, "dec")
        XCTAssertEqual(
            NativeArticleLink.destination(for: "笔记#^decision", in: [])?.heading,
            "^decision"
        )

        let parsed = NativeParsedMarkdownDocument(source: body)
        XCTAssertTrue(parsed.blockAnchorIDs.contains("markdown-block-decision"))
        XCTAssertTrue(parsed.blockAnchorIDs.contains("markdown-block-whole-list"))
        let hasAnchoredListItem = parsed.blocks.contains { block in
            guard case let .list(items) = block else { return false }
            return items.contains { $0.blockID == "first-item" && $0.text == "第一项" }
        }
        XCTAssertTrue(hasAnchoredListItem)

        let rich = NativeMarkdownArticleDocument(markdown: """
        ![[manual.pdf]]

        ![[recording.m4a]]

        ```mermaid
        flowchart LR
          A --> B
        ```

        $$
        E = mc^2
        $$

        行内公式 $x^2 + y^2 = z^2$。
        """)
        var hasPDF = false
        var hasAudio = false
        var hasMermaid = false
        var hasDisplayMath = false
        var hasInlineMath = false
        XCTAssertEqual(rich.embeddedAttachmentURLs, Set(["manual.pdf", "recording.m4a"]))
        for block in rich.blocks {
            switch block {
            case let .pdf(reference, _): hasPDF = reference == "manual.pdf"
            case let .audio(reference, _): hasAudio = reference == "recording.m4a"
            case let .text(blocks, _, _, _):
                for markdownBlock in blocks {
                    switch markdownBlock {
                    case .mermaid: hasMermaid = true
                    case let .math(_, display): hasDisplayMath = display
                    case let .paragraph(text):
                        hasInlineMath = hasInlineMath
                            || MarkdownMathSource.containsInlineExpression(in: text)
                    default: break
                    }
                }
            default: break
            }
        }
        XCTAssertTrue(hasPDF)
        XCTAssertTrue(hasAudio)
        XCTAssertTrue(hasMermaid)
        XCTAssertTrue(hasDisplayMath)
        XCTAssertTrue(hasInlineMath)
    }

    func testMarkdownTypographyCompressesCJKPunctuationWithoutChangingText() throws {
        let source = "中国台湾独立摇滚乐队，前身**草东街派对**；继续，[链接](https://example.com)。"
        let parsed = try AttributedString(markdown: source)
        let compressed = MarkdownTypography.compressedCJKPunctuation(in: parsed)
        let rendered = NSAttributedString(compressed)

        XCTAssertEqual(String(compressed.characters), String(parsed.characters))
        let commaLocation = (rendered.string as NSString).range(of: "，").location
        let semicolonLocation = (rendered.string as NSString).range(of: "；").location
        XCTAssertEqual(rendered.attribute(NSAttributedString.Key.kern, at: commaLocation, effectiveRange: nil) as? CGFloat, -5)
        XCTAssertEqual(rendered.attribute(NSAttributedString.Key.kern, at: semicolonLocation, effectiveRange: nil) as? CGFloat, -5)
        XCTAssertNil(rendered.attribute(NSAttributedString.Key.kern, at: 0, effectiveRange: nil))
        XCTAssertTrue(compressed.runs.contains {
            $0.inlinePresentationIntent?.contains(InlinePresentationIntent.stronglyEmphasized) == true
        })
        XCTAssertTrue(compressed.runs.contains { $0.link != nil })
    }

    func testBlockEditorRoundTripsMarkdownAndTransformsBlockTypes() {
        let source = """
        # 计划

        第一段

        - 项目 A
        - [ ] 项目 B

        ```swift
        let value = 1

        print(value)
        ```
        """
        let blocks = NativeBlockEditorDocument.parse(source)
        XCTAssertEqual(blocks.map(\.kind), [
            .heading1,
            .paragraph,
            .bulletedList,
            .task,
            .code,
        ])
        XCTAssertEqual(NativeBlockEditorDocument.render(blocks), source)

        var movable = NativeBlockEditorDocument.parse("第一块\n\n第二块\n\n第三块")
        let firstID = movable[0].id
        let thirdID = movable[2].id
        XCTAssertTrue(NativeBlockEditorDocument.move(
            &movable,
            blockID: firstID,
            relativeTo: thirdID
        ))
        XCTAssertEqual(
            NativeBlockEditorDocument.render(movable),
            "第二块\n\n第三块\n\n第一块"
        )

        var multiMovable = NativeBlockEditorDocument.parse("A\n\nB\n\nC\n\nD")
        let selectedIDs = Set([multiMovable[1].id, multiMovable[2].id])
        let firstDestinationID = multiMovable[0].id
        XCTAssertTrue(NativeBlockEditorDocument.move(
            &multiMovable,
            blockIDs: selectedIDs,
            relativeTo: firstDestinationID
        ))
        XCTAssertEqual(NativeBlockEditorDocument.render(multiMovable), "B\n\nC\n\nA\n\nD")
        let regroupedIDs = Set([multiMovable[0].id, multiMovable[1].id])
        let lastDestinationID = multiMovable[3].id
        XCTAssertTrue(NativeBlockEditorDocument.move(
            &multiMovable,
            blockIDs: regroupedIDs,
            relativeTo: lastDestinationID
        ))
        XCTAssertEqual(NativeBlockEditorDocument.render(multiMovable), "A\n\nD\n\nB\n\nC")
        XCTAssertEqual(
            NativeBlockEditorDocument.appending(
                ["## 搬入标题", "- [ ] 搬入任务"],
                to: "目标笔记正文"
            ),
            "目标笔记正文\n\n## 搬入标题\n\n- [ ] 搬入任务"
        )

        let parent = EditorMarkdownBlock(markdown: "- 父块", isCollapsed: true)
        let child = EditorMarkdownBlock(markdown: "- 子块", depth: 1)
        let grandchild = EditorMarkdownBlock(markdown: "- 孙块", depth: 2)
        let sibling = EditorMarkdownBlock(markdown: "同级正文")
        var hierarchy = [parent, child, grandchild, sibling]
        let hierarchyMarkdown = NativeBlockEditorDocument.render(hierarchy)
        XCTAssertTrue(hierarchyMarkdown.contains("leon:block depth=0 collapsed=true"))
        XCTAssertTrue(hierarchyMarkdown.contains("  - 子块"))
        let hierarchyRoundTrip = NativeBlockEditorDocument.parse(hierarchyMarkdown)
        XCTAssertEqual(hierarchyRoundTrip.map(\.depth), [0, 1, 2, 0])
        XCTAssertEqual(hierarchyRoundTrip.map(\.isCollapsed), [true, false, false, false])
        XCTAssertEqual(NativeBlockEditorDocument.visibleBlocks(hierarchyRoundTrip).map(\.markdown), [
            "- 父块", "同级正文",
        ])
        var renderedListDepths: [Int] = []
        for articleBlock in NativeMarkdownArticleDocument(markdown: hierarchyMarkdown).blocks {
            guard case let .text(markdownBlocks, _, _, _) = articleBlock else { continue }
            for markdownBlock in markdownBlocks {
                if case let .list(items) = markdownBlock {
                    renderedListDepths.append(contentsOf: items.map(\.depth))
                }
            }
        }
        XCTAssertEqual(renderedListDepths, [0, 1, 2])
        XCTAssertEqual(
            NativeBlockEditorDocument.descendantIDs(of: [parent.id], in: hierarchy),
            Set([parent.id, child.id, grandchild.id])
        )
        XCTAssertTrue(NativeBlockEditorDocument.move(
            &hierarchy,
            blockIDs: Set([parent.id, child.id, grandchild.id]),
            relativeTo: sibling.id
        ))
        XCTAssertEqual(hierarchy.map(\.markdown), ["同级正文", "- 父块", "- 子块", "- 孙块"])
        XCTAssertEqual(
            NativeBlockEditorDocument.syncedBlockReference(in: "![[source-note#^decision]]"),
            "source-note#^decision"
        )

        XCTAssertEqual(
            NativeBlockEditorDocument.converting("决定 ^choice", to: .heading2),
            "## 决定 ^choice"
        )
        let task = NativeBlockEditorDocument.converting("发布版本", to: .task)
        XCTAssertEqual(task, "- [ ] 发布版本")
        XCTAssertFalse(NativeBlockEditorDocument.isCompletedTask(task))
        XCTAssertEqual(NativeBlockEditorDocument.togglingTask(task), "- [x] 发布版本")
        XCTAssertTrue(NativeBlockEditorDocument.isCompletedTask("- [x] 发布版本"))

        let split = NativeBlockEditorDocument.split(
            task,
            atUTF16Location: (task as NSString).length
        )
        XCTAssertEqual(split?.0, task)
        XCTAssertEqual(split?.1, "- [ ] ")
        XCTAssertNil(NativeBlockEditorDocument.split("```\nlet x = 1\n```", atUTF16Location: 4))

        let table = NativeBlockEditorDocument.converting("本周进度", to: .table)
        XCTAssertEqual(EditorMarkdownBlockKind.detect(in: table), .table)
        XCTAssertTrue(table.contains("| --- | --- |"))
        XCTAssertNil(NativeBlockEditorDocument.split(table, atUTF16Location: 2))
        let math = NativeBlockEditorDocument.converting("x^2 + y^2", to: .math)
        XCTAssertEqual(EditorMarkdownBlockKind.detect(in: math), .math)
        XCTAssertEqual(
            NativeBlockEditorDocument.parse("$$\nx^2\n\n+ y^2\n$$").map(\.kind),
            [.math]
        )
        XCTAssertEqual(NativeBlockEditorDocument.converting(math, to: .paragraph), "x^2 + y^2")

        let addressable = NativeBlockEditorDocument.ensuringBlockID(in: "一段内容")
        XCTAssertEqual(NativeBlockEditorDocument.blockID(in: addressable.markdown), addressable.id)
        XCTAssertEqual(NativeBlockEditorDocument.removingBlockID(from: addressable.markdown), "一段内容")
    }

    func testBlockParagraphBoundariesFollowPlainReturns() {
        let source = "第一段\r\n第二段\r\n\r\n第三段\r第四段\u{2029}第五段"
        let blocks = NativeBlockEditorDocument.parse(source)
        XCTAssertEqual(blocks.map(\.markdown), ["第一段", "第二段", "第三段", "第四段", "第五段"])
        XCTAssertEqual(NativeBlockEditorDocument.render(blocks), "第一段\n\n第二段\n\n第三段\n\n第四段\n\n第五段")
        XCTAssertEqual(NativeBlockEditorDocument.parse(NativeBlockEditorDocument.render(blocks)).map(\.markdown), blocks.map(\.markdown))

        let inlineBreaks = "第一行\\\n第二行  \n第三行\n下一段"
        XCTAssertEqual(NativeBlockEditorDocument.parse(inlineBreaks).map(\.markdown), [
            "第一行\\\n第二行  \n第三行", "下一段",
        ])
        XCTAssertEqual(NativeBlockEditorDocument.parse("末尾转义\\\\\n下一段").count, 2)
    }

    func testBlockParagraphSplittingPreservesStructuredContent() {
        let source = """
        开头
        | 项目 | 进度 |
        | --- | --- |
        | 编辑器 | 完成 |
        表格后的段落
        ```swift
        let value = 1

        print(value)
        ```
        $$
        x^2

        + y^2
        $$
        - 项目
          缩进的续行
        > 第一段引用
        > 第二段引用
        > [!NOTE]
        > 提示的第一行
        > 提示的第二行
        结尾 ^ending
        """
        let blocks = NativeBlockEditorDocument.parse(source)
        XCTAssertEqual(blocks.map(\.kind), [
            .paragraph, .table, .paragraph, .code, .math,
            .bulletedList, .quote, .quote, .callout, .paragraph,
        ])
        XCTAssertEqual(blocks[1].markdown, "| 项目 | 进度 |\n| --- | --- |\n| 编辑器 | 完成 |")
        XCTAssertEqual(blocks[5].markdown, "- 项目\n  缩进的续行")
        XCTAssertEqual(blocks[8].markdown, "> [!NOTE]\n> 提示的第一行\n> 提示的第二行")
        XCTAssertEqual(NativeBlockEditorDocument.blockID(in: blocks.last!.markdown), "ending")
        let reopened = NativeBlockEditorDocument.parse(NativeBlockEditorDocument.render(blocks))
        XCTAssertEqual(reopened.map(\.markdown), blocks.map(\.markdown))
    }

    func testBlockSelectionOwnsRangeToggleAndReconciliationRules() {
        let ids = (0..<4).map { _ in UUID() }
        var selection = EditorBlockSelection()

        selection.select(ids[1], orderedIDs: ids, mode: .replace)
        selection.select(ids[3], orderedIDs: ids, mode: .extend(additive: false))
        XCTAssertEqual(selection.selectedIDs, Set(ids[1...3]))
        XCTAssertEqual(selection.focusedID, ids[3])

        selection.select(ids[0], orderedIDs: ids, mode: .toggle)
        XCTAssertEqual(selection.selectedIDs, Set(ids))
        selection.select(ids[2], orderedIDs: ids, mode: .toggle)
        XCTAssertEqual(selection.selectedIDs, Set([ids[0], ids[1], ids[3]]))

        selection.reconcile(validIDs: [ids[0], ids[1]])
        XCTAssertEqual(selection.selectedIDs, Set([ids[0], ids[1]]))
        XCTAssertNil(selection.focusedID)

        selection.anchorID = UUID()
        selection.select(ids[1], orderedIDs: ids, mode: .extend(additive: true))
        XCTAssertEqual(selection.selectedIDs, Set([ids[0]]))

        selection.escape(to: ids[0])
        XCTAssertEqual(selection.selectedIDs, Set([ids[0]]))
        XCTAssertNil(selection.focusedID)
    }

    func testBlockTemplatesPersistAndBuiltInsParse() {
        for template in EditorBlockTemplateCatalog.builtIn {
            let blocks = NativeBlockEditorDocument.parse(template.body)
            XCTAssertFalse(blocks.isEmpty)
            XCTAssertFalse(NativeBlockEditorDocument.render(blocks).isEmpty)
        }
        XCTAssertTrue(
            NativeBlockEditorDocument.parse(EditorBlockTemplateCatalog.builtIn[0].body)
                .contains(where: { $0.depth > 0 })
        )
        XCTAssertTrue(
            NativeBlockEditorDocument.parse(EditorBlockTemplateCatalog.builtIn[2].body)
                .contains(where: { $0.kind == .table })
        )

        let suiteName = "leon-book-block-template-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let custom = [EditorBlockTemplate(name: "项目模板", body: "## 项目\n\n- [ ] 任务")]
        EditorBlockTemplateCatalog.saveCustom(custom, defaults: defaults)
        XCTAssertEqual(EditorBlockTemplateCatalog.loadCustom(defaults: defaults), custom)
    }

    @MainActor
    func testPageTemplatesApplyMetadataAndPersistPerWorkspace() {
        let meeting = NativeArticlePageTemplateCatalog.builtIn[0]
        let fixedDate = ISO8601DateFormatter().date(from: "2026-08-30T09:15:00Z")!
        var draft = NativeEditorDraft()
        let recoveryID = draft.recoveryID
        meeting.apply(to: &draft, at: fixedDate, timeZone: TimeZone(secondsFromGMT: 0)!)

        XCTAssertEqual(draft.recoveryID, recoveryID)
        XCTAssertEqual(draft.title, "会议记录 · 2026-08-30")
        XCTAssertEqual(draft.category, "Meetings")
        XCTAssertEqual(draft.tags, "#会议")
        XCTAssertTrue(draft.body.contains("2026-08-30 09:15"))
        XCTAssertEqual(draft.properties["日期"], .date("2026-08-30"))
        XCTAssertEqual(draft.properties["状态"], .status("进行中"))
        XCTAssertEqual(draft.status, .draft)
        XCTAssertTrue(NativeArticlePageTemplate.canCapture(draft))

        let suiteName = "leon-book-page-template-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let library = NativeArticlePageTemplateLibrary(defaults: defaults)

        library.prepare(for: "workspace-one")
        XCTAssertTrue(library.save(draft, named: "团队会议"))
        XCTAssertEqual(library.customTemplates.map(\.name), ["团队会议"])

        library.prepare(for: "workspace-two")
        XCTAssertTrue(library.customTemplates.isEmpty)

        library.prepare(for: "workspace-one")
        XCTAssertEqual(library.customTemplates.first?.title, draft.title)
        XCTAssertEqual(library.customTemplates.first?.properties, draft.properties)
        XCTAssertTrue(library.save(draft, named: "团队会议"))
        XCTAssertEqual(library.customTemplates.count, 1, "saving the same name should update instead of duplicate")
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

    func testWorkspaceResourceTreeHidesJSONFiles() {
        let article = NativeArticleSummary(
            banner: nil,
            category: "Notes",
            excerpt: "",
            publishedAt: nil,
            slug: "note",
            sourceRelativePath: "note.md",
            status: .draft,
            tags: [],
            title: "Note",
            updatedAt: "2026-09-01T00:00:00Z",
            wordCount: 1
        )
        let records = [
            NativeWorkspaceResourceRecord(
                kind: .file,
                storage: .markdownSource,
                relativePath: "note.md",
                placementFolderPath: "",
                absolutePath: "/vault/note.md"
            ),
            NativeWorkspaceResourceRecord(
                kind: .file,
                storage: .markdownSource,
                relativePath: "note.json",
                placementFolderPath: "",
                absolutePath: "/vault/note.json"
            ),
            NativeWorkspaceResourceRecord(
                kind: .file,
                storage: .markdownSource,
                relativePath: "index.json",
                placementFolderPath: "",
                absolutePath: "/vault/index.json"
            ),
            NativeWorkspaceResourceRecord(
                kind: .file,
                storage: .markdownSource,
                relativePath: "nested/config.JSON",
                placementFolderPath: "nested",
                absolutePath: "/vault/nested/config.JSON"
            ),
            NativeWorkspaceResourceRecord(
                kind: .file,
                storage: .managedMedia,
                relativePath: "note/data.json",
                placementFolderPath: "",
                absolutePath: "/vault/media/note/data.json",
                displayName: "data.json"
            ),
            NativeWorkspaceResourceRecord(
                kind: .file,
                storage: .markdownSource,
                relativePath: "attachment.pdf",
                placementFolderPath: "",
                absolutePath: "/vault/attachment.pdf"
            ),
        ]

        let flattened = NativeWorkspaceResourceTree.flattened(
            NativeWorkspaceResourceTree.build(articles: [article], records: records)
        )
        XCTAssertEqual(flattened.filter { $0.kind == .article }.map(\.articleSlug), ["note"])
        XCTAssertEqual(flattened.filter { $0.kind == .attachment }.map(\.name), ["attachment.pdf"])
        XCTAssertFalse(flattened.contains { $0.relativePath.lowercased().hasSuffix(".json") })
        XCTAssertFalse(flattened.contains { $0.kind == .folder && $0.relativePath == "nested" })
    }

    func testP0PageHierarchyDatabaseLayoutsRelationsAndRollups() throws {
        XCTAssertEqual(NativeArticlePageHierarchy.containerPath(for: "Projects/Alpha.md"), "Projects")
        XCTAssertEqual(NativeArticlePageHierarchy.containerPath(for: "Projects/index.md"), "Projects")
        XCTAssertEqual(
            NativeArticlePageHierarchy.breadcrumbs(folderPath: "Projects/Alpha").map(\.title),
            ["Projects", "Alpha"]
        )

        func summary(_ slug: String, _ path: String, _ title: String) -> NativeArticleSummary {
            NativeArticleSummary(
                banner: nil,
                category: "Notes",
                excerpt: "",
                publishedAt: nil,
                slug: slug,
                sourceRelativePath: path,
                status: .draft,
                tags: [],
                title: title,
                updatedAt: "2026-08-30T00:00:00Z",
                wordCount: 1
            )
        }
        let pageArticles = [
            summary("project", "Project.md", "Project"),
            summary("child", "Project/Child.md", "Child"),
            summary("docs", "Docs/index.md", "Docs"),
            summary("docs-child", "Docs/Guide.md", "Guide"),
        ]
        let records = [
            NativeWorkspaceResourceRecord(kind: .folder, storage: .markdownSource, relativePath: "Project", placementFolderPath: "", absolutePath: "/vault/Project"),
            NativeWorkspaceResourceRecord(kind: .folder, storage: .markdownSource, relativePath: "Docs", placementFolderPath: "", absolutePath: "/vault/Docs"),
        ] + pageArticles.map {
            NativeWorkspaceResourceRecord(
                kind: .file,
                storage: .markdownSource,
                relativePath: $0.sourceRelativePath,
                placementFolderPath: $0.sourceFolderPath,
                absolutePath: "/vault/\($0.sourceRelativePath)"
            )
        }
        let roots = NativeWorkspaceResourceTree.build(articles: pageArticles, records: records)
        let project = roots.first(where: { $0.kind == .folder && $0.relativePath == "Project" })
        let docs = roots.first(where: { $0.kind == .folder && $0.relativePath == "Docs" })
        XCTAssertEqual(project?.children.map(\.articleSlug), ["child"])
        XCTAssertEqual(Set(docs?.children.compactMap(\.articleSlug) ?? []), Set(["docs", "docs-child"]))
        XCTAssertTrue(NativeWorkspaceResourceTree.folderPaths(in: roots).contains("Project"))

        let layouts: [NativeSmartCollectionLayout] = [.board, .calendar]
        XCTAssertEqual(
            try JSONDecoder().decode([NativeSmartCollectionLayout].self, from: JSONEncoder().encode(layouts)),
            layouts
        )
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("leon-book-p0-base-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let calendarView = NativeSmartCollectionView(
            id: "calendar-view",
            name: "计划",
            layout: .calendar,
            calendarDatePropertyKey: "due",
            columns: [
                .system(.title),
                NativeSmartCollectionColumn(source: .property, key: "due", propertyKind: .date),
                NativeSmartCollectionColumn(source: .property, key: "project", propertyKind: .relation),
                NativeSmartCollectionColumn(source: .property, key: "total", propertyKind: .rollup),
            ]
        )
        let calendarCollection = NativeSmartCollection(
            id: "p0-calendar",
            name: "计划",
            calendarDatePropertyKey: "due",
            layout: .calendar,
            columns: calendarView.columns,
            views: [calendarView],
            activeViewID: calendarView.id
        )
        _ = try NativeSmartCollectionFile.write(calendarCollection, in: baseDirectory)
        let persistedCalendar = try NativeSmartCollectionFile.readAll(in: baseDirectory)[0]
        XCTAssertEqual(persistedCalendar.layout, .calendar)
        XCTAssertEqual(persistedCalendar.calendarDatePropertyKey, "due")
        XCTAssertEqual(
            persistedCalendar.columns.first(where: { $0.key == "due" })?.propertyKind,
            .date
        )
        XCTAssertEqual(
            persistedCalendar.columns.first(where: { $0.key == "project" })?.propertyKind,
            .relation
        )

        let relation = NativeArticlePropertyValue.relation(["Task One", "task-two"])
        XCTAssertEqual(relation.listValues, ["Task One", "task-two"])
        let relationRoundTrip = NativeArticlePropertyValue.fromYAML(relation.yamlValue)
        XCTAssertEqual(relationRoundTrip.kind, .relation)
        XCTAssertEqual(relationRoundTrip.listValues, relation.listValues)

        let projectSummary = NativeArticleSummary(
            banner: nil,
            category: "Projects",
            excerpt: "",
            properties: [
                "tasks": relation,
                "effort": .rollup("tasks | points | sum"),
            ],
            publishedAt: nil,
            slug: "project-rollup",
            status: .draft,
            tags: [],
            title: "Project Rollup",
            updatedAt: "2026-08-30T00:00:00Z",
            wordCount: 1
        )
        let taskOne = NativeArticleSummary(
            banner: nil, category: "Tasks", excerpt: "", properties: ["points": .number(2)],
            publishedAt: nil, slug: "task-one", status: .draft, tags: [], title: "Task One",
            updatedAt: "2026-08-30T00:00:00Z", wordCount: 1
        )
        let taskTwo = NativeArticleSummary(
            banner: nil, category: "Tasks", excerpt: "", properties: ["points": .number(3)],
            publishedAt: nil, slug: "task-two", status: .draft, tags: [], title: "Task Two",
            updatedAt: "2026-08-30T00:00:00Z", wordCount: 1
        )
        XCTAssertEqual(
            NativeArticleRollup.displayText(
                specification: projectSummary.properties["effort"]?.value ?? "",
                article: projectSummary,
                articles: [projectSummary, taskOne, taskTwo]
            ),
            "5"
        )
    }

    func testDatabaseViewQuickCreatePrefillsDraftFields() {
        var draft = NativeEditorDraft()
        XCTAssertTrue(NativeArticleDraftPrefill.applyBoardGroup(
            label: NativeArticleStatus.published.label,
            field: .status,
            to: &draft
        ))
        XCTAssertEqual(draft.status, .published)
        XCTAssertTrue(NativeArticleDraftPrefill.applyBoardGroup(
            label: "Research",
            field: .category,
            to: &draft
        ))
        XCTAssertEqual(draft.category, "Research")
        XCTAssertTrue(NativeArticleDraftPrefill.applyBoardGroup(
            label: "#Swift",
            field: .tag,
            to: &draft
        ))
        XCTAssertEqual(draft.tags, "Swift")
        XCTAssertFalse(NativeArticleDraftPrefill.applyBoardGroup(
            label: "2026年8月",
            field: .updatedMonth,
            to: &draft
        ))
        XCTAssertTrue(NativeArticleDraftPrefill.applyCalendarDate(
            "2026-08-30",
            propertyKey: "due",
            to: &draft
        ))
        XCTAssertEqual(draft.properties["due"], .date("2026-08-30"))
        XCTAssertFalse(NativeArticleDraftPrefill.applyCalendarDate(
            "not-a-date",
            propertyKey: "due",
            to: &draft
        ))
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
                "finished": .checkbox(true),
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
            properties: [
                "price": .number(7.5),
                "months": .number(2),
                "finished": .checkbox(false),
            ],
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
                NativeSmartCollectionFormula(key: "case_cost", name: "大小写", expression: "PRICE * MONTHS"),
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
            NativeSmartCollectionFormulaEngine.formulaValue("case_cost", article: first, collection: collection, now: now),
            .number(50)
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

        let priceColumn = NativeSmartCollectionColumn(source: .property, key: "price", title: "价格")
        let finishedColumn = NativeSmartCollectionColumn(source: .property, key: "finished", title: "完成")
        XCTAssertEqual(
            NativeSmartCollectionFormulaEngine.summary(
                .filled,
                column: priceColumn,
                articles: [first, second],
                collection: collection,
                now: now
            ),
            .number(2)
        )
        XCTAssertEqual(
            NativeSmartCollectionFormulaEngine.summary(
                .empty,
                column: priceColumn,
                articles: [first, second],
                collection: collection,
                now: now
            ),
            .number(0)
        )
        XCTAssertEqual(
            NativeSmartCollectionFormulaEngine.summary(
                .unique,
                column: priceColumn,
                articles: [first, second],
                collection: collection,
                now: now
            ),
            .number(2)
        )
        XCTAssertEqual(
            NativeSmartCollectionFormulaEngine.summary(
                .average,
                column: priceColumn,
                articles: [first, second],
                collection: collection,
                now: now
            ),
            .number(10)
        )
        XCTAssertEqual(
            NativeSmartCollectionFormulaEngine.summary(
                .minimum,
                column: priceColumn,
                articles: [first, second],
                collection: collection,
                now: now
            ),
            .number(7.5)
        )
        XCTAssertEqual(
            NativeSmartCollectionFormulaEngine.summary(
                .maximum,
                column: priceColumn,
                articles: [first, second],
                collection: collection,
                now: now
            ),
            .number(12.5)
        )
        XCTAssertEqual(
            NativeSmartCollectionFormulaEngine.summary(
                .checked,
                column: finishedColumn,
                articles: [first, second],
                collection: collection,
                now: now
            ),
            .number(1)
        )
        XCTAssertEqual(
            NativeSmartCollectionFormulaEngine.summary(
                .unchecked,
                column: finishedColumn,
                articles: [first, second],
                collection: collection,
                now: now
            ),
            .number(1)
        )
    }

    func testDeclarativeExtensionsExposeFiveSafeCapabilities() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("reading-tools", isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let manifest = DeclarativeExtensionManifest(
            id: "demo.reading-tools",
            name: "Reading Tools",
            version: "1.0.0",
            description: "Safe test extension",
            commands: [
                DeclarativeExtensionCommand(
                    id: "daily-note",
                    title: "Daily note",
                    action: DeclarativeExtensionCommandAction(
                        type: .newNote,
                        title: "{{date}} · {{team}}",
                        body: "Owner: {{user}}"
                    )
                ),
            ],
            templateVariables: ["team": "Research"],
            importers: [
                DeclarativeExtensionImporter(
                    id: "book-json",
                    title: "Book JSON",
                    fileExtensions: ["json"],
                    format: .json,
                    titleTemplate: "{{json.title}}",
                    bodyTemplate: "Author: {{json.author}}"
                ),
            ],
            renderers: [
                DeclarativeExtensionRenderer(
                    language: "book-card",
                    titleTemplate: "{{team}} card",
                    bodyTemplate: "{{content}}",
                    style: .card
                ),
            ],
            baseFunctions: [
                DeclarativeExtensionBaseFunction(
                    name: "double",
                    parameters: ["value"],
                    expression: "value * 2"
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: packageURL.appendingPathComponent("extension.json"),
            options: .atomic
        )

        var runtime = try DeclarativeExtensionLoader.load(from: root)
        XCTAssertEqual(runtime.packages.map(\.id), ["demo.reading-tools"])
        XCTAssertTrue(runtime.diagnostics.isEmpty)
        XCTAssertEqual(runtime.commands.count, 1)
        XCTAssertEqual(runtime.importers.count, 1)
        XCTAssertEqual(runtime.renderers.count, 1)
        XCTAssertEqual(runtime.baseFunctions.count, 1)

        let fixedNow = Date(timeIntervalSince1970: 0)
        let renderedCommand = runtime.renderTemplate(
            runtime.commands[0].command.action.title ?? "",
            context: ["user": "Leon"],
            now: fixedNow
        )
        XCTAssertEqual(renderedCommand.value, "1970-01-01 · Research")
        XCTAssertTrue(renderedCommand.unresolvedVariables.isEmpty)

        let imported = try runtime.importDocument(
            using: runtime.importers[0],
            data: Data(#"{"title":"Dune","author":"Frank Herbert"}"#.utf8),
            fileName: "dune.json",
            now: fixedNow
        )
        XCTAssertEqual(imported.title, "Dune")
        XCTAssertEqual(imported.body, "Author: Frank Herbert")
        XCTAssertTrue(imported.unresolvedVariables.isEmpty)

        let block = runtime.renderBlock(language: "book-card", content: "Dune", now: fixedNow)
        XCTAssertEqual(block?.title, "Research card")
        XCTAssertEqual(block?.body, "Dune")
        XCTAssertEqual(block?.style, .card)

        let article = NativeArticleSummary(
            banner: nil,
            category: "Books",
            excerpt: "",
            publishedAt: nil,
            slug: "dune",
            status: .draft,
            tags: [],
            title: "Dune",
            updatedAt: "2026-08-30T00:00:00Z",
            wordCount: 21
        )
        let collection = NativeSmartCollection(
            name: "Reading",
            formulas: [
                NativeSmartCollectionFormula(
                    key: "score",
                    name: "Score",
                    expression: "double(wordcount)"
                ),
            ]
        )
        XCTAssertEqual(
            NativeSmartCollectionFormulaEngine.formulaValue(
                "score",
                article: article,
                collection: collection,
                baseFunctions: runtime.baseFunctions.map(\.function)
            ),
            .number(42)
        )

        XCTAssertTrue(runtime.setEnabled(false, extensionID: "demo.reading-tools"))
        XCTAssertTrue(runtime.commands.isEmpty)
        XCTAssertTrue(runtime.importers.isEmpty)
        XCTAssertTrue(runtime.renderers.isEmpty)
        XCTAssertTrue(runtime.baseFunctions.isEmpty)
    }

    func testDeclarativeExtensionRejectsExecutableTemplates() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("unsafe", isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let manifest = DeclarativeExtensionManifest(
            id: "demo.unsafe-extension",
            name: "Unsafe",
            version: "1.0.0",
            commands: [
                DeclarativeExtensionCommand(
                    id: "insert-script",
                    title: "Unsafe",
                    action: DeclarativeExtensionCommandAction(
                        type: .insertText,
                        text: "```html-render\n<script>alert(1)</script>\n```"
                    )
                ),
            ]
        )
        try JSONEncoder().encode(manifest).write(
            to: packageURL.appendingPathComponent("extension.json"),
            options: .atomic
        )

        let runtime = try DeclarativeExtensionLoader.load(from: root)
        XCTAssertTrue(runtime.packages.isEmpty)
        XCTAssertEqual(runtime.diagnostics.count, 1)
        XCTAssertTrue(runtime.diagnostics[0].message.contains("被禁止的可执行内容"))
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

    func testArticleGraphLayoutAppliesAndClampsManualNodePositions() {
        let nodes = [
            graphArticle(
                slug: "first",
                title: "First",
                status: .published,
                updatedAt: "2026-09-01T00:00:00Z"
            ),
            graphArticle(
                slug: "second",
                title: "Second",
                status: .published,
                updatedAt: "2026-09-02T00:00:00Z"
            ),
        ]
        let canvasSize = CGSize(width: 640, height: 520)
        let resolved = ArticleGraphLayout.resolvedPositions(
            for: nodes,
            in: canvasSize,
            manualPositions: [
                "first": CGPoint(x: 230, y: 310),
                "second": CGPoint(x: -100, y: 900),
            ]
        )

        XCTAssertEqual(resolved["first"], CGPoint(x: 230, y: 310))
        XCTAssertEqual(
            resolved["second"],
            CGPoint(
                x: ArticleGraphLayout.nodeSize.width / 2,
                y: canvasSize.height - ArticleGraphLayout.nodeSize.height / 2
            )
        )
    }

    func testArticleGraphShortestPathUsesVisibleDirectedReferences() {
        let articles = [
            graphArticle(slug: "start", title: "Start", status: .published, updatedAt: "2026-09-01T00:00:00Z"),
            graphArticle(slug: "long", title: "Long", status: .published, updatedAt: "2026-09-01T00:00:00Z"),
            graphArticle(slug: "middle", title: "Middle", status: .published, updatedAt: "2026-09-01T00:00:00Z"),
            graphArticle(slug: "finish", title: "Finish", status: .published, updatedAt: "2026-09-01T00:00:00Z"),
        ]
        let graph = NativeArticleGraph(
            nodes: articles,
            edges: [
                .init(sourceSlug: "start", targetSlug: "long"),
                .init(sourceSlug: "long", targetSlug: "middle"),
                .init(sourceSlug: "middle", targetSlug: "finish"),
                .init(sourceSlug: "start", targetSlug: "middle"),
            ]
        )

        let path = NativeArticleGraphPathFinder.shortestPath(
            in: graph,
            from: "start",
            to: "finish"
        )

        XCTAssertEqual(path?.nodes.map(\.slug), ["start", "middle", "finish"])
        XCTAssertEqual(
            path?.edges,
            [
                .init(sourceSlug: "start", targetSlug: "middle"),
                .init(sourceSlug: "middle", targetSlug: "finish"),
            ]
        )
        XCTAssertEqual(path?.hopCount, 2)
        XCTAssertNil(NativeArticleGraphPathFinder.shortestPath(in: graph, from: "finish", to: "start"))
    }

    @MainActor
    func testReloadPopulatesKnowledgeGraphWithIsolatedArticles() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "NativeKnowledgeGraphReloadTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("expected isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = NativeAppModel(
            navigationScopeID: nil,
            startsAutomatically: false,
            store: LocalBlogStore(rootURL: root)
        )
        model.firstPartyModuleRuntime = NativeFirstPartyModules.loadRuntime(defaults: defaults)
        _ = try await model.store.saveArticle(article(
            slug: "isolated-note",
            status: .published,
            expectedUpdatedAt: nil,
            body: "没有 Wiki 链接的正文",
            title: "孤立文章"
        ))

        try await model.reload()

        XCTAssertEqual(model.articles.map(\.slug), ["isolated-note"])
        XCTAssertEqual(
            model.articleGraph.nodes.map(\.slug),
            ["isolated-note"],
            "reloading the article library should also populate isolated graph nodes"
        )
        XCTAssertTrue(model.articleGraph.edges.isEmpty)
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

private final class WritingTextViewProbe: NSTextView {
    var isComposing = false
    override func hasMarkedText() -> Bool { isComposing }
}

private final class WritingStyleProbe: NSObject, NSTextStorageDelegate {
    var attributePasses = 0
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        if editedMask.contains(.editedAttributes) { attributePasses += 1 }
    }
}

private extension LocalBlogStore {
    func holdInteractionTestQueue(entered: @Sendable () -> Void, release: DispatchSemaphore) -> Bool {
        entered()
        return release.wait(timeout: .now() + 10) == .success
    }
}

@MainActor
final class AppInteractionTests {
    private func makeModel(root: URL) -> NativeAppModel {
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false, store: LocalBlogStore(rootURL: root))
        let suite = "AppInteractionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        model.firstPartyModuleRuntime = NativeFirstPartyModules.loadRuntime(defaults: defaults)
        defaults.removePersistentDomain(forName: suite)
        return model
    }

    private func holdStore(_ store: LocalBlogStore) async -> () async -> Void {
        let release = DispatchSemaphore(value: 0)
        var blocker: Task<Bool, Never>!
        await withCheckedContinuation { continuation in
            blocker = Task {
                await store.holdInteractionTestQueue(entered: { continuation.resume() }, release: release)
            }
        }
        return {
            release.signal()
            XCTAssertTrue(await blocker.value, "the test must release the store before its timeout")
        }
    }

    /// The queued main-thread continuation runs after the real request has
    /// suspended on the held store, so user actions can race it deterministically.
    private func beginBlockedRequest(
        _ model: NativeAppModel,
        operation: @escaping @MainActor () async throws -> Void
    ) async -> (Task<Void, Error>, () async -> Void) {
        let unblock = await holdStore(model.store)
        var reload: Task<Void, Error>!
        await withCheckedContinuation { continuation in
            reload = Task { @MainActor in
                DispatchQueue.main.async { continuation.resume() }
                try await operation()
            }
        }
        return (reload, unblock)
    }

    private func beginBlockedQuestionReload(_ model: NativeAppModel) async -> (Task<Void, Error>, () async -> Void) {
        await beginBlockedRequest(model) { try await model.reloadQuestionList() }
    }

    private func recoverySnapshot(body: String) -> NativeArticleRevisionSnapshot {
        NativeArticleRevisionSnapshot(
            banner: nil, body: body, category: "Notes", excerpt: "", media: [],
            status: .draft, tags: [], title: "恢复草稿", articleUpdatedAt: nil,
            properties: ["项目": .text("测试项目")]
        )
    }

    func testEditorRecoveryStartupRespectsNewerWork() async throws {
        for action in ["input", "navigation", "workspace", "cancel"] {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let model = makeModel(root: root)
            _ = try await model.store.saveArticleAutosave(
                draftKey: "unfinished", articleSlug: nil, snapshot: recoverySnapshot(body: "上次的未保存内容")
            )
            let (recovery, unblock) = await beginBlockedRequest(model) {
                try await model.restoreLatestUnsavedArticleDraftIfNeeded()
            }
            switch action {
            case "input": model.editor.body = "这次刚输入的内容"
            case "navigation": model.section = .settings
            case "workspace": model.workspaceGeneration += 1
            default: recovery.cancel()
            }
            let expectedDraft = model.editor
            let expectedSection = model.section
            await unblock()
            try await recovery.value
            XCTAssertEqual(model.editor, expectedDraft, "\(action): startup recovery must not overwrite newer editor state")
            XCTAssertEqual(model.section, expectedSection, "\(action): recovery must not pull the user back into the editor")
            XCTAssertTrue(model.articleRevisions.isEmpty, "\(action): obsolete recovery history must not replace the current history")
        }
    }

    func testEditorRecoveryOnOpenPreservesNewerTyping() async throws {
        for typesWhileLoading in [false, true] {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let model = makeModel(root: root)
            let saved = try await model.store.saveArticle(article(
                slug: "recovery-note", status: .draft, expectedUpdatedAt: nil, body: "正式正文"
            ))
            _ = try await model.store.saveArticleAutosave(
                draftKey: saved.slug, articleSlug: saved.slug,
                snapshot: recoverySnapshot(body: "待恢复的正文"), at: Date().addingTimeInterval(2)
            )
            model.selectedArticle = saved
            model.selectedSlug = saved.slug
            let unblock = await holdStore(model.store)
            model.editSelected()
            if typesWhileLoading { model.editor.body = "我刚输入的正文" }
            await unblock()
            await model.editorRecoveryTask?.value
            XCTAssertEqual(model.editor.body, typesWhileLoading ? "我刚输入的正文" : "待恢复的正文",
                           "opening an article may restore a draft only before the user starts editing")
        }
    }

    func testEditorRecoveryRestoresAnUntouchedStartupDraft() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root)
        let snapshot = recoverySnapshot(body: "尚未正式保存")
        let revision = try await model.store.saveArticleAutosave(draftKey: "unfinished", articleSlug: nil, snapshot: snapshot)
        try await model.restoreLatestUnsavedArticleDraftIfNeeded()
        XCTAssertEqual(model.editor.recoveryID, "unfinished")
        XCTAssertEqual(model.editor.body, snapshot.body)
        XCTAssertEqual(model.editor.properties, snapshot.properties)
        XCTAssertEqual(model.articleRevisions.map(\.id), [revision.id])
        XCTAssertEqual(model.section, .editor)
    }

    func testEditorRecoveryIncludesMetadataOnlyDrafts() async throws {
        for field in ["property", "category"] {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let model = makeModel(root: root)
            model.storageReady = true
            model.isLoading = false
            XCTAssertFalse(model.hasUnsavedEditorChanges)
            if field == "property" {
                model.editor.properties["项目"] = .text("重要资料")
            } else {
                model.editor.category = "工作"
            }
            XCTAssertTrue(model.hasUnsavedEditorChanges, "\(field): metadata changes must count as unsaved work")
            model.scheduleEditorAutosave()
            XCTAssertNotNil(model.editorAutosaveTask, "\(field): metadata-only drafts must be scheduled for recovery")
            await model.editorAutosaveTask?.value
            let revision = try await model.store.latestUnsavedArticleAutosave()
            XCTAssertNotNil(revision, "\(field): automatic saving must persist the metadata-only draft")
            if let revision {
                XCTAssertEqual(revision.snapshot.properties, model.editor.properties)
                XCTAssertEqual(revision.snapshot.category, model.editor.category)
            }
            await model.compatibilityExportTask?.value
        }
    }

    func testEditorRecoveryPendingAutosaveKeepsNewerSaveStatus() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root)
        model.storageReady = true
        model.isLoading = false
        model.editor.body = "上一轮内容"
        let unblock = await holdStore(model.store)
        model.scheduleEditorAutosave()
        let previousSave = model.editorAutosaveTask
        var saveStarted: AnyCancellable?
        await withCheckedContinuation { continuation in
            saveStarted = model.editorSession.$isAutosaving.filter { $0 }.prefix(1).sink { _ in
                continuation.resume()
            }
        }
        defer {
            saveStarted?.cancel()
            model.editorAutosaveTask?.cancel()
            model.compatibilityExportTask?.cancel()
        }
        model.editor.body = "这一轮还在输入"
        model.scheduleEditorAutosave()
        await unblock()
        await previousSave?.value
        XCTAssertEqual(model.editor.body, "这一轮还在输入")
        XCTAssertEqual(model.editorAutosaveStatus, "等待自动保存…",
                       "finishing an older save must not claim that the newer text has been saved")
    }

    func testSearchChangesHideOldResultsAndIgnorePendingOpen() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root)
        for title in ["alpha", "beta"] {
            _ = try await model.store.saveArticle(article(slug: title, status: .draft, expectedUpdatedAt: nil, body: title, title: title))
        }
        model.searchPresentation = .globalSearch
        model.updateGlobalSearch("alpha", articlesOnly: false, debounce: false)
        await model.globalSearchTask?.value
        guard let oldResult = model.globalSearchResults.first else {
            XCTFail("expected the first query to return an article")
            return
        }
        model.updateGlobalSearch("beta", articlesOnly: false)
        XCTAssertTrue(model.isSearchingGlobally)
        XCTAssertTrue(model.globalSearchResults.isEmpty, "changing the query must hide results for the previous query immediately")
        model.openSearchResult(oldResult)
        XCTAssertEqual(model.searchPresentation, .globalSearch, "Return during a pending search must not open a stale result")
        await model.globalSearchTask?.value
        XCTAssertEqual(model.globalSearchResults.map(\.documentID), ["beta"])
        XCTAssertFalse(model.isSearchingGlobally)
    }

    func testQuestionReloadPreservesNewerSelectionAndDraft() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root)
        let first = try await model.store.saveQuestion(title: "Swift", body: "first", tags: ["Swift"])
        let second = try await model.store.saveQuestion(title: "SQLite", body: "second", tags: ["SQLite"])
        try await model.reloadQuestionList(selecting: first.id)
        let (reload, unblock) = await beginBlockedQuestionReload(model)
        XCTAssertTrue(model.selectQuestion(second))
        model.questionAnswerDraft.body = "正在给第二个问题写回答"
        await unblock()
        try await reload.value
        XCTAssertEqual(model.selectedQuestion?.id, second.id, "a background refresh must not restore the older selection")
        XCTAssertEqual(model.questionAnswerDraft.body, "正在给第二个问题写回答", "a stale reload must not discard a newer draft")
    }

    func testObsoleteQuestionReloadDoesNotPublishItsResults() async throws {
        for invalidation in ["cancel", "query", "tag"] {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let model = makeModel(root: root)
            _ = try await model.store.saveQuestion(title: "Swift", body: "first", tags: ["Swift"])
            _ = try await model.store.saveQuestion(title: "SQLite", body: "second", tags: ["SQLite"])
            try await model.reloadQuestionList()
            let previous = model.questions
            model.questionSearchText = "Swift"
            let (reload, unblock) = await beginBlockedQuestionReload(model)
            switch invalidation {
            case "cancel": reload.cancel()
            case "query": model.questionSearchText = "SQLite"
            default: model.selectedQuestionTag = "SQLite"
            }
            await unblock()
            try await reload.value
            XCTAssertEqual(model.questions, previous, "\(invalidation) must invalidate the older question results")
        }
    }

    func testQuestionFilteringKeepsAnUnpublishedAnswer() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root)
        let first = try await model.store.saveQuestion(title: "Swift", body: "first", tags: ["Swift"])
        let second = try await model.store.saveQuestion(title: "SQLite", body: "second", tags: ["SQLite"])
        try await model.reloadQuestionList(selecting: first.id)
        model.questionAnswerDraft.body = "还没发布的回答"
        model.questionSearchText = "SQLite"
        try await model.reloadQuestionList()
        XCTAssertEqual(model.questions.map(\.id), [second.id], "the list must still apply the current search filter")
        XCTAssertEqual(model.selectedQuestion?.id, first.id)
        XCTAssertEqual(model.questionAnswerDraft.body, "还没发布的回答", "filtering the list must not silently discard an answer")
    }
}

@MainActor
final class EditorFocusTests {
    private func makeWindow<Editor: View>(editor: Editor, editorHeight: CGFloat = 260) -> (NSWindow, NSTextField, NSHostingView<Editor>) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: editorHeight + 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: editorHeight + 100))
        let title = NSTextField(frame: NSRect(x: 20, y: editorHeight + 40, width: 600, height: 32))
        title.placeholderString = "给这篇文章起个标题"
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 20, y: 20, width: 600, height: editorHeight)
        container.addSubview(title)
        container.addSubview(host)
        window.contentView = container
        host.layoutSubtreeIfNeeded()
        return (window, title, host)
    }

    private func drainFocusEvents() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func textView(in root: NSView) -> NSTextView? {
        if let textView = root as? NSTextView { return textView }
        return root.subviews.lazy.compactMap { self.textView(in: $0) }.first
    }

    private func blockEditor(_ text: String = "正文", shouldFocus: Bool = true) -> NativeBlockTextEditor {
        NativeBlockTextEditor(
            text: .constant(text), height: .constant(40), kind: .paragraph,
            typography: .default, isEditable: true, shouldFocus: shouldFocus,
            onFocus: {}, onSplit: { _ in }, onMergeBackward: {},
            onMoveBlocks: { _ in }, onChangeIndent: { _ in }, onBlockCommand: { _ in false }
        )
    }

    private func blockViews(in root: NSView) -> [NativeBlockNSTextView] {
        if let block = root as? NativeBlockNSTextView { return [block] }
        return root.subviews.flatMap { blockViews(in: $0) }
    }

    private func documentEditor(source: Binding<String>) -> ArticleBlockEditor {
        ArticleBlockEditor(
            source: source, documentID: "editing-experience", sourceSlug: nil,
            articleReference: "New article", isEditable: true, typography: .default,
            articleDestinations: [], onTransferBlocks: { _, _, _, _ in nil },
            onUndoTransfer: { _ in false }
        )
    }

    func testBlockEditingUsesIndependentFullWidthRows() async {
        let (window, _, host) = makeWindow(
            editor: documentEditor(source: .constant("第一块\n第二块\n\n第三块")),
            editorHeight: 480
        )
        defer { window.close() }
        await drainFocusEvents()
        host.layoutSubtreeIfNeeded()
        await drainFocusEvents()
        let views = blockViews(in: host)
        XCTAssertEqual(views.count, 3)
        let rows = views.map { $0.convert($0.bounds, to: host) }
        for row in rows {
            XCTAssertTrue(row.minX < 40, "block controls must not consume the text row's leading space")
            XCTAssertTrue(row.width > host.bounds.width - 100, "each block must have its own full-width text row")
        }
        for index in rows.indices.dropFirst() {
            XCTAssertFalse(rows[index - 1].intersects(rows[index]), "neighboring blocks must occupy separate rows")
        }
    }

    func testBlockParagraphPasteReplacesSelectionAndSupportsUndo() async {
        var source = "前缀选中后缀🌙"
        let (window, _, host) = makeWindow(
            editor: documentEditor(source: Binding(get: { source }, set: { source = $0 })),
            editorHeight: 480
        )
        defer { window.close() }
        await drainFocusEvents()
        host.layoutSubtreeIfNeeded()
        guard let body = blockViews(in: host).first else {
            XCTFail("expected a paragraph editor")
            return
        }
        XCTAssertTrue(window.makeFirstResponder(body))
        body.setSelectedRange((body.string as NSString).range(of: "选中"))
        body.insertText("第一段\r\n第二段\n\n第三段", replacementRange: body.selectedRange())
        await drainFocusEvents()
        host.layoutSubtreeIfNeeded()
        await drainFocusEvents()

        XCTAssertEqual(source, "前缀第一段\n\n第二段\n\n第三段后缀🌙")
        let paragraphs = blockViews(in: host)
        XCTAssertEqual(paragraphs.map(\.string), ["前缀第一段", "第二段", "第三段后缀🌙"])
        guard let last = paragraphs.last else { return }
        XCTAssertTrue(window.firstResponder === last)
        XCTAssertEqual(last.selectedRange(), NSRange(location: 3, length: 0))

        window.undoManager?.undo()
        await drainFocusEvents()
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(source, "前缀选中后缀🌙", "one undo must restore the paragraph before the paste")
        window.undoManager?.redo()
        await drainFocusEvents()
        XCTAssertEqual(source, "前缀第一段\n\n第二段\n\n第三段后缀🌙")
    }

    func testBlockParagraphSoftReturnSurvivesReopening() async {
        for prefix in ["", "# ", "- ", "12. ", "- [ ] ", "> "] {
            var source = prefix + "前半段后半段"
            let (window, _, host) = makeWindow(
                editor: documentEditor(source: Binding(get: { source }, set: { source = $0 })),
                editorHeight: 480
            )
            defer { window.close() }
            await drainFocusEvents()
            host.layoutSubtreeIfNeeded()
            guard let body = blockViews(in: host).first,
                  let coordinator = body.delegate as? NativeBlockTextEditor.Coordinator else {
                XCTFail("expected a paragraph editing delegate")
                return
            }
            XCTAssertTrue(window.makeFirstResponder(body))
            body.setSelectedRange(NSRange(location: (prefix as NSString).length + 3, length: 0))
            XCTAssertTrue(coordinator.textView(body, doCommandBy: #selector(NSResponder.insertLineBreak(_:))))
            await drainFocusEvents()
            XCTAssertEqual(source, prefix + "前半段\\\n后半段")
            XCTAssertEqual(blockViews(in: host).count, 1)
            XCTAssertEqual(NativeBlockEditorDocument.parse(source).map(\.markdown), [prefix + "前半段\\\n后半段"])
        }
    }

    func testBlockEditingEnterKeepsCaretBeforeTheSplitRemainder() async {
        let cases: [(prefix: String, remainderPrefix: String, separator: String)] = [
            ("", "", "\n\n"),
            ("# ", "", "\n\n"),
            ("- ", "- ", "\n"),
            ("12. ", "12. ", "\n"),
            ("- [ ] ", "- [ ] ", "\n"),
        ]
        for item in cases {
            var source = item.prefix + "前半段后半段"
            let (window, _, host) = makeWindow(
                editor: documentEditor(source: Binding(get: { source }, set: { source = $0 })),
                editorHeight: 480
            )
            defer { window.close() }
            await drainFocusEvents()
            host.layoutSubtreeIfNeeded()
            guard let body = blockViews(in: host).first,
                  let coordinator = body.delegate as? NativeBlockTextEditor.Coordinator else {
                XCTFail("expected the live block's editing delegate")
                return
            }
            XCTAssertTrue(window.makeFirstResponder(body))
            body.setSelectedRange(NSRange(location: (item.prefix as NSString).length + 3, length: 0))
            XCTAssertTrue(coordinator.textView(body, doCommandBy: #selector(NSResponder.insertNewline(_:))))
            await drainFocusEvents()
            host.layoutSubtreeIfNeeded()
            await drainFocusEvents()
            XCTAssertEqual(source, item.prefix + "前半段" + item.separator + item.remainderPrefix + "后半段")
            guard let remainder = blockViews(in: host).first(where: { $0.string == item.remainderPrefix + "后半段" }) else {
                XCTFail("Enter must create an independent block for the remainder")
                return
            }
            XCTAssertTrue(window.firstResponder === remainder)
            XCTAssertEqual(remainder.selectedRange(), NSRange(location: (item.remainderPrefix as NSString).length, length: 0),
                           "typing after Enter must start after the list marker and before the moved text")
        }
    }

    func testBlockEditingMergeKeepsCaretAtTheJoin() async {
        var source = "第一块\n\n第二块"
        let (window, _, host) = makeWindow(
            editor: documentEditor(source: Binding(get: { source }, set: { source = $0 })),
            editorHeight: 480
        )
        defer { window.close() }
        await drainFocusEvents()
        host.layoutSubtreeIfNeeded()
        guard let second = blockViews(in: host).first(where: { $0.string == "第二块" }),
              let coordinator = second.delegate as? NativeBlockTextEditor.Coordinator else {
            XCTFail("expected the second paragraph's live editing delegate")
            return
        }
        XCTAssertTrue(window.makeFirstResponder(second))
        second.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(coordinator.textView(second, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
        await drainFocusEvents()
        host.layoutSubtreeIfNeeded()
        await drainFocusEvents()
        XCTAssertEqual(source, "第一块 第二块")
        guard let merged = blockViews(in: host).first(where: { $0.string == source }) else {
            XCTFail("Backspace must merge the adjacent paragraphs")
            return
        }
        XCTAssertTrue(window.firstResponder === merged)
        XCTAssertEqual(merged.selectedRange(), NSRange(location: 4, length: 0), "typing after a merge must stay at the join")
    }

    func testBlockEditingHeightTracksWidthAndTheEmptyLastLine() async {
        var height: CGFloat = 40
        let editor = NativeBlockTextEditor(
            text: .constant(String(repeating: "中文正文自动折行。", count: 24) + "\n"),
            height: Binding(get: { height }, set: { height = $0 }), kind: .paragraph,
            typography: .default, isEditable: true, shouldFocus: false,
            onFocus: {}, onSplit: { _ in }, onMergeBackward: {},
            onMoveBlocks: { _ in }, onChangeIndent: { _ in }, onBlockCommand: { _ in false }
        )
        let (window, _, host) = makeWindow(editor: editor)
        defer { window.close() }
        await drainFocusEvents()
        guard let body = textView(in: host),
              let coordinator = body.delegate as? NativeBlockTextEditor.Coordinator else {
            XCTFail("expected a block text view and its real layout coordinator")
            return
        }
        coordinator.refreshPresentation(of: body)
        await drainFocusEvents()
        let wideHeight = height
        body.setFrameSize(NSSize(width: 220, height: body.frame.height))
        await drainFocusEvents()
        guard let manager = body.layoutManager, let container = body.textContainer else { return }
        manager.ensureLayout(for: container)
        XCTAssertTrue(height > wideHeight, "narrowing a block must grow its height to keep wrapped text visible")
        XCTAssertTrue(height >= manager.extraLineFragmentRect.maxY + body.textContainerInset.height * 2,
                      "the final empty line and its caret must fit inside the block")
    }

    func testBodyEditorInitialFocusPreservesTitleSelection() async {
        let editor = NativeBodyEditor(
            text: .constant(""), selectedRange: .constant(NSRange(location: 0, length: 0)),
            isEditable: true, linkController: ArticleLinkAutocompleteController(),
            slashController: EditorSlashCommandController(), appearance: .source,
            typography: .default, onPasteImage: { _, _ in }, onRunCommand: { _, _ in }
        )
        let (window, title, host) = makeWindow(editor: editor)
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(title), "the article title must accept focus")
        guard let titleEditor = title.currentEditor() else {
            XCTFail("expected the title's field editor to be active")
            return
        }
        await drainFocusEvents()
        XCTAssertTrue(window.firstResponder === titleEditor, "the body editor stole focus after clicking the article title")
        withExtendedLifetime(host) {}
    }

    func testBlockEditorRefreshPreservesTitleSelection() async {
        let (window, title, host) = makeWindow(editor: blockEditor())
        defer { window.close() }
        await drainFocusEvents()
        textView(in: host)?.setSelectedRange(NSRange(location: 1, length: 1))
        XCTAssertTrue(window.makeFirstResponder(title), "the article title must accept focus")
        guard let titleEditor = title.currentEditor() else {
            XCTFail("expected the title's field editor to be active")
            return
        }
        host.rootView = blockEditor("刷新后的正文")
        host.layoutSubtreeIfNeeded()
        await drainFocusEvents()
        XCTAssertEqual(textView(in: host)?.string, "刷新后的正文", "the test must exercise a real editor refresh")
        XCTAssertEqual(textView(in: host)?.selectedRange(), NSRange(location: 1, length: 1),
                       "an external text refresh must preserve the block's selection")
        XCTAssertTrue(window.firstResponder === titleEditor, "refreshing a previously focused block stole focus from the article title")
    }

    func testBodyEditorInitialFocusOnlyClaimsAnUnfocusedEditableWindow() async {
        for isEditable in [true, false] {
            let editor = NativeBodyEditor(
                text: .constant(""), selectedRange: .constant(NSRange(location: 0, length: 0)),
                isEditable: isEditable, linkController: ArticleLinkAutocompleteController(),
                slashController: EditorSlashCommandController(), appearance: .livePreview,
                typography: .default, onPasteImage: { _, _ in }, onRunCommand: { _, _ in }
            )
            let (window, _, host) = makeWindow(editor: editor)
            defer { window.close() }
            XCTAssertTrue(window.makeFirstResponder(window))
            await drainFocusEvents()
            guard let body = textView(in: host) else {
                XCTFail("expected a real body text view")
                return
            }
            XCTAssertEqual(window.firstResponder === body, isEditable, "only an editable body may take initial focus")
        }
    }

    func testBlockEditorPendingFocusPreservesNewerTitleSelection() async {
        let (window, title, host) = makeWindow(editor: blockEditor())
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(title))
        let titleEditor = title.currentEditor()
        XCTAssertNotNil(titleEditor)
        await drainFocusEvents()
        XCTAssertTrue(window.firstResponder === titleEditor, "a queued block focus request must respect a newer title click")
        withExtendedLifetime(host) {}
    }

    func testBlockEditorExplicitFocusCanBeRequestedAgain() async {
        let (window, title, host) = makeWindow(editor: blockEditor(shouldFocus: false))
        defer { window.close() }
        await drainFocusEvents()
        guard let body = textView(in: host) else {
            XCTFail("expected a real block text view")
            return
        }
        for _ in 0..<2 {
            XCTAssertTrue(window.makeFirstResponder(title))
            host.rootView = blockEditor(shouldFocus: true)
            host.layoutSubtreeIfNeeded()
            await drainFocusEvents()
            XCTAssertTrue(window.firstResponder === body, "an explicit block selection must still receive focus")
            XCTAssertEqual(body.selectedRange().location, (body.string as NSString).length)
            host.rootView = blockEditor(shouldFocus: false)
            host.layoutSubtreeIfNeeded()
            await drainFocusEvents()
        }
    }
}

final class PerformanceRegressionTests {
    func testMomentColumnsPreserveOrderAndPagination() {
        for size in [0, 1, 2, 9, 100, 20_000] {
            let input = Array(0..<size)
            for requested in 1...4 {
                let columns = NativeMomentColumns.distribute(input, columnCount: requested)
                let count = min(requested, max(1, size))
                let expected = (0..<count).map { column in
                    input.enumerated().compactMap { index, value in
                        index % count == column ? value : nil
                    }
                }
                XCTAssertEqual(columns, expected)
                XCTAssertEqual(columns.flatMap { $0 }.sorted(), input)
                if size >= requested {
                    let nextPage = NativeMomentColumns.distribute(
                        input + Array(size..<(size + 20)), columnCount: requested
                    )
                    for index in columns.indices {
                        XCTAssertEqual(Array(nextPage[index].prefix(columns[index].count)), columns[index])
                    }
                }
            }
        }
        XCTAssertEqual(NativeMomentColumns.distribute([1, 2, 3], columnCount: 0), [[1, 2, 3]])
    }

    @MainActor
    func testWritingCompletionOnlyPublishesChangedQueries() {
        let textView = WritingTextViewProbe()
        let links = ArticleLinkAutocompleteController()
        let slash = EditorSlashCommandController()
        var linkUpdates = 0
        var slashUpdates = 0
        let linkObserver = links.$activeLinkQuery.dropFirst().sink { _ in linkUpdates += 1 }
        let slashObserver = slash.$activeQuery.dropFirst().sink { _ in slashUpdates += 1 }
        textView.string = "普通段落"
        for index in 0..<4 {
            textView.setSelectedRange(NSRange(location: index, length: 0))
            links.updateLinkQuery(from: textView)
            slash.updateQuery(from: textView)
        }
        XCTAssertEqual(linkUpdates, 0, "ordinary caret movement must not refresh link suggestions")
        XCTAssertEqual(slashUpdates, 0, "ordinary caret movement must not refresh slash suggestions")
        textView.string = "前文\n[[中文#^块"
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        links.updateLinkQuery(from: textView)
        links.updateLinkQuery(from: textView)
        XCTAssertEqual(links.activeLinkQuery, "中文#^块")
        XCTAssertEqual(linkUpdates, 1)
        textView.isComposing = true
        links.updateLinkQuery(from: textView)
        XCTAssertNil(links.activeLinkQuery, "completion menus must stay out of the IME candidate session")
        textView.isComposing = false
        textView.string = "  /标题"
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        slash.updateQuery(from: textView)
        slash.updateQuery(from: textView)
        XCTAssertEqual(slash.activeQuery, "标题")
        XCTAssertEqual(slashUpdates, 1)
        textView.isComposing = true
        slash.updateQuery(from: textView)
        XCTAssertNil(slash.activeQuery)
        withExtendedLifetime((linkObserver, slashObserver)) {}

        for text in ["[[旧链接]]\n正文", "[[未闭合\n下一行", "[[已完成]]", "纯文本", "[[有[嵌套"] {
            XCTAssertNil(links.linkContext(in: text, selectedRange: NSRange(location: (text as NSString).length, length: 0)))
        }
        for text in ["😀 [[中文", "前文\r\n[[标题", "前文\n[[", "[[第一个]] 与 [[第二个"] {
            let context = links.linkContext(in: text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
            XCTAssertNotNil(context)
            if let context {
                XCTAssertEqual((text as NSString).substring(with: context.range), "[[" + context.query)
            }
        }
        for range in [NSRange(location: -1, length: 0), NSRange(location: NSNotFound, length: 0),
                      NSRange(location: 99, length: 0), NSRange(location: 1, length: 1)] {
            XCTAssertNil(links.linkContext(in: "[[测试", selectedRange: range))
        }
    }

    @MainActor
    func testWritingEditorsPreserveCompositionAndSkipUnchangedBlockStyling() {
        var body = "已提交"
        var selection = NSRange(location: 0, length: 0)
        var splitCount = 0
        var mergeCount = 0
        let bodyEditor = NativeBodyEditor(
            text: Binding(get: { body }, set: { body = $0 }),
            selectedRange: Binding(get: { selection }, set: { selection = $0 }),
            isEditable: true, linkController: ArticleLinkAutocompleteController(),
            slashController: EditorSlashCommandController(), appearance: .livePreview,
            typography: .default, onPasteImage: { _, _ in }, onRunCommand: { _, _ in }
        )
        let bodyCoordinator = bodyEditor.makeCoordinator()
        func makeBlockEditor(typography: NativeReadingTypography = .default) -> NativeBlockTextEditor {
            NativeBlockTextEditor(
                text: Binding(get: { body }, set: { body = $0 }), height: .constant(40),
                kind: .paragraph, typography: typography, isEditable: true, shouldFocus: false,
                onFocus: {}, onSplit: { _ in splitCount += 1 }, onMergeBackward: { mergeCount += 1 },
                onMoveBlocks: { _ in }, onChangeIndent: { _ in }, onBlockCommand: { _ in false }
            )
        }
        let blockCoordinator = makeBlockEditor().makeCoordinator()
        let textView = WritingTextViewProbe(frame: NSRect(x: 0, y: 0, width: 600, height: 120))
        textView.string = "## **中文**写作"
        let probe = WritingStyleProbe()
        textView.textStorage?.delegate = probe
        blockCoordinator.refreshPresentation(of: textView)
        let initialPasses = probe.attributePasses
        XCTAssertTrue(initialPasses > 0)
        for _ in 0..<20 { blockCoordinator.refreshPresentation(of: textView) }
        XCTAssertEqual(probe.attributePasses, initialPasses, "unrelated row updates must not restyle unchanged text")

        textView.isComposing = true
        textView.string = "正在组合的拼音"
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let beforeComposition = probe.attributePasses
        let change = Notification(name: NSText.didChangeNotification, object: textView)
        bodyCoordinator.textDidChange(change)
        blockCoordinator.textDidChange(change)
        NativeMarkdownLiveStyler.apply(.livePreview, typography: .default, to: textView, editedRange: nil)
        XCTAssertEqual(body, "已提交", "IME marked text must not leak into the bound draft")
        XCTAssertEqual(probe.attributePasses, beforeComposition, "styling must preserve the IME's marked attributes")
        XCTAssertFalse(blockCoordinator.textView(textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertFalse(blockCoordinator.textView(textView, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
        XCTAssertEqual(splitCount, 0, "confirming a Chinese candidate must not split the block")
        XCTAssertEqual(mergeCount, 0, "editing a Chinese candidate must not merge blocks")

        textView.isComposing = false
        textView.string = "中文已确认"
        blockCoordinator.textDidChange(change)
        bodyCoordinator.textDidChange(change)
        bodyCoordinator.cancelStyling()
        XCTAssertEqual(body, "中文已确认")
        XCTAssertTrue(probe.attributePasses > beforeComposition)
        XCTAssertTrue(blockCoordinator.textView(textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(splitCount, 1)
        var typography = NativeReadingTypography.default
        typography.fontSize = 24
        blockCoordinator.parent = makeBlockEditor(typography: typography)
        let previousPasses = probe.attributePasses
        blockCoordinator.refreshPresentation(of: textView)
        XCTAssertTrue(probe.attributePasses > previousPasses, "font changes must invalidate the presentation cache")
        let font = textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, 24)
        let updatedPasses = probe.attributePasses
        blockCoordinator.refreshPresentation(of: textView)
        XCTAssertEqual(probe.attributePasses, updatedPasses)
    }

    @MainActor
    func testWritingCompletionBenchmark() {
        let controller = ArticleLinkAutocompleteController()
        let source = String(repeating: "中文写作 paragraph with **Markdown** and punctuation。\n", count: 20_000) + "继续写作"
        let selection = NSRange(location: (source as NSString).length, length: 0)
        let iterations = 80
        let pair = bestPairedElapsed(samples: 2, first: {
            var checksum = 0
            for _ in 0..<iterations {
                let prefix = (source as NSString).substring(to: selection.location) as NSString
                if prefix.range(of: "[[", options: .backwards).location == NSNotFound { checksum += 1 }
            }
            return checksum
        }, second: {
            var checksum = 0
            for _ in 0..<iterations {
                if controller.linkContext(in: source, selectedRange: selection) == nil { checksum += 1 }
            }
            return checksum
        })
        XCTAssertEqual(pair.first.result, iterations)
        XCTAssertEqual(pair.second.result, iterations)
        let currentMilliseconds = pair.second.elapsed * 1_000 / Double(iterations)
        print(String(format: "PERF writing-link utf16=%d legacy=%.3fms current=%.6fms",
                     selection.location, pair.first.elapsed * 1_000 / Double(iterations), currentMilliseconds))
        XCTAssertTrue(currentMilliseconds < 0.5, "long-document completion lookup must stay under 0.5 ms")
        XCTAssertTrue(pair.second.elapsed < pair.first.elapsed * 0.25,
                      "line-local lookup must remove at least 75% of full-prefix scanning")
    }

    @MainActor
    func testWorkspaceResourceIndexPreservesNavigationSemantics() {
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false)
        let summaries = ["Project.md", "Project/Child.md", "Docs/index.md", "Docs/中文/Guide.md"].enumerated().map {
            performanceArticle(index: $0.offset, status: .draft, tags: [], sourceRelativePath: $0.element)
        }
        let records = summaries.map {
            NativeWorkspaceResourceRecord(
                kind: .file, storage: .markdownSource, relativePath: $0.sourceRelativePath,
                placementFolderPath: $0.sourceFolderPath, absolutePath: "/vault/\($0.sourceRelativePath)"
            )
        } + [
            NativeWorkspaceResourceRecord(
                kind: .file, storage: .managedMedia, relativePath: "article-0/cover.png",
                placementFolderPath: "", absolutePath: "/vault/media/cover.png", ownerArticleSlug: "article-0"
            ),
            NativeWorkspaceResourceRecord(
                kind: .folder, storage: .markdownSource, relativePath: "Empty",
                placementFolderPath: "", absolutePath: "/vault/Empty"
            ),
        ]
        model.workspaceResources = NativeWorkspaceResourceTree.build(articles: summaries, records: records)
        let expected = NativeWorkspaceResourceTree.flattened(model.workspaceResources)
        XCTAssertEqual(model.workspaceResourceItems, expected)
        XCTAssertEqual(model.workspaceFolderPaths, NativeWorkspaceResourceTree.folderPaths(in: model.workspaceResources))
        for node in expected {
            XCTAssertEqual(model.workspaceResource(id: node.id), node)
            XCTAssertEqual(model.workspaceResourceAncestorIDs(resourceID: node.id),
                           NativeWorkspaceResourceTree.ancestors(of: node.id, in: model.workspaceResources))
        }
        for summary in summaries {
            XCTAssertEqual(model.workspaceResourceID(articleSlug: summary.slug),
                           expected.first { $0.kind == .article && $0.articleSlug == summary.slug }?.id)
        }
        XCTAssertEqual(model.workspaceResourceAncestorIDs(resourceID: "workspace-article:article-1"),
                       ["workspace-folder:Project"], "only directories may be expandable ancestors")
        XCTAssertEqual(model.workspaceResourceAncestorIDs(resourceID: "workspace-article:article-3"),
                       ["workspace-folder:Docs", "workspace-folder:Docs/中文"])
        let selected = Set([expected.last!.id, expected.first!.id, "missing"])
        XCTAssertEqual(model.workspaceResources(ids: selected), expected.filter { selected.contains($0.id) })
        XCTAssertEqual(model.workspaceResources(ids: Set(expected.map(\.id))), expected)
        XCTAssertEqual(model.workspaceResources(ids: []), [])
        XCTAssertNil(model.workspaceResource(id: "missing"))
        XCTAssertNil(model.workspaceResourceID(articleSlug: "missing"))
        XCTAssertEqual(model.workspaceResourceAncestorIDs(resourceID: "missing"), [])
    }

    @MainActor
    func testWorkspaceResourceIndexInvalidatesAfterMutationAndWorkspaceReset() {
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false)
        model.workspaceResources = performanceResourceTree(folderCount: 2, articlesPerFolder: 2)
        XCTAssertNil(model.cachedWorkspaceResourceIndex, "replacing the tree must defer index work until it is read")
        let initial = model.workspaceResourceIndex
        for _ in 0..<20 {
            XCTAssertEqual(model.workspaceResources(ids: ["resource-1-1"]).count, 1)
            XCTAssertTrue(model.workspaceResourceIndex === initial, "ordinary interactions must reuse the same index")
        }
        let oldPaths = model.workspaceFolderPaths
        let original = model.workspaceResources[0].children[0]
        let renamed = NativeWorkspaceResourceNode(
            id: original.id, kind: original.kind, storage: original.storage,
            name: "Renamed", relativePath: "Folder 0/Renamed.md", sourceRelativePath: "Folder 0/Renamed.md",
            absolutePath: "/vault/Folder 0/Renamed.md", articleSlug: original.articleSlug, articleTitle: "Updated title",
            children: original.children, articleCount: original.articleCount
        )
        // Same ID and node count: metadata changes must invalidate navigation,
        // while renaming an article leaves the directory destinations unchanged.
        model.workspaceResources[0].children[0] = renamed
        XCTAssertNil(model.cachedWorkspaceResourceIndex)
        XCTAssertFalse(model.workspaceResourceIndex === initial)
        XCTAssertEqual(model.workspaceResource(id: original.id), renamed)
        XCTAssertEqual(initial.resource(id: original.id), original, "old snapshots must remain immutable")
        XCTAssertEqual(model.workspaceFolderPaths, oldPaths)
        XCTAssertFalse(model.workspaceFolderPaths.contains("Folder 0/Renamed"))
        XCTAssertFalse(model.workspaceFolderPaths.contains("Folder 0/Article 0"))

        // Moving a node without changing its ID must replace its parent chain.
        model.workspaceResources[0].children.removeFirst()
        model.workspaceResources[1].children.insert(renamed, at: 0)
        XCTAssertEqual(model.workspaceResourceAncestorIDs(resourceID: renamed.id), ["folder-1"])
        model.workspaceResources.reverse()
        XCTAssertEqual(model.workspaceResourceItems, NativeWorkspaceResourceTree.flattened(model.workspaceResources))
        model.workspaceResources[0].children.removeFirst()
        XCTAssertNil(model.workspaceResource(id: renamed.id))
        XCTAssertNil(model.workspaceResourceID(articleSlug: renamed.articleSlug!))

        let otherWindow = NativeAppModel(navigationScopeID: nil, startsAutomatically: false)
        XCTAssertEqual(otherWindow.workspaceResourceItems, [])
        let isPreviousIndexReleased = { [weak index = model.workspaceResourceIndex] in index == nil }
        model.workspaceResources = []
        XCTAssertTrue(isPreviousIndexReleased(), "discarding a tree must release its navigation cache")
        XCTAssertNil(model.cachedWorkspaceResourceIndex)
        XCTAssertEqual(model.workspaceResourceItems, [])
        XCTAssertEqual(model.workspaceFolderPaths, [])
        XCTAssertEqual(model.workspaceResourceAncestorIDs(resourceID: "resource-1-1"), [])
        model.workspaceResources = [renamed]
        XCTAssertEqual(model.workspaceResource(id: renamed.id), renamed)
        XCTAssertEqual(model.workspaceResourceAncestorIDs(resourceID: renamed.id), [])
        XCTAssertEqual(otherWindow.workspaceResourceItems, [], "window caches must remain independent")
    }

    @MainActor
    func testWorkspaceResourceInteractionBenchmark() {
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false)
        model.workspaceResources = performanceResourceTree(folderCount: 100, articlesPerFolder: 100)
        let buildStart = ProcessInfo.processInfo.systemUptime
        let initialCount = model.workspaceResourceItems.count
        let buildMilliseconds = (ProcessInfo.processInfo.systemUptime - buildStart) * 1_000
        XCTAssertEqual(initialCount, 10_100)
        print(String(format: "PERF resources-10k index-build=%.3fms", buildMilliseconds))
        XCTAssertTrue(buildMilliseconds < 50, "building a 10k resource index must stay under 50 ms")
        let selectedIDs = Set((0..<100).map { "resource-\($0)-99" })
        let expectedIDs = (0..<100).map { "resource-\($0)-99" }
        let iterations = 3
        let pair = bestPairedElapsed(samples: 2, first: {
            var checksum = 0
            for _ in 0..<iterations {
                let items = NativeWorkspaceResourceTree.flattened(model.workspaceResources)
                let order = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
                let selected = selectedIDs.compactMap { id in
                    NativeWorkspaceResourceTree.flattened(model.workspaceResources).first { $0.id == id }
                }.sorted { order[$0.id, default: .max] < order[$1.id, default: .max] }
                XCTAssertEqual(selected.map(\.id), expectedIDs)
                checksum += selected.count
            }
            return checksum
        }, second: {
            var checksum = 0
            for _ in 0..<iterations {
                let selected = model.workspaceResources(ids: selectedIDs)
                XCTAssertEqual(selected.map(\.id), expectedIDs)
                checksum += selected.count
            }
            return checksum
        })
        XCTAssertEqual(pair.first.result, iterations * selectedIDs.count)
        XCTAssertEqual(pair.second.result, pair.first.result)
        let currentMilliseconds = pair.second.elapsed * 1_000 / Double(iterations)
        print(String(format: "PERF resources-10k select-100 legacy=%.3fms current=%.3fms",
                     pair.first.elapsed * 1_000 / Double(iterations), currentMilliseconds))
        XCTAssertTrue(currentMilliseconds < 1, "selecting 100 resources in an unchanged 10k tree must stay under 1 ms")
        XCTAssertTrue(pair.second.elapsed < pair.first.elapsed * 0.1,
                      "resource selection must remove at least 90% of repeated tree traversal")

        let navigationIterations = 100
        let navigationPair = bestPairedElapsed(samples: 2, first: {
            var checksum = 0
            for index in 0..<navigationIterations {
                let slug = "article-\(index)-99"
                if let id = NativeWorkspaceResourceTree.flattened(model.workspaceResources)
                    .first(where: { $0.articleSlug == slug && $0.kind == .article })?.id {
                    checksum += NativeWorkspaceResourceTree.ancestors(of: id, in: model.workspaceResources).count
                }
            }
            return checksum
        }, second: {
            var checksum = 0
            for index in 0..<navigationIterations {
                if let id = model.workspaceResourceID(articleSlug: "article-\(index)-99") {
                    checksum += model.workspaceResourceAncestorIDs(resourceID: id).count
                }
            }
            return checksum
        })
        XCTAssertEqual(navigationPair.first.result, navigationIterations)
        XCTAssertEqual(navigationPair.second.result, navigationPair.first.result)
        let navigationMilliseconds = navigationPair.second.elapsed * 1_000 / Double(navigationIterations)
        print(String(format: "PERF resources-10k reveal legacy=%.3fms current=%.6fms",
                     navigationPair.first.elapsed * 1_000 / Double(navigationIterations), navigationMilliseconds))
        XCTAssertTrue(navigationMilliseconds < 0.1, "revealing an article in an unchanged 10k tree must stay under 0.1 ms")
        XCTAssertTrue(navigationPair.second.elapsed < navigationPair.first.elapsed * 0.1,
                      "revealing an article must remove at least 90% of tree traversal")
    }

    private func performanceResourceTree(folderCount: Int, articlesPerFolder: Int) -> [NativeWorkspaceResourceNode] {
        (0..<folderCount).map { folder in
            NativeWorkspaceResourceNode(
                id: "folder-\(folder)", kind: .folder, storage: .markdownSource,
                name: "Folder \(folder)", relativePath: "Folder \(folder)",
                sourceRelativePath: "Folder \(folder)", absolutePath: "", articleSlug: nil, articleTitle: nil,
                children: (0..<articlesPerFolder).map { article in
                    NativeWorkspaceResourceNode(
                        id: "resource-\(folder)-\(article)", kind: .article, storage: .markdownSource,
                        name: "Article \(article)", relativePath: "Folder \(folder)/Article \(article).md",
                        sourceRelativePath: "Folder \(folder)/Article \(article).md", absolutePath: "",
                        articleSlug: "article-\(folder)-\(article)", articleTitle: "Article \(article)",
                        children: [], articleCount: 1
                    )
                },
                articleCount: articlesPerFolder
            )
        }
    }

    @MainActor
    func testGraphPresentationReusesProjectionDuringInteraction() {
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false)
        model.articleGraph = NativeArticleGraph(
            nodes: (0..<12).map { index in
                performanceArticle(index: index, status: index.isMultiple(of: 2) ? .draft : .published,
                                   tags: ["Swift"], sourceRelativePath: "article-\(index).md")
            },
            edges: [.init(sourceSlug: "article-0", targetSlug: "article-1")]
        )
        let state = NativeArticleGraphPageState()
        let query = NativeArticleGraphQuery()
        let first = model.articleGraphPresentation(query: query)
        XCTAssertEqual(first.shortestPath(from: "article-0", to: "article-1")?.nodes.map(\.slug),
                       ["article-0", "article-1"])
        XCTAssertNil(first.shortestPath(from: "article-1", to: "article-0"))
        XCTAssertNil(first.shortestPath(from: "article-1", to: "article-0"))
        XCTAssertEqual(first.shortestPath(from: "article-0", to: "article-1")?.hopCount, 1)
        XCTAssertEqual(first.shortestPath(from: "article-0", to: "article-0")?.hopCount, 0)
        for index in 0..<20 {
            state.nodePositions["article-0"] = CGPoint(x: 100 + index, y: 200)
            state.zoomIn()
            state.pathStartText = "Article \(index)"
            XCTAssertTrue(model.articleGraphPresentation(query: query) === first,
                          "dragging, zooming, and typing path endpoints must reuse the graph projection")
        }

        var previous = first
        for changedQuery in [
            NativeArticleGraphQuery(searchText: "Swift"),
            NativeArticleGraphQuery(status: .draft),
            NativeArticleGraphQuery(includesOrphans: false),
            NativeArticleGraphQuery(nodeLimit: 10),
            query,
        ] {
            let changed = model.articleGraphPresentation(query: changedQuery)
            XCTAssertFalse(changed === previous, "each filter change must replace the cached projection")
            XCTAssertEqual(changed.projection, NativeArticleGraphProjector.project(model.articleGraph, query: changedQuery))
            previous = changed
        }

        // Updating edges with the same nodes must invalidate the cached result.
        model.articleGraph = NativeArticleGraph(nodes: model.articleGraph.nodes, edges: [])
        let changed = model.articleGraphPresentation(query: query)
        XCTAssertFalse(changed === previous)
        XCTAssertTrue(changed.projection.graph.edges.isEmpty)
        XCTAssertNil(changed.shortestPath(from: "article-0", to: "article-1"),
                     "changing the graph must also invalidate its cached paths")
        var updatedNodes = model.articleGraph.nodes
        updatedNodes[0].pageViews += 1
        model.articleGraph = NativeArticleGraph(nodes: updatedNodes, edges: [])
        let updated = model.articleGraphPresentation(query: query)
        XCTAssertFalse(updated === changed)
        XCTAssertEqual(updated.projection, NativeArticleGraphProjector.project(model.articleGraph, query: query),
                       "node metadata changes must be visible even when slugs and node count are unchanged")
        let otherWindow = NativeAppModel(navigationScopeID: nil, startsAutomatically: false)
        XCTAssertEqual(otherWindow.articleGraphPresentation(query: query).projection.graph, .empty,
                       "a different window must not reuse this window's graph")
        model.articleGraph = .empty
        XCTAssertEqual(model.articleGraphPresentation(query: query).projection.graph, .empty,
                       "workspace reset or disabling the graph must discard the previous workspace's nodes")
    }

    @MainActor
    func testGraphInteractionProjectionBenchmark() {
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false)
        let count = 10_000
        model.articleGraph = NativeArticleGraph(
            nodes: (0..<count).map { index in
                performanceArticle(index: index, status: .published, tags: ["Swift", "性能"],
                                   sourceRelativePath: "article-\(index).md")
            },
            edges: (1..<count).map { .init(sourceSlug: "article-\($0 - 1)", targetSlug: "article-\($0)") }
        )
        let query = NativeArticleGraphQuery(nodeLimit: 500)
        let start = ProcessInfo.processInfo.systemUptime
        let initial = model.articleGraphPresentation(query: query)
        let buildElapsed = ProcessInfo.processInfo.systemUptime - start
        let iterations = 8
        let pair = bestPairedElapsed(samples: 2, first: {
            var checksum = 0
            for _ in 0..<iterations {
                checksum += NativeArticleGraphProjector.project(model.articleGraph, query: query).graph.nodes.count
            }
            return checksum
        }, second: {
            var checksum = 0
            for _ in 0..<iterations {
                checksum += model.articleGraphPresentation(query: query).projection.graph.nodes.count
            }
            return checksum
        })
        XCTAssertEqual(initial.projection.graph.nodes.count, 500)
        XCTAssertEqual(pair.first.result, pair.second.result)
        let oldMilliseconds = pair.first.elapsed * 1_000 / Double(iterations)
        let newMilliseconds = pair.second.elapsed * 1_000 / Double(iterations)
        print(String(format: "PERF graph-10k build=%.3fms uncached=%.3fms reused=%.6fms", buildElapsed * 1_000, oldMilliseconds, newMilliseconds))
        XCTAssertTrue(newMilliseconds < 1, "unchanged graph projection must cost less than 1 ms per interaction")
        XCTAssertTrue(pair.second.elapsed < pair.first.elapsed * 0.1,
                      "unchanged graph projection must remove at least 90% of projection work")

        let pathGraph = NativeArticleGraph(
            nodes: Array(model.articleGraph.nodes.prefix(500)),
            edges: Array(model.articleGraph.edges.prefix(499))
        )
        let pathPresentation = NativeArticleGraphPresentation(projection: NativeArticleGraphProjection(
            graph: pathGraph, matchingNodeCount: 500, clippedNodeCount: 0
        ))
        XCTAssertEqual(pathPresentation.shortestPath(from: "article-0", to: "article-499")?.hopCount, 499)
        let pathIterations = 64
        let pathPair = bestPairedElapsed(samples: 2, first: {
            var checksum = 0
            for _ in 0..<pathIterations {
                checksum += NativeArticleGraphPathFinder.shortestPath(
                    in: pathGraph, from: "article-0", to: "article-499"
                )?.hopCount ?? 0
            }
            return checksum
        }, second: {
            var checksum = 0
            for _ in 0..<pathIterations {
                checksum += pathPresentation.shortestPath(from: "article-0", to: "article-499")?.hopCount ?? 0
            }
            return checksum
        })
        XCTAssertEqual(pathPair.first.result, 499 * pathIterations)
        XCTAssertEqual(pathPair.second.result, pathPair.first.result)
        let pathMilliseconds = pathPair.second.elapsed * 1_000 / Double(pathIterations)
        print(String(format: "PERF graph-path-500 uncached=%.3fms reused=%.6fms",
                     pathPair.first.elapsed * 1_000 / Double(pathIterations), pathMilliseconds))
        XCTAssertTrue(pathMilliseconds < 0.1, "unchanged highlighted path must cost less than 0.1 ms per redraw")
        XCTAssertTrue(pathPair.second.elapsed < pathPair.first.elapsed * 0.1,
                      "unchanged highlighted path must remove at least 90% of traversal work")
    }

    @MainActor
    func testArticleSelectionCacheRejectsStaleAndCrossWorkspaceEntries() {
        let cache = NativeArticleSelectionCache(countLimit: 4, totalCostLimit: 1_024 * 1_024)
        let first = smartCollectionArticle(
            slug: "cached-article",
            title: "Cached",
            status: .published,
            category: "Performance",
            updatedAt: "2026-08-30T10:00:00.000Z",
            pageViews: 3,
            properties: [:]
        )
        cache.insert(first, workspaceGeneration: 7)

        XCTAssertEqual(cache.article(matching: first.summary, workspaceGeneration: 7), first)
        XCTAssertNil(cache.article(matching: first.summary, workspaceGeneration: 8))

        let updated = smartCollectionArticle(
            slug: first.slug,
            title: first.title,
            status: first.status,
            category: first.category,
            updatedAt: "2026-08-30T10:01:00.000Z",
            pageViews: 4,
            properties: [:]
        )
        XCTAssertNil(cache.article(matching: updated.summary, workspaceGeneration: 7))
        cache.insert(updated, workspaceGeneration: 7)
        XCTAssertEqual(cache.article(matching: updated.summary, workspaceGeneration: 7), updated)
    }

    @MainActor
    func testArticleNavigationPersistenceCoalescesToLatestSnapshot() async throws {
        let scope = "persistence-\(UUID().uuidString)"
        let model = NativeAppModel(navigationScopeID: scope, startsAutomatically: false)
        let defaultsKey = "leon-book.article-navigation.\(model.currentUser.id).window.\(scope)"
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }

        let first = NativeArticleTab(slug: "first")
        let second = NativeArticleTab(slug: "second")
        model.articleTabs = [first, second]
        model.activeArticleTabID = first.id
        model.persistArticleNavigationState()
        model.activeArticleTabID = second.id
        model.recentArticleSlugs = ["second", "first"]
        model.persistArticleNavigationState()

        try await Task.sleep(nanoseconds: 300_000_000)
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let snapshot = try? JSONDecoder().decode(
                  NativeArticleNavigationSnapshot.self,
                  from: data
              ) else {
            XCTFail("expected the coalesced article navigation snapshot")
            return
        }
        XCTAssertEqual(snapshot.activeTabID, second.id)
        XCTAssertEqual(snapshot.tabs, [first, second])
        XCTAssertEqual(snapshot.recentSlugs, ["second", "first"])
    }

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

    func testRichArticleMetadataPreservesUnicodeAndCacheIdentity() {
        let html = RichArticleDocument.opening + """
        <p>开头👩🏽‍💻é</p><h1>章 &amp; <strong>节😀</strong></h1>
        <H4 data-block-id="last">é &lt;末尾&gt;</H4><h2></h2>
        <img src="media/中文😀.png?x=1&amp;y=2"><img src="data:image/png;base64,YQ==">
        <a href="leonbook://open?slug=%E4%B8%AD%E6%96%87%F0%9F%98%80&amp;other=1">内部链接</a>
        <a href="https://example.com/?slug=external">外部链接</a></article>
        """
        let document = NativeMarkdownArticleDocumentCache.shared.document(for: html)
        XCTAssertEqual(document.outline.map(\.title), ["章 & 节😀", "é <末尾>", ""])
        XCTAssertEqual(document.outline.map(\.level), [1, 4, 2])
        XCTAssertEqual(document.outline.map(\.id), (0..<3).map(MarkdownOutline.anchorID))
        XCTAssertEqual(document.imageURLs, ["media/中文😀.png?x=1&y=2", "data:image/png;base64,YQ=="])
        XCTAssertEqual(document.embeddedAttachmentURLs, document.imageURLs)
        XCTAssertEqual(RichArticleDocument.linkReferences(in: html), ["中文😀"])
        XCTAssertTrue(document === NativeMarkdownArticleDocumentCache.shared.document(for: html))
        let changed = NativeMarkdownArticleDocumentCache.shared.document(for: html.replacingOccurrences(of: "节😀", with: "新节😀"))
        XCTAssertFalse(changed === document)
        XCTAssertEqual(changed.outline.first?.title, "章 & 新节😀")
    }

    func testRichArticleReaderMetadataReuseBenchmark() {
        let source = RichArticleDocument.opening + (0..<1_000).map { index in
            "<h2>章节\(index) <strong>👩🏽‍💻 &amp; é</strong></h2><p>" + String(repeating: "中文文章的正文与格式。", count: 20) + "</p>"
        }.joined() + "</article>"
        let document = NativeMarkdownArticleDocumentCache.shared.document(for: source)
        let expected = document.outline.map { "\($0.id)|\($0.level)|\($0.title)" }
        XCTAssertEqual(expected.count, 1_000)
        func measure(_ operation: () -> [MarkdownOutlineItem]) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            var count = 0
            for _ in 0..<20 { count += operation().count }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            XCTAssertEqual(count, 20_000)
            XCTAssertEqual(operation().map { "\($0.id)|\($0.level)|\($0.title)" }, expected)
            return elapsed
        }
        // The reader already obtains a cached document for rendering. Compare
        // its former extra outline scan with reusing that document's outline.
        let previous = { RichArticleDocument.outline(in: source) }
        let current = { NativeMarkdownArticleDocumentCache.shared.document(for: source).outline }
        let oldFirst = measure(previous), newFirst = measure(current)
        let newSecond = measure(current), oldSecond = measure(previous)
        let oldMS = min(oldFirst, oldSecond), newMS = min(newFirst, newSecond)
        print("READER_METADATA_PERFORMANCE repeatedReads=20 previousMS=\(oldMS) cachedMS=\(newMS)")
        XCTAssertTrue(newMS < oldMS * 0.1, "reader metadata reuse must avoid reparsing an unchanged article")
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

    func testLibraryAndMomentProjectionsCacheDerivedStateWithoutChangingFilters() {
        var rebuilds = NativeProjectionRebuildCoordinator()
        let staleArticleToken = rebuilds.begin(.articleLibrary)
        let momentToken = rebuilds.begin(.momentFacets)
        let currentArticleToken = rebuilds.begin(.articleLibrary)
        XCTAssertFalse(rebuilds.isCurrent(staleArticleToken))
        XCTAssertTrue(rebuilds.isCurrent(momentToken))
        XCTAssertTrue(rebuilds.isCurrent(currentArticleToken))

        let articles = [
            performanceArticle(
                index: 0,
                status: .published,
                tags: ["Swift", "Performance"],
                sourceRelativePath: "work/swift/first.md"
            ),
            performanceArticle(
                index: 1,
                status: .draft,
                tags: ["performance"],
                sourceRelativePath: "work/drafts/second.md"
            ),
            performanceArticle(
                index: 2,
                status: .published,
                tags: ["Café"],
                sourceRelativePath: "personal/third.md"
            ),
        ]
        var projection = NativeArticleLibraryProjection(articles: articles)

        XCTAssertEqual(projection.publishedArticleCount, 2)
        XCTAssertEqual(projection.draftArticleCount, 1)
        XCTAssertEqual(
            projection.folderFilters.first(where: { $0.path == "work" })?.count,
            2
        )
        XCTAssertEqual(
            projection.tagFilters.first(where: { $0.tag == "Performance" })?.count,
            2
        )
        XCTAssertEqual(
            projection.filteredArticles(
                searchText: "",
                resolvedSearchText: "",
                searchMatchSlugs: [],
                selectedTags: [],
                selectedFolderPath: nil
            ),
            articles
        )
        let localSearchMatches = projection.localSearchMatchSlugs(searchText: "ARTICLE 1")
        XCTAssertEqual(localSearchMatches, ["article-1"])
        XCTAssertEqual(
            projection.filteredArticles(
                searchText: "ARTICLE 1",
                resolvedSearchText: "",
                searchMatchSlugs: [],
                selectedTags: [],
                selectedFolderPath: nil
            ),
            articles
        )
        XCTAssertEqual(
            projection.filteredArticles(
                searchText: "ARTICLE 1",
                resolvedSearchText: "ARTICLE 1",
                searchMatchSlugs: localSearchMatches,
                selectedTags: [],
                selectedFolderPath: nil
            ).map(\.slug),
            ["article-1"]
        )
        XCTAssertEqual(
            projection.filteredArticles(
                searchText: "body term",
                resolvedSearchText: "body term",
                searchMatchSlugs: ["article-2"],
                selectedTags: [],
                selectedFolderPath: nil
            ).map(\.slug),
            ["article-2"]
        )
        XCTAssertEqual(
            projection.filteredArticles(
                searchText: "",
                resolvedSearchText: "",
                searchMatchSlugs: [],
                selectedTags: ["swift", "missing"],
                selectedFolderPath: "work"
            ).map(\.slug),
            ["article-0"]
        )
        XCTAssertEqual(
            projection.articles(for: ["article-2", "missing", "article-0"]).map(\.slug),
            ["article-2", "article-0"]
        )

        projection.updatePageViews(for: "article-0", to: 42)
        XCTAssertEqual(projection.articles.first?.pageViews, 42)
        XCTAssertEqual(projection.publishedArticleCount, 2)
        XCTAssertEqual(projection.draftArticleCount, 1)
        XCTAssertEqual(projection.articles(for: ["article-0"]).first?.pageViews, 42)

        let facets = NativeMomentFacetProjection(records: [
            NativeMomentFacetRecord(createdAt: "2026-08-29T10:00:00.000Z", tags: ["Swift"]),
            NativeMomentFacetRecord(createdAt: "2026-08-01T10:00:00.000Z", tags: ["swift", "Life"]),
            NativeMomentFacetRecord(createdAt: "2025-12-01T10:00:00.000Z", tags: ["Life"]),
        ])
        XCTAssertEqual(facets.months, [
            NativeMomentMonth(year: 2026, month: 8),
            NativeMomentMonth(year: 2025, month: 12),
        ])
        XCTAssertEqual(facets.years, [2026, 2025])
        XCTAssertEqual(facets.tagFilters.first(where: { $0.tag == "Swift" })?.count, 2)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let timeline = NativeMomentTimelineProjection(
            moments: [
                performanceMoment(id: "first", createdAt: "2026-08-29T10:00:00.000Z"),
                performanceMoment(id: "second", createdAt: "2026-08-29T08:00:00.000Z"),
                performanceMoment(id: "third", createdAt: "2026-08-28T08:00:00.000Z"),
            ],
            now: NativeTimestamp.date(from: "2026-08-29T12:00:00.000Z")!,
            calendar: calendar
        )
        XCTAssertEqual(timeline.groups.map(\.id), ["2026-08-29", "2026-08-28"])
        XCTAssertEqual(timeline.groups.map(\.label), ["今天", "昨天"])
        XCTAssertEqual(timeline.groups.first?.moments.map(\.id), ["first", "second"])
    }

    @MainActor
    func testArticleProjectionRebuildPreservesConcurrentPageViewUpdate() async {
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false)
        let initial = performanceArticle(
            index: 0,
            status: .published,
            tags: ["Swift"],
            sourceRelativePath: "work/article-0.md"
        )
        await model.replaceArticleSummaries([initial])
        model.recentArticleSlugs = [initial.slug]

        let replacement = (0..<2).map { index in
            performanceArticle(
                index: index,
                status: .published,
                tags: ["Swift", "Topic-\(index % 24)"],
                sourceRelativePath: "work/article-\(index).md"
            )
        }
        let gate = AsyncTestGate()
        model.projectionRebuildWillBuild = { kind in
            if kind == .articleLibrary {
                await gate.suspend()
            }
        }
        let rebuild = Task { @MainActor in
            await model.replaceArticleSummaries(replacement)
        }
        await gate.waitUntilSuspended()
        model.updateArticleSummaryPageViews(slug: initial.slug, pageViews: 42)
        await gate.release()
        await rebuild.value
        model.projectionRebuildWillBuild = nil

        XCTAssertEqual(model.articles.first?.pageViews, 42)
        XCTAssertEqual(model.publishedArticleCount, 2)
        XCTAssertEqual(model.recentArticles.first?.pageViews, 42)
    }

    @MainActor
    func testPageViewIncrementReevaluatesSelectedSmartCollection() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let previousWorkDirectory = ProcessInfo.processInfo.environment["LEON_BOOK_WORKDIR"]
        setenv("LEON_BOOK_WORKDIR", root.path, 1)
        defer {
            if let previousWorkDirectory {
                setenv("LEON_BOOK_WORKDIR", previousWorkDirectory, 1)
            } else {
                unsetenv("LEON_BOOK_WORKDIR")
            }
        }

        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false)
        let saved = try await model.store.saveArticle(article(
            slug: "page-view-threshold",
            status: .published,
            expectedUpdatedAt: nil,
            body: "threshold",
            title: "Threshold"
        ))
        let collection = try await model.store.saveSmartCollection(NativeSmartCollection(
            name: "Unread",
            rules: [NativeSmartCollectionRule(
                field: .pageViews,
                comparison: .lessThan,
                value: "1"
            )],
            sorts: [NativeArticleSortDescriptor(field: .pageViews, ascending: true)]
        ))
        await model.replaceArticleSummaries(try await model.store.listArticles())
        model.smartCollections = [collection]
        model.selectedSmartCollectionID = collection.id
        try await model.refreshSelectedSmartCollection()
        XCTAssertEqual(model.smartCollectionArticles.map(\.slug), [saved.slug])

        let displayed = try await model.displayArticle(
            model.smartCollectionArticles[0],
            disposition: .currentTab,
            recordsPageView: true
        )

        XCTAssertTrue(displayed)
        XCTAssertEqual(model.smartCollectionArticles, [])
    }

    @MainActor
    func testCalendarChangeRebuildsCachedMomentFacets() async {
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false)
        let records = [NativeMomentFacetRecord(
            createdAt: "2026-09-01T00:30:00.000Z",
            tags: ["boundary"]
        )]
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        await model.replaceMomentFacetRecords(records, calendar: utc)
        XCTAssertEqual(model.availableMomentMonths, [NativeMomentMonth(year: 2026, month: 9)])

        var previousMonth = Calendar(identifier: .gregorian)
        previousMonth.timeZone = TimeZone(secondsFromGMT: -3_600)!
        await model.refreshCalendarDependentProjections(calendar: previousMonth)

        XCTAssertEqual(model.availableMomentMonths, [NativeMomentMonth(year: 2026, month: 8)])
    }

    func testLargeArticleLibraryProjectionBenchmark() {
        let articleCount = 10_000
        let iterations = 20
        let articles = (0..<articleCount).map { index in
            performanceArticle(
                index: index,
                status: index.isMultiple(of: 4) ? .draft : .published,
                tags: ["Swift", "性能", "Topic-\(index % 24)"],
                sourceRelativePath: "area-\(index % 20)/section-\(index % 100)/article-\(index).md"
            )
        }

        let buildStart = ProcessInfo.processInfo.systemUptime
        let previousProjection = NativeArticleLibraryProjection(articles: articles)
        let buildElapsed = ProcessInfo.processInfo.systemUptime - buildStart
        let residentBeforeRebuild = currentResidentMemoryBytes()
        let projection = NativeArticleLibraryProjection(articles: articles)
        let residentAfterRebuild = currentResidentMemoryBytes()
        withExtendedLifetime(previousProjection) {}
        let rebuildPeakResidentGrowth = residentAfterRebuild >= residentBeforeRebuild
            ? residentAfterRebuild - residentBeforeRebuild
            : 0
        let runtimeEmptyQuery = ProcessInfo.processInfo.environment["LEON_BOOK_BENCHMARK_QUERY"] ?? ""

        let noFilterPair = bestPairedElapsed(first: {
            var total = 0
            for _ in 0..<iterations {
                total += legacyFilteredArticles(
                    articles,
                    searchText: runtimeEmptyQuery,
                    resolvedSearchText: "",
                    searchMatchSlugs: [],
                    selectedTags: [],
                    selectedFolderPath: nil
                ).count
            }
            return total
        }, second: {
            var total = 0
            for _ in 0..<iterations {
                total += projection.filteredArticles(
                    searchText: runtimeEmptyQuery,
                    resolvedSearchText: "",
                    searchMatchSlugs: [],
                    selectedTags: [],
                    selectedFolderPath: nil
                ).count
            }
            return total
        })
        let legacyNoFilter = noFilterPair.first
        let projectedNoFilter = noFilterPair.second

        let pendingSearchPair = bestPairedElapsed(first: {
            var total = 0
            for _ in 0..<iterations {
                total += legacyFilteredArticles(
                    articles,
                    searchText: "needle",
                    resolvedSearchText: "",
                    searchMatchSlugs: [],
                    selectedTags: [],
                    selectedFolderPath: nil
                ).count
            }
            return total
        }, second: {
            var total = 0
            for _ in 0..<iterations {
                total += projection.filteredArticles(
                    searchText: "needle",
                    resolvedSearchText: "",
                    searchMatchSlugs: [],
                    selectedTags: [],
                    selectedFolderPath: nil
                ).count
            }
            return total
        })
        let legacyPendingSearch = pendingSearchPair.first
        let projectedPendingSearch = pendingSearchPair.second
        let localSearchPair = bestPairedElapsed(first: {
            legacyFilteredArticles(
                articles,
                searchText: "needle",
                resolvedSearchText: "",
                searchMatchSlugs: [],
                selectedTags: [],
                selectedFolderPath: nil
            ).count
        }, second: {
            projection.localSearchMatchSlugs(searchText: "needle").count
        })
        let legacyPendingSingleSearch = localSearchPair.first
        let backgroundLocalSearch = localSearchPair.second

        let matchSlugs = Set(stride(from: 0, to: articleCount, by: 10).map { "article-\($0)" })
        let resolvedSearchPair = bestPairedElapsed(first: {
            var total = 0
            for _ in 0..<iterations {
                total += legacyFilteredArticles(
                    articles,
                    searchText: "needle",
                    resolvedSearchText: "needle",
                    searchMatchSlugs: matchSlugs,
                    selectedTags: [],
                    selectedFolderPath: nil
                ).count
            }
            return total
        }, second: {
            var total = 0
            for _ in 0..<iterations {
                total += projection.filteredArticles(
                    searchText: "needle",
                    resolvedSearchText: "needle",
                    searchMatchSlugs: matchSlugs,
                    selectedTags: [],
                    selectedFolderPath: nil
                ).count
            }
            return total
        })
        let legacyResolvedSearch = resolvedSearchPair.first
        let projectedResolvedSearch = resolvedSearchPair.second

        XCTAssertEqual(legacyNoFilter.result, projectedNoFilter.result)
        XCTAssertEqual(legacyPendingSearch.result, projectedPendingSearch.result)
        XCTAssertEqual(legacyPendingSingleSearch.result, backgroundLocalSearch.result)
        XCTAssertEqual(legacyResolvedSearch.result, projectedResolvedSearch.result)
        XCTAssertTrue(buildElapsed < 0.5, "10k article projection build took \(buildElapsed) seconds")
        XCTAssertTrue(
            rebuildPeakResidentGrowth < 128 * 1_024 * 1_024,
            "10k article projection rebuild grew peak RSS by more than 128 MiB"
        )
        XCTAssertTrue(
            projectedNoFilter.elapsed / Double(iterations) < 0.001,
            "no-filter projection exceeded the 1 ms absolute budget"
        )
        XCTAssertTrue(
            projectedPendingSearch.elapsed / Double(iterations) < 0.008,
            "pending-search projection exceeded the 8 ms absolute budget"
        )
        XCTAssertTrue(
            backgroundLocalSearch.elapsed < 0.05,
            "background local search exceeded the 50 ms absolute budget"
        )
        XCTAssertTrue(
            projectedResolvedSearch.elapsed / Double(iterations) < 0.008,
            "resolved-search projection exceeded the 8 ms absolute budget"
        )
        XCTAssertTrue(
            projectedNoFilter.elapsed < legacyNoFilter.elapsed * 0.1,
            "no-filter projection should remove at least 90% of the legacy render cost"
        )
        XCTAssertTrue(
            projectedResolvedSearch.elapsed < legacyResolvedSearch.elapsed * 0.5,
            "resolved search projection should remove at least 50% of the legacy render cost"
        )
        XCTAssertTrue(
            backgroundLocalSearch.elapsed < legacyPendingSingleSearch.elapsed * 0.75,
            "background local search should remove at least 25% of the legacy pending-search cost"
        )

        print(String(
            format: "PERF articles=%d build_ms=%.3f rebuild_peak_rss_mb=%.3f legacy_no_filter_ms=%.3f projected_no_filter_ms=%.3f legacy_pending_ms=%.3f projected_pending_ms=%.3f background_local_search_ms=%.3f legacy_resolved_ms=%.3f projected_resolved_ms=%.3f",
            articleCount,
            buildElapsed * 1_000,
            Double(rebuildPeakResidentGrowth) / 1_024 / 1_024,
            legacyNoFilter.elapsed * 1_000 / Double(iterations),
            projectedNoFilter.elapsed * 1_000 / Double(iterations),
            legacyPendingSearch.elapsed * 1_000 / Double(iterations),
            projectedPendingSearch.elapsed * 1_000 / Double(iterations),
            backgroundLocalSearch.elapsed * 1_000,
            legacyResolvedSearch.elapsed * 1_000 / Double(iterations),
            projectedResolvedSearch.elapsed * 1_000 / Double(iterations)
        ))
    }

    func testLargeSmartCollectionFormulaSummaryBenchmark() {
        let articleCount = 10_000
        let now = NativeTimestamp.date(from: "2026-08-30T12:00:00Z")!
        let articles = (0..<articleCount).map { index in
            NativeArticleSummary(
                banner: nil,
                category: "Benchmark",
                excerpt: "",
                pageViews: index,
                properties: [
                    "price": .number(Double((index % 100) + 1)),
                    "months": .number(Double((index % 12) + 1)),
                    "tax": .number(1.25),
                    "divisor": .number(2),
                    "due": .date("2026-08-30"),
                    "unused-a": .text("a"),
                    "unused-b": .text("b"),
                    "unused-c": .text("c"),
                    "unused-d": .text("d"),
                ],
                publishedAt: nil,
                slug: "formula-\(index)",
                status: .published,
                tags: [],
                title: "Formula \(index)",
                updatedAt: "2026-08-30T00:00:00Z",
                wordCount: 10
            )
        }
        let column = NativeSmartCollectionColumn(
            source: .formula,
            key: "weighted",
            title: "加权价格",
            summary: .sum
        )
        let collection = NativeSmartCollection(
            name: "公式基准",
            columns: [column],
            formulas: [
                NativeSmartCollectionFormula(
                    key: "weighted",
                    name: "加权价格",
                    expression: "round((price * months + tax) / divisor, 2)"
                ),
                NativeSmartCollectionFormula(
                    key: "date_label",
                    name: "日期标签",
                    expression: "formatDate(due, \"yyyy/MM/dd\")"
                ),
            ]
        )

        var best = TimeInterval.greatestFiniteMagnitude
        var result = NativeBaseValue.empty
        for _ in 0..<4 {
            let start = ProcessInfo.processInfo.systemUptime
            result = NativeSmartCollectionFormulaEngine.summary(
                .sum,
                column: column,
                articles: articles,
                collection: collection,
                now: now
            )
            best = min(best, ProcessInfo.processInfo.systemUptime - start)
        }

        XCTAssertTrue(result.numberValue != nil, "formula benchmark should produce a numeric sum")
        XCTAssertTrue(
            best < 0.08,
            "10k formula summary exceeded the 80 ms render budget: \(best * 1_000) ms"
        )
        let dateColumn = NativeSmartCollectionColumn(
            source: .formula,
            key: "date_label",
            title: "日期标签",
            summary: .filled
        )
        var dateBest = TimeInterval.greatestFiniteMagnitude
        var dateResult = NativeBaseValue.empty
        for _ in 0..<4 {
            let start = ProcessInfo.processInfo.systemUptime
            dateResult = NativeSmartCollectionFormulaEngine.summary(
                .filled,
                column: dateColumn,
                articles: articles,
                collection: collection,
                now: now
            )
            dateBest = min(dateBest, ProcessInfo.processInfo.systemUptime - start)
        }
        XCTAssertEqual(dateResult, .number(Double(articleCount)))
        XCTAssertTrue(
            dateBest < 0.12,
            "10k date formula summary exceeded the 120 ms render budget: \(dateBest * 1_000) ms"
        )
        print(String(
            format: "PERF formula_articles=%d summary_ms=%.3f date_summary_ms=%.3f",
            articleCount,
            best * 1_000,
            dateBest * 1_000
        ))
    }

    func testMomentTimestampReuseBenchmark() {
        let momentCount = 10_000
        let timestamps = (0..<momentCount).map { index -> String in
            let hour = (index / 3_600) % 24
            let minute = (index / 60) % 60
            let second = index % 60
            return String(format: "2026-08-30T%02d:%02d:%02d.000Z", hour, minute, second)
        }
        let records = timestamps.map { NativeMomentFacetRecord(createdAt: $0, tags: ["性能"]) }
        let moments = timestamps.enumerated().map { index, timestamp in
            performanceMoment(id: "timestamp-\(index)", createdAt: timestamp)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = NativeTimestamp.date(from: "2026-08-30T12:00:00Z")!

        let facetStart = ProcessInfo.processInfo.systemUptime
        let facets = NativeMomentFacetProjection(records: records, calendar: calendar)
        let facetElapsed = ProcessInfo.processInfo.systemUptime - facetStart
        let timelineStart = ProcessInfo.processInfo.systemUptime
        let timeline = NativeMomentTimelineProjection(moments: moments, now: now, calendar: calendar)
        let timelineElapsed = ProcessInfo.processInfo.systemUptime - timelineStart

        XCTAssertEqual(facets.months, [NativeMomentMonth(year: 2026, month: 8)])
        XCTAssertFalse(timeline.groups.isEmpty)
        XCTAssertTrue(
            timelineElapsed < 0.12,
            "reusing 10k parsed timestamps exceeded the 120 ms budget: \(timelineElapsed * 1_000) ms"
        )
        print(String(
            format: "PERF moment_timestamps=%d facet_ms=%.3f reused_timeline_ms=%.3f",
            momentCount,
            facetElapsed * 1_000,
            timelineElapsed * 1_000
        ))
    }

    @MainActor
    func testArticleTabUserInteractionBenchmark() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let articleCount = 16
        let renderPasses = 20
        let largeBody = String(repeating: "## Heading\nA paragraph for tab switching.\n\n", count: 2_048)
        let navigationScope = "performance-\(UUID().uuidString)"
        let model = NativeAppModel(
            navigationScopeID: navigationScope,
            startsAutomatically: false,
            store: LocalBlogStore(rootURL: root)
        )
        let defaultsKey = "leon-book.article-navigation.\(model.currentUser.id).window.\(navigationScope)"
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }

        var savedArticles: [NativeArticle] = []
        savedArticles.reserveCapacity(articleCount)
        for index in 0..<articleCount {
            savedArticles.append(try await model.store.saveArticle(article(
                slug: "tab-\(index)",
                status: .published,
                expectedUpdatedAt: nil,
                body: largeBody,
                title: "Tab \(index)"
            )))
        }
        let savedSummaries = savedArticles.map(\.summary)
        let library = (0..<(10_000 - articleCount)).map { index in
            performanceArticle(
                index: index,
                status: .published,
                tags: ["Performance"],
                sourceRelativePath: "articles/article-\(index).md"
            )
        } + savedSummaries
        await model.replaceArticleSummaries(library)
        model.articleTabs = savedArticles.map { NativeArticleTab(slug: $0.slug) }
        model.activeArticleTabID = model.articleTabs[0].id
        _ = try await model.displayArticle(
            savedSummaries[0],
            disposition: .refreshActiveTab,
            recordsPageView: false
        )

        for tab in model.articleTabs.dropFirst() {
            XCTAssertTrue(try await model.activateArticleTabAndWait(tab.id))
        }
        XCTAssertTrue(try await model.activateArticleTabAndWait(model.articleTabs[0].id))

        let switchStart = ProcessInfo.processInfo.systemUptime
        var switchCount = 0
        for _ in 0..<4 {
            for tab in model.articleTabs {
                guard tab.id != model.activeArticleTabID else { continue }
                XCTAssertTrue(try await model.activateArticleTabAndWait(tab.id))
                switchCount += 1
            }
        }
        let switchElapsed = ProcessInfo.processInfo.systemUptime - switchStart

        model.articleTabs = (0..<48).map { offset in
            NativeArticleTab(slug: "article-\(library.count - articleCount - 1 - offset)")
        }
        let titleStart = ProcessInfo.processInfo.systemUptime
        var titleLength = 0
        for _ in 0..<renderPasses {
            for tab in model.articleTabs {
                titleLength += model.articleTabTitle(for: tab).count
            }
        }
        let titleElapsed = ProcessInfo.processInfo.systemUptime - titleStart

        XCTAssertTrue(titleLength > 0)
        XCTAssertTrue(
            switchElapsed / Double(switchCount) < 0.00025,
            "warm tab switch exceeded the 0.25 ms interaction budget: \(switchElapsed * 1_000 / Double(switchCount)) ms"
        )
        XCTAssertTrue(
            titleElapsed < 0.005,
            "20 tab-bar render passes exceeded the 5 ms budget: \(titleElapsed * 1_000) ms"
        )
        print(String(
            format: "PERF tab_switches=%d warm_switch_ms=%.3f tab_title_render_ms=%.3f",
            switchCount,
            switchElapsed * 1_000 / Double(switchCount),
            titleElapsed * 1_000
        ))
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    func testPairedPerformanceSamplingAlternatesOrder() {
        var order: [String] = []
        _ = bestPairedElapsed(samples: 4, first: {
            order.append("legacy")
            return 1
        }, second: {
            order.append("projected")
            return 1
        })
        XCTAssertEqual(order, [
            "legacy", "projected",
            "projected", "legacy",
            "legacy", "projected",
            "projected", "legacy",
        ])
    }

    private func performanceArticle(
        index: Int,
        status: NativeArticleStatus,
        tags: [String],
        sourceRelativePath: String
    ) -> NativeArticleSummary {
        NativeArticleSummary(
            banner: nil,
            category: "Knowledge",
            excerpt: "Article \(index) summary with enough text to model a real library row and needle terms",
            publishedAt: status == .published ? "2026-08-29T10:00:00.000Z" : nil,
            slug: "article-\(index)",
            sourceRelativePath: sourceRelativePath,
            status: status,
            tags: tags,
            title: "Article \(index)",
            updatedAt: "2026-08-29T10:00:00.000Z",
            wordCount: 120
        )
    }

    private func currentResidentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        XCTAssertEqual(result, KERN_SUCCESS, "failed to read benchmark resident memory")
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    private func performanceMoment(id: String, createdAt: String) -> NativeMoment {
        NativeMoment(
            createdAt: createdAt,
            id: id,
            images: [],
            text: id,
            textRuns: [],
            updatedAt: createdAt
        )
    }

    private func legacyFilteredArticles(
        _ articles: [NativeArticleSummary],
        searchText: String,
        resolvedSearchText: String,
        searchMatchSlugs: Set<String>,
        selectedTags: Set<String>,
        selectedFolderPath: String?
    ) -> [NativeArticleSummary] {
        let query = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let resolvedQuery = resolvedSearchText
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return articles.filter { article in
            let searchableSummary = [
                article.title,
                article.category,
                article.excerpt,
                article.tags.joined(separator: " "),
            ]
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let matchesSearch = query.isEmpty || (resolvedQuery == query
                ? searchMatchSlugs.contains(article.slug)
                : searchableSummary.contains(query))
            let matchesTags = selectedTags.isEmpty || article.tags.contains { tag in
                selectedTags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
            }
            let matchesFolder = selectedFolderPath.map { folder in
                article.sourceFolderPath == folder || article.sourceFolderPath.hasPrefix(folder + "/")
            } ?? true
            return matchesSearch && matchesTags && matchesFolder
        }
    }

    private func bestPairedElapsed(
        samples: Int = 4,
        first: () -> Int,
        second: () -> Int
    ) -> (
        first: (elapsed: TimeInterval, result: Int),
        second: (elapsed: TimeInterval, result: Int)
    ) {
        var firstBest = TimeInterval.greatestFiniteMagnitude
        var secondBest = TimeInterval.greatestFiniteMagnitude
        var firstResult: Int?
        var secondResult: Int?

        func measure(
            _ operation: () -> Int,
            best: inout TimeInterval,
            expectedResult: inout Int?
        ) {
            let start = ProcessInfo.processInfo.systemUptime
            let result = operation()
            best = min(best, ProcessInfo.processInfo.systemUptime - start)
            if let expectedResult {
                XCTAssertEqual(result, expectedResult, "benchmark samples must return stable results")
            } else {
                expectedResult = result
            }
        }

        for sample in 0..<samples {
            if sample.isMultiple(of: 2) {
                measure(first, best: &firstBest, expectedResult: &firstResult)
                measure(second, best: &secondBest, expectedResult: &secondResult)
            } else {
                measure(second, best: &secondBest, expectedResult: &secondResult)
                measure(first, best: &firstBest, expectedResult: &firstResult)
            }
        }
        return (
            first: (firstBest, firstResult ?? 0),
            second: (secondBest, secondResult ?? 0)
        )
    }
}

private actor AsyncTestGate {
    private var isSuspended = false
    private var isReleased = false
    private var suspendedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        isSuspended = true
        suspendedContinuation?.resume()
        suspendedContinuation = nil
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            suspendedContinuation = continuation
        }
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

final class LocalBlogStoreTests {
    func testMomentLifecycleNormalizesInputFiltersAndRecordsActivity() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)

        let images = [
            NativeMedia(kind: "video", name: "clip.mp4", size: 1, url: "/media/moment/clip.mp4"),
            NativeMedia(kind: "video", name: "legacy.mov", size: 1, url: "/media/moment/legacy.mov"),
            NativeMedia(kind: "image", name: "missing.png", size: 1, url: ""),
        ] + (1...10).map { index in
            NativeMedia(kind: "image", name: "image-\(index).png", size: index, url: "media/moment/image-\(index).png")
        }
        let saved = try await store.saveMoment(
            text: "  first note #Swift ",
            textRuns: [NativeMomentTextRun(text: "  first note #Swift ", bold: false, color: nil)],
            images: images
        )

        XCTAssertEqual(saved.text, "first note")
        XCTAssertEqual(saved.tags, ["Swift"])
        XCTAssertEqual(saved.images.count, 9)
        XCTAssertEqual(saved.videoAttachments.map(\.name), ["clip.mp4"])
        XCTAssertEqual(saved.imageAttachments.count, 8)
        XCTAssertTrue(saved.images.allSatisfy { ($0.isImage || $0.isVideo) && $0.url.hasPrefix("/") })
        XCTAssertEqual(try await store.listMoments().map(\.id), [saved.id])
        XCTAssertEqual(try await store.listMoments().first?.videoAttachments.map(\.name), ["clip.mp4"])

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

    func testMomentAudioUploadAndPersistence() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let source = root.appendingPathComponent("recording.MP3")
        // Storage accepts the format; AVFoundation validates playback separately.
        try Data([73, 68, 51]).write(to: source)
        let uploaded = try await NativeMediaUpload.files(
            [source], kind: .audio, destination: .moments, store: store
        )
        XCTAssertEqual(uploaded.count, 1)
        XCTAssertTrue(uploaded[0].isAudio)
        XCTAssertFalse(uploaded[0].isFile)
        XCTAssertTrue(uploaded[0].url.hasSuffix(".mp3"))
        let saved = try await store.saveMoment(text: "", textRuns: [], images: uploaded)
        XCTAssertEqual(saved.audioAttachments, uploaded)
        XCTAssertTrue(saved.imageAttachments.isEmpty)
        XCTAssertTrue(saved.videoAttachments.isEmpty)
        let reopened = LocalBlogStore(rootURL: root)
        XCTAssertEqual(try await reopened.listMoments().first?.audioAttachments, uploaded)

        let unsupported = root.appendingPathComponent("recording.wav")
        try Data([0]).write(to: unsupported)
        do {
            _ = try await store.uploadMedia(fileURL: unsupported, kind: "audio", slug: "moments")
            XCTFail("expected non-MP3 moment audio to be rejected")
        } catch let error as NativeStoreError {
            XCTAssertTrue(error.localizedDescription.contains("仅支持 MP3"))
        }
        let updated = try await store.updateMoment(id: saved.id, text: "audio removed", textRuns: [], images: [])
        XCTAssertTrue(updated.audioAttachments.isEmpty)
    }

    func testMomentVideoUploadOnlyAcceptsMP4() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)

        let mp4Source = root.appendingPathComponent("clip.MP4")
        try Data([0, 0, 0, 20, 102, 116, 121, 112]).write(to: mp4Source)
        let uploaded = try await store.uploadMedia(fileURL: mp4Source, kind: "video", slug: "moments")
        XCTAssertEqual(uploaded.kind, "video")
        XCTAssertTrue(uploaded.url.hasSuffix(".mp4"))

        let movSource = root.appendingPathComponent("clip.mov")
        try Data([0, 0, 0, 20, 102, 116, 121, 112]).write(to: movSource)
        do {
            _ = try await store.uploadMedia(fileURL: movSource, kind: "video", slug: "moments")
            XCTFail("expected non-MP4 moment video to be rejected")
        } catch let error as NativeStoreError {
            XCTAssertTrue(error.localizedDescription.contains("仅支持 MP4"))
        }
    }

    func testMediaUploadModuleCleansCompletedFilesWhenABatchFails() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let source = root.appendingPathComponent("first.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: source)

        do {
            _ = try await NativeMediaUpload.files(
                [source, root.appendingPathComponent("missing.png")],
                kind: .image,
                destination: .moments,
                store: store
            )
            XCTFail("expected the missing source to fail the batch")
        } catch {
            let destination = root
                .appendingPathComponent("media", isDirectory: true)
                .appendingPathComponent("moments", isDirectory: true)
            let remaining = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
            XCTAssertTrue(remaining.isEmpty)
        }
    }

    func testMomentCommentsPersistRepliesCountsAndCascadeDeletion() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let moment = try await store.saveMoment(text: "Discuss this", textRuns: [], images: [])
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let parent = try await store.createMomentComment(
            momentID: moment.id, authorName: " leon ", text: " First comment \n", at: start
        )
        let reply = try await store.createMomentComment(
            momentID: moment.id, authorName: "leon", text: "Reply", parentID: parent.id,
            at: start
        )
        let nested = try await store.createMomentComment(
            momentID: moment.id, authorName: "leon", text: "Nested reply", parentID: reply.id,
            at: start
        )
        let separate = try await store.createMomentComment(
            momentID: moment.id, authorName: "leon", text: "Separate thread",
            at: start
        )
        XCTAssertEqual(parent.authorName, "leon")
        XCTAssertEqual(parent.text, "First comment")
        XCTAssertTrue(parent.createdAt < reply.createdAt && reply.createdAt < nested.createdAt)
        let reopened = LocalBlogStore(rootURL: root)
        XCTAssertEqual(
            try await reopened.listMomentComments(momentID: moment.id),
            [parent, reply, nested, separate]
        )
        XCTAssertEqual(try await reopened.listMomentPage().moments.first?.commentCount, 4)
        XCTAssertEqual(try await store.setMomentFavorite(id: moment.id, isFavorite: true).commentCount, 4)
        XCTAssertEqual(try await store.updateMoment(id: moment.id, text: "Edited", textRuns: [], images: []).commentCount, 4)
        XCTAssertEqual(try await reopened.listMomentComments(momentID: moment.id), [parent, reply, nested, separate])

        try await reopened.deleteMomentComment(id: parent.id, momentID: moment.id)
        XCTAssertEqual(try await store.listMomentComments(momentID: moment.id), [separate])
        XCTAssertEqual(try await store.listMomentPage().moments.first?.commentCount, 1)
    }

    func testMomentCommentsRejectInvalidInputAndCrossPostReplies() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let first = try await store.saveMoment(text: "First", textRuns: [], images: [])
        let second = try await store.saveMoment(text: "Second", textRuns: [], images: [])
        let parent = try await store.createMomentComment(momentID: first.id, authorName: "leon", text: "Parent")
        for (author, text) in [("leon", " \n "), (" ", "Comment"), ("leon", String(repeating: "字", count: 2_001))] {
            do {
                _ = try await store.createMomentComment(momentID: first.id, authorName: author, text: text)
                XCTFail("invalid comment must be rejected")
            } catch NativeStoreError.invalidComment { }
        }
        do {
            _ = try await store.createMomentComment(momentID: "missing", authorName: "leon", text: "Comment")
            XCTFail("comments require an existing post")
        } catch NativeStoreError.notFound { }
        for parentID in [parent.id, "missing"] {
            do {
                _ = try await store.createMomentComment(
                    momentID: second.id, authorName: "leon", text: "Reply", parentID: parentID
                )
                XCTFail("reply must reference a comment on the same post")
            } catch NativeStoreError.notFound { }
        }
        do {
            try await store.deleteMomentComment(id: parent.id, momentID: second.id)
            XCTFail("deletion must reference the same post")
        } catch NativeStoreError.notFound { }
        XCTAssertEqual(try await store.listMomentComments(momentID: first.id), [parent])
        XCTAssertTrue(try await store.listMomentComments(momentID: second.id).isEmpty)
    }

    func testMomentCommentsFollowTrashRestoreAndPermanentDeletion() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let moment = try await store.saveMoment(text: "Trash lifecycle", textRuns: [], images: [])
        let parent = try await store.createMomentComment(momentID: moment.id, authorName: "leon", text: "Keep me")
        let reply = try await store.createMomentComment(
            momentID: moment.id, authorName: "leon", text: "And me", parentID: parent.id
        )
        try await store.deleteMoment(id: moment.id)
        do {
            _ = try await store.listMomentComments(momentID: moment.id)
            XCTFail("trashed posts must hide their comments")
        } catch NativeStoreError.notFound { }
        do {
            _ = try await store.createMomentComment(momentID: moment.id, authorName: "leon", text: "Too late")
            XCTFail("trashed posts must reject new comments")
        } catch NativeStoreError.notFound { }
        do {
            try await store.deleteMomentComment(id: parent.id, momentID: moment.id)
            XCTFail("trashed comments must be preserved until the post is restored")
        } catch NativeStoreError.notFound { }
        guard let item = try await store.listTrash().first else {
            XCTFail("post should be in trash")
            return
        }
        try await store.restoreTrash(item)
        XCTAssertEqual(try await store.listMomentComments(momentID: moment.id), [parent, reply])
        XCTAssertEqual(try await store.listMomentPage().moments.first?.commentCount, 2)
        try await store.deleteMoment(id: moment.id)
        try await store.permanentlyDeleteTrash(item)
        let database = try SQLiteDatabase(url: root.appendingPathComponent("leon-book.sqlite"))
        defer { database.close() }
        XCTAssertEqual(try database.integer("SELECT COUNT(*) FROM moment_comments"), 0)
    }

    func testMomentCommentsSurviveBackupSnapshots() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let store = LocalBlogStore(rootURL: source)
        let moment = try await store.saveMoment(text: "Back me up", textRuns: [], images: [])
        let comment = try await store.createMomentComment(momentID: moment.id, authorName: "leon", text: "Keep this comment")
        try await store.prepareForBackup()
        let snapshot = try LocalBackupManager.createManagedSnapshot(
            source: source, destination: root.appendingPathComponent("backups"),
            policy: NativeBackupPolicy(minimumFreeSpaceBytes: 0)
        ).snapshot
        let restoredRoot = root.appendingPathComponent("restored", isDirectory: true)
        try FileManager.default.copyItem(at: snapshot.url, to: restoredRoot)
        let restored = LocalBlogStore(rootURL: restoredRoot)
        XCTAssertEqual(try await restored.listMomentComments(momentID: moment.id), [comment])
        XCTAssertEqual(try await restored.listMomentPage().moments.first?.commentCount, 1)
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
        XCTAssertEqual(
            try await store.listQuestions(searchText: "性").map(\.id),
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

    func testAtomicArticleBodyUpdatesCommitAndUndoBothNotes() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let source = try await store.saveArticle(article(
            slug: "block-source",
            status: .draft,
            expectedUpdatedAt: nil,
            body: "来源正文\n\n可移动块 ^moving"
        ))
        let target = try await store.saveArticle(article(
            slug: "block-target",
            status: .draft,
            expectedUpdatedAt: nil,
            body: "目标正文"
        ))

        let moved = try await store.updateArticleBodiesAtomically([
            NativeArticleBodyUpdate(
                slug: source.slug,
                body: "来源正文",
                expectedUpdatedAt: source.updatedAt
            ),
            NativeArticleBodyUpdate(
                slug: target.slug,
                body: "目标正文\n\n可移动块 ^moving",
                expectedUpdatedAt: target.updatedAt
            ),
        ])
        let movedSource = moved.first { $0.slug == source.slug }!
        let movedTarget = moved.first { $0.slug == target.slug }!
        XCTAssertEqual(try await store.getArticle(slug: source.slug).body, "来源正文")
        XCTAssertTrue(try await store.getArticle(slug: target.slug).body.contains("可移动块"))

        do {
            _ = try await store.updateArticleBodiesAtomically([
                NativeArticleBodyUpdate(
                    slug: source.slug,
                    body: "不应写入",
                    expectedUpdatedAt: source.updatedAt
                ),
                NativeArticleBodyUpdate(
                    slug: target.slug,
                    body: "也不应写入",
                    expectedUpdatedAt: movedTarget.updatedAt
                ),
            ])
            XCTFail("a stale source timestamp should reject the complete body transaction")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("其他窗口中更新"))
        }
        XCTAssertEqual(try await store.getArticle(slug: target.slug).body, movedTarget.body)

        _ = try await store.updateArticleBodiesAtomically([
            NativeArticleBodyUpdate(
                slug: source.slug,
                body: source.body,
                expectedUpdatedAt: movedSource.updatedAt
            ),
            NativeArticleBodyUpdate(
                slug: target.slug,
                body: target.body,
                expectedUpdatedAt: movedTarget.updatedAt
            ),
        ])
        XCTAssertEqual(try await store.getArticle(slug: source.slug).body, source.body)
        XCTAssertEqual(try await store.getArticle(slug: target.slug).body, target.body)
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
            contentsOf: storeRoot.appendingPathComponent("articles/未分类/\(roadmap.slug).md"),
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

    func testShortSearchAndMediaReferenceIndexStayIncremental() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFile = root.appendingPathComponent("source.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: sourceFile)
        let store = LocalBlogStore(rootURL: root)
        let uploaded = try await store.uploadMedia(fileURL: sourceFile, kind: "image", slug: "indexed-note")
        let media = NativeMedia(
            kind: uploaded.kind,
            name: uploaded.name,
            size: uploaded.size,
            url: uploaded.url
        )
        let saved = try await store.saveArticle(article(
            slug: "indexed-note",
            status: .published,
            expectedUpdatedAt: nil,
            body: "性能 ![图](\(uploaded.url))"
        ))

        XCTAssertEqual(
            try await store.search("性", restrictingTo: [.article]).map(\.documentID),
            [saved.slug]
        )
        try await store.discardUnreferencedMedia([media])
        let storedURL = await store.mediaURL(for: uploaded.url)
        XCTAssertTrue(storedURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)

        _ = try await store.saveArticle(article(
            slug: saved.slug,
            status: .published,
            expectedUpdatedAt: saved.updatedAt,
            body: "引用已移除"
        ))
        try await store.discardUnreferencedMedia([media])
        XCTAssertTrue(storedURL.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
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
            contentsOf: root.appendingPathComponent("articles/未分类/saved-note.md"),
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
            atPath: root.appendingPathComponent("articles/未分类/\(extraction.createdArticles[0].slug).md").path
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
            atPath: root.appendingPathComponent("articles/未分类/\(mergeSource.slug).md").path
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("articles/未分类/managed-note.md").path))
        XCTAssertEqual(try String(contentsOf: vault.appendingPathComponent("mounted.md"), encoding: .utf8), mountedSource)
    }

    func testWorkspaceResourceTreeMixesArticlesAttachmentsAndMovesFolders() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)

        try await store.createWorkspaceFolder(relativePath: "projects")
        try await store.createWorkspaceFolder(relativePath: "projects/empty")
        let sourceAttachment = root.appendingPathComponent("source-cover.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: sourceAttachment)
        let uploaded = try await store.uploadMedia(
            fileURL: sourceAttachment,
            kind: "image",
            slug: "resource-note"
        )
        let saved = try await store.saveArticle(NativeSaveArticle(
            banner: nil,
            body: "Resource body\n\n![cover](\(uploaded.url))",
            category: "Notes",
            excerpt: "",
            media: [NativeMedia(
                kind: uploaded.kind,
                name: "cover.png",
                size: uploaded.size,
                url: uploaded.url
            )],
            slug: "resource-note",
            status: .published,
            tags: [],
            title: "Resource note",
            expectedUpdatedAt: nil,
            sourceRelativePath: "projects/resource-note.md"
        ))
        let markdownRoot = try await store.markdownSourceDirectoryURL()
        try Data("attachment".utf8).write(
            to: markdownRoot.appendingPathComponent("projects/specification.pdf")
        )

        let initial = try await store.listWorkspaceResources()
        let initialItems = NativeWorkspaceResourceTree.flattened(initial)
        XCTAssertNotNil(initialItems.first(where: {
            $0.kind == .folder && $0.relativePath == "projects/empty"
        }))
        XCTAssertEqual(initialItems.first(where: {
            $0.kind == .article && $0.articleSlug == saved.slug
        })?.sourceRelativePath, "projects/resource-note.md")
        XCTAssertNotNil(initialItems.first(where: {
            $0.kind == .attachment
                && $0.storage == .markdownSource
                && $0.name == "specification.pdf"
        }))
        XCTAssertNotNil(initialItems.first(where: {
            $0.kind == .attachment
                && $0.storage == .managedMedia
                && $0.name == "cover.png"
                && $0.relativePath == "projects/cover.png"
        }))

        let sync = try await store.moveWorkspaceSourceItems([
            NativeWorkspaceResourceMove(
                sourceRelativePath: "projects",
                destinationRelativePath: "archive/projects"
            ),
        ])
        XCTAssertTrue(sync.didChange)
        XCTAssertEqual(
            try await store.getArticle(slug: saved.slug).sourceRelativePath,
            "archive/projects/resource-note.md"
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: markdownRoot.appendingPathComponent("archive/projects/specification.pdf").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: markdownRoot.appendingPathComponent("projects").path
        ))

        let movedItems = NativeWorkspaceResourceTree.flattened(
            try await store.listWorkspaceResources()
        )
        XCTAssertNotNil(movedItems.first(where: {
            $0.kind == .attachment
                && $0.storage == .managedMedia
                && $0.relativePath == "archive/projects/cover.png"
        }))
    }

    func testPortableSidecarSynchronizesNonRebuildableStateAcrossWorkspaces() async throws {
        let vault = try makeTemporaryDirectory()
        let firstRoot = try makeTemporaryDirectory()
        let secondRoot = try makeTemporaryDirectory()
        let readOnlyRoot = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: vault)
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
            try? FileManager.default.removeItem(at: readOnlyRoot)
        }
        let source = """
        ---
        slug: portable-note
        title: Portable note
        ---
        Shared Markdown body
        """
        try Data(source.utf8).write(to: vault.appendingPathComponent("portable-note.md"))

        let first = LocalBlogStore(rootURL: firstRoot)
        _ = try await first.configureMarkdownWorkspaceSource(mode: .directEdit, directoryURL: vault)
        _ = try await first.setPortableSidecarEnabled(true)
        let comment = try await first.createArticleComment(
            articleSlug: "portable-note",
            authorName: "first-device",
            text: "Synced comment",
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let revision = try await first.saveArticleAutosave(
            draftKey: "portable-note",
            articleSlug: "portable-note",
            snapshot: revisionSnapshot(body: "Synced history"),
            at: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let bookmark = try await first.saveBookmark(NativeBookmark(
            title: "Portable bookmark",
            target: .article(slug: "portable-note"),
            createdAt: NativeTimestamp.string(from: Date(timeIntervalSince1970: 1_700_000_200))
        ))
        let portableUI = NativePortableUIState(
            workspaceLayouts: NativePortableLayoutState(
                profiles: [.defaultProfile(for: .reading)],
                activeProfileID: NativeWorkspaceLayoutKind.reading.profileID
            ),
            readingProfile: NativeReadingProfile(
                readingWidth: 920,
                bodyFont: .serif,
                codeFont: .menlo,
                fontSize: 19,
                lineSpacing: 7,
                paragraphSpacing: 18,
                theme: .sepia
            )
        )
        try await first.writePortableUIState(portableUI)
        try await first.verifyCompatibilityExports()

        let sidecar = vault.appendingPathComponent(".leonbook", isDirectory: true)
        for filename in ["manifest.json", "comments.json", "history.json", "bookmarks.json", "layouts.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.appendingPathComponent(filename).path))
        }

        let second = LocalBlogStore(rootURL: secondRoot)
        _ = try await second.configureMarkdownWorkspaceSource(mode: .directEdit, directoryURL: vault)
        let imported = try await second.setPortableSidecarEnabled(true)
        XCTAssertTrue(imported.didChange)
        XCTAssertEqual(try await second.listArticleComments(articleSlug: "portable-note"), [comment])
        XCTAssertEqual(
            try await second.listArticleRevisions(
                articleSlug: "portable-note",
                draftKey: "portable-note"
            ).first?.syncID,
            revision.syncID
        )
        XCTAssertEqual(try await second.listBookmarks(), [bookmark])
        XCTAssertEqual(try await second.readPortableUIState(), portableUI)

        try await first.deleteArticleComment(id: comment.id, articleSlug: comment.articleSlug)
        try await first.deleteBookmark(id: bookmark.id)
        try await first.verifyCompatibilityExports()
        let deleted = try await second.synchronizePortableSidecar()
        XCTAssertEqual(deleted.deletedCommentCount, 1)
        XCTAssertEqual(deleted.deletedBookmarkCount, 1)
        XCTAssertTrue(try await second.listArticleComments(articleSlug: "portable-note").isEmpty)
        XCTAssertTrue(try await second.listBookmarks().isEmpty)

        let readOnly = LocalBlogStore(rootURL: readOnlyRoot)
        _ = try await readOnly.configureMarkdownWorkspaceSource(mode: .readOnlyMount, directoryURL: vault)
        _ = try await readOnly.setPortableSidecarEnabled(true)
        let readOnlyStatus = try await readOnly.portableSidecarStatus()
        XCTAssertTrue(readOnlyStatus.isEnabled)
        XCTAssertFalse(readOnlyStatus.isWritable)
        do {
            try await readOnly.writePortableUIState(portableUI)
            XCTFail("read-only mounts must not write portable sidecars")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("只读"))
        }
    }

    func testPortableSidecarPreservesRecordsUntilMarkdownArrives() async throws {
        let vault = try makeTemporaryDirectory()
        let sourceRoot = try makeTemporaryDirectory()
        let receivingRoot = try makeTemporaryDirectory()
        let stagedNote = try makeTemporaryDirectory().appendingPathComponent("delayed-note.md")
        defer {
            try? FileManager.default.removeItem(at: vault)
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: receivingRoot)
            try? FileManager.default.removeItem(at: stagedNote.deletingLastPathComponent())
        }
        let noteURL = vault.appendingPathComponent("delayed-note.md")
        let source = """
        ---
        slug: delayed-note
        title: Delayed note
        ---
        Markdown can arrive after its sidecar.
        """
        try Data(source.utf8).write(to: noteURL)

        let sourceStore = LocalBlogStore(rootURL: sourceRoot)
        _ = try await sourceStore.configureMarkdownWorkspaceSource(
            mode: .directEdit,
            directoryURL: vault
        )
        _ = try await sourceStore.setPortableSidecarEnabled(true)
        let comment = try await sourceStore.createArticleComment(
            articleSlug: "delayed-note",
            authorName: "source-device",
            text: "Keep me until the Markdown file arrives."
        )
        try await sourceStore.verifyCompatibilityExports()

        try FileManager.default.moveItem(at: noteURL, to: stagedNote)
        let receivingStore = LocalBlogStore(rootURL: receivingRoot)
        _ = try await receivingStore.configureMarkdownWorkspaceSource(
            mode: .directEdit,
            directoryURL: vault
        )
        _ = try await receivingStore.setPortableSidecarEnabled(true)
        XCTAssertTrue(
            try await receivingStore.listArticleComments(articleSlug: "delayed-note").isEmpty
        )

        try FileManager.default.moveItem(at: stagedNote, to: noteURL)
        _ = try await receivingStore.refreshMarkdownSources()
        _ = try await receivingStore.synchronizePortableSidecar()
        XCTAssertEqual(
            try await receivingStore.listArticleComments(articleSlug: "delayed-note"),
            [comment]
        )
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

final class DataIntegrityTests {
    func testRestoreClosesAllStoresAndBlocksNewConnections() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("live")
        let users = UserWorkspaceStore(rootURL: live)
        let workspace = try await users.prepare().workspaceURL
        let first = LocalBlogStore(rootURL: workspace)
        let original = try await first.saveArticle(article(slug: "note", status: .draft, expectedUpdatedAt: nil, body: "Original"))
        let second = LocalBlogStore(rootURL: workspace)
        _ = try await second.listArticles()
        try await first.prepareForBackup()
        try await users.prepareForBackup()
        let snapshot = try LocalBackupManager.createManagedSnapshot(source: live, destination: root.appendingPathComponent("backups"), policy: NativeBackupPolicy(minimumFreeSpaceBytes: 0)).snapshot
        _ = try await second.saveArticle(article(slug: "note", status: .draft, expectedUpdatedAt: original.updatedAt, body: "Changed"))
        let suspension = try WorkspaceStorageLifecycle.suspend(in: live)
        defer { suspension.finish() }
        try await suspension.prepareAndClose()
        let duringRestore = LocalBlogStore(rootURL: workspace)
        for store in [first, second, duringRestore] {
            do { _ = try await store.listArticles(); XCTFail("storage must remain closed until restore finishes") }
            catch { }
        }
        do { _ = try await users.prepare(); XCTFail("user registry must also stay closed") }
        catch { }
        try LocalBackupManager.restoreSnapshot(at: snapshot.url, to: live, minimumFreeSpaceBytes: 0)
        suspension.finish()
        for store in [first, second, duringRestore] {
            XCTAssertEqual(try await store.getArticle(slug: "note").body, "Original")
            await store.closeForRestore()
        }
        XCTAssertEqual(try await users.prepare().workspaceURL, workspace)
        await users.closeForRestore()
    }

    func testRestoreWaitsForAsyncMediaWrites() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = try WorkspaceStorageLifecycle.beginAsyncWrite(in: root.appendingPathComponent("workspaces/user"))
        do { _ = try WorkspaceStorageLifecycle.suspend(in: root); XCTFail("restore must reject an active media copy") }
        catch { }
        withExtendedLifetime(lease) { }
    }

    @MainActor
    func testRestoreReconnectsEveryWindowAndPreservesDraftOnFailure() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("live")
        let backups = root.appendingPathComponent("backups")
        let first = NativeAppModel(navigationScopeID: nil, startsAutomatically: false, store: LocalBlogStore(rootURL: live))
        let second = NativeAppModel(navigationScopeID: nil, startsAutomatically: false, store: LocalBlogStore(rootURL: live))
        for model in [first, second] {
            try await model.connect(to: live)
            model.isLoading = false
            model.backupDirectoryPath = backups.path
            model.backupPolicy = NativeBackupPolicy(minimumFreeSpaceBytes: 0)
            model.stopMarkdownSourceMonitor()
        }
        let original = try await first.store.saveArticle(article(slug: "note", status: .draft, expectedUpdatedAt: nil, body: "Original"))
        try await first.store.prepareForBackup()
        try await first.userWorkspaces.prepareForBackup()
        let snapshot = try LocalBackupManager.createManagedSnapshot(source: live, destination: backups, policy: NativeBackupPolicy(minimumFreeSpaceBytes: 0)).snapshot
        _ = try await second.store.saveArticle(article(slug: "note", status: .draft, expectedUpdatedAt: original.updatedAt, body: "Changed"))
        await first.performBackupRestore(snapshot)
        for model in [first, second] {
            XCTAssertTrue(model.storageReady)
            XCTAssertFalse(model.isRestoringBackup)
            XCTAssertEqual(try await model.store.getArticle(slug: "note").body, "Original")
            model.stopMarkdownSourceMonitor()
        }
        second.editor.title = "Unsaved draft"
        second.editor.body = "Keep this draft if validation fails"
        let snapshotArticle = snapshot.url.appendingPathComponent("workspaces/leon/articles/未分类/note.md")
        try Data("corrupt".utf8).write(to: snapshotArticle, options: .atomic)
        await first.performBackupRestore(snapshot)
        XCTAssertTrue(first.storageReady)
        XCTAssertTrue(second.storageReady)
        XCTAssertEqual(second.editor.body, "Keep this draft if validation fails")
        XCTAssertNotNil(first.errorMessage)
        for model in [first, second] {
            model.pauseForWorkspaceRestore()
            await model.store.closeForRestore()
            await model.userWorkspaces.closeForRestore()
        }
    }

    func testExternalEditBeforeWatcherIsNotOverwritten() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let original = try await store.saveArticle(article(slug: "note", status: .draft, expectedUpdatedAt: nil, body: "Original"))
        let file = root.appendingPathComponent("articles/未分类/note.md")
        let external = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "Original", with: "External")
        try Data(external.utf8).write(to: file, options: .atomic)
        do {
            _ = try await store.saveArticle(article(slug: "note", status: .draft, expectedUpdatedAt: original.updatedAt, body: "Local"))
            XCTFail("saving before the watcher runs must reject external changes")
        } catch NativeStoreError.conflict { }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), external)
        XCTAssertEqual(try await store.getArticle(slug: "note").body, "External")
        await store.closeForRestore()
    }

    func testFailedSaveRestoresExactMarkdownAndDoesNotCreateNewFile() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let original = try await store.saveArticle(article(slug: "note", status: .draft, expectedUpdatedAt: nil, body: "Original"))
        let file = root.appendingPathComponent("articles/未分类/note.md")
        let before = try Data(contentsOf: file)
        let fault = try SQLiteDatabase(url: root.appendingPathComponent("leon-book.sqlite"))
        try fault.execute("CREATE TRIGGER reject_article BEFORE INSERT ON articles BEGIN SELECT RAISE(ABORT, 'injected failure'); END;")
        for (slug, version) in [("note", Optional(original.updatedAt)), ("new-note", nil)] {
            do {
                _ = try await store.saveArticle(article(slug: slug, status: .draft, expectedUpdatedAt: version, body: "Rejected"))
                XCTFail("injected database failure must fail the save")
            } catch { }
        }
        XCTAssertEqual(try Data(contentsOf: file), before, "failed save must restore the original bytes")
        XCTAssertEqual(try await store.getArticle(slug: "note").body, "Original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("articles/未分类/new-note.md").path))
        fault.close()
        await store.closeForRestore()
    }

    func testFailedSaveReturnsAttachmentsToInbox() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        _ = try await store.listArticles()
        let inbox = root.appendingPathComponent("media/inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let file = inbox.appendingPathComponent("attachment.png")
        try Data("image".utf8).write(to: file)
        let fault = try SQLiteDatabase(url: root.appendingPathComponent("leon-book.sqlite"))
        try fault.execute("CREATE TRIGGER reject_article BEFORE INSERT ON articles BEGIN SELECT RAISE(ABORT, 'injected failure'); END;")
        do {
            _ = try await store.saveArticle(NativeSaveArticle(
                banner: nil, body: "![image](/media/inbox/attachment.png)", category: "", excerpt: "",
                media: [NativeMedia(kind: "image", name: "attachment.png", size: 5, url: "/media/inbox/attachment.png")],
                slug: "note", status: .draft, tags: [], title: "Note", expectedUpdatedAt: nil
            ))
            XCTFail("injected database failure must fail the save")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: file), Data("image".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("media/note/attachment.png").path))
        fault.close()
        await store.closeForRestore()
    }

    func testReadOnlySwitchAppliesToAlreadyOpenStores() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        let vault = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let first = LocalBlogStore(rootURL: workspace)
        _ = try await first.configureMarkdownWorkspaceSource(mode: .directEdit, directoryURL: vault)
        let original = try await first.saveArticle(article(slug: "note", status: .draft, expectedUpdatedAt: nil, body: "Original"))
        let second = LocalBlogStore(rootURL: workspace)
        _ = try await second.listArticles()
        _ = try await first.configureMarkdownWorkspaceSource(mode: .readOnlyMount, directoryURL: vault)
        do {
            _ = try await second.saveArticle(article(slug: "note", status: .draft, expectedUpdatedAt: original.updatedAt, body: "Forbidden"))
            XCTFail("a previously opened store must honor the current read-only setting")
        } catch NativeStoreError.readOnlyArticleSource { }
        XCTAssertEqual(try await second.markdownWorkspaceSourceState().mode, .readOnlyMount)
        XCTAssertEqual(try await first.getArticle(slug: "note").body, "Original")
        await first.closeForRestore()
        await second.closeForRestore()
    }

    func testBackupDetectsSameSizeContentWithPreservedTimestamp() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("note.md")
        try Data("BEFORE".utf8).write(to: file)
        let date = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        let policy = NativeBackupPolicy(minimumFreeSpaceBytes: 0)
        _ = try LocalBackupManager.createManagedSnapshot(source: source, destination: destination, policy: policy)
        try Data("AFTER!".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let snapshot = try LocalBackupManager.createManagedSnapshot(source: source, destination: destination, policy: policy).snapshot
        XCTAssertEqual(try String(contentsOf: snapshot.url.appendingPathComponent("note.md"), encoding: .utf8), "AFTER!")
        XCTAssertTrue(try LocalBackupManager.validateSnapshot(at: snapshot.url).verifiedChecksums)
    }
}

final class RichArticleTests {
    func testRichArticleConversionPreservesContentAndFormatting() throws {
        let html = RichArticleDocument.convertingLegacyBody("# 标题\n第一段 **加粗**\n第二段\n\n```swift\nif x < 2 { print(x) }\n```\n\n> [!NOTE]\n> 重要提示\n\n![图片](/media/note/image.png)\n[[other|其他文章]]")
        XCTAssertTrue(RichArticleDocument.isHTML(html))
        XCTAssertTrue(html.contains("<h1"))
        XCTAssertTrue(html.contains("<strong>加粗</strong>"))
        XCTAssertTrue(html.contains("<pre"))
        XCTAssertTrue(html.contains("<aside"))
        XCTAssertFalse(html.contains("```"))
        XCTAssertEqual(RichArticleDocument.imageURLs(in: html), ["/media/note/image.png"])
        XCTAssertEqual(NativeArticleLink.references(in: html), ["other"])
        XCTAssertTrue(RichArticleDocument.plainText(html).contains("if x < 2 { print(x) }"))
        XCTAssertEqual(RichArticleDocument.outline(in: html).map(\.title), ["标题"])
        let fourLevels = RichArticleDocument.opening + "<h1>章</h1><h2>节</h2><h3>小节</h3><h4><strong>细节</strong></h4></article>"
        XCTAssertEqual(RichArticleDocument.outline(in: fourLevels).map(\.level), [1, 2, 3, 4])
        XCTAssertEqual(RichArticleDocument.outline(in: fourLevels).map(\.title), ["章", "节", "小节", "细节"])
        XCTAssertEqual(RichArticleDocument.convertingLegacyBody(html), html)
        XCTAssertEqual(NativeWritingMetrics.characterCount(of: RichArticleDocument.opening + "<p><strong>中文</strong>&amp;🌙</p></article>"), 4)
        XCTAssertEqual(RichArticleDocument.plainText(RichArticleDocument.empty), "")
        let captionText = RichArticleDocument.plainText(RichArticleDocument.opening + "<figure><img src=\"/media/image.png\"><figcaption>Picture caption</figcaption></figure><p>Following paragraph</p></article>")
        XCTAssertTrue(captionText.contains("caption\n"), "image captions must remain separate from following paragraphs in search text")
        XCTAssertFalse(captionText.contains("captionFollowing"))
    }

    func testRichArticleHTMLSaveAndReopen() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let html = RichArticleDocument.opening + "<p><strong>第一段</strong></p><aside data-type=\"callout\">高亮提示</aside><pre data-language=\"swift\"><code>let x = &lt;value&gt;</code></pre></article>"
        let saved = try await store.saveArticle(article(slug: "rich", status: .draft, expectedUpdatedAt: nil, body: html, title: "富文本 & <文章>"))
        XCTAssertEqual(saved.sourceRelativePath, "未分类/rich.html")
        let directory = try await store.markdownSourceDirectoryURL()
        let source = try String(contentsOf: directory.appendingPathComponent("未分类/rich.html"), encoding: .utf8)
        XCTAssertTrue(source.hasPrefix("<!doctype html>"))
        XCTAssertFalse(source.hasPrefix("---"))
        let record = try RichArticleFile.read(source, relativePath: "rich.html", modifiedAt: saved.updatedAt)
        XCTAssertEqual(record.body, html)
        XCTAssertEqual(record.title, "富文本 & <文章>")
        XCTAssertEqual(try await store.search("高亮提示").map(\.documentID), ["rich"])
        XCTAssertTrue(try await store.search("data-language").isEmpty, "HTML attributes must not enter full-text search")
        await store.closeForRestore()
        let reopened = LocalBlogStore(rootURL: root)
        XCTAssertEqual(try await reopened.listArticles().count, 1)
        XCTAssertEqual(try await reopened.getArticle(slug: "rich").body, html)
        await reopened.closeForRestore()
    }

    func testRichArticleMigrationArchivesLegacyAndRejectsCollisions() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let legacy = try await store.saveArticle(article(slug: "legacy", status: .draft, expectedUpdatedAt: nil, body: "第一段\n第二段"))
        let directory = try await store.markdownSourceDirectoryURL()
        let original = try Data(contentsOf: directory.appendingPathComponent("未分类/legacy.md"))
        let target = directory.appendingPathComponent("未分类/legacy.html")
        try Data("occupied".utf8).write(to: target)
        do {
            _ = try await store.saveArticle(article(slug: "legacy", status: .draft, expectedUpdatedAt: legacy.updatedAt, body: RichArticleDocument.convertingLegacyBody(legacy.body)))
            XCTFail("an existing HTML file must not be overwritten by migration")
        } catch NativeStoreError.fileSystem { }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("未分类/legacy.md")), original)
        try FileManager.default.removeItem(at: target)
        let migrated = try await store.saveArticle(article(slug: "legacy", status: .draft, expectedUpdatedAt: legacy.updatedAt, body: RichArticleDocument.convertingLegacyBody(legacy.body)))
        XCTAssertEqual(migrated.sourceRelativePath, "未分类/legacy.html")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("未分类/legacy.md").path))
        let archive = directory.appendingPathComponent(".legacy-markdown")
        let files = FileManager.default.enumerator(at: archive, includingPropertiesForKeys: nil)!.allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }
        XCTAssertEqual(files.count, 1)
        if let file = files.first { XCTAssertEqual(try Data(contentsOf: file), original) }
        _ = try await store.refreshMarkdownSources()
        XCTAssertEqual(try await store.listArticles().count, 1)
        XCTAssertEqual(try await store.getArticle(slug: "legacy").body, migrated.body)
        await store.closeForRestore()
    }

    @MainActor
    func testRichArticleCaretNavigationAvoidsContentCopies() async throws {
        try await withWebEditor { view in
            let result = try await view.evaluateJavaScript(#"""
            (() => {
              const root = document.getElementById('document');
              LeonArticle.load('<article data-leon-format="html-v1"><p>' + '<strong>富文本段落内容</strong><em>继续编辑</em>'.repeat(1200) + '</p></article>', 'navigation-work', true, 18);
              const node = root.firstElementChild.lastChild.firstChild;
              root.focus(); getSelection().setPosition(node, node.length);
              const clone = Range.prototype.cloneContents, stringify = Range.prototype.toString;
              let copiedCharacters = 0, scannedCharacters = 0;
              Range.prototype.cloneContents = function() { const copy = clone.call(this); copiedCharacters += copy.textContent.length; return copy; };
              Range.prototype.toString = function() { const text = stringify.call(this); scannedCharacters += text.length; return text; };
              const start = performance.now();
              try {
                for (let i = 0; i < 40; i++) {
                  root.dispatchEvent(new KeyboardEvent('keydown', {key: 'ArrowLeft', bubbles: true}));
                  getSelection().setPosition(node, i % (node.length + 1));
                  document.dispatchEvent(new Event('selectionchange'));
                }
              } finally { Range.prototype.cloneContents = clone; Range.prototype.toString = stringify; }
              return JSON.stringify({copiedCharacters, scannedCharacters, elapsedMS: performance.now() - start, menuHidden: document.getElementById('commands').hidden});
            })()
            """#)
            let json = try JSONSerialization.jsonObject(with: Data((result as! String).utf8)) as! [String: Any]
            print("CARET_NAVIGATION_PERFORMANCE \(result as! String)")
            XCTAssertEqual(json["copiedCharacters"] as? Int, 0, "caret bookmarks must not copy paragraph content")
            XCTAssertTrue((json["scannedCharacters"] as! Int) < 2_000, "ordinary caret movement must not stringify the paragraph for slash detection")
            XCTAssertEqual(json["menuHidden"] as? Bool, true)
        }
    }

    @MainActor
    func testRichArticleSelectionBookmarksPreserveMixedContent() async throws {
        try await withWebEditor { view in
            let result = try await view.callAsyncJavaScript(#"""
            const root = document.getElementById('document'), opening = '<article data-leon-format="html-v1">';
            const units = node => node.nodeType === Node.TEXT_NODE ? node.length : ['IMG','BR','HR'].includes(node.nodeName) ? 1 : [...node.childNodes].reduce((sum, child) => sum + units(child), 0);
            const point = (node, offset) => {
              const block = (node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement).closest('[data-block-id]');
              const range = document.createRange(); range.selectNodeContents(block); range.setEnd(node, offset);
              return {id: block.dataset.blockId, offset: units(range.cloneContents())};
            };
            const bookmark = () => { const s = getSelection(); return JSON.stringify([point(s.anchorNode, s.anchorOffset), point(s.focusNode, s.focusOffset)]); };
            const source = '<p data-block-id="p">甲<strong>👩🏽‍💻乙</strong><br><img src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"><em>é丙</em>末</p><p data-block-id="q">另一段</p><p data-block-id="empty"><br></p><table><tr><td><p data-block-id="cell">格内<strong>粗体</strong>末尾</p></td></tr></table><pre data-block-id="code"><code>第一行\n😀第二行</code></pre>';
            const cases = [
              ['start', p => [p.firstChild, 0]],
              ['emoji', p => [p.querySelector('strong').firstChild, 7]],
              ['before inline', p => [p, 1]],
              ['after break', p => [p, 3]],
              ['after image', p => [p, 4]],
              ['combining text', p => [p.querySelector('em').firstChild, 2]],
              ['backward', p => [p.lastChild, 1, p.firstChild, 0]],
              ['cross block', p => [root.querySelector('[data-block-id=q]').firstChild, 2, p.querySelector('strong').firstChild, 7]],
              ['empty', p => [root.querySelector('[data-block-id=empty]'), 0]],
              ['table', p => [root.querySelector('[data-block-id=cell]'), 2]],
              ['code', p => [root.querySelector('code').firstChild, 6]],
              ['text mutation', p => [p, 4]],
              ['detached mutation', p => [p, 4]]
            ];
            for (const [label, endpoints] of cases) {
              LeonArticle.load(opening + source + '</article>', 'bookmark-' + label, true, 18);
              const p = root.firstElementChild;
              root.focus(); getSelection().setPosition(p, 4);
              root.dispatchEvent(new KeyboardEvent('keydown', {key: 'ArrowLeft', bubbles: true}));
              if (label === 'text mutation') p.querySelector('strong').firstChild.data += '追加😀';
              if (label === 'detached mutation') {
                p.remove(); LeonArticle.serialize(); await new Promise(resolve => setTimeout(resolve, 0));
                p.querySelector('strong').firstChild.data += '脱离后追加'; root.prepend(p);
              }
              if (label.endsWith('mutation')) {
                // Publish this separate edit, then leave the typing-coalescing
                // window so undo of Z should return to the modified document.
                root.dispatchEvent(new Event('input'));
                await new Promise(resolve => setTimeout(resolve, 650));
              }
              const points = endpoints(p);
              getSelection().setBaseAndExtent(...(points.length === 2 ? [...points, ...points] : points));
              const expected = bookmark(), before = LeonArticle.serialize();
              root.dispatchEvent(new InputEvent('beforeinput', {inputType: 'insertText', data: 'Z', bubbles: true, cancelable: true}));
              document.execCommand('insertText', false, 'Z');
              const after = LeonArticle.serialize();
              if (after === before) throw new Error(label + ': input must change content');
              LeonArticle.undo(-1);
              if (bookmark() !== expected || LeonArticle.serialize() !== before) throw new Error(label + ': undo must restore content, direction and inline-object offsets; expected ' + expected + ', got ' + bookmark());
              LeonArticle.undo(1);
              if (LeonArticle.serialize() !== after || !getSelection().isCollapsed) throw new Error(label + ': redo must restore the edit and caret');
            }
            return cases.length;
            """#, arguments: [:], in: nil, contentWorld: .page)
            XCTAssertEqual(result as? Int, 13)
        }
    }

    @MainActor
    func testRichArticleSelectionUIWorkIsBounded() async throws {
        try await withWebEditor { view in
            let result = try await view.callAsyncJavaScript(#"""
            const root = document.getElementById('document'), menu = document.getElementById('commands');
            const wait = () => new Promise(resolve => setTimeout(resolve, 80));
            LeonArticle.load('<article data-leon-format="html-v1"><p>/</p></article>', 'menu-reuse', true, 18);
            root.focus(); getSelection().setPosition(root.firstChild.firstChild, 1);
            document.dispatchEvent(new Event('selectionchange')); await wait();
            const observer = new MutationObserver(() => {}); observer.observe(menu, {childList: true, subtree: true});
            for (let i = 0; i < 40; i++) document.dispatchEvent(new Event('selectionchange'));
            const menuMutations = observer.takeRecords().length; observer.disconnect();
            const menuVisible = !menu.hidden;
            root.dispatchEvent(new KeyboardEvent('keydown', {key: 'ArrowDown', bubbles: true}));
            document.dispatchEvent(new Event('selectionchange'));
            const selected = menu.querySelector('[aria-selected=true]')?.dataset.commandId;
            root.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true}));
            const commandApplied = selected === 'code' && root.firstElementChild.tagName === 'PRE';
            LeonArticle.load('<article data-leon-format="html-v1"><table><tbody><tr><td><p>表格文字</p></td><td><p>另一列</p></td></tr></tbody></table></article>', 'selection-ui', true, 18);
            root.focus(); getSelection().setPosition(root.querySelector('td p').firstChild, 1); await wait();
            const read = Element.prototype.getBoundingClientRect; let layoutReads = 0;
            Element.prototype.getBoundingClientRect = function() { layoutReads++; return read.call(this); };
            try { for (let i = 0; i < 120; i++) document.dispatchEvent(new Event('selectionchange')); await wait(); }
            finally { Element.prototype.getBoundingClientRect = read; }
            const add = document.getElementById('table-add-row'), rowVisible = !add.hidden;
            add.click(); const rowAdded = root.querySelector('table').rows.length === 2;
            return JSON.stringify({menuMutations, menuVisible, commandApplied, layoutReads, rowVisible, rowAdded});
            """#, arguments: [:], in: nil, contentWorld: .page)
            let json = try JSONSerialization.jsonObject(with: Data((result as! String).utf8)) as! [String: Any]
            print("SELECTION_UI_PERFORMANCE \(result as! String)")
            XCTAssertEqual(json["menuMutations"] as? Int, 0, "unchanged slash queries must reuse menu content")
            XCTAssertTrue((json["layoutReads"] as! Int) < 80, "selection bursts must share table layout measurements")
            for name in ["menuVisible", "commandApplied", "rowVisible", "rowAdded"] { XCTAssertEqual(json[name] as? Bool, true, name) }
        }
    }

    @MainActor
    func testRichArticlePointerWorkIsFrameBounded() async throws {
        try await withWebEditor { view in
            let result = try await view.callAsyncJavaScript(#"""
              const root = document.getElementById('document');
              LeonArticle.load('<article data-leon-format="html-v1"><table><tbody>' + '<tr>' + '<td><p>内容</p></td>'.repeat(12) + '</tr>' + '</tbody></table></article>', 'pointer-perf', true, 18);
              const cell = root.querySelector('td'), rect = cell.getBoundingClientRect();
              root.focus(); const range = document.createRange(); range.selectNodeContents(cell.firstElementChild); range.collapse(true); getSelection().removeAllRanges(); getSelection().addRange(range);
              await new Promise(resolve => setTimeout(resolve, 80));
              const original = Element.prototype.getBoundingClientRect; let layoutReads = 0;
              Element.prototype.getBoundingClientRect = function() { layoutReads++; return original.call(this); };
              const start = performance.now();
              for (let i = 0; i < 120; i++) cell.dispatchEvent(new PointerEvent('pointermove', {bubbles: true, clientX: rect.right - 2, clientY: rect.top + 10}));
              const eventMS = performance.now() - start;
              await new Promise(resolve => setTimeout(resolve, 80));
              Element.prototype.getBoundingClientRect = original;
              const columnAdd = document.getElementById('table-add-column');
              const visible = !columnAdd.hidden;
              columnAdd.click();
              return JSON.stringify({layoutReads, eventMS, visible, inserted: root.querySelector('tr').cells.length === 13});
            """#, arguments: [:], in: nil, contentWorld: .page)
            let json = try JSONSerialization.jsonObject(with: Data((result as! String).utf8)) as! [String: Any]
            print("POINTER_PERFORMANCE \(result as! String)")
            XCTAssertTrue((json["layoutReads"] as! Int) < 80, "pointer bursts must share layout measurements within a frame")
            XCTAssertEqual(json["visible"] as? Bool, true)
            XCTAssertEqual(json["inserted"] as? Bool, true)
        }
    }

    @MainActor
    func testRichArticleIncrementalSerializationMatchesFullSanitizer() async throws {
        try await withWebEditor { view in
            let result = try await view.callAsyncJavaScript(#"""
              const root = document.getElementById('document'), opening = '<article data-leon-format="html-v1">';
              LeonArticle.load(opening + '<p>第一段</p><p>第二段</p><table><tr><td><p>单元格</p></td></tr></table></article>', 'serialization-cache', true, 18);
              const failures = [], check = label => {
                const actual = LeonArticle.serialize(), reference = opening + LeonArticle.cleanHTML(root.innerHTML) + '</article>';
                if (actual !== reference) failures.push(label);
              };
              check('warm');
              root.firstElementChild.firstChild.data += '即时输入'; check('character data');
              root.firstElementChild.style.color = '#4b7dce'; check('color');
              root.querySelector('td p').innerHTML = '<strong>表格内容</strong><img src="javascript:alert(1)"><span onclick="evil()">安全</span>'; check('table and sanitizer');
              const table = root.querySelector('table');
              table.innerHTML = '<colgroup><col style="width:35%"><col style="width:65%"></colgroup><tbody><tr><td><p>文字</p><table><tbody><tr><td>嵌套内容</td></tr></tbody></table></td><td><aside><strong>提示</strong></aside></td></tr><tr><td colspan="2"><p>尾行</p></td></tr></tbody>'; check('nested table');
              table.querySelector('table td').firstChild.data += '&更新'; check('nested table text');
              table.querySelector('col').style.width = '45%'; check('column width');
              table.rows[0].cells[1].style.backgroundColor = '#cceeff'; check('cell color');
              table.rows[1].cells[0].setAttribute('colspan', '1'); check('cell span');
              const movedRow = table.rows[1]; movedRow.remove(); check('remove row');
              await new Promise(resolve => setTimeout(resolve, 0));
              movedRow.cells[0].firstElementChild.textContent = '脱离表格后更新'; table.tBodies[0].prepend(movedRow); check('reattach changed row');
              table.rows[1].cells[1].append(document.createTextNode('直接文本 & <')); check('cell text node');
              table.remove(); check('remove table');
              await new Promise(resolve => setTimeout(resolve, 0));
              table.querySelector('table td').textContent = '重新插入前更新'; root.append(table); check('reattach changed nested table');
              const detached = root.firstElementChild; detached.remove(); check('remove');
              await new Promise(resolve => setTimeout(resolve, 0));
              detached.textContent = '离开文档后修改'; root.append(detached); check('reattach modified block');
              root.prepend(root.lastElementChild); check('reorder');
              const text = document.createTextNode('顶层 & 文本'); root.append(text); check('root text');
              text.data += '<更新>'; check('root text mutation');
              root.firstElementChild.setAttribute('data-type', 'task'); root.dispatchEvent(new Event('input')); check('structural normalization');
              const saved = LeonArticle.serialize(); LeonArticle.load(saved, 'serialization-reopen', true, 18); check('document switch');
              return JSON.stringify(failures);
            """#, arguments: [:], in: nil, contentWorld: .page)
            XCTAssertEqual(result as? String, "[]", "incremental snapshots must always match the full sanitizer")
        }
    }

    func testRichArticleContentPresenceShortCircuitsLongDocuments() {
        let opening = RichArticleDocument.opening
        func reference(_ source: String) -> Bool {
            !RichArticleDocument.plainText(source).isEmpty || (RichArticleDocument.isHTML(source) && ["<img ", "<pre", "<aside", "<table", "<hr"].contains(where: source.contains))
        }
        let samples = ["", " ", "普通文字", opening, RichArticleDocument.empty,
            opening + "<p> \n &nbsp;&#32;&#x20;</p></article>",
            opening + "<p>&lt;内容&gt; &amp;</p></article>",
            opening + "<script>忽略文字</script><style>忽略样式</style><p><br></p></article>",
            opening + "<img src=\"photo.png\"></article>", opening + "<table></table></article>",
            opening + "<pre><code></code></pre></article>", opening + "<aside></aside></article>",
            opening + "<p>👩🏽‍💻</p></article>", opening + "<p>&unknown;</p></article>",
            opening + "<p>&#0;</p></article>", opening + "<"]
        for sample in samples { XCTAssertEqual(RichArticleDocument.hasContent(sample), reference(sample), "content presence must preserve empty-document semantics") }
        let entitySamples = [
            ("&lt;&gt;&quot;&apos;&nbsp;&amp;", "<>\"' &"),
            ("👩🏽‍💻 &amp; e\u{301} &#x1F600; &#20013;", "👩🏽‍💻 & e\u{301} 😀 中"),
            ("&amp;lt; &unknown; &#xD800; &#1114112; &#999999999999999999999;", "&lt; &unknown; &#xD800; &#1114112; &#999999999999999999999;"),
            ("A&#10;B&#9;C&#0;D", "A\nB\tC\0D")
        ]
        for (html, expected) in entitySamples { XCTAssertEqual(RichArticleDocument.plainText(opening + "<p>\(html)</p></article>"), expected) }
        let source = opening + String(repeating: "<p>长文正文内容 &amp; <strong>格式</strong></p>", count: 8_000) + "</article>"
        func elapsed(_ operation: () -> Bool) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<6 { XCTAssertTrue(operation()) }
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        let plainStart = DispatchTime.now().uptimeNanoseconds
        XCTAssertEqual(RichArticleDocument.plainText(source), String(repeating: "长文正文内容 & 格式\n", count: 8_000).trimmingCharacters(in: .whitespacesAndNewlines))
        let plainMS = Double(DispatchTime.now().uptimeNanoseconds - plainStart) / 1_000_000
        print("PLAIN_TEXT_PERFORMANCE entities=8000 elapsedMS=\(plainMS)")
        let oldMS = (0..<3).map { _ in elapsed { reference(source) } }.min()!
        let newMS = (0..<3).map { _ in elapsed { RichArticleDocument.hasContent(source) } }.min()!
        print("CONTENT_PRESENCE_PERFORMANCE baselineMS=\(oldMS) currentMS=\(newMS)")
        XCTAssertTrue(newMS < oldMS * 0.5, "content-presence checks must stop after finding visible content")
    }

    @MainActor
    func testRichArticleTableTypingAndParagraphSplitWork() async throws {
        try await withWebEditor { view in
            let result = try await view.evaluateJavaScript(#"""
            (() => {
              const root = document.getElementById('document'), opening = '<article data-leon-format="html-v1">';
              const focus = block => { root.focus(); const range = document.createRange(); range.selectNodeContents(block); range.collapse(false); getSelection().removeAllRanges(); getSelection().addRange(range); };
              const measure = action => {
                const descriptor = Object.getOwnPropertyDescriptor(Element.prototype, 'innerHTML'); let characters = 0;
                Object.defineProperty(Element.prototype, 'innerHTML', {...descriptor, set(value) { if (this.tagName === 'TEMPLATE') characters += value.length; descriptor.set.call(this, value); }});
                const start = performance.now();
                try { action(); return {characters, elapsedMS: performance.now() - start}; }
                finally { Object.defineProperty(Element.prototype, 'innerHTML', descriptor); }
              };
              const loadStart = performance.now();
              LeonArticle.load(opening + '<table><tbody>' + '<tr>'.concat('<td><p>表格内的富文本输入<strong>内容</strong></p></td>'.repeat(8), '</tr>').repeat(100) + '</tbody></table></article>', 'large-table', true, 18);
              const tableLoadMS = performance.now() - loadStart;
              focus(root.querySelector('td p')); LeonArticle.serialize();
              const table = measure(() => { for (let i = 0; i < 12; i++) document.execCommand('insertText', false, 'x'); });
              const tableSaved = LeonArticle.serialize();
              const tableExact = tableSaved === opening + LeonArticle.cleanHTML(root.innerHTML) + '</article>';
              LeonArticle.undo(-1); const undoTable = !root.querySelector('td').textContent.endsWith('xxxxxxxxxxxx'); LeonArticle.undo(1);
              const redoTable = LeonArticle.serialize() === tableSaved;
              LeonArticle.load(opening + Array.from({length: 2000}, (_, i) => `<p data-block-id="split-${i}">长文段落${i}</p>`).join('') + '</article>', 'long-splits', true, 18);
              focus(root.children[1000]); LeonArticle.serialize();
              const split = measure(() => { for (let i = 0; i < 8; i++) root.dispatchEvent(new InputEvent('beforeinput', {inputType: 'insertParagraph', bubbles: true, cancelable: true})); });
              const splitSaved = LeonArticle.serialize();
              const splitExact = root.children.length === 2008 && splitSaved === opening + LeonArticle.cleanHTML(root.innerHTML) + '</article>';
              LeonArticle.undo(-1); const undoSplit = root.children.length === 2007; LeonArticle.undo(1); const redoSplit = LeonArticle.serialize() === splitSaved;
              return JSON.stringify({tableLoadMS, table, split, tableExact, splitExact, undoTable, redoTable, undoSplit, redoSplit});
            })()
            """#)
            let json = try JSONSerialization.jsonObject(with: Data((result as! String).utf8)) as! [String: Any]
            print("EDITOR_STRUCTURAL_PERFORMANCE \(result as! String)")
            for name in ["table", "split"] {
                let metric = json[name] as! [String: Any]
                XCTAssertTrue((metric["characters"] as! Int) < 50_000, "\(name) edits must avoid cleaning unchanged document content")
            }
            for name in ["tableExact", "splitExact", "undoTable", "redoTable", "undoSplit", "redoSplit"] { XCTAssertEqual(json[name] as? Bool, true, name) }
        }
    }

    @MainActor
    func testRichArticleLongDocumentTypingWork() async throws {
        try await withWebEditor { view in
            let result = try await view.evaluateJavaScript(#"""
            (() => {
              const root = document.getElementById('document');
              const paragraph = '长文输入性能检查，保留加粗、颜色与段落结构。'.repeat(4);
              LeonArticle.load('<article data-leon-format="html-v1">' + Array.from({length: 2000}, (_, i) => `<p data-block-id="b${i}">${paragraph}<strong>重点</strong></p>`).join('') + '</article>', 'performance', true, 18);
              const block = root.children[1000], range = document.createRange(); range.selectNodeContents(block); range.collapse(false);
              root.focus(); getSelection().removeAllRanges(); getSelection().addRange(range);
              LeonArticle.serialize();
              const descriptor = Object.getOwnPropertyDescriptor(Element.prototype, 'innerHTML');
              let sanitizedCharacters = 0, documentScans = 0;
              const query = root.querySelectorAll;
              root.querySelectorAll = function(selector) { documentScans++; return query.call(this, selector); };
              Object.defineProperty(Element.prototype, 'innerHTML', {...descriptor, set(value) {
                if (this.tagName === 'TEMPLATE') sanitizedCharacters += value.length;
                descriptor.set.call(this, value);
              }});
              const timings = [];
              try {
                for (let i = 0; i < 12; i++) {
                  const start = performance.now();
                  root.dispatchEvent(new KeyboardEvent('keydown', {key: 'x', bubbles: true}));
                  root.dispatchEvent(new InputEvent('beforeinput', {inputType: 'insertText', data: 'x', bubbles: true}));
                  document.execCommand('insertText', false, 'x');
                  timings.push(performance.now() - start);
                }
              } finally {
                Object.defineProperty(Element.prototype, 'innerHTML', descriptor); root.querySelectorAll = query;
              }
              const saved = LeonArticle.serialize();
              LeonArticle.undo(-1); const undone = !root.children[1000].textContent.endsWith('xxxxxxxxxxxx');
              LeonArticle.undo(1); const redone = root.children[1000].textContent.endsWith('xxxxxxxxxxxx');
              return JSON.stringify({sanitizedCharacters, documentScans, averageMS: timings.reduce((a,b)=>a+b,0)/timings.length, maxMS: Math.max(...timings), saved: saved.includes('xxxxxxxxxxxx'), undone, redone});
            })()
            """#)
            let json = try JSONSerialization.jsonObject(with: Data((result as! String).utf8)) as! [String: Any]
            print("EDITOR_PERFORMANCE \(result as! String)")
            XCTAssertTrue((json["sanitizedCharacters"] as! Int) < 50_000, "typing in one paragraph must not sanitize the entire long document")
            for key in ["saved", "undone", "redone"] { XCTAssertEqual(json[key] as? Bool, true, key) }
        }
    }

    @MainActor
    func testRichArticleSlashCommandsAndComposition() async throws {
        try await withWebEditor { view in
            let result = try await view.evaluateJavaScript(#"""
            (() => {
              const root = document.getElementById('document');
              const focus = block => { const range = document.createRange(); range.selectNodeContents(block); range.collapse(false); getSelection().removeAllRanges(); getSelection().addRange(range); root.focus(); };
              LeonArticle.load('<article data-leon-format="html-v1"><p><br></p></article>', 'test', true, 18);
              focus(root.firstElementChild);
              document.execCommand('insertText', false, '/code');
              const menuVisible = !document.getElementById('commands').hidden;
              root.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
              const codeCreated = root.firstElementChild.tagName === 'PRE' && root.firstElementChild.textContent === '';
              document.execCommand('insertText', false, 'if x < 2 {}');
              const codeEscaped = LeonArticle.serialize().includes('if x &lt; 2 {}');
              root.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', metaKey: true, bubbles: true }));
              document.execCommand('insertText', false, '/callout');
              root.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
              document.execCommand('insertText', false, '重要提示');
              const callout = root.lastElementChild.tagName === 'ASIDE' && root.lastElementChild.textContent === '重要提示';
              const saved = LeonArticle.serialize();
              LeonArticle.load(saved, 'reopened', true, 18);
              const reopened = root.querySelectorAll('pre,aside').length === 2;
              LeonArticle.load('<article data-leon-format="html-v1"><p>/code</p></article>', 'ime', true, 18);
              focus(root.firstElementChild);
              root.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
              root.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', isComposing: true, bubbles: true }));
              const compositionSafe = root.firstElementChild.tagName === 'P' && root.firstElementChild.textContent === '/code';
              root.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true }));
              const sanitized = LeonArticle.cleanHTML('<p onclick="evil()">安全<script>evil()</script><a href="javascript:evil()">链接</a></p>');
              return JSON.stringify({menuVisible, codeCreated, codeEscaped, callout, reopened, compositionSafe, sanitized});
            })()
            """#)
            let json = try JSONSerialization.jsonObject(with: Data((result as! String).utf8)) as! [String: Any]
            for key in ["menuVisible", "codeCreated", "codeEscaped", "callout", "reopened", "compositionSafe"] {
                XCTAssertEqual(json[key] as? Bool, true, "rich editor interaction failed: \(key)")
            }
            let sanitized = json["sanitized"] as! String
            XCTAssertFalse(sanitized.contains("script"))
            XCTAssertFalse(sanitized.contains("onclick"))
            XCTAssertTrue(sanitized.contains("安全"))
        }
    }

    @MainActor
    func testRichArticleParagraphPasteAndUndo() async throws {
        try await withWebEditor { view in
            let result = try await view.evaluateJavaScript(#"""
            (() => {
              const root = document.getElementById('document');
              LeonArticle.load('<article data-leon-format="html-v1"><p>前缀后缀🌙</p></article>', 'paste', true, 18);
              root.focus(); const range = document.createRange(); range.setStart(root.firstElementChild.firstChild, 2); range.collapse(true);
              getSelection().removeAllRanges(); getSelection().addRange(range);
              const data = new DataTransfer(); data.setData('text/plain', '第一段\n第二段\n\n第三段');
              root.dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true }));
              const paragraphs = [...root.children].map(p => p.textContent);
              const pasted = LeonArticle.serialize(); LeonArticle.undo(-1);
              const undo = root.textContent === '前缀后缀🌙' && root.children.length === 1;
              LeonArticle.undo(1); const redo = LeonArticle.serialize() === pasted;
              return JSON.stringify({ paragraphs, undo, redo });
            })()
            """#)
            let json = try JSONSerialization.jsonObject(with: Data((result as! String).utf8)) as! [String: Any]
            XCTAssertEqual(json["paragraphs"] as? [String], ["前缀第一段", "第二段", "第三段后缀🌙"])
            XCTAssertEqual(json["undo"] as? Bool, true)
            XCTAssertEqual(json["redo"] as? Bool, true)
        }
    }

    @MainActor
    func testRichArticleTableCellsSupportBlocksAndFormatting() async throws {
        try await withWebEditor { view in
            let result = try await view.evaluateJavaScript(#"""
            (() => {
              const root = document.getElementById('document'), toolbar = document.getElementById('selection-toolbar');
              LeonArticle.load('<article data-leon-format="html-v1"><p>表格前</p><table><thead><tr><th>名称</th><th>说明</th></tr></thead><tbody><tr><td>前缀选中后缀</td><td>相邻单元格</td></tr></tbody></table><p>表格后</p></article>', 'table-format', true, 18);
              const table = root.querySelector('table'), cell = table.querySelector('td'), neighbor = table.querySelectorAll('td')[1];
              const focus = (element, start = null, end = start) => {
                root.focus(); const range = document.createRange();
                if (start === null) { range.selectNodeContents(element); range.collapse(false); }
                else { range.setStart(element.firstChild, start); range.setEnd(element.firstChild, end); }
                getSelection().removeAllRanges(); getSelection().addRange(range); document.dispatchEvent(new Event('selectionchange'));
              };
              const normalizedCells = [...table.querySelectorAll('td,th')].every(item => item.firstElementChild?.tagName === 'P');
              focus(cell.firstElementChild, 2, 4);
              for (const format of ['bold', 'italic', 'underline', 'strikeThrough']) toolbar.querySelector(`[data-format="${format}"]`).click();
              toolbar.querySelector('[data-format=foreColor]').click(); document.querySelector('#selection-colors [data-color-value="#4b7dce"]').click();
              toolbar.querySelector('[data-format=hiliteColor]').click(); document.querySelector('#selection-colors [data-color-value="#fff0bb"]').click();
              const inlineStyles = !toolbar.hidden && getSelection().toString() === '选中' && [...toolbar.querySelectorAll('[aria-pressed]')].every(button => button.getAttribute('aria-pressed') === 'true');
              const coloredText = [...cell.querySelectorAll('[style]')].some(element => element.style.color === 'rgb(75, 125, 206)') && [...cell.querySelectorAll('[style]')].some(element => element.style.backgroundColor === 'rgb(255, 240, 187)');
              const add = (command, text) => {
                const paragraph = document.createElement('p'); paragraph.textContent = '/' + command; cell.append(paragraph); focus(paragraph);
                root.dispatchEvent(new Event('input', { bubbles: true }));
                const menuOpened = !document.getElementById('commands').hidden;
                root.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
                if (text) document.execCommand('insertText', false, text);
                return menuOpened && cell.lastElementChild.dataset.blockId;
              };
              const shortcuts = [add('code', 'let value = <item>'), add('callout', '重要提示'), add('h2', '表格内标题'), add('quote', '引用内容'), add('bullet', '列表内容'), add('task', '待办内容')].every(Boolean);
              const nestedBlocks = !!cell.querySelector('pre code') && !!cell.querySelector('aside') && !!cell.querySelector('h2') && !!cell.querySelector('blockquote') && !!cell.querySelector('[data-type=bullet]') && !!cell.querySelector('[data-type=task]');
              focus(cell.querySelector('code')); root.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', bubbles: true }));
              const codeIndent = cell.querySelector('code').textContent.endsWith('    ');
              root.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', metaKey: true, bubbles: true }));
              const codeExitStaysInCell = getSelection().anchorNode.parentElement.closest('td') === cell && cell.querySelector('pre').nextElementSibling?.tagName === 'P';
              const paragraph = cell.lastElementChild; paragraph.textContent = '前缀后缀'; focus(paragraph, 2);
              const paste = new DataTransfer(); paste.setData('text/plain', '第一段\n第二段');
              root.dispatchEvent(new ClipboardEvent('paste', { clipboardData: paste, bubbles: true, cancelable: true }));
              const multilineStaysInCell = [...cell.children].slice(-2).map(item => item.textContent).join('|') === '前缀第一段|第二段后缀';
              root.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertParagraph', bubbles: true, cancelable: true }));
              const enterStaysInCell = getSelection().anchorNode.parentElement.closest('td') === cell;
              root.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', bubbles: true }));
              const tabNextCell = getSelection().anchorNode.parentElement.closest('td') === neighbor && !table.dataset.depth;
              root.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', shiftKey: true, bubbles: true }));
              const tabPreviousCell = getSelection().anchorNode.parentElement.closest('td') === cell;
              focus(table.querySelector('th').firstElementChild, 0, 2); toolbar.querySelector('[data-format=bold]').click();
              const headerNormalWeight = LeonArticle.serialize().includes('font-weight: normal');
              const saved = LeonArticle.serialize(); LeonArticle.load(saved, 'table-reopened', true, 18);
              const reopened = root.querySelector('td pre code')?.textContent.startsWith('let value = <item>') && root.querySelector('td aside')?.textContent === '重要提示' && [...root.querySelector('td').querySelectorAll('[style]')].some(element => element.style.color === 'rgb(75, 125, 206)') && root.querySelector('th span')?.style.fontWeight === 'normal';
              const structurePreserved = root.children.length === 3 && root.children[1].tagName === 'TABLE' && root.querySelectorAll('th,td').length === 4 && root.querySelectorAll('td')[1].textContent === '相邻单元格' && root.firstElementChild.textContent === '表格前' && root.lastElementChild.textContent === '表格后';
              const ids = [...root.querySelectorAll('[data-block-id]')].map(element => element.dataset.blockId);
              const uniqueBlocks = ids.length === new Set(ids).size;
              LeonArticle.load('<article data-leon-format="html-v1"><table><tr><td>表格结尾</td></tr></table></article>', 'table-exit', true, 18);
              focus(root.querySelector('td p')); root.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', metaKey: true, bubbles: true }));
              const canExitTable = root.children.length === 2 && root.lastElementChild.tagName === 'P' && !getSelection().anchorNode.parentElement.closest('table');
              return JSON.stringify({normalizedCells, inlineStyles, coloredText, shortcuts, nestedBlocks, codeIndent, codeExitStaysInCell, multilineStaysInCell, enterStaysInCell, tabNextCell, tabPreviousCell, headerNormalWeight, reopened, structurePreserved, uniqueBlocks, canExitTable});
            })()
            """#)
            let json = try JSONSerialization.jsonObject(with: Data((result as! String).utf8)) as! [String: Bool]
            for (key, value) in json { XCTAssertTrue(value, "table formatting failed: \(key)") }
        }
    }

    @MainActor
    func testRichArticleTableImagePasteAndNativeClipboard() async throws {
        let pasteboard = NSPasteboard(name: .init("leon-rich-image-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<4 { for y in 0..<3 { bitmap.setColor(.systemBlue, atX: x, y: y) } }
        pasteboard.setData(bitmap.tiffRepresentation!, forType: .tiff)
        guard let imageURL = RichArticleClipboard.imageDataURL(from: pasteboard),
              let png = Data(base64Encoded: String(imageURL.dropFirst("data:image/png;base64,".count))) else {
            XCTFail("expected native TIFF clipboard image to convert to PNG")
            return
        }
        XCTAssertEqual(NSBitmapImageRep(data: png)?.pixelsWide, 4)
        XCTAssertEqual(NSBitmapImageRep(data: png)?.pixelsHigh, 3)
        pasteboard.clearContents(); pasteboard.setString("只有文字", forType: .string)
        XCTAssertNil(RichArticleClipboard.imageDataURL(from: pasteboard))

        let messages = RichImagePasteTestHandler()
        var savedBody = ""
        try await withWebEditor(messageHandler: messages) { view in
            let result = try await view.callAsyncJavaScript(#"""
              const root = document.getElementById('document');
              const load = id => LeonArticle.load('<article data-leon-format="html-v1"><p>表格前</p><table><tr><td>前缀替换后缀</td><td>保持原样</td></tr></table><p>表格后</p></article>', id, true, 18);
              const select = () => { root.focus(); const range = document.createRange(), text = root.querySelector('td p').firstChild; range.setStart(text, 2); range.setEnd(text, 4); getSelection().removeAllRanges(); getSelection().addRange(range); };
              const pasteImages = () => {
                const data = new DataTransfer(), bytes = Uint8Array.from(atob(imageURL.split(',')[1]), character => character.charCodeAt(0));
                data.items.add(new File([bytes], 'first.png', { type: 'image/png' }));
                data.items.add(new File([bytes], 'second.png', { type: 'image/png' }));
                root.dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true }));
              };
              load('table-image'); select(); pasteImages();
              for (let attempt = 0; attempt < 50 && root.querySelectorAll('td img').length !== 2; attempt++) await new Promise(resolve => setTimeout(resolve, 10));
              const imagesInCell = root.querySelector('td').querySelectorAll('img').length === 2 && root.querySelector('td').textContent === '前缀后缀' && root.querySelectorAll('td')[1].textContent === '保持原样' && root.children.length === 3;
              const caretAfterImages = getSelection().isCollapsed && getSelection().anchorNode.parentElement.closest('td') === root.querySelector('td');
              const pasted = LeonArticle.serialize(); LeonArticle.undo(-1);
              const undoBatch = !root.querySelector('img') && root.querySelector('td').textContent === '前缀替换后缀';
              LeonArticle.undo(1); const redoBatch = LeonArticle.serialize() === pasted;
              LeonArticle.load(pasted, 'table-image-reopened', true, 18);
              const reopenedImages = [...root.querySelectorAll('td img')].length === 2 && [...root.querySelectorAll('td img')].every(image => image.src === imageURL);
              const saved = LeonArticle.serialize();
              load('pending-image'); select(); pasteImages();
              LeonArticle.load('<article data-leon-format="html-v1"><p>新的文章</p></article>', 'different-article', true, 18);
              await new Promise(resolve => setTimeout(resolve, 80));
              const stalePasteRejected = !root.querySelector('img') && root.textContent === '新的文章';
              load('native-image'); select();
              root.dispatchEvent(new ClipboardEvent('paste', { clipboardData: new DataTransfer(), bubbles: true, cancelable: true }));
              const neighbor = root.querySelectorAll('td p')[1], range = document.createRange(); range.selectNodeContents(neighbor); range.collapse(false); getSelection().removeAllRanges(); getSelection().addRange(range);
              return JSON.stringify({imagesInCell, caretAfterImages, undoBatch, redoBatch, reopenedImages, stalePasteRejected, saved});
            """#, arguments: ["imageURL": imageURL], in: nil, contentWorld: .page)
            let json = try JSONSerialization.jsonObject(with: Data((result as! String).utf8)) as! [String: Any]
            for key in ["imagesInCell", "caretAfterImages", "undoBatch", "redoBatch", "reopenedImages", "stalePasteRejected"] {
                XCTAssertEqual(json[key] as? Bool, true, "table image paste failed: \(key)")
            }
            savedBody = json["saved"] as! String
            for _ in 0..<40 where messages.requests.isEmpty { try await Task.sleep(nanoseconds: 25_000_000) }
            guard let request = messages.requests.first else { XCTFail("expected native clipboard image request"); return }
            let nativeResult = try await view.callAsyncJavaScript(#"""
              const root = document.getElementById('document');
              const inserted = LeonArticle.insertPastedImages(requestID, [imageURL]);
              const staysInOriginalCell = root.querySelector('td img')?.src === imageURL && !root.querySelectorAll('td')[1].querySelector('img') && root.querySelector('td').textContent === '前缀后缀';
              const preservesNewCaret = getSelection().anchorNode.parentElement.closest('td') === root.querySelectorAll('td')[1];
              return JSON.stringify({inserted, staysInOriginalCell, preservesNewCaret});
            """#, arguments: ["requestID": request, "imageURL": imageURL], in: nil, contentWorld: .page)
            let nativeJSON = try JSONSerialization.jsonObject(with: Data((nativeResult as! String).utf8)) as! [String: Bool]
            for (key, value) in nativeJSON { XCTAssertTrue(value, "native clipboard paste failed: \(key)") }
        }
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalBlogStore(rootURL: directory)
        _ = try await store.saveArticle(article(slug: "table-images", status: .draft, expectedUpdatedAt: nil, body: savedBody))
        await store.closeForRestore()
        let reopened = LocalBlogStore(rootURL: directory)
        let body = try await reopened.getArticle(slug: "table-images").body
        XCTAssertEqual(body, savedBody)
        XCTAssertEqual(RichArticleDocument.imageURLs(in: body), [imageURL, imageURL])
        await reopened.closeForRestore()
    }

    @MainActor
    func testRichArticleTableQuickAddButtons() async throws {
        try await withWebEditor { view in
            let result = try await view.callAsyncJavaScript(#"""
              const root = document.getElementById('document'), rowAdd = document.getElementById('table-add-row'), columnAdd = document.getElementById('table-add-column');
              const focus = cell => { root.focus(); const range = document.createRange(); range.selectNodeContents(cell.firstElementChild); range.collapse(false); getSelection().removeAllRanges(); getSelection().addRange(range); };
              const hover = async (cell, side = 'middle') => { focus(cell); const rect = cell.getBoundingClientRect(); cell.dispatchEvent(new PointerEvent('pointermove', { bubbles: true, clientX: side === 'left' ? rect.left + 1 : side === 'right' ? rect.right - 2 : rect.left + 25, clientY: rect.top + 15 })); await new Promise(resolve => setTimeout(resolve, 80)); };
              LeonArticle.load('<article data-leon-format="html-v1"><p>表格前</p><table><thead><tr><th>名称</th><th>说明</th></tr></thead><tbody><tr><td><strong>已有内容</strong></td><td>第二列</td></tr></tbody></table><p>表格后</p></article>', 'quick-table', true, 18);
              let table = root.querySelector('table'); await hover(table.rows[1].cells[1]);
              const rowBox = rowAdd.getBoundingClientRect(), tableBox = table.getBoundingClientRect();
              const rowAtBottomLeft = !rowAdd.hidden && getComputedStyle(rowAdd).display !== 'none' && Math.abs(rowBox.left + rowBox.width / 2 - tableBox.left) < 1 && Math.abs(rowBox.top + rowBox.height / 2 - tableBox.bottom) < 1;
              const columnHiddenAwayFromBoundary = columnAdd.hidden && getComputedStyle(columnAdd).display === 'none';
              const anchor = getSelection().anchorNode, down = new MouseEvent('mousedown', { bubbles: true, cancelable: true }); rowAdd.dispatchEvent(down);
              const preservesSelectionOnMouseDown = down.defaultPrevented && getSelection().anchorNode === anchor;
              rowAdd.click();
              const appendedRow = table.rows.length === 3 && table.rows[2].cells.length === 2 && table.rows[2].cells[0].innerText.trim() === '' && table.rows[1].cells[0].querySelector('strong')?.textContent === '已有内容' && table.rows[1].cells[1].textContent === '第二列';
              const caretInNewRow = getSelection().anchorNode.parentElement.closest('td') === table.rows[2].cells[0];
              const rowBoxAfter = rowAdd.getBoundingClientRect(); const followsNewBottom = !rowAdd.hidden && Math.abs(rowBoxAfter.top + rowBoxAfter.height / 2 - table.getBoundingClientRect().bottom) < 1;
              const afterRow = LeonArticle.serialize(); LeonArticle.undo(-1); table = root.querySelector('table');
              const undoRow = table.rows.length === 2 && getSelection().anchorNode.parentElement.closest('td') === table.rows[1].cells[1];
              LeonArticle.undo(1); table = root.querySelector('table'); const redoRow = LeonArticle.serialize() === afterRow;
              await hover(table.rows[1].cells[0], 'right'); const boundaryFromLeft = !columnAdd.hidden && !document.getElementById('column-grip').hidden;
              await hover(table.rows[1].cells[1], 'left');
              const columnBox = columnAdd.getBoundingClientRect(), boundary = table.rows[1].cells[0].getBoundingClientRect().right, toolbarBox = document.getElementById('table-tools').getBoundingClientRect();
              const columnAtBoundary = !columnAdd.hidden && Math.abs(columnBox.left + columnBox.width / 2 - boundary) < 1 && Math.abs(columnBox.top + columnBox.height / 2 - table.getBoundingClientRect().top) < 1;
              const separateFromResizeAndToolbar = columnBox.bottom < table.rows[1].cells[0].getBoundingClientRect().top && (columnBox.top >= toolbarBox.bottom || columnBox.bottom <= toolbarBox.top);
              root.dispatchEvent(new PointerEvent('pointerleave', { relatedTarget: columnAdd })); columnAdd.dispatchEvent(new PointerEvent('pointerenter'));
              await new Promise(resolve => setTimeout(resolve, 220)); const reachableColumnButton = !columnAdd.hidden;
              columnAdd.click();
              const insertedBetweenColumns = [...table.rows].every(row => row.cells.length === 3) && table.rows[0].cells[1].tagName === 'TH' && table.rows[1].cells[1].tagName === 'TD' && table.rows[0].cells[0].textContent === '名称' && table.rows[0].cells[2].textContent === '说明' && table.rows[1].cells[0].querySelector('strong')?.textContent === '已有内容' && table.rows[1].cells[2].textContent === '第二列';
              const caretInNewColumn = getSelection().anchorNode.parentElement.closest('td') === table.rows[1].cells[1];
              const afterColumn = LeonArticle.serialize(); LeonArticle.undo(-1); table = root.querySelector('table');
              const undoColumn = [...table.rows].every(row => row.cells.length === 2);
              LeonArticle.undo(1); const redoColumn = LeonArticle.serialize() === afterColumn;
              LeonArticle.load(afterColumn, 'quick-table-reopened', true, 18); table = root.querySelector('table');
              const savedCleanly = table.rows.length === 3 && table.rows[1].cells.length === 3 && !afterColumn.includes('table-add-row') && !afterColumn.includes('table-add-column') && root.children.length === 3;
              await hover(table.rows[1].cells[0], 'right'); await new Promise(resolve => setTimeout(resolve, 30));
              root.lastElementChild.dispatchEvent(new PointerEvent('pointermove', { bubbles: true })); await new Promise(resolve => setTimeout(resolve, 240));
              const hidesAfterLeavingTable = rowAdd.hidden && columnAdd.hidden;
              LeonArticle.load(afterColumn, 'quick-table-readonly', false, 18); await hover(root.querySelector('td')); rowAdd.click(); columnAdd.click();
              const readOnlySafe = rowAdd.hidden && columnAdd.hidden && root.querySelectorAll('table > tbody > tr').length === 2 && root.querySelector('table').rows[0].cells.length === 3;
              LeonArticle.load('<article data-leon-format="html-v1"><p>另一篇文章</p></article>', 'quick-table-different', true, 18); rowAdd.click(); columnAdd.click();
              const staleActionsSafe = root.textContent === '另一篇文章' && !root.querySelector('table') && rowAdd.hidden && columnAdd.hidden;
              LeonArticle.load('<article data-leon-format="html-v1"><table><tr><td>外层<table><tr><td>内层</td><td>内容</td></tr></table></td><td>外层第二列</td></tr></table></article>', 'quick-nested-table', true, 18);
              const outer = root.querySelector('table'), inner = outer.querySelector('table'); await hover(inner.querySelector('td')); rowAdd.click();
              const nestedTableSafe = outer.rows.length === 1 && outer.rows[0].cells.length === 2 && inner.rows.length === 2 && inner.rows[1].cells.length === 2;
              return JSON.stringify({rowAtBottomLeft, columnHiddenAwayFromBoundary, preservesSelectionOnMouseDown, appendedRow, caretInNewRow, followsNewBottom, undoRow, redoRow, boundaryFromLeft, columnAtBoundary, separateFromResizeAndToolbar, reachableColumnButton, insertedBetweenColumns, caretInNewColumn, undoColumn, redoColumn, savedCleanly, hidesAfterLeavingTable, readOnlySafe, staleActionsSafe, nestedTableSafe});
            """#, arguments: [:], in: nil, contentWorld: .page)
            let json = try JSONSerialization.jsonObject(with: Data((result as! String).utf8)) as! [String: Bool]
            for (key, value) in json { XCTAssertTrue(value, "table quick add failed: \(key)") }
        }
    }

    @MainActor
    func testRichArticleTableControlsAndColumnWidths() async throws {
        try await withWebEditor { view in
            let result = try await view.callAsyncJavaScript(#"""
              const root = document.getElementById('document');
              const focus = element => { root.focus(); const range = document.createRange(); range.selectNodeContents(element); range.collapse(false); getSelection().removeAllRanges(); getSelection().addRange(range); };
              const hover = async cell => { focus(cell.firstElementChild); const rect = cell.getBoundingClientRect(); cell.dispatchEvent(new PointerEvent('pointermove', { bubbles: true, clientX: rect.right - 2, clientY: rect.top + 8 })); await new Promise(resolve => setTimeout(resolve, 80)); };
              LeonArticle.load('<article data-leon-format="html-v1"><p>/table</p></article>', 'table-controls', true, 18); focus(root.firstElementChild);
              LeonArticle.execute('table'); const picker = document.getElementById('table-picker');
              const pickerVisible = !picker.hidden;
              const inputs = picker.querySelectorAll('input'); for (const input of inputs) { input.value = 3; input.dispatchEvent(new Event('change')); }
              picker.querySelector('.insert-table').click();
              let table = root.querySelector('table');
              const chosenSize = table.rows.length === 3 && [...table.rows].every(row => row.cells.length === 3) && picker.hidden;
              table.rows[1].cells[0].firstElementChild.textContent = '已有内容'; root.dispatchEvent(new Event('input'));
              await hover(table.rows[1].cells[0]); const tools = document.getElementById('table-tools');
              const hoverTools = !tools.hidden && tools.textContent.includes('第 2 行');
              tools.querySelector('[data-table=row-after]').click();
              const addedRow = table.rows.length === 4 && table.rows[1].cells[0].textContent === '已有内容';
              LeonArticle.undo(-1); table = root.querySelector('table');
              const undoRow = table.rows.length === 3 && table.rows[1].cells[0].textContent === '已有内容';
              LeonArticle.undo(1); table = root.querySelector('table');
              await hover(table.rows[1].cells[0]); tools.querySelector('[data-table=column-after]').click();
              const addedColumn = [...table.rows].every(row => row.cells.length === 4) && table.rows[1].cells[0].textContent === '已有内容';
              await hover(table.rows[1].cells[1]); tools.querySelector('[data-table=column-delete]').click();
              const deletedColumn = [...table.rows].every(row => row.cells.length === 3) && table.rows[1].cells[0].textContent === '已有内容';
              await hover(table.rows[2].cells[0]); tools.querySelector('[data-table=row-delete]').click();
              const deletedRow = table.rows.length === 3 && table.rows[1].cells[0].textContent === '已有内容';
              await hover(table.rows[1].cells[0]); const grip = document.getElementById('column-grip'), rect = table.rows[1].cells[0].getBoundingClientRect();
              const gripVisible = !grip.hidden;
              grip.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, pointerId: 1, clientX: rect.right }));
              document.dispatchEvent(new PointerEvent('pointermove', { pointerId: 1, clientX: rect.right + 40 }));
              document.dispatchEvent(new PointerEvent('pointerup', { pointerId: 1, clientX: rect.right + 40 }));
              const widths = [...table.querySelector('colgroup').children].map(col => parseFloat(col.style.width));
              const resized = widths[0] > widths[1] && Math.abs(widths.reduce((a,b) => a+b, 0) - 100) < .01;
              const saved = LeonArticle.serialize(); LeonArticle.load(saved, 'table-widths-reopened', true, 18); table = root.querySelector('table');
              const persistedWidths = [...table.querySelector('colgroup').children].every((col, index) => Math.abs(parseFloat(col.style.width) - widths[index]) < .01);
              const last = table.rows[table.rows.length - 1].lastElementChild; focus(last.firstElementChild);
              root.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', bubbles: true }));
              const tabAppendsRow = table.rows.length === 4 && getSelection().anchorNode.parentElement.closest('tr') === table.rows[3];
              LeonArticle.undo(-1); table = root.querySelector('table');
              const undoRestoresCell = table.rows.length === 3 && getSelection().anchorNode.parentElement.closest('td') === table.rows[2].lastElementChild;
              LeonArticle.load('<article data-leon-format="html-v1"><table><tr><td>唯一内容</td></tr></table></article>', 'single-cell', true, 18); await hover(root.querySelector('td')); tools.querySelector('[data-table=column-delete]').click();
              const deletesLastColumn = !root.querySelector('table') && root.firstElementChild.tagName === 'P'; LeonArticle.undo(-1);
              const restoresLastColumn = root.querySelector('td').textContent === '唯一内容';
              await hover(root.querySelector('td')); tools.querySelector('[data-table=row-delete]').click();
              const deletesLastRow = !root.querySelector('table') && root.firstElementChild.tagName === 'P';
              return JSON.stringify({pickerVisible, chosenSize, hoverTools, addedRow, undoRow, addedColumn, deletedColumn, deletedRow, gripVisible, resized, persistedWidths, tabAppendsRow, undoRestoresCell, deletesLastColumn, restoresLastColumn, deletesLastRow});
            """#, arguments: [:], in: nil, contentWorld: .page)
            let json = try JSONSerialization.jsonObject(with: Data((result as! String).utf8)) as! [String: Bool]
            for (key, value) in json { XCTAssertTrue(value, "table controls failed: \(key)") }
            if let preview = ProcessInfo.processInfo.environment["LEON_RICH_TABLE_PREVIEW_PATH"] {
                _ = try await view.evaluateJavaScript(#"""
                (() => {
                  const root = document.getElementById('document');
                  LeonArticle.load('<article data-leon-format="html-v1"><h2>项目进度</h2><p>在表格中直接整理内容，调整结构。</p><table><thead><tr><th>任务</th><th>状态</th><th>说明</th></tr></thead><tbody><tr><td>编辑体验</td><td><span style="color:#328568">已完成</span></td><td>表格、图片与选区恢复</td></tr><tr><td>交互验证</td><td><span style="color:#4b7dce">进行中</span></td><td>保留内容与编辑位置</td></tr></tbody></table></article>', 'table-preview', true, 18);
                  const cell = root.querySelector('td'), range = document.createRange(); root.focus(); range.selectNodeContents(cell.firstElementChild); range.collapse(false); getSelection().removeAllRanges(); getSelection().addRange(range);
                  const rect = cell.getBoundingClientRect(); cell.dispatchEvent(new PointerEvent('pointermove', { bubbles: true, clientX: rect.right - 2, clientY: rect.top + 10 })); return true;
                })()
                """#)
                try await Task.sleep(nanoseconds: 150_000_000)
                let configuration = WKSnapshotConfiguration()
                configuration.rect = CGRect(x: 0, y: 40, width: 700, height: 380)
                let snapshot = try await view.takeSnapshot(configuration: configuration)
                if let tiff = snapshot.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: URL(fileURLWithPath: preview))
                }
            }
        }
    }

    @MainActor
    func testRichArticleImageControlsAndCaptions() async throws {
        let messages = RichImagePasteTestHandler()
        try await withWebEditor(messageHandler: messages) { view in
            let result = try await view.callAsyncJavaScript(#"""
              const root = document.getElementById('document');
              const source = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jV1sAAAAASUVORK5CYII=';
              LeonArticle.load('<article data-leon-format="html-v1"><p>前缀<img src="' + source + '" style="width:60%">后缀</p><p>末尾段落</p></article>', 'image-controls', true, 18);
              for (let attempt = 0; attempt < 50 && !root.querySelector('img').complete; attempt++) await new Promise(resolve => setTimeout(resolve, 10));
              let image = root.querySelector('img'); image.click();
              const tools = document.getElementById('image-tools'), frame = document.getElementById('image-frame');
              const imageToolsVisible = !tools.hidden && !frame.hidden && getComputedStyle(tools).display !== 'none' && getComputedStyle(document.getElementById('image-preview')).display === 'none';
              const rect = image.getBoundingClientRect(), handle = frame.querySelector('[data-side="1"]');
              handle.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, pointerId: 2, clientX: rect.right }));
              document.dispatchEvent(new PointerEvent('pointermove', { pointerId: 2, clientX: rect.right - 80 }));
              document.dispatchEvent(new PointerEvent('pointerup', { pointerId: 2, clientX: rect.right - 80 }));
              const resizedWidth = image.style.width, resizedImage = parseFloat(resizedWidth) < 60 && parseFloat(resizedWidth) >= 10;
              LeonArticle.undo(-1); const undoResize = root.querySelector('img').style.width === '60%';
              LeonArticle.undo(1); image = root.querySelector('img'); const redoResize = image.style.width === resizedWidth; image.click();
              tools.querySelector('[data-image=caption]').click(); document.execCommand('insertText', false, '图片说明');
              const caption = root.querySelector('figcaption');
              const captionCreated = caption?.textContent === '图片说明' && root.querySelector('figure img') === image && root.firstElementChild.textContent === '前缀' && root.children[2].textContent === '后缀';
              LeonArticle.undo(-1); const undoCaptionCaret = root.querySelector('figcaption')?.textContent === '' && getSelection().anchorNode === root.querySelector('figcaption');
              LeonArticle.undo(1); image = root.querySelector('img');
              const saved = LeonArticle.serialize(); LeonArticle.load(saved, 'image-caption-reopened', true, 18); image = root.querySelector('img'); image.click();
              const persistedCaption = root.querySelector('figcaption').textContent === '图片说明' && image.style.width === resizedWidth;
              tools.querySelector('[data-image=preview]').click(); const preview = document.getElementById('image-preview');
              const canPreview = !preview.hidden && preview.querySelector('img').src === source;
              document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); const closesPreview = preview.hidden && getComputedStyle(preview).display === 'none';
              image.click(); tools.querySelector('[data-image=replace]').click();
              return JSON.stringify({imageToolsVisible, resizedImage, undoResize, redoResize, captionCreated, undoCaptionCaret, persistedCaption, canPreview, closesPreview});
            """#, arguments: [:], in: nil, contentWorld: .page)
            let json = try JSONSerialization.jsonObject(with: Data((result as! String).utf8)) as! [String: Bool]
            for (key, value) in json { XCTAssertTrue(value, "image controls failed: \(key)") }
            for _ in 0..<40 where messages.replacements.isEmpty { try await Task.sleep(nanoseconds: 25_000_000) }
            guard let request = messages.replacements.first else { XCTFail("expected image replacement request"); return }
            let replaced = try await view.callAsyncJavaScript(#"""
              const root = document.getElementById('document'), source = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
              const width = root.querySelector('img').style.width;
              const replacement = LeonArticle.completeImageReplacement(requestID, source) && root.querySelector('img').src === source && root.querySelector('img').style.width === width && root.querySelector('figcaption').textContent === '图片说明';
              document.querySelector('#image-tools [data-image=delete]').click();
              const deleted = !root.querySelector('figure,img,figcaption') && root.textContent === '前缀后缀末尾段落';
              LeonArticle.undo(-1); const undoDelete = root.querySelector('img')?.src === source && root.querySelector('figcaption')?.textContent === '图片说明';
              const saved = LeonArticle.serialize(); LeonArticle.load(saved, 'image-reader', false, 18); root.querySelector('img').click();
              const readOnlyPreview = !document.getElementById('image-preview').hidden && document.getElementById('image-tools').hidden;
              LeonArticle.load('<article data-leon-format="html-v1"><p>另一篇文章</p></article>', 'image-stale', true, 18);
              const staleReplacementRejected = !LeonArticle.completeImageReplacement(requestID, source) && !root.querySelector('img');
              return JSON.stringify({replacement, deleted, undoDelete, readOnlyPreview, staleReplacementRejected});
            """#, arguments: ["requestID": request], in: nil, contentWorld: .page)
            let replacementJSON = try JSONSerialization.jsonObject(with: Data((replaced as! String).utf8)) as! [String: Bool]
            for (key, value) in replacementJSON { XCTAssertTrue(value, "image replacement failed: \(key)") }
        }
    }

    @MainActor
    func testRichArticleUndoRestoresSelectionsAndCaret() async throws {
        try await withWebEditor { view in
            let result = try await view.evaluateJavaScript(#"""
            (() => {
              const root = document.getElementById('document');
              LeonArticle.load('<article data-leon-format="html-v1"><table><tr><td>第一段文本</td><td>相邻内容</td></tr></table><p>文章末尾</p></article>', 'undo-caret', true, 18);
              const selection = getSelection(), text = root.querySelector('td p').firstChild; root.focus(); selection.setBaseAndExtent(text, 4, text, 2);
              document.dispatchEvent(new Event('selectionchange')); document.querySelector('#selection-toolbar [data-format=bold]').click();
              const formatted = LeonArticle.serialize(); LeonArticle.undo(-1);
              const backward = () => { const probe = document.createRange(); probe.setStart(selection.anchorNode, selection.anchorOffset); probe.setEnd(selection.focusNode, selection.focusOffset); return probe.collapsed && !selection.isCollapsed; };
              const restoresBackwardSelection = selection.toString() === '段文' && backward() && selection.anchorNode.parentElement.closest('td') === root.querySelector('td');
              LeonArticle.undo(1); const redoFormatting = LeonArticle.serialize() === formatted && selection.toString() === '段文' && backward();
              root.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertText', data: '替换', bubbles: true, cancelable: true })); document.execCommand('insertText', false, '替换');
              const afterText = root.querySelector('td').textContent;
              LeonArticle.undo(-1); const restoresReplacedSelection = selection.toString() === '段文' && backward();
              LeonArticle.undo(1);
              const prefix = document.createRange(); prefix.selectNodeContents(root.querySelector('td p')); prefix.setEnd(selection.anchorNode, selection.anchorOffset);
              const restoresTypingCaret = selection.isCollapsed && root.querySelector('td').textContent === afterText && prefix.toString() === '第一替换';
              root.style.paddingBottom = '1800px'; scrollTo(0, 350);
              const scrollBefore = scrollY; const current = root.querySelector('td p'); root.focus({preventScroll:true}); const range = document.createRange(); range.selectNodeContents(current); range.collapse(false); selection.removeAllRanges(); selection.addRange(range);
              root.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertText', data: '末', bubbles: true, cancelable: true })); document.execCommand('insertText', false, '末');
              LeonArticle.undo(-1); const restoresScroll = scrollY === scrollBefore;
              return JSON.stringify({restoresBackwardSelection, redoFormatting, restoresReplacedSelection, restoresTypingCaret, restoresScroll});
            })()
            """#)
            let json = try JSONSerialization.jsonObject(with: Data((result as! String).utf8)) as! [String: Bool]
            for (key, value) in json { XCTAssertTrue(value, "undo selection failed: \(key)") }
        }
    }

    @MainActor
    func testRichArticleSelectionToolbarSetsHeadingLevels() async throws {
        try await withWebEditor { view in
            view.setFrameSize(NSSize(width: 360, height: 540))
            try await Task.sleep(nanoseconds: 50_000_000)
            let result = try await view.evaluateJavaScript(#"""
            (() => {
              const root = document.getElementById('document'), toolbar = document.getElementById('selection-toolbar');
              const panel = document.getElementById('selection-headings'), trigger = toolbar.querySelector('[data-format=heading]');
              const selection = getSelection();
              const load = (body, id, editable = true) => LeonArticle.load('<article data-leon-format="html-v1">' + body + '</article>', id, editable, 18);
              const select = (start, from, end, to, backward = false) => {
                root.focus(); selection.setBaseAndExtent(...(backward ? [end, to, start, from] : [start, from, end, to]));
                document.dispatchEvent(new Event('selectionchange'));
              };
              const choose = tag => { trigger.click(); panel.querySelector('[data-heading=' + tag + ']').click(); };
              load('<p data-depth="2">前缀<strong>选中文字</strong>后缀</p><p>不变</p>', 'heading-levels');
              root.style.paddingTop = '140px';
              const text = root.querySelector('strong').firstChild;
              select(text, 0, text, text.length, true);
              const selected = selection.toString(), original = LeonArticle.serialize(), id = root.firstElementChild.dataset.blockId;
              trigger.click();
              const bounds = panel.getBoundingClientRect(), tools = toolbar.getBoundingClientRect();
              const fitsViewport = bounds.left >= 7 && bounds.right <= innerWidth - 7 && bounds.top >= 7 && bounds.bottom <= innerHeight - 7 && tools.right <= innerWidth - 7;
              const options = !panel.hidden && panel.querySelectorAll('[data-heading]').length === 5 && panel.querySelector('[data-heading=p]').getAttribute('aria-checked') === 'true';
              let levels = true, selectionPreserved = true, activeHeading = true;
              for (let level = 1; level <= 4; level++) {
                if (panel.hidden) trigger.click();
                panel.querySelector('[data-heading=h' + level + ']').click();
                const block = root.firstElementChild;
                levels &&= block.tagName === 'H' + level && block.dataset.blockId === id && block.dataset.depth === '2' && block.querySelector('strong').textContent === selected && root.lastElementChild.tagName === 'P';
                const range = selection.getRangeAt(0);
                selectionPreserved &&= selection.toString() === selected && selection.anchorNode === range.endContainer && selection.anchorOffset === range.endOffset;
                trigger.click(); activeHeading &&= panel.querySelector('[aria-checked=true]')?.dataset.heading === 'h' + level; trigger.click();
              }
              const saved = LeonArticle.serialize();
              for (let i = 0; i < 4; i++) LeonArticle.undo(-1);
              const undo = LeonArticle.serialize() === original && selection.toString() === selected;
              for (let i = 0; i < 4; i++) LeonArticle.undo(1);
              const redo = LeonArticle.serialize() === saved && selection.toString() === selected;
              LeonArticle.load(saved, 'heading-reopened', true, 18);
              const reopened = root.firstElementChild.tagName === 'H4' && root.querySelector('h4 strong').textContent === selected;
              select(root.querySelector('strong').firstChild, 0, root.querySelector('strong').firstChild, selected.length);
              choose('p'); const resetsToText = root.firstElementChild.tagName === 'P' && !!root.querySelector('p strong');
              load('<p>第一段</p><p data-type="task" data-checked="true">第二段</p><p>第三段</p>', 'heading-multiple');
              select(root.children[0].firstChild, 1, root.children[2].firstChild, 0);
              const multipleText = selection.toString(); choose('h2');
              const multipleBlocks = [...root.children].map(block => block.tagName).join(',') === 'H2,H2,P' && !root.querySelector('[data-type],[data-checked]') && selection.toString() === multipleText;
              load('<table><tbody><tr><td><p>单元格文字</p></td><td><p>保留单元格</p></td></tr></tbody></table>', 'heading-table');
              const cellText = root.querySelector('td p').firstChild; select(cellText, 0, cellText, cellText.length); choose('h4');
              const tablePreserved = root.querySelectorAll('td').length === 2 && root.querySelector('td h4').textContent === '单元格文字' && root.querySelectorAll('td')[1].firstElementChild.tagName === 'P';
              const tableSaved = LeonArticle.serialize(); LeonArticle.load(tableSaved, 'heading-table-reopened', true, 18);
              const tableReopened = root.querySelector('td').firstElementChild.tagName === 'H4';
              const reopenedText = root.querySelector('h4').firstChild; select(reopenedText, 0, reopenedText, reopenedText.length);
              trigger.click(); toolbar.querySelector('[data-format=foreColor]').click();
              const colorExclusive = panel.hidden && !document.getElementById('selection-colors').hidden;
              trigger.click(); const headingExclusive = !panel.hidden && document.getElementById('selection-colors').hidden;
              document.dispatchEvent(new KeyboardEvent('keydown', {key:'Escape', bubbles:true}));
              const escape = panel.hidden && !toolbar.hidden && selection.toString() === '单元格文字';
              trigger.dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowDown', bubbles:true, cancelable:true}));
              const keyboard = !panel.hidden && document.activeElement.dataset.heading === 'h4';
              panel.dispatchEvent(new KeyboardEvent('keydown', {key:'Home', bubbles:true, cancelable:true}));
              const keyboardNavigation = document.activeElement.dataset.heading === 'p';
              load('<p>另一篇文章</p>', 'heading-new'); panel.querySelector('[data-heading=h1]').click();
              const staleRange = panel.hidden && !root.querySelector('h1') && root.textContent === '另一篇文章';
              load('<h4>只读标题</h4>', 'heading-readonly', false);
              select(root.firstElementChild.firstChild, 0, root.firstElementChild.firstChild, 4); choose('h1');
              const readonly = toolbar.hidden && panel.hidden && root.firstElementChild.tagName === 'H4';
              return JSON.stringify({fitsViewport, options, levels, selectionPreserved, activeHeading, undo, redo, reopened, resetsToText, multipleBlocks, tablePreserved, tableReopened, colorExclusive, headingExclusive, escape, keyboard, keyboardNavigation, staleRange, readonly});
            })()
            """#)
            let json = try JSONSerialization.jsonObject(with: Data((result as! String).utf8)) as! [String: Bool]
            for (key, value) in json { XCTAssertTrue(value, "selection heading failed: \(key)") }
            if let preview = ProcessInfo.processInfo.environment["LEON_RICH_HEADING_PREVIEW_PATH"] {
                view.setFrameSize(NSSize(width: 700, height: 540))
                _ = try await view.evaluateJavaScript(#"""
                (() => {
                  const root = document.getElementById('document'); root.style.paddingTop = '40px';
                  LeonArticle.load('<article data-leon-format="html-v1"><h3>音乐特点</h3><p>嗓音粗粝、质朴沙哑，歌词聚焦普通人的青春迷惘、理想失落、故乡与漂泊感。</p><p>作品大多来自自身真实生活体验。</p></article>', 'heading-preview', true, 18);
                  root.focus(); const range = document.createRange(); range.selectNodeContents(root.querySelector('p'));
                  getSelection().removeAllRanges(); getSelection().addRange(range); document.dispatchEvent(new Event('selectionchange'));
                  document.querySelector('#selection-toolbar [data-format=heading]').click();
                })()
                """#)
                try await Task.sleep(nanoseconds: 100_000_000)
                let image = try await view.takeSnapshot(configuration: nil)
                if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: URL(fileURLWithPath: preview))
                }
            }
        }
    }

    @MainActor
    func testRichArticleSelectionToolbarFormatsAndPersistsColors() async throws {
        try await withWebEditor { view in
            view.setFrameSize(NSSize(width: 360, height: 540))
            try await Task.sleep(nanoseconds: 50_000_000)
            let result = try await view.evaluateJavaScript(#"""
            (() => {
              const root = document.getElementById('document'), toolbar = document.getElementById('selection-toolbar'), palette = document.getElementById('selection-colors');
              const text = '保留前缀 选中片段 后缀', selectedText = '选中片段';
              LeonArticle.load('<article data-leon-format="html-v1"><p>' + text + '</p></article>', 'selection-format', true, 18);
              root.style.paddingTop = '140px'; root.focus();
              const range = document.createRange(); range.setStart(root.firstElementChild.firstChild, 5); range.setEnd(root.firstElementChild.firstChild, 9);
              getSelection().removeAllRanges(); getSelection().addRange(range); document.dispatchEvent(new Event('selectionchange'));
              const toolbarVisible = !toolbar.hidden;
              const box = toolbar.getBoundingClientRect(), selected = range.getBoundingClientRect();
              const positionedAbove = box.bottom < selected.top && box.left >= 7 && box.right <= innerWidth - 7;
              const bold = toolbar.querySelector('[data-format=bold]');
              const down = new MouseEvent('mousedown', { bubbles: true, cancelable: true }); bold.dispatchEvent(down); bold.click();
              const retainsSelection = down.defaultPrevented && getSelection().toString() === selectedText;
              const boldOnlySelected = (root.querySelector('b,strong')?.textContent === selectedText) && root.textContent === text;
              toolbar.querySelector('[data-format=italic]').click();
              toolbar.querySelector('[data-format=underline]').click();
              toolbar.querySelector('[data-format=strikeThrough]').click();
              const activeStyles = [...toolbar.querySelectorAll('[aria-pressed]')].every(button => button.getAttribute('aria-pressed') === 'true');
              toolbar.querySelector('[data-format=foreColor]').click();
              const paletteVisible = !palette.hidden && palette.querySelectorAll('.color-swatch').length === 10;
              palette.querySelector('[data-color-value="#4b7dce"]').click();
              const blueText = [...root.querySelectorAll('[style]')].some(span => span.style.color === 'rgb(75, 125, 206)' && span.textContent === selectedText);
              toolbar.querySelector('[data-format=hiliteColor]').click();
              palette.querySelector('[data-color-value="#fff0bb"]').click();
              const yellowBackground = [...root.querySelectorAll('[style]')].some(span => span.style.backgroundColor === 'rgb(255, 240, 187)' && span.textContent === selectedText);
              const beforeUndo = LeonArticle.serialize(); LeonArticle.undo(-1);
              const undoColorOnly = ![...root.querySelectorAll('[style]')].some(span => span.style.backgroundColor === 'rgb(255, 240, 187)') && [...root.querySelectorAll('[style]')].some(span => span.style.color === 'rgb(75, 125, 206)');
              LeonArticle.undo(1); const redoColor = LeonArticle.serialize() === beforeUndo;
              const saved = LeonArticle.serialize(); LeonArticle.load(saved, 'selection-reopened', true, 18);
              const reopenedColors = [...root.querySelectorAll('[style]')].some(span => span.style.color === 'rgb(75, 125, 206)') && [...root.querySelectorAll('[style]')].some(span => span.style.backgroundColor === 'rgb(255, 240, 187)');
              const noUIInContent = !saved.includes('selection-toolbar') && !saved.includes('selection-colors') && root.textContent === text;
              const reopenedRange = document.createRange(); reopenedRange.selectNodeContents(root.firstElementChild);
              getSelection().removeAllRanges(); getSelection().addRange(reopenedRange); document.dispatchEvent(new Event('selectionchange'));
              toolbar.querySelector('[data-format=hiliteColor]').click(); palette.querySelector('.reset-color').click();
              const resetsBackground = ![...root.querySelectorAll('[style]')].some(element => element.style.backgroundColor === 'rgb(255, 240, 187)');
              toolbar.querySelector('[data-format=foreColor]').click(); palette.querySelector('.reset-color').click();
              const resetsForeground = ![...root.querySelectorAll('[style]')].some(element => element.style.color === 'rgb(75, 125, 206)');
              toolbar.querySelector('[data-format=removeFormat]').click();
              const clearsStyles = !root.querySelector('b,strong,i,em,u,s,strike,font,span') && root.textContent === text;
              const clean = LeonArticle.cleanHTML('<span style="color:#4b7dce;background-color:#fff0bb;background-image:url(https://example.com/tracker);position:fixed" onclick="evil()">保留颜色</span>');
              const safeColorsOnly = clean.includes('color:') && clean.includes('background-color:') && !clean.includes('url(') && !clean.includes('position:') && !clean.includes('onclick');
              return JSON.stringify({toolbarVisible, positionedAbove, retainsSelection, boldOnlySelected, activeStyles, paletteVisible, blueText, yellowBackground, undoColorOnly, redoColor, reopenedColors, noUIInContent, resetsBackground, resetsForeground, clearsStyles, safeColorsOnly});
            })()
            """#)
            let json = try JSONSerialization.jsonObject(with: Data((result as! String).utf8)) as! [String: Bool]
            for (key, value) in json { XCTAssertTrue(value, "selection formatting failed: \(key)") }

            if let preview = ProcessInfo.processInfo.environment["LEON_RICH_SELECTION_PREVIEW_PATH"] {
                _ = try await view.evaluateJavaScript(#"""
                (() => {
                  const root = document.getElementById('document'); root.style.paddingTop = '140px';
                  LeonArticle.load('<article data-leon-format="html-v1"><p>选中文字，让表达更清晰。</p><p>加粗、斜体与颜色，随选随改。</p></article>', 'selection-preview', true, 18);
                  root.focus(); const range = document.createRange(); range.setStart(root.firstElementChild.firstChild, 5); range.setEnd(root.firstElementChild.firstChild, 11);
                  getSelection().removeAllRanges(); getSelection().addRange(range); document.dispatchEvent(new Event('selectionchange'));
                  document.querySelector('#selection-toolbar [data-format=bold]').click();
                  document.querySelector('#selection-toolbar [data-format=foreColor]').click();
                  document.querySelector('#selection-colors [data-color-value="#4b7dce"]').click();
                  return true;
                })()
                """#)
                try await Task.sleep(nanoseconds: 150_000_000)
                let configuration = WKSnapshotConfiguration()
                configuration.rect = CGRect(x: 0, y: 110, width: 360, height: 230)
                let image = try await view.takeSnapshot(configuration: configuration)
                if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: URL(fileURLWithPath: preview))
                }
            }
        }
    }

    @MainActor
    func testRichArticleSelectionToolbarHidesAndRejectsStaleRanges() async throws {
        try await withWebEditor { view in
            let result = try await view.evaluateJavaScript(#"""
            (() => {
              const root = document.getElementById('document'), toolbar = document.getElementById('selection-toolbar'), palette = document.getElementById('selection-colors');
              const select = element => { root.focus(); const range = document.createRange(); range.selectNodeContents(element); getSelection().removeAllRanges(); getSelection().addRange(range); document.dispatchEvent(new Event('selectionchange')); };
              const load = (body, id, editable = true) => LeonArticle.load('<article data-leon-format="html-v1">' + body + '</article>', id, editable, 18);
              load('<p>选择这段文字</p>', 'selection-lifecycle'); select(root.firstElementChild);
              toolbar.querySelector('[data-format=foreColor]').click();
              getSelection().collapseToEnd(); document.dispatchEvent(new Event('selectionchange'));
              const hidesWhenCollapsed = toolbar.hidden && palette.hidden;
              select(root.firstElementChild); root.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
              toolbar.querySelector('[data-format=bold]').click();
              const compositionSafe = toolbar.hidden && !root.querySelector('b,strong');
              root.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true }));
              load('<p>只读文字</p>', 'readonly-selection', false); select(root.firstElementChild);
              const readonlySafe = toolbar.hidden;
              load('<pre><code>const value = 1;</code></pre>', 'code-selection'); select(root.querySelector('code'));
              const codeStaysPlain = toolbar.hidden;
              load('<p>原来的文章</p>', 'old-selection'); select(root.firstElementChild);
              toolbar.querySelector('[data-format=foreColor]').click(); const oldSwatch = palette.querySelector('[data-color-value="#4b7dce"]');
              load('<p>另一篇文章</p>', 'new-selection'); oldSwatch.click(); toolbar.querySelector('[data-format=bold]').click();
              const staleRangeRejected = toolbar.hidden && palette.hidden && root.textContent === '另一篇文章' && !root.querySelector('span,b,strong');
              select(root.firstElementChild); document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
              const dismissesWithEscape = toolbar.hidden;
              return JSON.stringify({hidesWhenCollapsed, compositionSafe, readonlySafe, codeStaysPlain, staleRangeRejected, dismissesWithEscape});
            })()
            """#)
            let json = try JSONSerialization.jsonObject(with: Data((result as! String).utf8)) as! [String: Bool]
            for (key, value) in json { XCTAssertTrue(value, "selection toolbar lifecycle failed: \(key)") }
        }
    }

    @MainActor
    func testRichArticleCommandMenuSupportsPointerKeyboardAndSmallViewports() async throws {
        try await withWebEditor { view in
            view.setFrameSize(NSSize(width: 360, height: 540))
            try await Task.sleep(nanoseconds: 50_000_000)
            let result = try await view.evaluateJavaScript(#"""
            (() => {
              const root = document.getElementById('document'), menu = document.getElementById('commands');
              const style = document.createElement('style'); style.textContent = '#commands { animation: none; }'; document.head.append(style);
              const open = (query, id) => {
                LeonArticle.load('<article data-leon-format="html-v1"><p>' + query + '</p></article>', id, true, 18);
                root.focus(); const range = document.createRange(); range.selectNodeContents(root.firstElementChild); range.collapse(false);
                getSelection().removeAllRanges(); getSelection().addRange(range);
                root.dispatchEvent(new Event('input', { bubbles: true }));
              };
              const key = value => root.dispatchEvent(new KeyboardEvent('keydown', { key: value, bubbles: true, cancelable: true }));
              open('/', 'menu-navigation'); key('ArrowDown'); key('ArrowDown');
              const keyboardSelection = menu.querySelector('[aria-selected=true]').dataset.commandId === 'callout';
              menu.querySelector('[data-command-id=h2]').dispatchEvent(new PointerEvent('pointerenter'));
              const pointerSelection = menu.querySelector('[aria-selected=true]').dataset.commandId === 'h2';
              const keepsEditorSelection = root.contains(getSelection().anchorNode);
              key('Enter'); const insertedHeading = root.firstElementChild.tagName === 'H2';
              open('/not-a-command', 'menu-empty'); key('ArrowDown');
              const emptyState = !menu.hidden && menu.querySelectorAll('button').length === 0 && !!menu.querySelector('.command-empty');
              key('Escape'); const dismisses = menu.hidden;
              root.style.paddingTop = '380px'; open('/', 'menu-placement');
              const bounds = menu.getBoundingClientRect();
              const caretRange = getSelection().getRangeAt(0).cloneRange(); caretRange.selectNodeContents(root.firstElementChild);
              const caret = caretRange.getBoundingClientRect();
              const fitsViewport = bounds.left >= 10 && bounds.right <= innerWidth - 10 && bounds.top >= 10 && bounds.bottom <= innerHeight - 10;
              const avoidsCaret = menu.dataset.placement === 'above' && bounds.bottom <= caret.top - 6;
              for (let i = 0; i < 11; i++) key('ArrowDown');
              const row = menu.querySelector('[aria-selected=true]').getBoundingClientRect(), list = menu.querySelector('.command-list').getBoundingClientRect();
              const revealsSelection = row.top >= list.top && row.bottom <= list.bottom;
              return JSON.stringify({keyboardSelection, pointerSelection, keepsEditorSelection, insertedHeading, emptyState, dismisses, fitsViewport, avoidsCaret, revealsSelection,
                placement: menu.dataset.placement, menuTop: bounds.top, menuBottom: bounds.bottom, caretTop: caret.top, caretBottom: caret.bottom, viewportHeight: innerHeight, scrollY});
            })()
            """#)
            let json = try JSONSerialization.jsonObject(with: Data((result as! String).utf8)) as! [String: Any]
            for key in ["keyboardSelection", "pointerSelection", "keepsEditorSelection", "insertedHeading", "emptyState", "dismisses", "fitsViewport", "avoidsCaret", "revealsSelection"] {
                XCTAssertTrue(json[key] as? Bool == true, "command menu interaction failed: \(key) \(json)")
            }

            if let preview = ProcessInfo.processInfo.environment["LEON_RICH_MENU_PREVIEW_PATH"] {
                _ = try await view.evaluateJavaScript(#"""
                (() => {
                  const root = document.getElementById('document'); root.style.paddingTop = '22px';
                  LeonArticle.load('<article data-leon-format="html-v1"><p>/</p></article>', 'menu-preview', true, 18);
                  root.focus(); const range = document.createRange(); range.selectNodeContents(root.firstElementChild); range.collapse(false);
                  getSelection().removeAllRanges(); getSelection().addRange(range); root.dispatchEvent(new Event('input', { bubbles: true }));
                  return true;
                })()
                """#)
                try await Task.sleep(nanoseconds: 180_000_000)
                let image = try await view.takeSnapshot(configuration: nil)
                if let tiff = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: URL(fileURLWithPath: preview))
                }
            }
        }
    }

    @MainActor
    func testRichArticleReaderSelectionCoalescesNativeNotifications() async throws {
        let messages = RichReaderSelectionTestHandler()
        try await withWebEditor(messageHandler: messages) { view in
            _ = try await view.callAsyncJavaScript(#"""
            const root = document.getElementById('document');
            LeonArticle.load('<article data-leon-format="html-v1"><p>' + '阅读正文'.repeat(100) + '</p></article>', 'reader-selection', false, 18);
            root.dispatchEvent(new PointerEvent('pointerdown', {bubbles: true}));
            const text = root.firstChild.firstChild;
            for (let i = 1; i <= 120; i++) {
              getSelection().setBaseAndExtent(text, 0, text, i);
              document.dispatchEvent(new Event('selectionchange'));
            }
            await new Promise(resolve => setTimeout(resolve, 80)); return true;
            """#, arguments: [:], in: nil, contentWorld: .page)
            let duringDrag = messages.texts.count
            XCTAssertEqual(duringDrag, 0, "dragging a reader selection must not refresh native comment UI for each intermediate range")
            _ = try await view.callAsyncJavaScript(#"""
            document.dispatchEvent(new PointerEvent('pointerup'));
            await new Promise(resolve => setTimeout(resolve, 80)); return true;
            """#, arguments: [:], in: nil, contentWorld: .page)
            XCTAssertEqual(messages.texts.count, 1)
            XCTAssertEqual(messages.texts.last, String(repeating: "阅读正文", count: 30))
            _ = try await view.callAsyncJavaScript(#"""
            const text = document.getElementById('document').firstChild.firstChild;
            for (let i = 121; i <= 160; i++) {
              getSelection().setBaseAndExtent(text, 0, text, i);
              document.dispatchEvent(new Event('selectionchange'));
            }
            await new Promise(resolve => setTimeout(resolve, 80));
            for (let i = 0; i < 20; i++) document.dispatchEvent(new Event('selectionchange'));
            await new Promise(resolve => setTimeout(resolve, 80)); return true;
            """#, arguments: [:], in: nil, contentWorld: .page)
            XCTAssertEqual(messages.texts.count, 2, "keyboard bursts must publish their latest selection once and ignore duplicate notifications")
            XCTAssertEqual(messages.texts.last, String(repeating: "阅读正文", count: 40))
            _ = try await view.callAsyncJavaScript(#"""
            const text = document.getElementById('document').firstChild.firstChild;
            getSelection().collapse(text, 0); document.dispatchEvent(new Event('selectionchange'));
            getSelection().setBaseAndExtent(text, 0, text, 160); document.dispatchEvent(new Event('selectionchange'));
            await new Promise(resolve => setTimeout(resolve, 80)); return true;
            """#, arguments: [:], in: nil, contentWorld: .page)
            XCTAssertEqual(messages.texts.count, 3, "a newly made selection must still reopen comments even when its text matches the previous one")
            _ = try await view.callAsyncJavaScript(#"""
            const root = document.getElementById('document'), text = root.firstChild.firstChild;
            getSelection().setBaseAndExtent(text, 0, text, 12); document.dispatchEvent(new Event('selectionchange'));
            LeonArticle.load('<article data-leon-format="html-v1"><p>另一篇文章</p></article>', 'reader-next', false, 18);
            await new Promise(resolve => setTimeout(resolve, 80)); return true;
            """#, arguments: [:], in: nil, contentWorld: .page)
            XCTAssertEqual(messages.texts.count, 3, "document switches must discard pending selections")
            print("READER_SELECTION_PERFORMANCE dragEvents=120 notificationsDuringDrag=\(duringDrag) notificationsAfterAllChecks=\(messages.texts.count)")
        }
    }

    @MainActor
    func testRichArticleNativeBridgePublishesRichText() async throws {
        _ = NSApplication.shared
        var html = RichArticleDocument.empty
        let binding = Binding(get: { html }, set: { html = $0 })
        let host = NSHostingView(rootView: RichArticleEditor(html: binding, documentID: "native-bridge"))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        func findWebView(_ view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap(findWebView).first
        }
        guard let view = findWebView(host) else { XCTFail("native rich editor has no WebKit view"); return }
        var ready = false
        for _ in 0..<200 {
            try await Task.sleep(nanoseconds: 25_000_000)
            if (try? await view.evaluateJavaScript("document.getElementById('document')?.contentEditable === 'true'")) as? Bool == true { ready = true; break }
        }
        guard ready else { XCTFail("native rich editor bridge did not load"); return }
        _ = try await view.evaluateJavaScript(#"""
        (() => {
          const root = document.getElementById('document'); root.focus();
          const range = document.createRange(); range.selectNodeContents(root.firstElementChild); range.collapse(true);
          getSelection().removeAllRanges(); getSelection().addRange(range);
          document.execCommand('insertText', false, '/callout');
          root.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
          document.execCommand('insertText', false, '高亮框正文'); return true;
        })()
        """#)
        for _ in 0..<10 { try await Task.sleep(nanoseconds: 25_000_000); if html.contains("高亮框正文") { break } }
        XCTAssertTrue(RichArticleDocument.isHTML(html))
        XCTAssertTrue(html.contains("<aside"))
        XCTAssertEqual(RichArticleDocument.plainText(html), "高亮框正文")
    }

    @MainActor
    func withWebEditor(messageHandler: WKScriptMessageHandler? = nil, _ run: (WKWebView) async throws -> Void) async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if let messageHandler { configuration.userContentController.add(messageHandler, name: "richArticle") }
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 600), configuration: configuration)
        window.contentView = view
        defer { view.stopLoading(); window.close() }
        let page = try ProcessInfo.processInfo.environment["LEON_RICH_EDITOR_PAGE_PATH"].map { try String(contentsOfFile: $0, encoding: .utf8) } ?? RichArticleEditor.pageHTML
        view.loadHTMLString(page, baseURL: nil)
        var ready = false
        for _ in 0..<200 {
            try await Task.sleep(nanoseconds: 25_000_000)
            if (try? await view.evaluateJavaScript("typeof window.LeonArticle === 'object'")) as? Bool == true { ready = true; break }
        }
        guard ready else { XCTFail("rich editor did not initialize"); return }
        try await run(view)
    }
}

private final class RichReaderSelectionTestHandler: NSObject, WKScriptMessageHandler {
    var texts: [String] = []

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any], payload["type"] as? String == "selection",
              let text = payload["text"] as? String else { return }
        texts.append(text)
    }
}

private final class RichImagePasteTestHandler: NSObject, WKScriptMessageHandler {
    var requests: [String] = []
    var replacements: [String] = []

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any], let requestID = payload["requestID"] as? String else { return }
        if payload["type"] as? String == "pasteImage" { requests.append(requestID) }
        if payload["type"] as? String == "chooseImage" { replacements.append(requestID) }
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
        var tests: [(String, () async throws -> Void)] = [
            ("ArticleWhiteboardTests.testWhiteboardImmutableStorageAndValidation", { try await ArticleWhiteboardTests().testWhiteboardImmutableStorageAndValidation() }),
            ("ArticleWhiteboardTests.testWhiteboardArticleRoundTripUndoAndStaleRequests", { try await ArticleWhiteboardTests().testWhiteboardArticleRoundTripUndoAndStaleRequests() }),
            ("ArticleWhiteboardTests.testWhiteboardBundledRuntimeExportsAndReopensOffline", { try await ArticleWhiteboardTests().testWhiteboardBundledRuntimeExportsAndReopensOffline() }),
            ("TodoTests.testTodoPersistenceCompletionDeletionAndConflicts", { try await TodoTests().testTodoPersistenceCompletionDeletionAndConflicts() }),
            ("TodoTests.testTodoWorkspaceIsolationAndBackup", { try await TodoTests().testTodoWorkspaceIsolationAndBackup() }),
            ("TodoTests.testTodoAppCommandsFilteringAndModuleLifecycle", { try await TodoTests().testTodoAppCommandsFilteringAndModuleLifecycle() }),
            ("RichArticleTests.testRichArticleCaretMatchesTextAndPreservesEditing", { try await RichArticleTests().testRichArticleCaretMatchesTextAndPreservesEditing() }),
            ("RichArticleTests.testRichArticleCaretNavigationAvoidsContentCopies", { try await RichArticleTests().testRichArticleCaretNavigationAvoidsContentCopies() }),
            ("RichArticleTests.testRichArticleSelectionBookmarksPreserveMixedContent", { try await RichArticleTests().testRichArticleSelectionBookmarksPreserveMixedContent() }),
            ("RichArticleTests.testRichArticleSelectionUIWorkIsBounded", { try await RichArticleTests().testRichArticleSelectionUIWorkIsBounded() }),
            ("RichArticleTests.testRichArticlePointerWorkIsFrameBounded", { try await RichArticleTests().testRichArticlePointerWorkIsFrameBounded() }),
            ("RichArticleTests.testRichArticleIncrementalSerializationMatchesFullSanitizer", { try await RichArticleTests().testRichArticleIncrementalSerializationMatchesFullSanitizer() }),
            ("RichArticleTests.testRichArticleContentPresenceShortCircuitsLongDocuments", { RichArticleTests().testRichArticleContentPresenceShortCircuitsLongDocuments() }),
            ("RichArticleTests.testRichArticleTableTypingAndParagraphSplitWork", { try await RichArticleTests().testRichArticleTableTypingAndParagraphSplitWork() }),
            ("RichArticleTests.testRichArticleLongDocumentTypingWork", { try await RichArticleTests().testRichArticleLongDocumentTypingWork() }),
            ("RichArticleTests.testRichArticleConversionPreservesContentAndFormatting", { try RichArticleTests().testRichArticleConversionPreservesContentAndFormatting() }),
            ("RichArticleTests.testRichArticleHTMLSaveAndReopen", { try await RichArticleTests().testRichArticleHTMLSaveAndReopen() }),
            ("RichArticleTests.testRichArticleMigrationArchivesLegacyAndRejectsCollisions", { try await RichArticleTests().testRichArticleMigrationArchivesLegacyAndRejectsCollisions() }),
            ("RichArticleTests.testRichArticleSlashCommandsAndComposition", { try await RichArticleTests().testRichArticleSlashCommandsAndComposition() }),
            ("RichArticleTests.testRichArticleParagraphPasteAndUndo", { try await RichArticleTests().testRichArticleParagraphPasteAndUndo() }),
            ("RichArticleTests.testRichArticleTableCellsSupportBlocksAndFormatting", { try await RichArticleTests().testRichArticleTableCellsSupportBlocksAndFormatting() }),
            ("RichArticleTests.testRichArticleTableImagePasteAndNativeClipboard", { try await RichArticleTests().testRichArticleTableImagePasteAndNativeClipboard() }),
            ("RichArticleTests.testRichArticleTableControlsAndColumnWidths", { try await RichArticleTests().testRichArticleTableControlsAndColumnWidths() }),
            ("RichArticleTests.testRichArticleTableQuickAddButtons", { try await RichArticleTests().testRichArticleTableQuickAddButtons() }),
            ("RichArticleTests.testRichArticleImageControlsAndCaptions", { try await RichArticleTests().testRichArticleImageControlsAndCaptions() }),
            ("RichArticleTests.testRichArticleUndoRestoresSelectionsAndCaret", { try await RichArticleTests().testRichArticleUndoRestoresSelectionsAndCaret() }),
            ("RichArticleTests.testRichArticleSelectionToolbarFormatsAndPersistsColors", { try await RichArticleTests().testRichArticleSelectionToolbarFormatsAndPersistsColors() }),
            ("RichArticleTests.testRichArticleSelectionToolbarSetsHeadingLevels", { try await RichArticleTests().testRichArticleSelectionToolbarSetsHeadingLevels() }),
            ("RichArticleTests.testRichArticleSelectionToolbarHidesAndRejectsStaleRanges", { try await RichArticleTests().testRichArticleSelectionToolbarHidesAndRejectsStaleRanges() }),
            ("RichArticleTests.testRichArticleCommandMenuSupportsPointerKeyboardAndSmallViewports", { try await RichArticleTests().testRichArticleCommandMenuSupportsPointerKeyboardAndSmallViewports() }),
            ("RichArticleTests.testRichArticleNativeBridgePublishesRichText", { try await RichArticleTests().testRichArticleNativeBridgePublishesRichText() }),
            ("RichArticleTests.testRichArticleReaderSelectionCoalescesNativeNotifications", { try await RichArticleTests().testRichArticleReaderSelectionCoalescesNativeNotifications() }),
            ("AppInteractionTests.testEditorRecoveryStartupRespectsNewerWork", { try await AppInteractionTests().testEditorRecoveryStartupRespectsNewerWork() }),
            ("AppInteractionTests.testEditorRecoveryOnOpenPreservesNewerTyping", { try await AppInteractionTests().testEditorRecoveryOnOpenPreservesNewerTyping() }),
            ("AppInteractionTests.testEditorRecoveryRestoresAnUntouchedStartupDraft", { try await AppInteractionTests().testEditorRecoveryRestoresAnUntouchedStartupDraft() }),
            ("AppInteractionTests.testEditorRecoveryIncludesMetadataOnlyDrafts", { try await AppInteractionTests().testEditorRecoveryIncludesMetadataOnlyDrafts() }),
            ("AppInteractionTests.testEditorRecoveryPendingAutosaveKeepsNewerSaveStatus", { try await AppInteractionTests().testEditorRecoveryPendingAutosaveKeepsNewerSaveStatus() }),
            ("AppInteractionTests.testSearchChangesHideOldResultsAndIgnorePendingOpen", { try await AppInteractionTests().testSearchChangesHideOldResultsAndIgnorePendingOpen() }),
            ("AppInteractionTests.testQuestionReloadPreservesNewerSelectionAndDraft", { try await AppInteractionTests().testQuestionReloadPreservesNewerSelectionAndDraft() }),
            ("AppInteractionTests.testObsoleteQuestionReloadDoesNotPublishItsResults", { try await AppInteractionTests().testObsoleteQuestionReloadDoesNotPublishItsResults() }),
            ("AppInteractionTests.testQuestionFilteringKeepsAnUnpublishedAnswer", { try await AppInteractionTests().testQuestionFilteringKeepsAnUnpublishedAnswer() }),
            ("EditorFocusTests.testBlockEditingUsesIndependentFullWidthRows", { await EditorFocusTests().testBlockEditingUsesIndependentFullWidthRows() }),
            ("EditorFocusTests.testBlockParagraphPasteReplacesSelectionAndSupportsUndo", { await EditorFocusTests().testBlockParagraphPasteReplacesSelectionAndSupportsUndo() }),
            ("EditorFocusTests.testBlockParagraphSoftReturnSurvivesReopening", { await EditorFocusTests().testBlockParagraphSoftReturnSurvivesReopening() }),
            ("EditorFocusTests.testBlockEditingEnterKeepsCaretBeforeTheSplitRemainder", { await EditorFocusTests().testBlockEditingEnterKeepsCaretBeforeTheSplitRemainder() }),
            ("EditorFocusTests.testBlockEditingMergeKeepsCaretAtTheJoin", { await EditorFocusTests().testBlockEditingMergeKeepsCaretAtTheJoin() }),
            ("EditorFocusTests.testBlockEditingHeightTracksWidthAndTheEmptyLastLine", { await EditorFocusTests().testBlockEditingHeightTracksWidthAndTheEmptyLastLine() }),
            ("EditorFocusTests.testBodyEditorInitialFocusPreservesTitleSelection", { await EditorFocusTests().testBodyEditorInitialFocusPreservesTitleSelection() }),
            ("EditorFocusTests.testBlockEditorRefreshPreservesTitleSelection", { await EditorFocusTests().testBlockEditorRefreshPreservesTitleSelection() }),
            ("EditorFocusTests.testBodyEditorInitialFocusOnlyClaimsAnUnfocusedEditableWindow", { await EditorFocusTests().testBodyEditorInitialFocusOnlyClaimsAnUnfocusedEditableWindow() }),
            ("EditorFocusTests.testBlockEditorPendingFocusPreservesNewerTitleSelection", { await EditorFocusTests().testBlockEditorPendingFocusPreservesNewerTitleSelection() }),
            ("EditorFocusTests.testBlockEditorExplicitFocusCanBeRequestedAgain", { await EditorFocusTests().testBlockEditorExplicitFocusCanBeRequestedAgain() }),
            ("DataIntegrityTests.testFailedSaveReturnsAttachmentsToInbox", { try await DataIntegrityTests().testFailedSaveReturnsAttachmentsToInbox() }),
            ("DataIntegrityTests.testRestoreClosesAllStoresAndBlocksNewConnections", { try await DataIntegrityTests().testRestoreClosesAllStoresAndBlocksNewConnections() }),
            ("DataIntegrityTests.testRestoreWaitsForAsyncMediaWrites", { try DataIntegrityTests().testRestoreWaitsForAsyncMediaWrites() }),
            ("DataIntegrityTests.testRestoreReconnectsEveryWindowAndPreservesDraftOnFailure", { try await DataIntegrityTests().testRestoreReconnectsEveryWindowAndPreservesDraftOnFailure() }),
            ("DataIntegrityTests.testExternalEditBeforeWatcherIsNotOverwritten", { try await DataIntegrityTests().testExternalEditBeforeWatcherIsNotOverwritten() }),
            ("DataIntegrityTests.testFailedSaveRestoresExactMarkdownAndDoesNotCreateNewFile", { try await DataIntegrityTests().testFailedSaveRestoresExactMarkdownAndDoesNotCreateNewFile() }),
            ("DataIntegrityTests.testReadOnlySwitchAppliesToAlreadyOpenStores", { try await DataIntegrityTests().testReadOnlySwitchAppliesToAlreadyOpenStores() }),
            ("DataIntegrityTests.testBackupDetectsSameSizeContentWithPreservedTimestamp", { try DataIntegrityTests().testBackupDetectsSameSizeContentWithPreservedTimestamp() }),
            ("NativeModelsTests.testLanguagePreferencesPersistAndLocalizationsResolve", { await MainActor.run { NativeModelsTests().testLanguagePreferencesPersistAndLocalizationsResolve() } }),
            ("NativeModelsTests.testEnglishCatalogCoversEditorSurface", { NativeModelsTests().testEnglishCatalogCoversEditorSurface() }),
            ("NativeModelsTests.testVideoPlaybackFormatsAndPersistsResumePositions", { NativeModelsTests().testVideoPlaybackFormatsAndPersistsResumePositions() }),
            ("NativeModelsTests.testWritingMetricsAndTimestampRoundTrip", { NativeModelsTests().testWritingMetricsAndTimestampRoundTrip() }),
            ("NativeModelsTests.testAutomationURLsParseActionsAndEncodedParameters", { try NativeModelsTests().testAutomationURLsParseActionsAndEncodedParameters() }),
            ("NativeModelsTests.testCommandRegistryFuzzyMatchingRankingAndAvailability", { NativeModelsTests().testCommandRegistryFuzzyMatchingRankingAndAvailability() }),
            ("NativeModelsTests.testCommandPreferencesPersistPinsRecentsAndRejectConflicts", { await NativeModelsTests().testCommandPreferencesPersistPinsRecentsAndRejectConflicts() }),
            ("NativeModelsTests.testMomentFeedTimestampBatchStaysResponsive", { NativeModelsTests().testMomentFeedTimestampBatchStaysResponsive() }),
            ("NativeModelsTests.testLegacyMediaJSONUsesSafeDefaults", { try NativeModelsTests().testLegacyMediaJSONUsesSafeDefaults() }),
            ("NativeModelsTests.testMomentTagsAreExtractedDeduplicatedAndRemovedFromDisplayContent", { NativeModelsTests().testMomentTagsAreExtractedDeduplicatedAndRemovedFromDisplayContent() }),
            ("NativeModelsTests.testArticleHashtagsNormalizeAndPreserveLegacyCommaTags", { NativeModelsTests().testArticleHashtagsNormalizeAndPreserveLegacyCommaTags() }),
            ("NativeModelsTests.testFrontmatterDocumentSharesScalarListAndBodySemantics", { NativeModelsTests().testFrontmatterDocumentSharesScalarListAndBodySemantics() }),
            ("NativeModelsTests.testQuestionSessionKeepsSelectionAndAnswerDraftAligned", { NativeModelsTests().testQuestionSessionKeepsSelectionAndAnswerDraftAligned() }),
            ("NativeModelsTests.testArticleLinksExtractAndResolveTitlesOrSlugs", { try NativeModelsTests().testArticleLinksExtractAndResolveTitlesOrSlugs() }),
            ("NativeModelsTests.testArticleEmbedsSelectWholeNotesHeadingsAndBlocks", { NativeModelsTests().testArticleEmbedsSelectWholeNotesHeadingsAndBlocks() }),
            ("NativeModelsTests.testRichMarkdownEmbedsAndBlockLinkAnchors", { NativeModelsTests().testRichMarkdownEmbedsAndBlockLinkAnchors() }),
            ("NativeModelsTests.testMarkdownTypographyCompressesCJKPunctuationWithoutChangingText", { try NativeModelsTests().testMarkdownTypographyCompressesCJKPunctuationWithoutChangingText() }),
            ("NativeModelsTests.testBlockEditorRoundTripsMarkdownAndTransformsBlockTypes", { NativeModelsTests().testBlockEditorRoundTripsMarkdownAndTransformsBlockTypes() }),
            ("NativeModelsTests.testBlockParagraphBoundariesFollowPlainReturns", { NativeModelsTests().testBlockParagraphBoundariesFollowPlainReturns() }),
            ("NativeModelsTests.testBlockParagraphSplittingPreservesStructuredContent", { NativeModelsTests().testBlockParagraphSplittingPreservesStructuredContent() }),
            ("NativeModelsTests.testBlockSelectionOwnsRangeToggleAndReconciliationRules", { NativeModelsTests().testBlockSelectionOwnsRangeToggleAndReconciliationRules() }),
            ("NativeModelsTests.testBlockTemplatesPersistAndBuiltInsParse", { NativeModelsTests().testBlockTemplatesPersistAndBuiltInsParse() }),
            ("NativeModelsTests.testPageTemplatesApplyMetadataAndPersistPerWorkspace", { await MainActor.run { NativeModelsTests().testPageTemplatesApplyMetadataAndPersistPerWorkspace() } }),
            ("NativeModelsTests.testArticleTabMaintainsIndependentBackAndForwardHistory", { try NativeModelsTests().testArticleTabMaintainsIndependentBackAndForwardHistory() }),
            ("NativeModelsTests.testArticleCommentSelectionAnchorsToNearestHeading", { NativeModelsTests().testArticleCommentSelectionAnchorsToNearestHeading() }),
            ("NativeModelsTests.testArticleLineDiffMarksAddedAndRemovedLines", { NativeModelsTests().testArticleLineDiffMarksAddedAndRemovedLines() }),
            ("NativeModelsTests.testLegacyRevisionSnapshotDefaultsObsidianProperties", { try NativeModelsTests().testLegacyRevisionSnapshotDefaultsObsidianProperties() }),
            ("NativeModelsTests.testMomentSearchAndFilterMatchTextTagsDatesAndFavorites", { NativeModelsTests().testMomentSearchAndFilterMatchTextTagsDatesAndFavorites() }),
            ("NativeModelsTests.testDateFiltersUseTheProvidedCalendarAndNow", { NativeModelsTests().testDateFiltersUseTheProvidedCalendarAndNow() }),
            ("NativeModelsTests.testGlobalSearchQueryParsesPhrasesAndFilters", { NativeModelsTests().testGlobalSearchQueryParsesPhrasesAndFilters() }),
            ("NativeModelsTests.testTypedArticlePropertiesDecodeLegacyValuesValidateAndRename", { try NativeModelsTests().testTypedArticlePropertiesDecodeLegacyValuesValidateAndRename() }),
            ("ArticleDirectoryTests.testDirectoryTreeAndLegacySources", { try await ArticleDirectoryTests().testDirectoryTreeAndLegacySources() }),
            ("ArticleDirectoryTests.testDirectorySaveAndMoveBoundaries", { try await ArticleDirectoryTests().testDirectorySaveAndMoveBoundaries() }),
            ("ArticleDirectoryTests.testNewArticlesUseSelectedDirectory", { try await ArticleDirectoryTests().testNewArticlesUseSelectedDirectory() }),
            ("NativeModelsTests.testWorkspaceResourceTreeHidesJSONFiles", { NativeModelsTests().testWorkspaceResourceTreeHidesJSONFiles() }),
            ("NativeModelsTests.testP0PageHierarchyDatabaseLayoutsRelationsAndRollups", { try NativeModelsTests().testP0PageHierarchyDatabaseLayoutsRelationsAndRollups() }),
            ("NativeModelsTests.testDatabaseViewQuickCreatePrefillsDraftFields", { NativeModelsTests().testDatabaseViewQuickCreatePrefillsDraftFields() }),
            ("NativeModelsTests.testSmartCollectionCombinesPropertiesDatesAndMultiSort", { NativeModelsTests().testSmartCollectionCombinesPropertiesDatesAndMultiSort() }),
            ("NativeModelsTests.testBaseFormulasCalculatePropertiesDatesAndSummaries", { NativeModelsTests().testBaseFormulasCalculatePropertiesDatesAndSummaries() }),
            ("NativeModelsTests.testDeclarativeExtensionsExposeFiveSafeCapabilities", { try NativeModelsTests().testDeclarativeExtensionsExposeFiveSafeCapabilities() }),
            ("NativeModelsTests.testDeclarativeExtensionRejectsExecutableTemplates", { try NativeModelsTests().testDeclarativeExtensionRejectsExecutableTemplates() }),
            ("NativeModelsTests.testArticleGraphProjectionFiltersOrphansAndClipsByDegree", { NativeModelsTests().testArticleGraphProjectionFiltersOrphansAndClipsByDegree() }),
            ("NativeModelsTests.testArticleGraphLayoutAppliesAndClampsManualNodePositions", { NativeModelsTests().testArticleGraphLayoutAppliesAndClampsManualNodePositions() }),
            ("NativeModelsTests.testArticleGraphShortestPathUsesVisibleDirectedReferences", { NativeModelsTests().testArticleGraphShortestPathUsesVisibleDirectedReferences() }),
            ("NativeModelsTests.testReloadPopulatesKnowledgeGraphWithIsolatedArticles", { try await NativeModelsTests().testReloadPopulatesKnowledgeGraphWithIsolatedArticles() }),
            ("PerformanceRegressionTests.testMomentColumnsPreserveOrderAndPagination", { PerformanceRegressionTests().testMomentColumnsPreserveOrderAndPagination() }),
            ("PerformanceRegressionTests.testWritingCompletionOnlyPublishesChangedQueries", { PerformanceRegressionTests().testWritingCompletionOnlyPublishesChangedQueries() }),
            ("PerformanceRegressionTests.testWorkspaceResourceIndexPreservesNavigationSemantics", { PerformanceRegressionTests().testWorkspaceResourceIndexPreservesNavigationSemantics() }),
            ("PerformanceRegressionTests.testWorkspaceResourceIndexInvalidatesAfterMutationAndWorkspaceReset", { PerformanceRegressionTests().testWorkspaceResourceIndexInvalidatesAfterMutationAndWorkspaceReset() }),
            ("PerformanceRegressionTests.testWritingEditorsPreserveCompositionAndSkipUnchangedBlockStyling", { PerformanceRegressionTests().testWritingEditorsPreserveCompositionAndSkipUnchangedBlockStyling() }),
            ("PerformanceRegressionTests.testGraphPresentationReusesProjectionDuringInteraction", { PerformanceRegressionTests().testGraphPresentationReusesProjectionDuringInteraction() }),
            ("PerformanceRegressionTests.testEditorSessionOwnsHighFrequencyDraftState", { PerformanceRegressionTests().testEditorSessionOwnsHighFrequencyDraftState() }),
            ("PerformanceRegressionTests.testArticleSelectionCacheRejectsStaleAndCrossWorkspaceEntries", { PerformanceRegressionTests().testArticleSelectionCacheRejectsStaleAndCrossWorkspaceEntries() }),
            ("PerformanceRegressionTests.testArticleNavigationPersistenceCoalescesToLatestSnapshot", { try await PerformanceRegressionTests().testArticleNavigationPersistenceCoalescesToLatestSnapshot() }),
            ("PerformanceRegressionTests.testMarkdownRefreshPlanSkipsUnrelatedDomains", { PerformanceRegressionTests().testMarkdownRefreshPlanSkipsUnrelatedDomains() }),
            ("PerformanceRegressionTests.testMarkdownLiveStylingLimitsOrdinaryEditsToNearbyParagraphs", { PerformanceRegressionTests().testMarkdownLiveStylingLimitsOrdinaryEditsToNearbyParagraphs() }),
            ("PerformanceRegressionTests.testArticleMarkdownAnalysisIsCachedAndSharedAcrossConsumers", { PerformanceRegressionTests().testArticleMarkdownAnalysisIsCachedAndSharedAcrossConsumers() }),
            ("PerformanceRegressionTests.testRichArticleMetadataPreservesUnicodeAndCacheIdentity", { PerformanceRegressionTests().testRichArticleMetadataPreservesUnicodeAndCacheIdentity() }),
            ("PerformanceRegressionTests.testSharedImagePipelineCoalescesRequestsAndCapsDecodeConcurrency", { try await PerformanceRegressionTests().testSharedImagePipelineCoalescesRequestsAndCapsDecodeConcurrency() }),
            ("PerformanceRegressionTests.testLibraryAndMomentProjectionsCacheDerivedStateWithoutChangingFilters", { PerformanceRegressionTests().testLibraryAndMomentProjectionsCacheDerivedStateWithoutChangingFilters() }),
            ("PerformanceRegressionTests.testArticleProjectionRebuildPreservesConcurrentPageViewUpdate", { await PerformanceRegressionTests().testArticleProjectionRebuildPreservesConcurrentPageViewUpdate() }),
            ("PerformanceRegressionTests.testPageViewIncrementReevaluatesSelectedSmartCollection", { try await PerformanceRegressionTests().testPageViewIncrementReevaluatesSelectedSmartCollection() }),
            ("PerformanceRegressionTests.testCalendarChangeRebuildsCachedMomentFacets", { await PerformanceRegressionTests().testCalendarChangeRebuildsCachedMomentFacets() }),
            ("PerformanceRegressionTests.testPairedPerformanceSamplingAlternatesOrder", { PerformanceRegressionTests().testPairedPerformanceSamplingAlternatesOrder() }),
            ("LocalBlogStoreTests.testMomentLifecycleNormalizesInputFiltersAndRecordsActivity", { try await LocalBlogStoreTests().testMomentLifecycleNormalizesInputFiltersAndRecordsActivity() }),
            ("LocalBlogStoreTests.testMomentAudioUploadAndPersistence", { try await LocalBlogStoreTests().testMomentAudioUploadAndPersistence() }),
            ("LocalBlogStoreTests.testMomentVideoUploadOnlyAcceptsMP4", { try await LocalBlogStoreTests().testMomentVideoUploadOnlyAcceptsMP4() }),
            ("LocalBlogStoreTests.testMediaUploadModuleCleansCompletedFilesWhenABatchFails", { try await LocalBlogStoreTests().testMediaUploadModuleCleansCompletedFilesWhenABatchFails() }),
            ("LocalBlogStoreTests.testMomentUpdatePreservesIdentityAndDeleteHidesIt", { try await LocalBlogStoreTests().testMomentUpdatePreservesIdentityAndDeleteHidesIt() }),
            ("LocalBlogStoreTests.testMomentCommentsPersistRepliesCountsAndCascadeDeletion", { try await LocalBlogStoreTests().testMomentCommentsPersistRepliesCountsAndCascadeDeletion() }),
            ("LocalBlogStoreTests.testMomentCommentsRejectInvalidInputAndCrossPostReplies", { try await LocalBlogStoreTests().testMomentCommentsRejectInvalidInputAndCrossPostReplies() }),
            ("LocalBlogStoreTests.testMomentCommentsFollowTrashRestoreAndPermanentDeletion", { try await LocalBlogStoreTests().testMomentCommentsFollowTrashRestoreAndPermanentDeletion() }),
            ("LocalBlogStoreTests.testMomentCommentsSurviveBackupSnapshots", { try await LocalBlogStoreTests().testMomentCommentsSurviveBackupSnapshots() }),
            ("LocalBlogStoreTests.testQuestionAnswersAndTagSearchPersistInSQLite", { try await LocalBlogStoreTests().testQuestionAnswersAndTagSearchPersistInSQLite() }),
            ("LocalBlogStoreTests.testArticleLifecycleSupportsDraftPublishingAndConflictProtection", { try await LocalBlogStoreTests().testArticleLifecycleSupportsDraftPublishingAndConflictProtection() }),
            ("LocalBlogStoreTests.testAtomicArticleBodyUpdatesCommitAndUndoBothNotes", { try await LocalBlogStoreTests().testAtomicArticleBodyUpdatesCommitAndUndoBothNotes() }),
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
            ("LocalBlogStoreTests.testShortSearchAndMediaReferenceIndexStayIncremental", { try await LocalBlogStoreTests().testShortSearchAndMediaReferenceIndexStayIncremental() }),
            ("LocalBlogStoreTests.testSmartCollectionsAndBookmarksPersistInSQLite", { try await LocalBlogStoreTests().testSmartCollectionsAndBookmarksPersistInSQLite() }),
            ("LocalBlogStoreTests.testSmartCollectionSQLMatchesTheInMemoryEvaluator", { try await LocalBlogStoreTests().testSmartCollectionSQLMatchesTheInMemoryEvaluator() }),
            ("LocalBlogStoreTests.testStandardObsidianBaseImportsMultipleViewsAndPreservesUnknownFields", { try await LocalBlogStoreTests().testStandardObsidianBaseImportsMultipleViewsAndPreservesUnknownFields() }),
            ("LocalBlogStoreTests.testTwoWindowStoresCanShareOneWorkspaceInTheSameProcess", { try await LocalBlogStoreTests().testTwoWindowStoresCanShareOneWorkspaceInTheSameProcess() }),
            ("LocalBlogStoreTests.testArticleRefactorsPersistMarkdownAndRepairIncomingLinks", { try await LocalBlogStoreTests().testArticleRefactorsPersistMarkdownAndRepairIncomingLinks() }),
            ("LocalBlogStoreTests.testReadOnlyMarkdownMountIndexesExternalChangesWithoutWritingVault", { try await LocalBlogStoreTests().testReadOnlyMarkdownMountIndexesExternalChangesWithoutWritingVault() }),
            ("LocalBlogStoreTests.testDirectEditMarkdownMountWritesBackInPlace", { try await LocalBlogStoreTests().testDirectEditMarkdownMountWritesBackInPlace() }),
            ("LocalBlogStoreTests.testSwitchingBackToManagedMarkdownRevivesWorkspaceArticles", { try await LocalBlogStoreTests().testSwitchingBackToManagedMarkdownRevivesWorkspaceArticles() }),
            ("LocalBlogStoreTests.testWorkspaceResourceTreeMixesArticlesAttachmentsAndMovesFolders", { try await LocalBlogStoreTests().testWorkspaceResourceTreeMixesArticlesAttachmentsAndMovesFolders() }),
            ("LocalBlogStoreTests.testPortableSidecarSynchronizesNonRebuildableStateAcrossWorkspaces", { try await LocalBlogStoreTests().testPortableSidecarSynchronizesNonRebuildableStateAcrossWorkspaces() }),
            ("LocalBlogStoreTests.testPortableSidecarPreservesRecordsUntilMarkdownArrives", { try await LocalBlogStoreTests().testPortableSidecarPreservesRecordsUntilMarkdownArrives() }),
            ("UserWorkspaceStoreTests.testWorkspacePreparationCreatesAndPersistsDefaultUser", { try await UserWorkspaceStoreTests().testWorkspacePreparationCreatesAndPersistsDefaultUser() }),
            ("UserWorkspaceStoreTests.testTwoWindowRegistriesCanShareTheDataRootInTheSameProcess", { try await UserWorkspaceStoreTests().testTwoWindowRegistriesCanShareTheDataRootInTheSameProcess() }),
            ("LocalBackupManagerTests.testSnapshotCopiesDataWritesManifestAndSkipsLockFile", { try LocalBackupManagerTests().testSnapshotCopiesDataWritesManifestAndSkipsLockFile() }),
            ("LocalBackupManagerTests.testBackupDestinationCannotBeTheSourceOrInsideIt", { try LocalBackupManagerTests().testBackupDestinationCannotBeTheSourceOrInsideIt() }),
            ("LocalBackupManagerTests.testManagedSnapshotsReuseUnchangedFilesAndValidateChecksums", { try LocalBackupManagerTests().testManagedSnapshotsReuseUnchangedFilesAndValidateChecksums() }),
            ("LocalBackupManagerTests.testRetentionKeepsNewestSnapshotsWithinCountLimit", { try LocalBackupManagerTests().testRetentionKeepsNewestSnapshotsWithinCountLimit() }),
            ("LocalBackupManagerTests.testRestoreReplacesWholeDataRootWithoutRestoringBackupMetadata", { try LocalBackupManagerTests().testRestoreReplacesWholeDataRootWithoutRestoringBackupMetadata() }),
            ("LocalBackupManagerTests.testCapacityGuardPreservesConfiguredFreeSpace", { try LocalBackupManagerTests().testCapacityGuardPreservesConfiguredFreeSpace() }),
        ]

        if ProcessInfo.processInfo.environment["LEON_BOOK_PERFORMANCE_BENCHMARKS"] == "1" {
            tests.append((
                "PerformanceRegressionTests.testRichArticleReaderMetadataReuseBenchmark",
                { PerformanceRegressionTests().testRichArticleReaderMetadataReuseBenchmark() }
            ))
            tests.append((
                "PerformanceRegressionTests.testWorkspaceResourceInteractionBenchmark",
                { PerformanceRegressionTests().testWorkspaceResourceInteractionBenchmark() }
            ))
            tests.append((
                "PerformanceRegressionTests.testWritingCompletionBenchmark",
                { PerformanceRegressionTests().testWritingCompletionBenchmark() }
            ))
            tests.append((
                "PerformanceRegressionTests.testGraphInteractionProjectionBenchmark",
                { PerformanceRegressionTests().testGraphInteractionProjectionBenchmark() }
            ))
            tests.append((
                "PerformanceRegressionTests.testLargeArticleLibraryProjectionBenchmark",
                { PerformanceRegressionTests().testLargeArticleLibraryProjectionBenchmark() }
            ))
            tests.append((
                "PerformanceRegressionTests.testLargeSmartCollectionFormulaSummaryBenchmark",
                { PerformanceRegressionTests().testLargeSmartCollectionFormulaSummaryBenchmark() }
            ))
            tests.append((
                "PerformanceRegressionTests.testMomentTimestampReuseBenchmark",
                { PerformanceRegressionTests().testMomentTimestampReuseBenchmark() }
            ))
            tests.append((
                "PerformanceRegressionTests.testArticleTabUserInteractionBenchmark",
                { try await PerformanceRegressionTests().testArticleTabUserInteractionBenchmark() }
            ))
        }
        let filter = ProcessInfo.processInfo.environment["LEON_BOOK_TEST_FILTER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedTests = filter.map { filter in
            tests.filter { $0.0.localizedCaseInsensitiveContains(filter) }
        } ?? tests

        for (name, test) in selectedTests {
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
            print("LeonBook unit tests passed (\(selectedTests.count) tests)")
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
