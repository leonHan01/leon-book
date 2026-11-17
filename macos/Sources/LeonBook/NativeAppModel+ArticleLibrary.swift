import Foundation
import LeonBookPublishingModule

extension NativeAppModel {
    @discardableResult
    func updateArticleProperty(
        article: NativeArticleSummary,
        key: String,
        kind: NativeArticlePropertyKind,
        text: String
    ) -> Task<Void, Never>? {
        updateArticleProperties(articles: [article], key: key, kind: kind, text: text)
    }

    @discardableResult
    func updateArticleProperties(
        articles: [NativeArticleSummary],
        key: String,
        kind: NativeArticlePropertyKind,
        text: String
    ) -> Task<Void, Never>? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = normalized.isEmpty ? nil : NativeArticlePropertyValue.fromEditor(kind: kind, text: text)
        return mutateLibraryArticles(articles, failureMessage: {
            NativeLocalization.text("更新 Property 失败：\($0.localizedDescription)")
        }) { article, activeStore in
            try await activeStore.setArticleProperty(
                slug: article.slug,
                expectedUpdatedAt: article.updatedAt,
                key: key,
                value: value
            )
        }
    }

    @discardableResult
    func moveArticle(
        _ article: NativeArticleSummary,
        toGroup label: String,
        field: NativeArticleGroupField
    ) -> Task<Void, Never>? {
        moveArticles([article], toGroup: label, field: field)
    }

    @discardableResult
    func moveArticles(
        _ articles: [NativeArticleSummary],
        toGroup label: String,
        field: NativeArticleGroupField
    ) -> Task<Void, Never>? {
        guard field != .updatedMonth, field != .none else {
            errorMessage = field == .updatedMonth ? NativeLocalization.text("更新时间分组不可通过拖动修改。") : nil
            return nil
        }
        let workspace = workspaceGeneration
        return mutateLibraryArticles(articles, failureMessage: {
            NativeLocalization.text("移动看板卡片失败：\($0.localizedDescription)")
        }) { article, activeStore in
            let stored = try await activeStore.getArticle(slug: article.slug)
            guard !Task.isCancelled, workspace == self.workspaceGeneration else { return nil }
            var status = stored.status
            var category = stored.category
            var tags = stored.tags

            switch field {
            case .status:
                if label == NativeArticleStatus.published.label || label == NativeArticleStatus.published.rawValue {
                    status = .published
                } else if label == NativeArticleStatus.draft.label || label == NativeArticleStatus.draft.rawValue {
                    status = .draft
                } else {
                    throw NativeStoreError.fileSystem(NativeLocalization.text("不支持的文章状态：\(label)"))
                }
            case .category:
                category = label == "未分类" ? "Notes" : label
            case .tag:
                if label == "无标签" {
                    tags = []
                } else {
                    let tag = label.trimmingCharacters(in: CharacterSet(charactersIn: "#＃"))
                    tags = [tag] + tags.filter { $0.caseInsensitiveCompare(tag) != .orderedSame }
                }
            case .none, .updatedMonth:
                return nil
            }

            if stored.status != .published, status == .published {
                guard self.authorizeFirstPartyModule(
                    PublishingFirstPartyModule.id,
                    permission: .contentPublish,
                    action: "通过看板发布文章"
                ) else { return nil }
                try FirstPartyPublicationPolicy.validate(.init(
                    kind: .article,
                    title: stored.title,
                    body: stored.body,
                    attachmentCount: stored.media.count
                ))
                self.recordFirstPartyModuleEvent(
                    moduleID: PublishingFirstPartyModule.id,
                    name: "publishing.requested",
                    payload: ["kind": "article", "source": "board"]
                )
            }

            guard status != stored.status || category != stored.category || tags != stored.tags else { return nil }
            return try await activeStore.saveArticle(NativeSaveArticle(
                banner: stored.banner,
                body: stored.body,
                category: category,
                excerpt: stored.excerpt,
                media: stored.media,
                slug: stored.slug,
                status: status,
                tags: tags,
                title: stored.title,
                expectedUpdatedAt: stored.updatedAt,
                properties: stored.properties
            ))
        }
    }

    /// Keep a drop batch together: saves remain individually conflict checked,
    /// while list projections, graph reads, and backup scheduling are shared.
    private func mutateLibraryArticles(
        _ summaries: [NativeArticleSummary],
        failureMessage: @escaping (Error) -> String,
        mutation: @escaping @MainActor (NativeArticleSummary, LocalBlogStore) async throws -> NativeArticle?
    ) -> Task<Void, Never>? {
        guard !summaries.isEmpty else { return nil }
        let activeStore = store
        let workspace = workspaceGeneration
        return Task {
            guard !Task.isCancelled, workspace == workspaceGeneration else { return }
            var seen = Set<String>()
            var updatedArticles: [NativeArticle] = []
            errorMessage = nil
            for summary in summaries where seen.insert(summary.slug).inserted {
                guard !Task.isCancelled, workspace == workspaceGeneration else { return }
                do {
                    if let updated = try await mutation(summary, activeStore) {
                        updatedArticles.append(updated)
                    }
                } catch {
                    guard !Task.isCancelled, workspace == workspaceGeneration else { return }
                    errorMessage = failureMessage(error)
                    // Refresh only the conflicting record, preserving successful
                    // members of a batch without reloading the whole workspace.
                    if let current = try? await activeStore.getArticle(slug: summary.slug) {
                        updatedArticles.append(current)
                    }
                }
            }
            guard !Task.isCancelled, workspace == workspaceGeneration, !updatedArticles.isEmpty else { return }
            for article in updatedArticles {
                articleSelectionCache.insert(article, workspaceGeneration: workspace)
                if let selected = selectedArticle, selected.slug == article.slug,
                   selected.updatedAt <= article.updatedAt {
                    selectedArticle = article.withPageViews(max(selected.pageViews, article.pageViews))
                }
            }
            let refresh = articleLibraryUpdateCoordinator.enqueue(
                updatedArticles.map(\.summary), model: self,
                store: activeStore, workspaceGeneration: workspace
            )
            scheduleBackup()
            await refresh.value
        }
    }

    func isBookmarked(_ target: NativeBookmarkTarget) -> Bool {
        bookmarks.contains(where: { $0.target == target })
    }

    func toggleArticleBookmark(_ article: NativeArticleSummary) {
        toggleBookmark(
            title: article.title,
            target: .article(slug: article.slug)
        )
    }

    func bookmarkHeading(article: NativeArticle, heading: MarkdownOutlineItem) {
        toggleBookmark(
            title: "\(article.title) › \(heading.title)",
            target: .heading(slug: article.slug, heading: heading.title, anchorID: heading.id)
        )
    }

    func bookmarkSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        toggleBookmark(title: "搜索：\(trimmed)", target: .search(query: trimmed))
    }

    func bookmarkGraph() {
        toggleBookmark(title: "文章关系图", target: .graph)
    }

    private func toggleBookmark(title: String, target: NativeBookmarkTarget) {
        Task {
            do {
                if let existing = bookmarks.first(where: { $0.target == target }) {
                    try await store.deleteBookmark(id: existing.id)
                } else {
                    _ = try await store.saveBookmark(NativeBookmark(title: title, target: target))
                }
                bookmarks = try await store.listBookmarks()
                scheduleBackup()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func deleteBookmark(_ bookmark: NativeBookmark) {
        Task {
            do {
                try await store.deleteBookmark(id: bookmark.id)
                bookmarks = try await store.listBookmarks()
                scheduleBackup()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func openBookmark(_ bookmark: NativeBookmark) {
        switch bookmark.target {
        case let .article(slug):
            selectSlug(slug)
        case let .heading(slug, heading, anchorID):
            guard let summary = articleSummary(for: slug) else {
                errorMessage = NativeLocalization.text("收藏的文章已不存在。")
                return
            }
            Task {
                do {
                    guard try await displayArticle(
                        summary,
                        disposition: .currentTab,
                        recordsPageView: true
                    ) else { return }
                    let currentAnchor = selectedArticle.map { article in
                        MarkdownOutline.items(in: article.body).first(where: {
                            $0.title.caseInsensitiveCompare(heading) == .orderedSame
                        })?.id
                    } ?? nil
                    pendingArticleScrollAnchor = currentAnchor ?? anchorID
                    articleScrollRevision = UUID()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        case let .search(query):
            globalSearchText = query
            presentGlobalSearch()
        case .graph:
            openKnowledgeGraph()
        }
    }

    func consumePendingArticleScrollAnchor() -> String? {
        defer { pendingArticleScrollAnchor = nil }
        return pendingArticleScrollAnchor
    }
}

