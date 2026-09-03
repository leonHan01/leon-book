import AppKit
import Foundation
import LeonBookPublishingModule

extension NativeAppModel {
    var isFilteringQuestions: Bool {
        questionSession.isFiltering
    }

    func reloadQuestionList(selecting questionID: String? = nil) async throws {
        let generation = workspaceGeneration
        let currentQuestionID = selectedQuestion?.id
        let preferredQuestionID = questionID ?? currentQuestionID
        let loadedQuestions = try await store.listQuestions(
            searchText: questionSearchText,
            tag: selectedQuestionTag
        )
        let loadedFacets = try await store.listQuestionTagFacets()
        let loadedTotal = try await store.countQuestions()
        let nextSelection = preferredQuestionID.flatMap { preferredID in
            loadedQuestions.first(where: { $0.id == preferredID })
        }
        let loadedAnswers: [NativeQuestionAnswer]
        if let nextSelection {
            loadedAnswers = try await store.listQuestionAnswers(questionID: nextSelection.id)
        } else {
            loadedAnswers = []
        }

        guard generation == workspaceGeneration else { return }

        let discardedMedia = questionSession.applyReload(
            questions: loadedQuestions,
            totalCount: loadedTotal,
            tagFacets: loadedFacets,
            selectedQuestion: nextSelection,
            answers: loadedAnswers
        )
        discardUnreferencedMedia(discardedMedia)
    }

