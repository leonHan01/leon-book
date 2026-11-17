import Foundation
import LeonBookPublishingModule

extension NativeAppModel {
    /// The target and store are captured by the chat, independently of the current selection.
    func saveAIReadingOutput(_ text: String, context: AIReadingContext, sourceStore: LocalBlogStore) async throws {
        guard store === sourceStore else { throw AIReadingError.sourceChanged }
        guard !isBackingUp, !isRestoringBackup else {
            throw AIReadingError.message(NativeLocalization.text("资料库正在备份或恢复，请稍后保存。"))
        }
        let generation = workspaceGeneration
        switch context.kind {
        case .article:
            guard !isSavingArticleComment else {
                throw AIReadingError.message(NativeLocalization.text("正在保存评论，请稍后重试。"))
            }
            isSavingArticleComment = true
            defer { if generation == workspaceGeneration { isSavingArticleComment = false } }
            let comment = try await sourceStore.createArticleComment(articleSlug: context.id, authorName: currentUser.name, text: text)
            guard generation == workspaceGeneration else { return }
            if selectedArticle?.slug == context.id { articleComments.append(comment) }
        case .question:
            guard authorizeFirstPartyModule(PublishingFirstPartyModule.id, permission: .contentPublish, action: "保存 AI 回答") else {
                throw AIReadingError.message(NativeLocalization.text("请先启用发布模块，再保存 AI 回答。"))
            }
            guard !isPublishingQuestionAnswer else {
                throw AIReadingError.message(NativeLocalization.text("正在保存回答，请稍后重试。"))
            }
            isPublishingQuestionAnswer = true
            defer { if generation == workspaceGeneration { isPublishingQuestionAnswer = false } }
            let answer = try await sourceStore.saveQuestionAnswer(questionID: context.id, body: text)
            // A successful save must not be reported as failed if a following refresh fails.
            let question = try? await sourceStore.getQuestion(id: context.id)
            let hot = try? await sourceStore.listHotQuestions()
            guard generation == workspaceGeneration else { return }
            if selectedQuestion?.id == context.id {
                questionAnswers.append(answer)
                if let question { selectedQuestion = question }
            }
            if let question, let index = questions.firstIndex(where: { $0.id == context.id }) { questions[index] = question }
            if let hot { questionSession.hotQuestions = hot }
        }
        guard generation == workspaceGeneration else { return }
        scheduleBackup()
    }
}
