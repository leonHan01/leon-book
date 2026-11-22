import Foundation
@testable import LeonBook

enum ContentPrivacyTests {
    private struct Failure: Error {
        let message: String
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func testPrivateContentVisibilityAndPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ContentPrivacy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let privacy = NativeContentPrivacy()
        let store = LocalBlogStore(rootURL: root, contentPrivacy: privacy)
        let publicArticle = try await store.saveArticle(.init(
            banner: nil, body: "shared phrase", category: "Notes", excerpt: "",
            media: [], slug: "public-note", status: .published, tags: [],
            title: "Public note", expectedUpdatedAt: nil
        ))
        let privateArticle = try await store.saveArticle(.init(
            banner: nil, body: RichArticleDocument.convertingLegacyBody("shared phrase"),
            category: "Notes", excerpt: "private excerpt", media: [], slug: "private-note",
            status: .published, tags: [], title: "Private note", expectedUpdatedAt: nil, isPrivate: true
        ))
        _ = try await store.saveBookmark(.init(title: privateArticle.title, target: .article(slug: privateArticle.slug)))
        _ = try await store.saveMoment(text: "shared phrase", textRuns: [], images: [])
        let privateMoment = try await store.saveMoment(text: "shared phrase #private-tag", textRuns: [], images: [], isPrivate: true)
        let privateQuestion = try await store.saveQuestion(title: "Hidden question", body: "", tags: ["secret"], isPrivate: true)
        let publicQuestion = try await store.saveQuestion(title: "Visible question", body: "", tags: ["visible"])
        _ = try await store.saveArticleAutosave(
            draftKey: "hidden-recovery", articleSlug: nil, snapshot: .init(article: privateArticle)
        )

        try expect(try await store.listArticles().map(\.slug) == [publicArticle.slug], "Private article appeared in the library")
        try expect(try await store.listBookmarks().isEmpty, "Private article appeared in bookmarks")
        try expect(try await store.articleGraph().nodes.map(\.slug) == [publicArticle.slug], "Private article appeared in the graph")
        try expect(try await store.listMomentPage(limit: 1).moments.count == 1, "Private moment occupied a public page slot")
        try expect(try await store.countMoments() == 1, "Private moment affected the visible count")
        try expect(try await store.listHotQuestions().map(\.id) == [publicQuestion.id], "Private question appeared in the ranking")
        try expect(try await store.listQuestionTagFacets().map(\.tag) == ["visible"], "Private question tag appeared in filters")
        try expect(try await store.search("shared phrase").count == 2, "Private content appeared in global search")
        try expect(try await store.latestUnsavedArticleAutosave() == nil, "Private draft was offered for recovery")
        do {
            _ = try await store.getArticle(slug: privateArticle.slug)
            throw Failure(message: "Direct open bypassed privacy")
        } catch NativeStoreError.notFound {}

        privacy.setEnabled(true)
        try expect(try await store.listArticles().count == 2, "Enabling privacy mode did not reveal the article")
        try expect(try await store.listBookmarks().count == 1, "Enabling privacy mode did not reveal the bookmark")
        try expect(try await store.listMomentPage(limit: 1).moments.first?.id == privateMoment.id, "Enabling privacy mode did not reveal the moment")
        try expect(try await store.getQuestion(id: privateQuestion.id).isPrivate, "Enabling privacy mode did not reveal the question")
        try expect(try await store.search("shared phrase").count == 4, "Enabling privacy mode did not restore full search results")
        let answer = try await store.saveQuestionAnswer(questionID: privateQuestion.id, body: "private answer")
        let answeredQuestion = try await store.getQuestion(id: privateQuestion.id)
        privacy.setEnabled(false)
        do {
            _ = try await store.listQuestionAnswers(questionID: privateQuestion.id)
            throw Failure(message: "Answers bypassed the parent question's privacy")
        } catch NativeStoreError.notFound {}

