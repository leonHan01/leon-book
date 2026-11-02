import Foundation
@testable import LeonBook

private struct ArticlePerformanceFailure: Error, CustomStringConvertible {
    let description: String
}

private extension LocalBlogStore {
    func holdPerformanceQueue(entered: @Sendable () -> Void, release: DispatchSemaphore) -> Bool {
        entered()
        return release.wait(timeout: .now() + 5) == .success
    }
}

final class ArticlePerformanceRegressionTests {
    @MainActor
    func testCachedArticleOpensWhileStoreIsBusy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("article-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let article = try await store.saveArticle(NativeSaveArticle(
            banner: nil, body: "正文", category: "Notes", excerpt: "", media: [],
            slug: "cached-open", status: .draft, tags: [], title: "缓存", expectedUpdatedAt: nil
        ))
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false, store: store)
        model.selectedArticle = article
        let release = DispatchSemaphore(value: 0)
        var blocker: Task<Bool, Never>!
        await withCheckedContinuation { continuation in
            blocker = Task {
                await store.holdPerformanceQueue(entered: { continuation.resume() }, release: release)
            }
        }
        let opened = try await model.displayArticle(article.summary, disposition: .currentTab, recordsPageView: true)
        release.signal()
        guard await blocker.value, opened, model.selectedArticle?.body == article.body else {
            throw ArticlePerformanceFailure(description: "cached article should open before a busy store is released")
        }
    }

    func testPageViewsDeferSidecarWritesUntilBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("article-views-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let article = try await store.saveArticle(NativeSaveArticle(
            banner: nil, body: "测试正文", category: "Notes", excerpt: "", media: [],
            slug: "page-views", status: .draft, tags: [], title: "测试", expectedUpdatedAt: nil
        ))
        try await store.verifyCompatibilityExports()
        let json = root.appendingPathComponent("articles/page-views.json")
        let draft = root.appendingPathComponent("drafts/page-views.json")
        let markdown = root.appendingPathComponent("articles").appendingPathComponent(article.sourceRelativePath)
        let original = try [json, draft, markdown].map { try Data(contentsOf: $0) }
        let first = try await store.incrementArticlePageViewCount(slug: article.slug)
        let second = try await store.incrementArticlePageViewCount(slug: article.slug)
        guard first == 1, second == 2,
              try [json, draft, markdown].map({ try Data(contentsOf: $0) }) == original else {
            throw ArticlePerformanceFailure(description: "page views must update SQLite without rewriting article files")
        }
        await store.closeForRestore()
        let reopened = LocalBlogStore(rootURL: root)
        try await reopened.prepareForBackup()
        let decoder = JSONDecoder()
        for url in [json, draft] {
            let exported = try decoder.decode(NativeArticle.self, from: Data(contentsOf: url))
            guard exported.pageViews == 2 else {
                throw ArticlePerformanceFailure(description: "backup preparation must flush persisted page-view counts")
            }
        }
        guard try Data(contentsOf: markdown) == original[2] else {
            throw ArticlePerformanceFailure(description: "flushing page views must not rewrite Markdown")
        }
    }
}