    func refreshQuestionList(after delay: TimeInterval = 0) {
        questionSearchTask?.cancel()
        questionSearchTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }
            do {
                try await self.reloadQuestionList()
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    func selectQuestion(_ question: NativeQuestion) -> Bool {
        guard question.id != selectedQuestion?.id else { return true }
        if !questionAnswerDraft.isEmpty || editingQuestionAnswerID != nil {
            guard confirmDiscardQuestionAnswerDraft() else { return false }
        }
        let discardedMedia = questionSession.beginSelecting(question)
        discardUnreferencedMedia(discardedMedia)
        let generation = workspaceGeneration
        let activeStore = store
        Task {
            defer {
                if generation == workspaceGeneration, selectedQuestion?.id == question.id {
                    isLoadingQuestionAnswers = false
                }
            }
            do {
                let loadedAnswers = try await activeStore.listQuestionAnswers(questionID: question.id)
                guard generation == workspaceGeneration, selectedQuestion?.id == question.id else { return }
                questionAnswers = loadedAnswers
                errorMessage = nil
            } catch {
                guard generation == workspaceGeneration else { return }
                errorMessage = error.localizedDescription
            }
        }
        return true
    }

    func selectQuestionTag(_ tag: String?) {
        let normalized = tag?.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedQuestionTag = normalized?.isEmpty == false ? normalized : nil
        refreshQuestionList()
    }

    func clearQuestionFilters() {
        questionSearchText = ""
        selectedQuestionTag = nil
        refreshQuestionList()
    }

    func publishQuestion(title: String, body: String, tagsText: String) async -> Bool {
        guard authorizeFirstPartyModule(
            PublishingFirstPartyModule.id,
            permission: .contentPublish,
            action: "发布问题"
        ) else { return false }
        recordFirstPartyModuleEvent(
            moduleID: PublishingFirstPartyModule.id,
            name: "publishing.requested",
            payload: ["kind": "question"]
        )
        guard !isBackingUp, !isPublishingQuestion else { return false }
        isPublishingQuestion = true
        defer { isPublishingQuestion = false }
        do {
            try FirstPartyPublicationPolicy.validate(.init(
                kind: .question,
                title: title,
                body: body
            ))
            let saved = try await store.saveQuestion(
                title: title,
                body: body,
                tags: NativeQuestionTag.parse(tagsText)
            )
            questionSearchText = ""
            selectedQuestionTag = nil
            try await reloadQuestionList(selecting: saved.id)
            scheduleBackup()
            errorMessage = nil
            recordFirstPartyModuleEvent(
                moduleID: PublishingFirstPartyModule.id,
                name: "publishing.completed",
                payload: ["kind": "question", "id": saved.id]
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func uploadQuestionAnswerPastedImages(_ images: [NSImage]) {
        guard !isBackingUp, !isUploadingMedia, let questionID = selectedQuestion?.id else { return }
        let remaining = max(0, 9 - questionAnswerDraft.images.count)
        guard remaining > 0 else {
            errorMessage = "每个回答最多添加 9 张图片。"
            return
        }
        let imagesToUpload = Array(images.prefix(remaining))
        guard !imagesToUpload.isEmpty else { return }

        let activeStore = store
        Task {
            let generation = beginUpload()
            defer { endUpload() }
            do {
                let uploadedImages = try await NativeMediaUpload.images(
                    imagesToUpload,
                    destination: .questionAnswers,
                    temporaryNamePrefix: "question-answer",
                    store: activeStore
                )
                guard generation == workspaceGeneration, selectedQuestion?.id == questionID else {
                    try? await activeStore.discardUnreferencedMedia(uploadedImages)
                    return
                }
                questionAnswerDraft.images.append(contentsOf: uploadedImages)
                try await refreshActivity()
                scheduleBackup()
                errorMessage = nil
            } catch {
                guard generation == workspaceGeneration else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func removeQuestionAnswerImage(_ image: NativeMedia) {
        questionAnswerDraft.images.removeAll { $0.id == image.id }
        discardUnreferencedMedia([image])
    }

    func beginEditingQuestionAnswer(_ answer: NativeQuestionAnswer) {
        guard !isPublishingQuestionAnswer, answer.questionID == selectedQuestion?.id else { return }
        if !questionAnswerDraft.isEmpty || editingQuestionAnswerID != nil {
            guard confirmDiscardQuestionAnswerDraft() else { return }
        }
        let discardedMedia = questionSession.beginEditing(answer)
        discardUnreferencedMedia(discardedMedia)
        errorMessage = nil
    }

    func cancelQuestionAnswerEditing() {
        guard !isPublishingQuestionAnswer else { return }
        let discardedMedia = questionSession.discardAnswerDraft()
        discardUnreferencedMedia(discardedMedia)
        errorMessage = nil
    }

    func publishQuestionAnswer() async -> Bool {
        guard authorizeFirstPartyModule(
            PublishingFirstPartyModule.id,
            permission: .contentPublish,
            action: "发布回答"
        ) else { return false }
        recordFirstPartyModuleEvent(
            moduleID: PublishingFirstPartyModule.id,
            name: "publishing.requested",
            payload: ["kind": "answer"]
        )
        guard !isBackingUp, !isUploadingMedia, !isPublishingQuestionAnswer,
              let selectedQuestion, !questionAnswerDraft.isEmpty else { return false }
        isPublishingQuestionAnswer = true
        defer { isPublishingQuestionAnswer = false }
        do {
            try FirstPartyPublicationPolicy.validate(.init(
                kind: .answer,
                body: questionAnswerDraft.body,
                attachmentCount: questionAnswerDraft.images.count
            ))
            if let editingQuestionAnswerID, let editingQuestionAnswerUpdatedAt {
                _ = try await store.updateQuestionAnswer(
                    id: editingQuestionAnswerID,
                    body: questionAnswerDraft.body,
                    images: questionAnswerDraft.images,
                    expectedUpdatedAt: editingQuestionAnswerUpdatedAt
                )
            } else {
                _ = try await store.saveQuestionAnswer(
                    questionID: selectedQuestion.id,
                    body: questionAnswerDraft.body,
                    images: questionAnswerDraft.images
                )
            }
            questionSession.discardAnswerDraft()
            try await reloadQuestionList(selecting: selectedQuestion.id)
            scheduleBackup()
            errorMessage = nil
            recordFirstPartyModuleEvent(
                moduleID: PublishingFirstPartyModule.id,
                name: "publishing.completed",
                payload: ["kind": "answer", "questionID": selectedQuestion.id]
            )
            return true
        } catch {
            if let storeError = error as? NativeStoreError,
               case .questionAnswerConflict = storeError {
                try? await reloadQuestionList(selecting: selectedQuestion.id)
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func confirmDiscardQuestionAnswerDraft() -> Bool {
        guard !questionAnswerDraft.isEmpty || editingQuestionAnswerID != nil else { return true }
        let alert = NSAlert()
        alert.messageText = "放弃未发布的回答？"
        alert.informativeText = "当前回答草稿中的 Markdown 内容和图片将被放弃。"
        alert.addButton(withTitle: "放弃")
        alert.addButton(withTitle: "继续编辑")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