        let reopened = LocalBlogStore(rootURL: root, contentPrivacy: privacy)
        try expect(try await reopened.listArticles().count == 1, "The article did not stay private after reopening")
        privacy.setEnabled(true)
        let loadedArticles = try await reopened.listArticles()
        let sourceURL = try await reopened.markdownSourceDirectoryURL()
        let diskRecord = try MarkdownArticleSource.read(
            at: sourceURL.appendingPathComponent(privateArticle.sourceRelativePath),
            relativePath: privateArticle.sourceRelativePath
        )
        try expect(loadedArticles.first(where: { $0.slug == privateArticle.slug })?.isPrivate == true && diskRecord.isPrivate == true,
                   "The article privacy flag did not round-trip through the native document")
        try await reopened.setQuestionPrivacy(id: privateQuestion.id, isPrivate: false, expectedUpdatedAt: answeredQuestion.updatedAt)
        try await reopened.deleteMoment(id: privateMoment.id)
        privacy.setEnabled(false)
        try expect(try await reopened.listTrash().isEmpty, "Private moment appeared in the trash")
        try expect(try await reopened.listQuestionAnswers(questionID: privateQuestion.id) == [answer], "Making the question visible did not restore answers")
    }

    static func testReadOnlyArticlePrivacySurvivesSourceChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReadOnlyPrivacy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("note.md")
        let original = "---\ntitle: Mounted note\nleonPrivate: false\n---\nBody."
        try original.write(to: file, atomically: true, encoding: .utf8)

        let privacy = NativeContentPrivacy()
        let store = LocalBlogStore(rootURL: root.appendingPathComponent("workspace"), contentPrivacy: privacy)
        _ = try await store.configureMarkdownWorkspaceSource(mode: .readOnlyMount, directoryURL: source)
        let summaries = try await store.listArticles()
        guard let article = summaries.first else { throw Failure(message: "Missing mounted article") }
        _ = try await store.setArticlePrivacy(slug: article.slug, isPrivate: true, expectedUpdatedAt: article.updatedAt)
        try expect(try String(contentsOf: file, encoding: .utf8) == original, "Privacy wrote to the read-only source")
        try expect(try await store.listArticles().isEmpty, "The mounted article stayed visible")

        try (original + " Changed.").write(to: file, atomically: true, encoding: .utf8)
        _ = try await store.refreshMarkdownSources()
        try expect(try await store.listArticles().isEmpty, "Source refresh erased the local privacy setting")
        privacy.setEnabled(true)
        try expect(try await store.getArticle(slug: article.slug).body.contains("Changed."), "Private mounted article stopped refreshing")
    }

    @MainActor
    static func testClosingPrivacyModeClearsOpenContentInEveryWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WindowPrivacy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let privacy = NativeContentPrivacy()
        privacy.setEnabled(true)
        let store = LocalBlogStore(rootURL: root, contentPrivacy: privacy)
        let article = try await store.saveArticle(.init(
            banner: nil, body: "Hidden body", category: "Notes", excerpt: "",
            media: [], slug: "hidden", status: .published, tags: [],
            title: "Hidden title", expectedUpdatedAt: nil, isPrivate: true
        ))
        let first = NativeAppModel(navigationScopeID: "privacy-first", startsAutomatically: false, store: store)
        let second = NativeAppModel(navigationScopeID: "privacy-second", startsAutomatically: false, store: store)
        let source = try await store.markdownSourceDirectoryURL()
        for model in [first, second] {
            model.storageReady = true
            model.markdownSourceDirectoryPath = source.path
            model.selectedArticle = article
            model.selectedSlug = article.slug
            model.articleTabs = [NativeArticleTab(slug: article.slug)]
            model.section = .reader
        }
        defer {
            for model in [first, second] {
                model.privacyReloadTask?.cancel()
                model.stopMarkdownSourceMonitor()
            }
        }
        first.togglePrivacyMode()
        for model in [first, second] {
            try expect(!model.privacyModeEnabled && model.selectedArticle == nil && model.articleTabs.isEmpty && model.section == .articles,
                       "An open window kept the private article visible")
        }
    }
}
