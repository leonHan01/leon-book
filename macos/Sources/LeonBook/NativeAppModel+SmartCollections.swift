import Foundation
import LeonBookPublishingModule

extension NativeAppModel {
    func showSmartCollection(_ collection: NativeSmartCollection) {
        selectedSmartCollectionID = collection.id
        selectedSmartCollectionViewID = collection.views.first?.id
        clearSmartCollectionArticleSummaries()
        selectedArticleFolderPath = nil
        clearArticleFilters()
        section = .articles
        Task {
            do { try await refreshSelectedSmartCollection() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func saveSmartCollection(_ collection: NativeSmartCollection) async -> Bool {
        do {
            let saved = try await store.saveSmartCollection(collection)
            smartCollections = try await store.listSmartCollections()
            selectedSmartCollectionID = saved.id
            selectedSmartCollectionViewID = saved.activeViewID ?? saved.views.first?.id
            try await refreshSelectedSmartCollection()
            scheduleBackup()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func setSmartCollectionLayout(_ layout: NativeSmartCollectionLayout) {
        guard var collection = selectedSmartCollection, collection.layout != layout else { return }
        collection.layout = layout
        Task { _ = await saveSmartCollection(collection) }
    }

    func setSmartCollectionGroupBy(_ field: NativeArticleGroupField) {
        guard var collection = selectedSmartCollection, collection.groupBy != field else { return }
        collection.groupBy = field
        Task { _ = await saveSmartCollection(collection) }
    }

    func setSmartCollectionCalendarDateProperty(_ rawKey: String?) {
        guard var collection = selectedSmartCollection else { return }
        let key = rawKey.flatMap { rawValue -> String? in
            let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }
        guard collection.calendarDatePropertyKey != key else { return }
        collection.calendarDatePropertyKey = key
        if let key {
            if let index = collection.columns.firstIndex(where: {
                $0.source == .property && $0.key.caseInsensitiveCompare(key) == .orderedSame
            }) {
                collection.columns[index].propertyKind = .date
            } else if collection.columns.count < 30 {
                collection.columns.append(NativeSmartCollectionColumn(
                    source: .property,
                    key: key,
                    title: key,
                    propertyKind: .date
                ))
            }
        }
        Task { _ = await saveSmartCollection(collection) }
    }

    func selectSmartCollectionView(_ viewID: String) {
        guard let definition = selectedSmartCollectionDefinition,
              definition.views.contains(where: { $0.id == viewID }),
              selectedSmartCollectionViewID != viewID else { return }
        selectedSmartCollectionViewID = viewID
        clearSmartCollectionArticleSummaries()
        Task {
            do { try await refreshSelectedSmartCollection() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func updateArticleProperty(
        article: NativeArticleSummary,
        key: String,
        kind: NativeArticlePropertyKind,
        text: String
    ) {
        Task {
            do {
                let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let value = normalized.isEmpty
                    ? nil : NativeArticlePropertyValue.fromEditor(kind: kind, text: text)
                let updated = try await store.setArticleProperty(
                    slug: article.slug,
                    expectedUpdatedAt: article.updatedAt,
                    key: key,
                    value: value
                )
                await replaceArticleSummaries(try await store.listArticles())
                try await refreshSelectedSmartCollection()
                if selectedArticle?.slug == updated.slug { selectedArticle = updated }
                try await reloadKnowledgeGraph()
                scheduleBackup()
                errorMessage = nil
            } catch {
                errorMessage = "更新 Property 失败：\(error.localizedDescription)"
                try? await reload()
            }
        }
    }

    func moveArticle(
        _ article: NativeArticleSummary,
        toGroup label: String,
        field: NativeArticleGroupField
    ) {
        guard field != .updatedMonth, field != .none else {
            errorMessage = field == .updatedMonth ? "更新时间分组不可通过拖动修改。" : nil
            return
        }
        Task {
            do {
                let stored = try await store.getArticle(slug: article.slug)
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
                        throw NativeStoreError.fileSystem("不支持的文章状态：\(label)")
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
                    return
                }

                if stored.status != .published, status == .published {
                    guard authorizeFirstPartyModule(
                        PublishingFirstPartyModule.id,
                        permission: .contentPublish,
                        action: "通过看板发布文章"
                    ) else { return }
                    do {
                        try FirstPartyPublicationPolicy.validate(.init(
                            kind: .article,
                            title: stored.title,
                            body: stored.body,
                            attachmentCount: stored.media.count
                        ))
                    } catch {
                        errorMessage = error.localizedDescription
                        return
                    }
                    recordFirstPartyModuleEvent(
                        moduleID: PublishingFirstPartyModule.id,
                        name: "publishing.requested",
                        payload: ["kind": "article", "source": "board"]
                    )
                }

                let updated = try await store.saveArticle(NativeSaveArticle(
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
                await replaceArticleSummaries(try await store.listArticles())
                try await refreshSelectedSmartCollection()
                if selectedArticle?.slug == updated.slug { selectedArticle = updated }
                try await reloadKnowledgeGraph()
                scheduleBackup()
                errorMessage = nil
            } catch {
                errorMessage = "移动看板卡片失败：\(error.localizedDescription)"
                try? await reload()
            }
        }
    }

    func deleteSmartCollection(_ collection: NativeSmartCollection) async {
        do {
            try await store.deleteSmartCollection(id: collection.id)
            if selectedSmartCollectionID == collection.id {
                selectedSmartCollectionID = nil
                selectedSmartCollectionViewID = nil
                clearSmartCollectionArticleSummaries()
            }
            smartCollections = try await store.listSmartCollections()
            scheduleBackup()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshSelectedSmartCollection() async throws {
        guard let collection = selectedSmartCollection else {
            clearSmartCollectionArticleSummaries()
            return
        }
        let summaries = try await store.listArticles(in: collection)
        guard collection == selectedSmartCollection else { return }
        await replaceSmartCollectionArticleSummaries(summaries)
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
                errorMessage = "收藏的文章已不存在。"
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

