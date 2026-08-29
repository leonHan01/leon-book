import AppKit
import Foundation

extension NativeAppModel {
    func toggleArticleTask(article: NativeArticle, lineIndex: Int, completed: Bool) {
        Task {
            do {
                let updated = try await store.toggleArticleTask(
                    slug: article.slug,
                    expectedUpdatedAt: article.updatedAt,
                    lineIndex: lineIndex,
                    completed: completed
                )
                guard selectedArticle?.slug == updated.slug else { return }
                selectedArticle = updated
                articles = try await store.listArticles()
                articleGraph = try await store.articleGraph()
                selectedArticleRelations = try await store.articleRelations(for: updated.slug)
                scheduleBackup()
                errorMessage = nil
            } catch {
                errorMessage = "更新任务失败：\(error.localizedDescription)"
            }
        }
    }

    func promptToExtractArticleSelection(_ selectedRange: NSRange) {
        guard !editor.isNew, let updatedAt = editor.updatedAt, selectedRange.length > 0 else {
            errorMessage = NativeStoreError.invalidArticleSelection.localizedDescription
            return
        }
        let source = editor.body as NSString
        guard NSMaxRange(selectedRange) <= source.length else {
            errorMessage = NativeStoreError.invalidArticleSelection.localizedDescription
            return
        }
        let selectedText = source.substring(with: selectedRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let suggestedTitle = selectedText.components(separatedBy: .newlines).first?
            .trimmingCharacters(in: CharacterSet(charactersIn: "# \t")) ?? ""

        let titleField = NSTextField(string: String(suggestedTitle.prefix(60)))
        titleField.placeholderString = "新文章标题"
        let replacementPopup = NSPopUpButton()
        replacementPopup.addItems(withTitles: NativeArticleExtractionReplacement.allCases.map(\.label))
        let stack = NSStackView(views: [
            labeledRefactorControl("标题", control: titleField),
            labeledRefactorControl("原位置", control: replacementPopup),
        ])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 76)

        let alert = NSAlert()
        alert.messageText = "提取为新文章"
        alert.informativeText = "选中文字会成为一篇新的 Markdown 文章；原位置可替换为双链或嵌入。"
        alert.addButton(withTitle: "提取")
        alert.addButton(withTitle: "取消")
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            errorMessage = "请输入新文章标题。"
            return
        }
        let replacement = NativeArticleExtractionReplacement.allCases[replacementPopup.indexOfSelectedItem]
        let slug = editor.slug
        let body = editor.body

