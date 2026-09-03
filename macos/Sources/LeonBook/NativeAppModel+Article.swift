import AppKit
import Foundation
import LeonBookPublishingModule

extension NativeAppModel {
    @discardableResult
    func applyArticlePageTemplate(_ template: NativeArticlePageTemplate) -> Bool {
        guard editor.isNew else {
            errorMessage = "整页模板只能应用到尚未保存的新页面。"
            return false
        }
        if isEditorDirty {
            let alert = NSAlert()
            alert.messageText = "应用“\(template.name)”模板？"
            alert.informativeText = "当前新页面已有内容。模板会替换标题、正文、分类、标签和属性，并移除尚未保存的附件。"
            alert.addButton(withTitle: "应用模板")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }

        let bannerMedia = editor.banner.map {
            NativeMedia(kind: "image", name: $0.name, size: $0.size, url: $0.url)
        }
        discardUnreferencedMedia(editor.media + (bannerMedia.map { [$0] } ?? []) + pendingEditorMediaCleanup)
        pendingEditorMediaCleanup = []
        template.apply(to: &editor)
        editorBodySelection = NSRange(location: 0, length: 0)
        editorAutosaveStatus = "已应用页面模板“\(template.name)”"
        errorMessage = nil
        return true
    }

    func newArticle(inBoardGroup label: String, field: NativeArticleGroupField) {
        let previousRecoveryID = editor.recoveryID
        newArticle()
        guard editor.recoveryID != previousRecoveryID else { return }
        if NativeArticleDraftPrefill.applyBoardGroup(label: label, field: field, to: &editor) {
            editorAutosaveStatus = "已按“\(label)”预填新页面"
        }
    }

    func newArticle(onCalendarDate value: String, propertyKey: String?) {
        let previousRecoveryID = editor.recoveryID
        newArticle()
        guard editor.recoveryID != previousRecoveryID else { return }
        if NativeArticleDraftPrefill.applyCalendarDate(value, propertyKey: propertyKey, to: &editor) {
            editorAutosaveStatus = "已预填日期 \(value)"
        }
    }

