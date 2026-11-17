import Foundation
@testable import LeonBook

private struct HotQuestionTestFailure: Error { let message: String }

private func hotQuestionExpect(_ condition: Bool, _ message: String) throws {
    if !condition { throw HotQuestionTestFailure(message: message) }
}

final class QAndAHotQuestionsTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HotQuestions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testGlobalHotRankingAndPersistentViews() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        try hotQuestionExpect(try await store.listHotQuestions().isEmpty, "An empty workspace must have an empty ranking")
        var questions: [NativeQuestion] = []
        for index in 0..<12 {
            questions.append(try await store.saveQuestion(title: "Question \(index)", body: "", tags: []))
        }
        let initial = try await store.listHotQuestions()
        try hotQuestionExpect(initial.count == 10, "The global ranking must stop at ten questions")
        try hotQuestionExpect(initial.first?.id == questions[11].id, "Zero-heat questions must favor recent activity")
        for _ in 0..<21 { _ = try await store.recordQuestionView(id: questions[2].id) }
        for _ in 0..<20 { _ = try await store.recordQuestionView(id: questions[3].id) }
        _ = try await store.saveQuestionAnswer(questionID: questions[0].id, body: "First answer")
        _ = try await store.saveQuestionAnswer(questionID: questions[0].id, body: "Second answer")
        _ = try await store.saveQuestionAnswer(questionID: questions[1].id, body: "Most recent answer")

        let ranking = try await store.listHotQuestions()
        try hotQuestionExpect(ranking.count == 10, "Engagement must not change the ranking limit")
        try hotQuestionExpect(
            ranking.prefix(4).map(\.id) == [questions[0].id, questions[2].id, questions[1].id, questions[3].id],
            "Answers and views must both affect heat, with recent activity breaking ties"
        )
        try hotQuestionExpect(ranking.prefix(4).map(\.heatScore) == [40, 21, 20, 20], "Heat must weight an answer as twenty views")
        let viewed = try await store.getQuestion(id: questions[2].id)
        try hotQuestionExpect(viewed.updatedAt == questions[2].updatedAt, "Viewing must not reorder questions by content activity")
        let reopened = LocalBlogStore(rootURL: root)
        try hotQuestionExpect(try await reopened.getQuestion(id: viewed.id).viewCount == 21, "Views must persist across store instances")
        _ = try await reopened.listQuestions()
        _ = try await reopened.listHotQuestions()
        try hotQuestionExpect(try await reopened.getQuestion(id: viewed.id).viewCount == 21, "Reading lists must not count as a detail visit")
        do {
            _ = try await store.recordQuestionView(id: "missing-question")
            throw HotQuestionTestFailure(message: "Viewing a missing question must fail")
        } catch NativeStoreError.notFound {}
    }

    func testLegacyQuestionDatabaseAndJSONRemainReadable() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyDatabase = try SQLiteDatabase(url: root.appendingPathComponent("leon-book.sqlite"))
        try legacyDatabase.execute("""
        CREATE TABLE questions (
            id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL,
            tags_json TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
        );
        INSERT INTO questions VALUES ('legacy-question', 'Legacy', '', '[]', '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z');
        """)
        legacyDatabase.close()
        let store = LocalBlogStore(rootURL: root)
        let legacy = try await store.getQuestion(id: "legacy-question")
        try hotQuestionExpect(legacy.viewCount == 0, "Existing questions must migrate with zero views")
        try hotQuestionExpect(try await store.recordQuestionView(id: legacy.id).viewCount == 1, "Migrated questions must accept views")
        try hotQuestionExpect(try await store.listHotQuestions().first?.id == legacy.id, "Migrated questions must participate in ranking")

        let oldJSON = Data(#"{"id":"old","title":"Old","body":"","tags":[],"createdAt":"2026-09-01","updatedAt":"2026-09-01","answerCount":3}"#.utf8)
        let decoded = try JSONDecoder().decode(NativeQuestion.self, from: oldJSON)
        try hotQuestionExpect(decoded.viewCount == 0 && decoded.answerCount == 3, "Older JSON must retain answers and default views to zero")
        let roundTrip = try JSONDecoder().decode(NativeQuestion.self, from: JSONEncoder().encode(legacy))
        try hotQuestionExpect(roundTrip == legacy, "Question JSON must still round-trip")
    }

    @MainActor
    func testHotQuestionsIgnoreFiltersAndReopeningPreservesDraft() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false, store: LocalBlogStore(rootURL: root))
        let first = try await model.store.saveQuestion(title: "Swift", body: "", tags: ["Swift"])
        let second = try await model.store.saveQuestion(title: "SQLite", body: "", tags: ["SQLite"])
        model.questionSearchText = "Swift"
        model.selectedQuestionTag = "Swift"
        try await model.reloadQuestionList()
        try hotQuestionExpect(model.questions.map(\.id) == [first.id], "The regular list must honor filters")
        try hotQuestionExpect(Set(model.hotQuestions.map(\.id)) == Set([first.id, second.id]), "The hot ranking must remain global")
        try hotQuestionExpect(model.selectQuestion(second), "A hot question outside the current filter must open")
        for _ in 0..<100 where model.selectedQuestion?.viewCount != 1 || model.isLoadingQuestionAnswers {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try hotQuestionExpect(model.selectedQuestion?.viewCount == 1, "Opening a hot question must record one visit")
        model.questionAnswerDraft.body = "Unpublished answer"
        model.editingQuestionAnswerID = "editing-answer"
        try hotQuestionExpect(model.selectQuestion(second), "Returning to the same question must be allowed")
        for _ in 0..<100 where model.selectedQuestion?.viewCount != 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try hotQuestionExpect(model.selectedQuestion?.viewCount == 2, "Reopening the same selected question must count another visit")
        try hotQuestionExpect(model.questionAnswerDraft.body == "Unpublished answer", "Reopening must preserve the answer draft")
        try hotQuestionExpect(model.editingQuestionAnswerID == "editing-answer", "Reopening must preserve answer editing identity")
        try hotQuestionExpect(model.hotQuestions.first?.id == second.id, "A visit must refresh the hot ranking immediately")
        try await model.reloadQuestionList()
        try hotQuestionExpect(model.selectedQuestion?.id == second.id, "Refreshing a filtered list must preserve a selected hot question")
        try hotQuestionExpect(try await model.store.getQuestion(id: second.id).viewCount == 2, "Background reloads must not create visits")

        _ = model.questionSession.applyReload(
            questions: [first], hotQuestions: [second, first], totalCount: 2,
            tagFacets: [], selectedQuestion: second, answers: []
        )
        try hotQuestionExpect(model.selectedQuestion?.viewCount == 2, "An older background snapshot must not roll back a completed visit")
        try hotQuestionExpect(model.hotQuestions.first?.viewCount == 2, "A stale ranking snapshot must retain newer view counts")
    }

    @MainActor
    func testQuestionViewResultDoesNotEnterAnotherWorkspace() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false, store: LocalBlogStore(rootURL: root))
        let question = try await model.store.saveQuestion(title: "Old workspace", body: "", tags: [])
        let visit = model.recordQuestionView(questionID: question.id)
        model.workspaceGeneration += 1
        await visit.value
        try hotQuestionExpect(model.hotQuestions.isEmpty && model.selectedQuestion == nil, "An old visit must not repopulate a new workspace")
        try hotQuestionExpect(try await model.store.getQuestion(id: question.id).viewCount == 1, "The visit must still persist in its original store")
    }
}
