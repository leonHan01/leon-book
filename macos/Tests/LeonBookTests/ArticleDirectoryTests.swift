import Foundation
@testable import LeonBook

private struct DirectoryTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func directoryExpect(_ condition: Bool, _ message: String) throws {
    if !condition { throw DirectoryTestFailure(description: message) }
}

final class ArticleDirectoryTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("leon-directory-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func draft(_ slug: String, path: String? = nil, html: Bool = false) -> NativeSaveArticle {
        NativeSaveArticle(
            banner: nil, body: html ? RichArticleDocument.opening + "<p>正文</p></article>" : "正文",
            category: "Notes", excerpt: "", media: [], slug: slug, status: .draft, tags: [],
            title: slug, expectedUpdatedAt: nil, sourceRelativePath: path
        )
    }

    func testDirectoryTreeAndLegacySources() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("vault")
        let paths = ["Project.md", "Project/Child.md", "Docs/index.md", "Docs/Guide.md", "a/b/c/d/e/f/g/Deep.md"]
        for (index, path) in paths.enumerated() {
            let file = vault.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("---\nslug: note-\(index)\n---\nBody".utf8).write(to: file)
        }
        let store = LocalBlogStore(rootURL: root.appendingPathComponent("workspace"))
        _ = try await store.configureMarkdownWorkspaceSource(mode: .readOnlyMount, directoryURL: vault)
        let roots = try await store.listWorkspaceResources()
        let items = NativeWorkspaceResourceTree.flattened(roots)
        try directoryExpect(roots.allSatisfy { $0.kind == .folder }, "articles must never be root nodes")
        try directoryExpect(items.filter { $0.kind == .article }.count == paths.count, "legacy sources must remain visible")
        try directoryExpect(items.filter { $0.kind == .article }.allSatisfy { $0.children.isEmpty && !$0.canContainPages }, "articles must remain leaves, including index.md")
        try directoryExpect(items.filter { $0.kind == .folder }.allSatisfy { NativeArticleDirectoryPolicy.depth(of: $0.relativePath) <= 5 }, "navigation must have at most five directory levels")
        try directoryExpect(roots.first { $0.relativePath == "Docs" }?.children.count == 2, "index pages must stay inside their directory")
        try directoryExpect(roots.first { $0.relativePath == "未分类" }?.children.first?.sourceRelativePath == "Project.md", "legacy root articles must appear in Uncategorized without losing source identity")
        try directoryExpect(NativeWorkspaceResourceTree.folderPaths(in: roots).contains("Project/Child") == false, "articles must not become destination directories")
        try directoryExpect(NativeWorkspaceResourceTree.ancestors(of: "workspace-article:note-4", in: roots).count == 5, "deep legacy articles must be reachable at the fifth directory")
        let summaries = try await store.listArticles()
        let projection = NativeArticleLibraryProjection(articles: summaries)
        try directoryExpect(projection.folderFilters.contains { $0.path == "未分类" && $0.count == 1 }, "Uncategorized must participate in directory filters")
        for path in paths {
            try directoryExpect(FileManager.default.fileExists(atPath: vault.appendingPathComponent(path).path), "reading legacy folders must preserve mounted files")
        }
        await store.closeForRestore()
    }

    func testDirectorySaveAndMoveBoundaries() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let markdown = try await store.saveArticle(draft("markdown"))
        let html = try await store.saveArticle(draft("rich", html: true))
        try directoryExpect(markdown.sourceRelativePath == "未分类/markdown.md", "new Markdown needs a directory")
        try directoryExpect(html.sourceRelativePath == "未分类/rich.html", "new HTML needs a directory")
        let deepest = try await store.saveArticle(draft("deepest", path: "一/二/三/四/五/deepest.md"))
        try directoryExpect(deepest.sourceFolderPath == "一/二/三/四/五", "the fifth directory must accept articles")
        for path in ["root.md", "one/two/three/four/five/six/invalid.md", "one/../invalid.md"] {
            do {
                _ = try await store.saveArticle(draft("invalid", path: path))
                throw DirectoryTestFailure(description: "invalid article destination was accepted: \(path)")
            } catch NativeStoreError.fileSystem { }
        }
        try await store.createWorkspaceFolder(relativePath: "一/二/三/四/empty")
        do {
            try await store.createWorkspaceFolder(relativePath: "一/二/三/四/五/六")
            throw DirectoryTestFailure(description: "sixth-level directory creation must fail")
        } catch NativeStoreError.fileSystem { }
        for saved in [markdown, html] {
            do {
                _ = try await store.moveWorkspaceSourceItems([.init(
                    sourceRelativePath: saved.sourceRelativePath,
                    destinationRelativePath: URL(fileURLWithPath: saved.sourceRelativePath).lastPathComponent
                )])
                throw DirectoryTestFailure(description: "moving an article to root must fail")
            } catch NativeStoreError.fileSystem { }
        }
        for destination in ["root.md", "a/b/c/d/e/f/markdown.md"] {
            do {
                _ = try await store.moveArticleSource(slug: markdown.slug, to: destination, expectedUpdatedAt: markdown.updatedAt)
                throw DirectoryTestFailure(description: "the single-article move API must enforce directory rules")
            } catch NativeStoreError.fileSystem { }
        }
        do {
            _ = try await store.moveWorkspaceSourceItems([
                .init(sourceRelativePath: markdown.sourceRelativePath, destinationRelativePath: "Moved/markdown.md"),
                .init(sourceRelativePath: "一", destinationRelativePath: "Moved/一"),
            ])
            throw DirectoryTestFailure(description: "moving a subtree past five levels must fail before mutating any item")
        } catch NativeStoreError.fileSystem { }
        try directoryExpect(try await store.getArticle(slug: markdown.slug).sourceRelativePath == markdown.sourceRelativePath, "a rejected batch must leave earlier items in place")
        try directoryExpect(FileManager.default.fileExists(atPath: root.appendingPathComponent("articles/一/二/三/四/五").path), "a rejected subtree move must preserve the source")
        _ = try await store.moveWorkspaceSourceItems([.init(
            sourceRelativePath: html.sourceRelativePath,
            destinationRelativePath: "一/二/三/四/五/rich.html"
        )])
        try directoryExpect(try await store.getArticle(slug: html.slug).sourceFolderPath == "一/二/三/四/五", "moving an article into the fifth level must succeed")
        _ = try await store.moveWorkspaceSourceItems([.init(sourceRelativePath: "一", destinationRelativePath: "Renamed")])
        try directoryExpect(try await store.getArticle(slug: deepest.slug).sourceFolderPath == "Renamed/二/三/四/五", "renaming a five-level tree must preserve its articles")
        await store.closeForRestore()
    }

    @MainActor
    func testNewArticlesUseSelectedDirectory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false, store: LocalBlogStore(rootURL: root))
        model.newArticle()
        try directoryExpect(model.pendingNewArticleFolderPath == "未分类", "global creation needs a default directory")
        model.selectedArticleFolderPath = "Projects/Notes"
        model.newArticle()
        try directoryExpect(model.pendingNewArticleFolderPath == "Projects/Notes", "creation must inherit the selected directory")
        model.newArticle(inFolder: "a/b/c/d/e")
        try directoryExpect(model.pendingNewArticleFolderPath == "a/b/c/d/e", "fifth-level creation must be allowed")
        let recoveryID = model.editor.recoveryID
        model.newArticle(inFolder: "a/b/c/d/e/f")
        try directoryExpect(model.editor.recoveryID == recoveryID && model.errorMessage != nil, "invalid creation must preserve the current draft")
        await model.store.closeForRestore()
    }
}
