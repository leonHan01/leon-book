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