    func schedulePostSaveArticleRefresh(_ saved: NativeArticle, recoveryID: String) {
        articlePostSaveTask?.cancel()
        let activeStore = store
        let workspace = workspaceGeneration
        articlePostSaveTask = Task { [weak self] in
            guard let self else { return }

            var summaries = self.articles
            let summary = saved.summary
            if let index = summaries.firstIndex(where: { $0.slug == summary.slug }) {
                summaries[index] = summary
            } else {
                summaries.append(summary)
            }
            summaries.sort {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.slug < $1.slug
            }
            await self.replaceArticleSummaries(summaries)
            guard !Task.isCancelled, workspace == self.workspaceGeneration else { return }

            if !self.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.updateArticleListSearch(self.searchText, debounce: false)
            }
            do {
                self.workspaceResources = try await activeStore.listWorkspaceResources()
                if self.selectedSmartCollection != nil {
                    try await self.refreshSelectedSmartCollection()
                }
                let revisions = try await activeStore.listArticleRevisions(
                    articleSlug: saved.slug,
                    draftKey: recoveryID
                )
                guard !Task.isCancelled,
                      workspace == self.workspaceGeneration,
                      self.selectedSlug == saved.slug else { return }
                self.articleRevisions = revisions
                try await self.refreshActivity()
            } catch {
                guard !Task.isCancelled, workspace == self.workspaceGeneration else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

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
                await replaceArticleSummaries(try await store.listArticles())
                try await reloadKnowledgeGraph()
                selectedArticleRelations = try await store.articleRelations(for: updated.slug)
                scheduleBackup()
                errorMessage = nil
            } catch {
                errorMessage = "更新任务失败：\(error.localizedDescription)"
            }
        }
    }

    @MainActor
    func transferEditorBlocks(
        _ markdownBlocks: [String],
        sourceBodyAfter: String?,
        toArticleSlug targetSlug: String,
        operation: EditorBlockTransferOperation
    ) async -> EditorBlockTransferReceipt? {
        guard !markdownBlocks.isEmpty, !isMarkdownSourceReadOnly else { return nil }
        do {
            let targetBefore = try await store.getArticle(slug: targetSlug)
            var sourceBefore: NativeArticle?
            var updates: [NativeArticleBodyUpdate] = []
            if let sourceBodyAfter {
                guard !editor.slug.isEmpty, let expectedUpdatedAt = editor.updatedAt else { return nil }
                let source = try await store.getArticle(slug: editor.slug)
                guard source.updatedAt == expectedUpdatedAt else { throw NativeStoreError.conflict }
                if source.body != sourceBodyAfter {
                    sourceBefore = source
                    updates.append(NativeArticleBodyUpdate(
                        slug: source.slug,
                        body: sourceBodyAfter,
                        expectedUpdatedAt: expectedUpdatedAt
                    ))
                }
            }
            updates.append(NativeArticleBodyUpdate(
                slug: targetBefore.slug,
                body: NativeBlockEditorDocument.appending(markdownBlocks, to: targetBefore.body),
                expectedUpdatedAt: targetBefore.updatedAt
            ))
            let saved = try await store.updateArticleBodiesAtomically(updates)
            let sourceAfter = sourceBefore.flatMap { source in
                saved.first(where: { $0.slug == source.slug })
            }
            guard let targetAfter = saved.first(where: { $0.slug == targetBefore.slug }) else {
                throw NativeStoreError.notFound
            }
            await applyBlockTransferArticles(saved, sourceArticle: sourceAfter)
            scheduleBackup()
            errorMessage = nil
            return EditorBlockTransferReceipt(
                operation: operation,
                sourceBefore: sourceBefore,
                sourceAfter: sourceAfter,
                targetBefore: targetBefore,
                targetAfter: targetAfter
            )
        } catch {
            errorMessage = "跨笔记写入块失败：\(error.localizedDescription)"
            return nil
        }
    }

    @MainActor
    func undoEditorBlockTransfer(_ receipt: EditorBlockTransferReceipt) async -> Bool {
        do {
            var updates: [NativeArticleBodyUpdate] = []
            if let sourceBefore = receipt.sourceBefore, let sourceAfter = receipt.sourceAfter {
                updates.append(NativeArticleBodyUpdate(
                    slug: sourceBefore.slug,
                    body: sourceBefore.body,
                    expectedUpdatedAt: sourceAfter.updatedAt
                ))
            }
            updates.append(NativeArticleBodyUpdate(
                slug: receipt.targetBefore.slug,
                body: receipt.targetBefore.body,
                expectedUpdatedAt: receipt.targetAfter.updatedAt
            ))
            let restored = try await store.updateArticleBodiesAtomically(updates)
            let restoredSource = receipt.sourceBefore.flatMap { source in
                restored.first(where: { $0.slug == source.slug })
            }
            await applyBlockTransferArticles(restored, sourceArticle: restoredSource)
            scheduleBackup()
            errorMessage = nil
            return true
        } catch {
            errorMessage = "撤销跨笔记块操作失败：\(error.localizedDescription)"
            return false
        }
    }

    @MainActor
    private func applyBlockTransferArticles(
        _ updatedArticles: [NativeArticle],
        sourceArticle: NativeArticle?
    ) async {
        var summaries = articles
        for article in updatedArticles {
            if let index = summaries.firstIndex(where: { $0.slug == article.slug }) {
                summaries[index] = article.summary
            } else {
                summaries.append(article.summary)
            }
            if selectedArticle?.slug == article.slug { selectedArticle = article }
        }
        summaries.sort {
            $0.updatedAt == $1.updatedAt ? $0.slug < $1.slug : $0.updatedAt > $1.updatedAt
        }
        await replaceArticleSummaries(summaries)
        if let sourceArticle, editor.slug == sourceArticle.slug {
            editor.body = sourceArticle.body
            editor.updatedAt = sourceArticle.updatedAt
            editorOriginalArticle = sourceArticle
            editorAutosaveTask?.cancel()
            editorAutosaveStatus = "跨笔记块操作已保存"
        }
        if selectedSmartCollection != nil {
            try? await refreshSelectedSmartCollection()
        }
        try? await reloadKnowledgeGraph()
        if let selectedSlug {
            selectedArticleRelations = (try? await store.articleRelations(for: selectedSlug)) ?? .empty
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
                await replaceArticleSummaries(try await store.listArticles())
                try await reloadKnowledgeGraph()
                articleTabs.removeAll(where: { $0.slug == source.slug })
                recentArticleSlugs.removeAll(where: { $0 == source.slug })
                if let summary = articleSummary(for: result.primaryArticle.slug) {
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
        await replaceArticleSummaries(try await store.listArticles())
        try await reloadKnowledgeGraph()
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
                await replaceArticleSummaries(try await store.listArticles())
                try await reloadKnowledgeGraph()
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
        recordsPageView: Bool,
        persistsNavigation: Bool = true
    ) async throws -> Bool {
        articleNavigationGeneration += 1
        let navigationGeneration = articleNavigationGeneration
        let workspace = workspaceGeneration
        let selected: NativeArticle
        if recordsPageView {
            selected = try await store.incrementArticlePageViews(slug: summary.slug)
        } else if let cached = articleSelectionCache.article(
            matching: summary,
            workspaceGeneration: workspace
        ) {
            selected = cached
        } else {
            selected = try await store.getArticle(slug: summary.slug)
        }
        guard navigationGeneration == articleNavigationGeneration,
              workspace == workspaceGeneration else { return false }
        if recordsPageView {
            updateArticleSummaryPageViews(slug: summary.slug, pageViews: selected.pageViews)
        }
        if selectedSlug != summary.slug {
            articleRevisions = []
        }
        updateArticleTabs(for: summary.slug, disposition: disposition)
        selectedSlug = summary.slug
        selectedArticle = selected
        selectedArticleRelations = .empty
        articleComments = []
        pendingArticleCommentSelection = nil
        recordRecentArticle(summary.slug)
        section = .reader
        if persistsNavigation {
            persistArticleNavigationState()
        }
        errorMessage = nil
        let refreshesPageViewCollection = recordsPageView
            && selectedSmartCollection?.dependsOnPageViews == true
        loadArticleAncillaryState(
            slug: summary.slug,
            navigationGeneration: navigationGeneration,
            workspaceGeneration: workspace,
            refreshesPageViewCollection: false
        )
        // The reader is already visible at this point. Keep the selected Base
        // semantically current before returning, without putting comments and
        // backlinks back on the navigation critical path.
        if refreshesPageViewCollection {
            try await refreshSelectedSmartCollection()
        }
        return true
    }

    func loadArticleAncillaryState(
        slug: String,
        navigationGeneration: Int,
        workspaceGeneration: Int,
        refreshesPageViewCollection: Bool
    ) {
        articleAncillaryLoadTask?.cancel()
        let activeStore = store
        articleAncillaryLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let comments = try await activeStore.listArticleComments(articleSlug: slug)
                guard !Task.isCancelled,
                      navigationGeneration == self.articleNavigationGeneration,
                      workspaceGeneration == self.workspaceGeneration,
                      self.selectedSlug == slug else { return }
                self.articleComments = comments

                let relations = try await activeStore.articleRelations(for: slug)
                guard !Task.isCancelled,
                      navigationGeneration == self.articleNavigationGeneration,
                      workspaceGeneration == self.workspaceGeneration,
                      self.selectedSlug == slug else { return }
                self.selectedArticleRelations = relations

                if refreshesPageViewCollection {
                    try await self.refreshSelectedSmartCollection()
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      navigationGeneration == self.articleNavigationGeneration,
                      workspaceGeneration == self.workspaceGeneration else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func selectSlug(_ slug: String?) {
        guard let slug, let summary = articleSummary(for: slug) else { return }
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
        clearSmartCollectionArticleSummaries()
        selectedArticleFolderPath = nil
        clearArticleFilters()
        section = .articles
    }

    func showArticleFolder(_ path: String) {
        selectedSmartCollectionID = nil
        selectedSmartCollectionViewID = nil
        clearSmartCollectionArticleSummaries()
        selectedArticleFolderPath = path
        clearArticleFilters()
        section = .articles
    }

    func promptToMoveArticleSource(_ summary: NativeArticleSummary) {
        guard !isSaving, !isBackingUp, !isRestoringBackup else { return }
        if let resource = workspaceResourceItems.first(where: {
            $0.kind == .article && $0.articleSlug == summary.slug
        }) {
            promptToMoveWorkspaceResources([resource])
            return
        }
        Task {
            do {
                workspaceResources = try await store.listWorkspaceResources()
                guard let resource = workspaceResourceItems.first(where: {
                    $0.kind == .article && $0.articleSlug == summary.slug
                }) else {
                    errorMessage = "无法在文件资源树中定位这篇文章。请刷新后重试。"
                    return
                }
                promptToMoveWorkspaceResources([resource])
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
