import Foundation

extension NativeAppModel {
    public func reload() async throws {
        let syncResult = try await store.refreshMarkdownSources()
        try await reloadIndexedState()
        if !syncResult.warnings.isEmpty {
            errorMessage = syncResult.warnings.joined(separator: "\n")
        }
    }

    private func reloadIndexedState() async throws {
        try await reloadArticleLibraryState()
        try await reloadWorkspaceAncillaryState(generation: workspaceGeneration)
        if !isEditorDirty,
           let selectedSlug,
           let selected = articleSummary(for: selectedSlug) {
            try await displayArticle(
                selected,
                disposition: .refreshActiveTab,
                recordsPageView: false
            )
        }
    }

    private func reloadArticleLibraryState() async throws {
        await replaceArticleSummaries(try await store.listArticles())
        workspaceResources = try await store.listWorkspaceResources()
        smartCollections = try await store.listSmartCollections()
        bookmarks = try await store.listBookmarks()
        if let selectedSmartCollectionID,
           !smartCollections.contains(where: { $0.id == selectedSmartCollectionID }) {
            self.selectedSmartCollectionID = nil
            selectedSmartCollectionViewID = nil
        } else if let definition = selectedSmartCollectionDefinition,
                  !definition.views.contains(where: { $0.id == selectedSmartCollectionViewID }) {
            selectedSmartCollectionViewID = definition.views.first?.id
        }
        try await refreshSelectedSmartCollection()
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updateArticleListSearch(searchText, debounce: false)
        }
        try await reloadKnowledgeGraph()
    }

    private func reloadWorkspaceAncillaryState(generation: Int) async throws {
        guard generation == workspaceGeneration else { return }
        try await reloadMomentFeed(refreshesFacets: true)
        guard generation == workspaceGeneration else { return }
        try await reloadQuestionList()
        guard generation == workspaceGeneration else { return }
        let loadedTrash = try await store.listTrash()
        guard generation == workspaceGeneration else { return }
        trashItems = loadedTrash
        let loadedActivity = try await store.listActivity(since: activityWindowStart())
        guard generation == workspaceGeneration else { return }
        activity = loadedActivity
    }

    private func scheduleWorkspaceAncillaryReload(generation: Int) {
        workspaceAncillaryLoadTask?.cancel()
        workspaceAncillaryLoadTask = Task { [weak self] in
            guard let self, generation == self.workspaceGeneration else { return }
            do {
                try await self.reloadWorkspaceAncillaryState(generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, generation == self.workspaceGeneration else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func reloadAfterMarkdownSourceChanges(_ result: NativeMarkdownSyncResult) async throws {
        let plan = NativeMarkdownRefreshPlan(
            result: result,
            selectedArticleSlug: selectedSlug
        )
        guard plan.reloadsArticleList else { return }

        let affectedSlugs = result.affectedArticleSlugs
        let refreshed = try await store.listArticleSummaries(slugs: affectedSlugs)
        var summariesBySlug = Dictionary(uniqueKeysWithValues: articles.map { ($0.slug, $0) })
        for slug in affectedSlugs { summariesBySlug.removeValue(forKey: slug) }
        for summary in refreshed { summariesBySlug[summary.slug] = summary }
        let summaries = summariesBySlug.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.slug < $1.slug
        }
        await replaceArticleSummaries(summaries)
        workspaceResources = try await store.listWorkspaceResources()
        if plan.reloadsSelectedSmartCollection {
            try await refreshSelectedSmartCollection()
        }
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updateArticleListSearch(searchText, debounce: false)
        }
        if plan.reloadsKnowledgeGraph {
            try await reloadKnowledgeGraph()
        }
        if plan.reloadsTrash {
            trashItems = try await store.listTrash()
        }

        guard plan.reloadsSelectedArticle, !isEditorDirty, let selectedSlug else { return }
        guard let selected = articleSummary(for: selectedSlug) else {
            articleTabs.removeAll(where: { $0.slug == selectedSlug })
            recentArticleSlugs.removeAll(where: { $0 == selectedSlug })
            self.selectedSlug = nil
            selectedArticle = nil
            selectedArticleRelations = .empty
            articleComments = []
            pendingArticleCommentSelection = nil
            activeArticleTabID = articleTabs.first?.id
            if section == .reader { section = .articles }
            persistArticleNavigationState()
            return
        }

        let previousSection = section
        try await displayArticle(
            selected,
            disposition: .refreshActiveTab,
            recordsPageView: false
        )
        if previousSection != .reader {
            section = previousSection
        }
    }

    var isMarkdownSourceReadOnly: Bool { activeMarkdownWorkspaceMode.isReadOnly }

    func startMarkdownSourceMonitor() {
        stopMarkdownSourceMonitor()
        let generation = workspaceGeneration
        let articlesURL = URL(fileURLWithPath: markdownSourceDirectoryPath, isDirectory: true)
        let monitor = MarkdownSourceEventMonitor(rootURL: articlesURL)
        markdownSourceEventMonitor = monitor
        do {
            try monitor.start { [weak self] changes in
                Task { @MainActor [weak self] in
                    self?.enqueueMarkdownSourceChanges(changes, generation: generation)
                }
            }
        } catch {
            markdownSourceEventMonitor = nil
            errorMessage = "Markdown 事件监听启动失败，将使用低频校验：\(error.localizedDescription)"
        }
        markdownSourceVerificationTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self,
                      generation == self.workspaceGeneration else { return }
                self.enqueueMarkdownSourceChanges(
                    NativeMarkdownSourceChangeSet(requiresFullScan: true),
                    generation: generation
                )
            }
        }
    }

    func stopMarkdownSourceMonitor() {
        markdownSourceEventMonitor?.stop()
        markdownSourceEventMonitor = nil
        markdownSourceSyncTask?.cancel()
        markdownSourceSyncTask = nil
        markdownSourceVerificationTask?.cancel()
        markdownSourceVerificationTask = nil
        pendingMarkdownSourceChanges = NativeMarkdownSourceChangeSet()
    }

    private func enqueueMarkdownSourceChanges(
        _ changes: NativeMarkdownSourceChangeSet,
        generation: Int
    ) {
        guard generation == workspaceGeneration else { return }
        pendingMarkdownSourceChanges.merge(changes)
        guard markdownSourceSyncTask == nil else { return }
        markdownSourceSyncTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 700_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.processPendingMarkdownSourceChanges(generation: generation)
        }
    }

    private func processPendingMarkdownSourceChanges(generation: Int) async {
        defer {
            markdownSourceSyncTask = nil
            if generation == workspaceGeneration, !pendingMarkdownSourceChanges.isEmpty {
                enqueueMarkdownSourceChanges(
                    NativeMarkdownSourceChangeSet(),
                    generation: generation
                )
            }
        }
        guard generation == workspaceGeneration else { return }
        let changes = pendingMarkdownSourceChanges
        pendingMarkdownSourceChanges = NativeMarkdownSourceChangeSet()
        guard !changes.isEmpty else { return }
        do {
            let result: NativeMarkdownSyncResult
            if changes.requiresFullScan {
                result = try await store.refreshMarkdownSources()
            } else {
                result = try await store.refreshMarkdownSources(
                    changedRelativePaths: changes.relativePaths,
                    changedDirectoryPrefixes: changes.directoryPrefixes
                )
            }
            guard generation == workspaceGeneration else { return }
            if result.didChange { try await reloadAfterMarkdownSourceChanges(result) }
            if !result.didChange, changes.reloadsResources {
                workspaceResources = try await store.listWorkspaceResources()
            }
            if changes.reloadsPortableSidecar || changes.requiresFullScan {
                try await importPortableSidecarAfterExternalChange()
            }
            if !result.warnings.isEmpty {
                errorMessage = result.warnings.joined(separator: "\n")
            }
        } catch {
            guard generation == workspaceGeneration else { return }
            errorMessage = "Markdown 自动同步失败：\(error.localizedDescription)"
        }
    }

    func loadWorkspace(_ workspace: NativeWorkspaceState) async throws {
        let nextStore = LocalBlogStore(rootURL: workspace.workspaceURL)
        try await nextStore.prepareForInteractiveUse()
        let sourceState = try await nextStore.markdownWorkspaceSourceState()
        let sourceURL = try await nextStore.markdownSourceDirectoryURL()
        let portableStatus = try await nextStore.portableSidecarStatus()
        stopMarkdownSourceMonitor()
        articleAncillaryLoadTask?.cancel()
        articlePostSaveTask?.cancel()
        backupOverviewTask?.cancel()
        compatibilityExportTask?.cancel()
        workspaceAncillaryLoadTask?.cancel()
        articleListSearchTask?.cancel()
        globalSearchTask?.cancel()
        questionSearchTask?.cancel()
        workspaceGeneration += 1
        momentFeedGeneration += 1
        store = nextStore
        scheduleCompatibilityExportVerification(for: nextStore)
        users = workspace.users
        currentUser = workspace.activeUser
        dataDirectoryPath = workspace.workspaceURL.path
        reloadDeclarativeExtensions()
        activeMarkdownWorkspaceMode = sourceState.mode
        selectedMarkdownWorkspaceMode = sourceState.mode
        markdownSourceDirectoryPath = sourceURL.path
        applyPortableSidecarStatus(portableStatus)
        portableSidecarRevision = UUID()
        await replaceArticleSummaries([])
        workspaceResources = []
        moments = []
        totalMomentCount = 0
        filteredMomentCount = 0
        questions = []
        totalQuestionCount = 0
        questionTagFacets = []
        selectedQuestion = nil
        questionAnswers = []
        isLoadingQuestionAnswers = false
        questionAnswerDraft = NativeQuestionAnswerDraft()
        editingQuestionAnswerID = nil
        editingQuestionAnswerUpdatedAt = nil
        clearMomentFacetRecords()
        nextMomentCursor = nil
        hasMoreMoments = false
        trashItems = []
        activity = []
        selectedArticle = nil
        selectedArticleRelations = .empty
        articleComments = []
        pendingArticleCommentSelection = nil
        articleTabs = []
        activeArticleTabID = nil
        recentArticleSlugs = []
        articleGraph = .empty
        articleRevisions = []
        articleSourceConflict = nil
        selectedSlug = nil
        editor = NativeEditorDraft()
        pendingNewArticleFolderPath = nil
        editorAutosaveStatus = "尚未自动保存"
        pendingEditorMediaCleanup = []
        editorOriginalArticle = nil
        momentDraft = NativeMomentDraft()
        editingMomentID = nil
        searchText = ""
        momentSearchText = ""
        questionSearchText = ""
        selectedQuestionTag = nil
        globalSearchText = ""
        globalSearchResults = []
        searchPresentation = nil
        articleSearchMatchSlugs = []
        articleSearchResolvedText = ""
        smartCollections = []
        selectedSmartCollectionID = nil
        selectedSmartCollectionViewID = nil
        clearSmartCollectionArticleSummaries()
        bookmarks = []
        pendingArticleScrollAnchor = nil
        isSearchingArticles = false
        isSearchingGlobally = false
        obsidianImportPreview = nil
        obsidianImportStatus = "尚未选择 Vault"
        isScanningObsidianVault = false
        isImportingObsidianVault = false
        selectedArticleTags = []
        selectedArticleFolderPath = nil
        selectedMomentTags = []
        momentDateFilter = .all
        showsOnlyFavoriteMoments = false
        section = .dashboard
        try await reloadArticleLibraryState()
        await restoreArticleNavigationState()
        try await restoreLatestUnsavedArticleDraftIfNeeded()
        startMarkdownSourceMonitor()
        let generation = workspaceGeneration
        scheduleWorkspaceAncillaryReload(generation: generation)
        enqueueMarkdownSourceChanges(
            NativeMarkdownSourceChangeSet(requiresFullScan: true),
            generation: generation
        )
    }

}
