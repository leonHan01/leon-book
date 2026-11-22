import Foundation

extension NativeAppModel {
    func changeArticlePrivacy(_ article: NativeArticle) async {
        guard !isSaving, !isBackingUp else { return }
        let activeStore = store
        do {
            let saved = try await activeStore.setArticlePrivacy(
                slug: article.slug, isPrivate: !article.isPrivate, expectedUpdatedAt: article.updatedAt
            )
            guard activeStore === store else { return }
            NativeWorkspaceWindows.reloadAfterContentPrivacyChange(in: activeStore.rootURL, excluding: self, articleSlugs: [saved.slug])
            if saved.isPrivate, !privacyModeEnabled {
                concealPrivateContent(articleSlugs: [saved.slug])
            } else {
                if selectedArticle?.slug == saved.slug { selectedArticle = saved }
                invalidateContentPreviews()
            }
            schedulePrivacyReload()
            scheduleBackup()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func togglePrivacyMode() {
        NativeWorkspaceWindows.setPrivacyMode(!privacyModeEnabled, using: contentPrivacy)
    }

    func applyPrivacyMode(_ enabled: Bool) {
        privacyModeEnabled = enabled
        guard storageReady, !isRestoringBackup else { return }
        if enabled {
            invalidateContentPreviews()
            if momentDraft.isEmpty, editingMomentID == nil,
               let draft = concealedMomentDrafts.removeValue(forKey: "") {
                momentDraft = draft
            }
        } else {
            concealPrivateContent()
        }
        schedulePrivacyReload(recoverPrivateDraft: enabled)
    }

    func invalidateContentPreviews() {
        mediaLibrary = NativeMediaLibraryModel(store: store)
        privacyPresentationRevision = UUID()
        globalSearchTask?.cancel()
        globalSearchGeneration += 1
        globalSearchResults = []
        searchPresentation = nil
    }

    func concealPrivateContent(
        articleSlugs: Set<String> = [],
        momentIDs: Set<String> = [],
        questionIDs: Set<String> = [],
        preservesEditor: Bool = true
    ) {
        var hiddenArticles = articleSlugs.union(articles.lazy.filter(\.isPrivate).map(\.slug))
        if let article = selectedArticle, article.isPrivate { hiddenArticles.insert(article.slug) }
        if let article = editorOriginalArticle, article.isPrivate { hiddenArticles.insert(article.slug) }
        let hiddenMoments = momentIDs.union(moments.lazy.filter(\.isPrivate).map(\.id))
        let hidesReader = selectedArticle?.isPrivate == true || selectedSlug.map(hiddenArticles.contains) == true
        let hidesEditor = editor.isPrivate || editorOriginalArticle?.isPrivate == true || hiddenArticles.contains(editor.slug)
        let hidesQuestion = selectedQuestion.map { $0.isPrivate || questionIDs.contains($0.id) } == true

        workspaceGeneration += 1
        articleNavigationGeneration += 1
        momentFeedGeneration += 1
        questionListGeneration += 1
        workspaceAncillaryLoadTask?.cancel()
        articlePostSaveTask?.cancel()
        articleAncillaryLoadTask?.cancel()
        articleListSearchTask?.cancel()
        editorRecoveryTask?.cancel()
        momentSearchTask?.cancel()
        questionSearchTask?.cancel()
        knowledgeGraphTask?.cancel()
        invalidateContentPreviews()
        clearArticleSummaries()
        workspaceResources = []
        bookmarks = []
        articleGraph = .empty
        selectedArticleRelations = .empty
        articleRevisions = []
        articleSourceConflict = nil
        searchText = ""
        globalSearchText = ""
        momentSearchText = ""
        questionSearchText = ""
        articleSearchMatchSlugs = []
        articleSearchResolvedText = ""
        isSearchingArticles = false
        isSearchingGlobally = false
        trashItems = []
        selectedArticleTags = []
        selectedArticleFolderPath = nil
        selectedMomentTags = []
        moments.removeAll { hiddenMoments.contains($0.id) }
        clearMomentFacetRecords()
        totalMomentCount = 0
        filteredMomentCount = 0
        nextMomentCursor = nil
        hasMoreMoments = false
        questionSession.applyList(
            questions: questions.filter { !$0.isPrivate && !questionIDs.contains($0.id) },
            hotQuestions: [], totalCount: 0, tagFacets: []
        )
        selectedQuestionTag = nil
        if hidesQuestion, let id = selectedQuestion?.id {
            concealQuestionDetail(id: id)
        }
        if momentDraft.isPrivate || editingMomentID.map(hiddenMoments.contains) == true {
            concealedMomentDrafts[editingMomentID ?? ""] = momentDraft
            self.editingMomentID = nil
            momentDraft = NativeMomentDraft()
        }
        if hidesEditor {
            editorAutosaveTask?.cancel()
            if preservesEditor, isEditorDirty {
                let snapshot = editorRevisionSnapshot
                let draftKey = editor.recoveryID
                let slug = editor.isNew ? nil : editor.slug
                let activeStore = store
                Task {
                    do {
                        _ = try await activeStore.saveArticleAutosave(draftKey: draftKey, articleSlug: slug, snapshot: snapshot)
                    } catch {
                        if store === activeStore { errorMessage = error.localizedDescription }
                    }
                }
            }
            editor = NativeEditorDraft()
            editorOriginalArticle = nil
            pendingEditorMediaCleanup = []
            pendingNewArticleFolderPath = nil
            if section == .editor { section = .articles }
        }
        if hidesReader {
            selectedArticle = nil
            selectedSlug = nil
            articleComments = []
            pendingArticleCommentSelection = nil
            activeArticleTabID = nil
            if section == .reader { section = .articles }
        }
        articleTabs.removeAll { hiddenArticles.contains($0.slug) }
        recentArticleSlugs.removeAll { hiddenArticles.contains($0) }
        if storageReady {
            startMarkdownSourceMonitor()
            enqueueMarkdownSourceChanges(NativeMarkdownSourceChangeSet(requiresFullScan: true), generation: workspaceGeneration)
        }
    }

    func concealQuestionDetail(id: String) {
        guard selectedQuestion?.id == id else { return }
        if !questionAnswerDraft.isEmpty || editingQuestionAnswerID != nil {
            concealedQuestionAnswerDrafts[id] = (questionAnswerDraft, editingQuestionAnswerID, editingQuestionAnswerUpdatedAt)
        }
        selectedQuestion = nil
        questionAnswers = []
        isLoadingQuestionAnswers = false
        questionSession.discardAnswerDraft()
    }

    @discardableResult
    func reconcileContentPrivacy() async throws -> Bool {
        guard !privacyModeEnabled else { return false }
        let generation = workspaceGeneration
        let hidden = try await store.privateContentIDs()
        guard !privacyModeEnabled, generation == workspaceGeneration else { return false }
        let affectedArticles = hidden.articles.intersection(articles.map(\.slug) + [selectedSlug ?? "", editor.slug])
        let affectedMoments = hidden.moments.intersection(moments.map(\.id) + [editingMomentID ?? ""])
        let affectedQuestions = hidden.questions.intersection(questions.map(\.id) + hotQuestions.map(\.id) + [selectedQuestion?.id ?? ""])
        guard !affectedArticles.isEmpty || !affectedMoments.isEmpty || !affectedQuestions.isEmpty else { return false }
        concealPrivateContent(articleSlugs: affectedArticles, momentIDs: affectedMoments, questionIDs: affectedQuestions)
        return true
    }

    func schedulePrivacyReload(recoverPrivateDraft: Bool = false) {
        privacyReloadTask?.cancel()
        let generation = workspaceGeneration
        privacyReloadTask = Task { [weak self] in
            guard let self, generation == workspaceGeneration, storageReady else { return }
            do {
                try await reloadArticleLibraryState()
                try Task.checkCancellation()
                try await reloadMomentFeed(refreshesFacets: true)
                try await reloadQuestionList()
                let loadedTrash = try await store.listTrash()
                guard !Task.isCancelled, generation == workspaceGeneration else { return }
                trashItems = loadedTrash
                if let slug = selectedSlug, let summary = articleSummary(for: slug), section == .reader {
                    try await displayArticle(summary, disposition: .refreshActiveTab, recordsPageView: false)
                }
                if recoverPrivateDraft, privacyModeEnabled, section == .articles {
                    try await restoreLatestUnsavedArticleDraftIfNeeded(onlyPrivate: true)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, generation == workspaceGeneration else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}