        Task {
            do {
                let result = try await store.extractArticleSelection(
                    sourceSlug: slug,
                    expectedUpdatedAt: updatedAt,
                    sourceBody: body,
                    selectedRange: selectedRange,
                    newTitle: title,
                    replacement: replacement
                )
                acceptArticleRefactor(result.primaryArticle)
                try await refreshAfterArticleRefactor(primarySlug: result.primaryArticle.slug)
                editorAutosaveStatus = "已提取“\(title)”并保存 Markdown"
                scheduleBackup()
                errorMessage = nil
            } catch {
                errorMessage = "提取文章失败：\(error.localizedDescription)"
            }
        }
    }

    func promptToSplitArticleByLevel2Headings() {
        guard !editor.isNew, let updatedAt = editor.updatedAt else { return }
        let split = ArticleKnowledgeComposer.level2Sections(in: editor.body)
        guard !split.sections.isEmpty else {
            errorMessage = NativeStoreError.noLevel2Sections.localizedDescription
            return
        }
        let replacementPopup = NSPopUpButton()
        replacementPopup.addItems(withTitles: NativeArticleExtractionReplacement.allCases.map(\.label))
        let alert = NSAlert()
        alert.messageText = "按二级标题拆分文章？"
        alert.informativeText = "将创建 \(split.sections.count) 篇草稿：\(split.sections.map(\.title).joined(separator: "、"))"
        alert.addButton(withTitle: "拆分")
        alert.addButton(withTitle: "取消")
        alert.accessoryView = labeledRefactorControl("原文保留", control: replacementPopup)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let replacement = NativeArticleExtractionReplacement.allCases[replacementPopup.indexOfSelectedItem]
        let slug = editor.slug
        let body = editor.body

        Task {
            do {
                let result = try await store.splitArticleByLevel2Headings(
                    sourceSlug: slug,
                    expectedUpdatedAt: updatedAt,
                    sourceBody: body,
                    replacement: replacement
                )
                acceptArticleRefactor(result.primaryArticle)
                try await refreshAfterArticleRefactor(primarySlug: result.primaryArticle.slug)
                editorAutosaveStatus = "已拆分为 \(result.createdArticles.count) 篇 Markdown 草稿"
                scheduleBackup()
                errorMessage = nil
            } catch {
                errorMessage = "拆分文章失败：\(error.localizedDescription)"
            }
        }
    }

    func promptToMergeEditedArticle() {
        guard !editor.isNew, let source = selectedArticle, source.slug == editor.slug else { return }
        guard !hasUnsavedEditorChanges else {
            errorMessage = "合并前请先保存或放弃当前修改，避免丢失未保存内容。"
            return
        }
        let destinations = articles.filter { $0.slug != source.slug }
        guard !destinations.isEmpty else { throwMergeUnavailable() ; return }
        let destinationPopup = NSPopUpButton()
        destinationPopup.addItems(withTitles: destinations.map { "\($0.title)  ·  \($0.slug)" })
        let positionPopup = NSPopUpButton()
        positionPopup.addItems(withTitles: ["追加到目标末尾", "插入到目标开头"])
        let stack = NSStackView(views: [
            labeledRefactorControl("合并到", control: destinationPopup),
            labeledRefactorControl("位置", control: positionPopup),
        ])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: 76)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "合并“\(source.title)”？"
        alert.informativeText = "来源文章会移入回收站，所有指向它的双链和嵌入会批量改为目标文章。"
        alert.addButton(withTitle: "合并并更新入链")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let destination = destinations[destinationPopup.indexOfSelectedItem]
        let position: NativeArticleMergePosition = positionPopup.indexOfSelectedItem == 0 ? .end : .beginning

        Task {
            do {
                let destinationArticle = try await store.getArticle(slug: destination.slug)
                let result = try await store.mergeArticle(
                    sourceSlug: source.slug,
                    destinationSlug: destination.slug,
                    expectedSourceUpdatedAt: source.updatedAt,
                    expectedDestinationUpdatedAt: destinationArticle.updatedAt,
                    position: position
                )
                articles = try await store.listArticles()
                articleGraph = try await store.articleGraph()
                articleTabs.removeAll(where: { $0.slug == source.slug })
                recentArticleSlugs.removeAll(where: { $0 == source.slug })
                if let summary = articles.first(where: { $0.slug == result.primaryArticle.slug }) {
                    _ = try await displayArticle(summary, disposition: .currentTab, recordsPageView: false)
                }
                scheduleBackup()
                errorMessage = nil
            } catch {
                errorMessage = "合并文章失败：\(error.localizedDescription)"
            }
        }
    }

    private func refreshAfterArticleRefactor(primarySlug: String) async throws {
        articles = try await store.listArticles()
        articleGraph = try await store.articleGraph()
        selectedArticleRelations = try await store.articleRelations(for: primarySlug)
        try await refreshSelectedSmartCollection()
    }

    private func labeledRefactorControl(_ label: String, control: NSView) -> NSView {
        let caption = NSTextField(labelWithString: label)
        caption.font = .systemFont(ofSize: 12, weight: .semibold)
        let row = NSStackView(views: [caption, control])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 4
        control.widthAnchor.constraint(equalToConstant: 380).isActive = true
        return row
    }

    private func throwMergeUnavailable() {
        errorMessage = "没有可作为合并目标的其他文章。"
    }

    func renameArticleProperty(from oldKey: String, to newKey: String) {
        guard !isRenamingArticleProperty, !isSaving, !isBackingUp, !isRestoringBackup else { return }
        isRenamingArticleProperty = true
        Task {
            defer { isRenamingArticleProperty = false }
            do {
                let editorProperties = try NativeArticleProperties.renaming(
                    oldKey,
                    to: newKey,
                    in: editor.properties
                )
                let changedCount = try await store.renameArticleProperty(from: oldKey, to: newKey)
                editor.properties = editorProperties
                articles = try await store.listArticles()
                articleGraph = try await store.articleGraph()
                try await refreshSelectedSmartCollection()
                if let slug = selectedArticle?.slug {
                    selectedArticle = try await store.getArticle(slug: slug)
                }
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    updateArticleListSearch(searchText, debounce: false)
                }
                articlePropertyStatus = changedCount == 0
                    ? "没有文章使用属性“\(oldKey)”"
                    : "已在 \(changedCount) 篇文章中将“\(oldKey)”重命名为“\(newKey)”"
                if changedCount > 0 { scheduleBackup() }
                errorMessage = nil
            } catch {
                errorMessage = "属性重命名失败：\(error.localizedDescription)"
            }
        }
    }

    func select(_ summary: NativeArticleSummary, recordsPageView: Bool = true) async throws {
        try await displayArticle(
            summary,
            disposition: .currentTab,
            recordsPageView: recordsPageView
        )
    }

    @discardableResult
    func displayArticle(
        _ summary: NativeArticleSummary,
        disposition: NativeArticleOpenDisposition,
        recordsPageView: Bool
    ) async throws -> Bool {
        articleNavigationGeneration += 1
        let navigationGeneration = articleNavigationGeneration
        let workspace = workspaceGeneration
        let selected: NativeArticle
        if recordsPageView {
            selected = try await store.incrementArticlePageViews(slug: summary.slug)
        } else {
            selected = try await store.getArticle(slug: summary.slug)
        }
        async let relationsRequest = store.articleRelations(for: summary.slug)
        async let commentsRequest = store.listArticleComments(articleSlug: summary.slug)
        let (relations, comments) = try await (relationsRequest, commentsRequest)
        guard navigationGeneration == articleNavigationGeneration,
              workspace == workspaceGeneration else { return false }
        if recordsPageView, let index = articles.firstIndex(where: { $0.slug == summary.slug }) {
            articles[index].pageViews = selected.pageViews
        }
        if selectedSlug != summary.slug {
            articleRevisions = []
        }
        updateArticleTabs(for: summary.slug, disposition: disposition)
        selectedSlug = summary.slug
        selectedArticle = selected
        selectedArticleRelations = relations
        articleComments = comments
        pendingArticleCommentSelection = nil
        recordRecentArticle(summary.slug)
        section = .reader
        persistArticleNavigationState()
        errorMessage = nil
        return true
    }

    func selectSlug(_ slug: String?) {
        guard let slug, let summary = articles.first(where: { $0.slug == slug }) else { return }
        let opensNewTab = NSEvent.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.command)
        Task {
            do {
                try await displayArticle(
                    summary,
                    disposition: opensNewTab ? .newTab : .currentTab,
                    recordsPageView: true
                )
            }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func showAllArticles() {
        selectedSmartCollectionID = nil
        selectedSmartCollectionViewID = nil
        smartCollectionArticles = []
        selectedArticleFolderPath = nil
        clearArticleFilters()
        section = .articles
    }

    func showArticleFolder(_ path: String) {
        selectedSmartCollectionID = nil
        selectedSmartCollectionViewID = nil
        smartCollectionArticles = []
        selectedArticleFolderPath = path
        clearArticleFilters()
        section = .articles
    }

    func promptToMoveArticleSource(_ summary: NativeArticleSummary) {
        guard !isSaving, !isBackingUp, !isRestoringBackup else { return }
        let alert = NSAlert()
        alert.messageText = "移动或重命名 Markdown"
        alert.informativeText = "输入 articles 目录内的相对路径。slug 不会改变，评论、版本和双链会继续关联原文章。"
        alert.addButton(withTitle: "移动")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: summary.sourceRelativePath)
        field.placeholderString = "文件夹/文章.md"
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let destination = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else { return }

        Task {
            do {
                let moved = try await store.moveArticleSource(
                    slug: summary.slug,
                    to: destination,
                    expectedUpdatedAt: summary.updatedAt
                )
                if selectedArticle?.slug == moved.slug { selectedArticle = moved }
                try await reload()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func showSmartCollection(_ collection: NativeSmartCollection) {
        selectedSmartCollectionID = collection.id
        selectedSmartCollectionViewID = collection.views.first?.id
        smartCollectionArticles = []
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

    func selectSmartCollectionView(_ viewID: String) {
        guard let definition = selectedSmartCollectionDefinition,
              definition.views.contains(where: { $0.id == viewID }),
              selectedSmartCollectionViewID != viewID else { return }
        selectedSmartCollectionViewID = viewID
        smartCollectionArticles = []
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
                articles = try await store.listArticles()
                try await refreshSelectedSmartCollection()
                if selectedArticle?.slug == updated.slug { selectedArticle = updated }
                articleGraph = try await store.articleGraph()
                scheduleBackup()
                errorMessage = nil
            } catch {
                errorMessage = "更新 Property 失败：\(error.localizedDescription)"
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
                smartCollectionArticles = []
            }
            smartCollections = try await store.listSmartCollections()
            scheduleBackup()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshSelectedSmartCollection() async throws {
        guard let selectedSmartCollection else {
            smartCollectionArticles = []
            return
        }
        smartCollectionArticles = try await store.listArticles(in: selectedSmartCollection)
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
            guard let summary = articles.first(where: { $0.slug == slug }) else {
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
            section = .graph
        }
    }

    func consumePendingArticleScrollAnchor() -> String? {
        defer { pendingArticleScrollAnchor = nil }
        return pendingArticleScrollAnchor
    }

    func openArticleLink(_ slug: String) {
        let opensNewTab = NSEvent.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.command)
        openArticleLink(slug, disposition: opensNewTab ? .newTab : .currentTab)
    }

    func openArticleLink(_ destination: NativeArticleLinkDestination) {
        if destination.target.isEmpty, let heading = destination.heading {
            scrollToLinkedHeading(heading)
            return
        }
        let resolvedSlug = destination.resolvedSlug
            ?? NativeArticleLink.resolve(destination.target, in: articles)?.slug
        guard let resolvedSlug else {
            createArticle(from: destination)
            return
        }
        guard let summary = articles.first(where: { $0.slug == resolvedSlug }) else {
            errorMessage = "关联的文章已不存在。"
            return
        }
        let opensNewTab = NSEvent.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.command)
        Task {
            do {
                guard try await displayArticle(
                    summary,
                    disposition: opensNewTab ? .newTab : .currentTab,
                    recordsPageView: true
                ) else { return }
                if let heading = destination.heading { scrollToLinkedHeading(heading) }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func openArticleLinkInNewTab(_ slug: String) {
        openArticleLink(slug, disposition: .newTab)
    }

    func openArticleLink(_ slug: String, disposition: NativeArticleOpenDisposition) {
        guard let summary = articles.first(where: { $0.slug == slug }) else {
            errorMessage = "关联的文章已不存在。"
            return
        }
        Task {
            do {
                try await displayArticle(
                    summary,
                    disposition: disposition,
                    recordsPageView: true
                )
            }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func scrollToLinkedHeading(_ rawHeading: String) {
        guard let article = selectedArticle else { return }
        let requested = rawHeading.split(separator: "#", omittingEmptySubsequences: true)
            .last.map(String.init) ?? rawHeading
        guard let heading = MarkdownOutline.items(in: article.body).first(where: {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(requested.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }) else {
            errorMessage = "已打开文章，但没有找到标题“\(rawHeading)”。"
            return
        }
        pendingArticleScrollAnchor = heading.id
        articleScrollRevision = UUID()
    }

    private func createArticle(from destination: NativeArticleLinkDestination) {
        let decodedTarget = destination.target.removingPercentEncoding ?? destination.target
        let extensionName = URL(fileURLWithPath: decodedTarget).pathExtension
        guard extensionName.isEmpty || extensionName.caseInsensitiveCompare("md") == .orderedSame else {
            errorMessage = "“\(destination.target)”不是文章链接，无法创建。"
            return
        }
        let targetWithoutExtension = extensionName.isEmpty
            ? decodedTarget
            : String(decodedTarget.dropLast(extensionName.count + 1))
        let title = URL(fileURLWithPath: targetWithoutExtension).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            errorMessage = "双链目标为空，无法创建文章。"
            return
        }

        let previousRecoveryID = editor.recoveryID
        newArticle()
        guard editor.recoveryID != previousRecoveryID else { return }
        editor.title = title
        if targetWithoutExtension.caseInsensitiveCompare(title) != .orderedSame {
            editor.properties["aliases"] = .list([targetWithoutExtension])
        }
        if let rawHeading = destination.heading {
            let heading = rawHeading.split(separator: "#", omittingEmptySubsequences: true)
                .last.map(String.init) ?? rawHeading
            if !heading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                editor.body = "## \(heading)\n\n"
            }
        }
        editorAutosaveStatus = "已从未创建双链预填，等待保存…"
        scheduleEditorAutosave()
        errorMessage = nil
    }

    func activateArticleTab(_ id: UUID) {
        guard id != activeArticleTabID,
              let tab = articleTabs.first(where: { $0.id == id }),
              let summary = articles.first(where: { $0.slug == tab.slug }) else { return }
        Task {
            do {
                guard try await displayArticle(
                    summary,
                    disposition: .refreshActiveTab,
                    recordsPageView: false
                ) else { return }
                activeArticleTabID = id
                persistArticleNavigationState()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func navigateArticleBack() {
        navigateActiveArticleTab(forward: false)
    }

    public func navigateArticleForward() {
        navigateActiveArticleTab(forward: true)
    }

    private func navigateActiveArticleTab(forward: Bool) {
        guard let activeArticleTabID,
              let index = articleTabs.firstIndex(where: { $0.id == activeArticleTabID }) else { return }
        var updatedTab = articleTabs[index]
        guard let targetSlug = forward ? updatedTab.goForward() : updatedTab.goBack(),
              let summary = articles.first(where: { $0.slug == targetSlug }) else { return }

        Task {
            do {
                guard try await displayArticle(
                    summary,
                    disposition: .refreshActiveTab,
                    recordsPageView: false
                ) else { return }
                guard self.activeArticleTabID == activeArticleTabID,
                      selectedSlug == targetSlug,
                      let currentIndex = articleTabs.firstIndex(where: { $0.id == activeArticleTabID }) else { return }
                articleTabs[currentIndex] = updatedTab
                persistArticleNavigationState()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func toggleActiveArticleTabPin() {
        guard let activeArticleTabID,
              let index = articleTabs.firstIndex(where: { $0.id == activeArticleTabID }) else { return }
        articleTabs[index].isPinned.toggle()
        reorderArticleTabs()
        persistArticleNavigationState()
    }

    func toggleArticleTabPin(_ id: UUID) {
        guard let index = articleTabs.firstIndex(where: { $0.id == id }) else { return }
        articleTabs[index].isPinned.toggle()
        reorderArticleTabs()
        persistArticleNavigationState()
    }

    public func closeActiveArticleTab() {
        guard let activeArticleTabID else { return }
        closeArticleTab(activeArticleTabID)
    }

    func closeArticleTab(_ id: UUID) {
        guard let index = articleTabs.firstIndex(where: { $0.id == id }) else { return }
        articleNavigationGeneration += 1
        let wasActive = id == activeArticleTabID
        articleTabs.remove(at: index)

        guard wasActive else {
            persistArticleNavigationState()
            return
        }

        selectedSlug = nil
        selectedArticle = nil
        selectedArticleRelations = .empty
        articleComments = []
        pendingArticleCommentSelection = nil
        activeArticleTabID = nil
        guard !articleTabs.isEmpty else {
            section = .articles
            persistArticleNavigationState()
            return
        }
        let nextIndex = min(index, articleTabs.count - 1)
        let nextID = articleTabs[nextIndex].id
        persistArticleNavigationState()
        activateArticleTab(nextID)
    }

    func updateArticleTabs(for slug: String, disposition: NativeArticleOpenDisposition) {
        switch disposition {
        case .refreshActiveTab:
            return
        case .newTab:
            let tab = NativeArticleTab(slug: slug)
            articleTabs.append(tab)
            activeArticleTabID = tab.id
        case .currentTab:
            guard let activeArticleTabID,
                  let index = articleTabs.firstIndex(where: { $0.id == activeArticleTabID }) else {
                let tab = NativeArticleTab(slug: slug)
                articleTabs.append(tab)
                self.activeArticleTabID = tab.id
                return
            }
            if articleTabs[index].isPinned, articleTabs[index].slug != slug {
                let tab = NativeArticleTab(slug: slug)
                articleTabs.append(tab)
                self.activeArticleTabID = tab.id
            } else {
                articleTabs[index].navigate(to: slug)
            }
        }
    }

    private func reorderArticleTabs() {
        let pinned = articleTabs.filter(\.isPinned)
        let unpinned = articleTabs.filter { !$0.isPinned }
        articleTabs = pinned + unpinned
    }

    func restoreWorkspaceTabs(_ savedTabs: [NativeArticleTab], activeTabID: UUID?) {
        let validSlugs = Set(articles.map(\.slug))
        var seen = Set<UUID>()
        articleTabs = savedTabs.compactMap { tab in
            guard validSlugs.contains(tab.slug), seen.insert(tab.id).inserted else { return nil }
            return NativeArticleTab(
                id: tab.id,
                slug: tab.slug,
                isPinned: tab.isPinned,
                backStack: tab.backStack.filter(validSlugs.contains),
                forwardStack: tab.forwardStack.filter(validSlugs.contains)
            )
        }
        reorderArticleTabs()
        self.activeArticleTabID = activeTabID.flatMap { savedID in
            articleTabs.contains(where: { $0.id == savedID }) ? savedID : nil
        } ?? articleTabs.first?.id
        persistArticleNavigationState()

        guard let activeArticleTab,
              let summary = articles.first(where: { $0.slug == activeArticleTab.slug }) else { return }
        Task {
            do {
                _ = try await displayArticle(
                    summary,
                    disposition: .refreshActiveTab,
                    recordsPageView: false
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func recordRecentArticle(_ slug: String) {
        recentArticleSlugs.removeAll(where: { $0 == slug })
        recentArticleSlugs.insert(slug, at: 0)
        recentArticleSlugs = Array(recentArticleSlugs.prefix(20))
    }

    private var articleNavigationDefaultsKey: String {
        if let navigationScopeID {
            return "leon-book.article-navigation.\(currentUser.id).window.\(navigationScopeID)"
        }
        return "leon-book.article-navigation.\(currentUser.id)"
    }

    func persistArticleNavigationState() {
        let snapshot = NativeArticleNavigationSnapshot(
            tabs: articleTabs,
            activeTabID: activeArticleTabID,
            recentSlugs: recentArticleSlugs
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: articleNavigationDefaultsKey)
    }

    func restoreArticleNavigationState() async {
        guard let data = UserDefaults.standard.data(forKey: articleNavigationDefaultsKey),
              let snapshot = try? JSONDecoder().decode(NativeArticleNavigationSnapshot.self, from: data) else {
            return
        }
        let validSlugs = Set(articles.map(\.slug))
        var seenTabIDs = Set<UUID>()
        articleTabs = snapshot.tabs.compactMap { tab in
            guard validSlugs.contains(tab.slug), seenTabIDs.insert(tab.id).inserted else { return nil }
            return NativeArticleTab(
                id: tab.id,
                slug: tab.slug,
                isPinned: tab.isPinned,
                backStack: tab.backStack.filter(validSlugs.contains),
                forwardStack: tab.forwardStack.filter(validSlugs.contains)
            )
        }
        reorderArticleTabs()
        var seenRecentSlugs = Set<String>()
        recentArticleSlugs = Array(snapshot.recentSlugs.filter {
            validSlugs.contains($0) && seenRecentSlugs.insert($0).inserted
        }.prefix(20))
        activeArticleTabID = snapshot.activeTabID.flatMap { savedID in
            articleTabs.contains(where: { $0.id == savedID }) ? savedID : nil
        } ?? articleTabs.first?.id

        guard let activeArticleTab,
              let summary = articles.first(where: { $0.slug == activeArticleTab.slug }) else {
            persistArticleNavigationState()
            return
        }
        do {
            try await displayArticle(
                summary,
                disposition: .refreshActiveTab,
                recordsPageView: false
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func prepareArticleComment(from selectedText: String, in markdown: String) {
        guard let selection = NativeArticleCommentAnchor.selection(
            for: selectedText,
            in: markdown
        ) else { return }
        pendingArticleCommentSelection = selection
        articleCommentSelectionRevision = UUID()
    }

    func clearPendingArticleCommentSelection() {
        pendingArticleCommentSelection = nil
    }

    func createArticleComment(text: String, parentID: String? = nil) async -> Bool {
        guard !isSavingArticleComment, let article = selectedArticle else { return false }
        isSavingArticleComment = true
        defer { isSavingArticleComment = false }
        do {
            let comment = try await store.createArticleComment(
                articleSlug: article.slug,
                authorName: currentUser.name,
                text: text,
                selection: parentID == nil ? pendingArticleCommentSelection : nil,
                parentID: parentID
            )
            scheduleBackup()
            guard selectedArticle?.slug == article.slug else { return true }
            articleComments.append(comment)
            articleComments.sort {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id < $1.id
            }
            if parentID == nil {
                pendingArticleCommentSelection = nil
            }
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteArticleComment(_ comment: NativeArticleComment) async {
        guard !isSavingArticleComment,
              selectedArticle?.slug == comment.articleSlug else { return }
        isSavingArticleComment = true
        defer { isSavingArticleComment = false }
        do {
            try await store.deleteArticleComment(id: comment.id, articleSlug: comment.articleSlug)
            scheduleBackup()
            guard selectedArticle?.slug == comment.articleSlug else { return }
            articleComments = try await store.listArticleComments(articleSlug: comment.articleSlug)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func convertUnlinkedMention(_ mention: NativeArticleMention) {
        guard let target = selectedArticle,
              !isSaving, !isBackingUp, !isRestoringBackup else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                _ = try await store.convertUnlinkedMention(
                    sourceSlug: mention.article.slug,
                    targetSlug: target.slug,
                    expectedUpdatedAt: mention.article.updatedAt
                )
                try await reload()
                scheduleBackup()
                errorMessage = nil
            } catch {
                errorMessage = "转换双链失败：\(error.localizedDescription)"
            }
        }
    }

}
