import Foundation

extension NativeAppModel {
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
        let generation = workspaceGeneration
        let activeStore = store
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let converted = try await activeStore.convertUnlinkedMention(
                    sourceSlug: mention.article.slug,
                    targetSlug: target.slug,
                    expectedUpdatedAt: mention.article.updatedAt
                )
                guard generation == workspaceGeneration, store === activeStore else { return }
                scheduleBackup()
                articleSelectionCache.insert(converted, workspaceGeneration: generation)
                await mergeArticleSummaries([converted.summary], workspaceGeneration: generation)
                guard generation == workspaceGeneration, store === activeStore else { return }
                try await reloadKnowledgeGraph()
                guard generation == workspaceGeneration, store === activeStore else { return }
                errorMessage = nil
                if let selectedArticle, selectedArticle.slug == target.slug {
                    await loadArticleRelations(for: selectedArticle)
                }
            } catch {
                guard generation == workspaceGeneration, store === activeStore else { return }
                errorMessage = NativeLocalization.text("转换双链失败：\(error.localizedDescription)")
            }
        }
    }
}

