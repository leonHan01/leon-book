import Foundation

extension LocalBlogStore {
    // MARK: - Questions and answers

    public func listQuestions(
        searchText: String = "",
        tag: String? = nil
    ) throws -> [NativeQuestion] {
        try prepare()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawSelectedTag = tag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectedTag = rawSelectedTag.isEmpty ? nil : NativeQuestionTag.identifier(rawSelectedTag)
        var predicates = [contentVisibility("q.is_private")]
        var values: [SQLiteValue] = []

        if query.count >= 3 {
            predicates.append("""
            q.id IN (
                SELECT question_id FROM question_search
                WHERE question_search MATCH ?
            )
            """)
            values.append(.text("\"\(query.replacingOccurrences(of: "\"", with: "\"\""))\""))
        } else if let token = shortSearchToken(for: query) {
            predicates.append("""
            q.id IN (
                SELECT document_id FROM content_short_search
                WHERE content_short_search MATCH ? AND document_type = 'question'
            )
            """)
            values.append(.text("\"\(token.replacingOccurrences(of: "\"", with: "\"\""))\""))
        }
        if let selectedTag {
            predicates.append("""
            EXISTS (
                SELECT 1 FROM question_tags AS selected_tag
                WHERE selected_tag.question_id = q.id
                  AND selected_tag.normalized_tag = ?
            )
            """)
            values.append(.text(selectedTag))
        }

        let whereClause = predicates.isEmpty ? "" : "WHERE " + predicates.joined(separator: " AND ")
        var questions: [NativeQuestion] = []
        try db().query(
            """
            \(questionSelect)
            \(whereClause)
            ORDER BY q.updated_at DESC, q.id DESC
            """,
            values: values
        ) { row in
            questions.append(try decodeQuestion(row))
        }
        return questions
    }

    public func listHotQuestions() throws -> [NativeQuestion] {
        try prepare()
        var questions: [NativeQuestion] = []
        try db().query("""
        \(questionSelect)
        WHERE \(contentVisibility("q.is_private"))
        ORDER BY (
            (SELECT COUNT(*) FROM question_answers AS ranked_answer WHERE ranked_answer.question_id = q.id) * \(NativeQuestion.answerHeatWeight)
            + q.view_count
        ) DESC, q.updated_at DESC, q.id DESC
        LIMIT 10
        """) { row in
            questions.append(try decodeQuestion(row))
        }
        return questions
    }

    public func recordQuestionView(id: String) throws -> NativeQuestion {
        try prepare()
        let safeID = try requireSafeSegment(id, label: "问题 ID")
        _ = try getQuestion(id: safeID)
        try db().execute(
            "UPDATE questions SET view_count = view_count + 1 WHERE id = ?",
            values: [.text(safeID)]
        )
        return try getQuestion(id: safeID)
    }

    public func countQuestions() throws -> Int {
        try prepare()
        return try db().integer("SELECT COUNT(*) FROM questions WHERE \(contentVisibility())") ?? 0
    }

    public func listQuestionTagFacets() throws -> [NativeQuestionTagFacet] {
        try prepare()
        var facets: [NativeQuestionTagFacet] = []
        try db().query("""
        SELECT MIN(tag), COUNT(*)
        FROM question_tags AS tag
        JOIN questions AS q ON q.id = tag.question_id
        WHERE \(contentVisibility("q.is_private"))
        GROUP BY normalized_tag
        ORDER BY COUNT(*) DESC, normalized_tag ASC
        """) { row in
            guard let tag = row.text(at: 0) else {
                throw NativeStoreError.fileSystem(NativeLocalization.text("SQLite：问题标签记录不完整"))
            }
            facets.append(NativeQuestionTagFacet(tag: tag, count: row.integer(at: 1) ?? 0))
        }
        return facets
    }

    public func getQuestion(id: String) throws -> NativeQuestion {
        try prepare()
        let safeID = try requireSafeSegment(id, label: "问题 ID")
        var result: NativeQuestion?
        try db().query(
            questionSelect + " WHERE q.id = ? AND \(contentVisibility("q.is_private"))",
            values: [.text(safeID)]
        ) { row in
            result = try decodeQuestion(row)
        }
        guard let result else { throw NativeStoreError.notFound }
        return result
    }

    public func saveQuestion(
        title: String,
        body: String,
        tags: [String],
        isPrivate: Bool = false
    ) throws -> NativeQuestion {
        try prepare()
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTags = NativeQuestionTag.normalized(tags)
        guard (1...200).contains(normalizedTitle.count) else {
            throw NativeStoreError.invalidQuestion
        }

        let latestQuestionTimestamp = try db().text("SELECT MAX(updated_at) FROM questions")
        let createdAt = nextQuestionTimestamp(after: latestQuestionTimestamp)
        let id = "question-\(Int(Date().timeIntervalSince1970 * 1_000))-\(UUID().uuidString.lowercased().prefix(8))"
        try db().transaction {
            try db().execute("""
            INSERT INTO questions(id, title, body, tags_json, created_at, updated_at, is_private)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, values: [
                .text(id),
                .text(normalizedTitle),
                .text(normalizedBody),
                .text(try jsonString(normalizedTags)),
                .text(createdAt),
                .text(createdAt),
                .integer(isPrivate ? 1 : 0),
            ])
            try replaceQuestionTags(questionID: id, tags: normalizedTags)
            try replaceShortSearchDocument(
                type: "question",
                id: id,
                source: [normalizedTitle, normalizedBody, normalizedTags.joined(separator: " ")],
                isActive: true,
                in: db()
            )
        }
        return NativeQuestion(
            id: id,
            title: normalizedTitle,
            body: normalizedBody,
            tags: normalizedTags,
            createdAt: createdAt,
            updatedAt: createdAt,
            isPrivate: isPrivate
        )
    }

    func setQuestionPrivacy(id: String, isPrivate: Bool, expectedUpdatedAt: String) throws {
        let question = try getQuestion(id: id)
        try db().execute(
            "UPDATE questions SET is_private = ?, updated_at = ? WHERE id = ? AND updated_at = ?",
            values: [.integer(isPrivate ? 1 : 0), .text(nextQuestionTimestamp(after: question.updatedAt)),
                     .text(question.id), .text(expectedUpdatedAt)]
        )
        guard try db().integer("SELECT changes()") == 1 else { throw NativeStoreError.conflict }
    }

    public func listQuestionAnswers(questionID: String) throws -> [NativeQuestionAnswer] {
        try prepare()
        let safeQuestionID = try requireSafeSegment(questionID, label: "问题 ID")
        if !showsPrivateContent,
           try db().integer("SELECT is_private FROM questions WHERE id = ?", values: [.text(safeQuestionID)]) == 1 {
            throw NativeStoreError.notFound
        }
        var answers: [NativeQuestionAnswer] = []
        try db().query(
            questionAnswerSelect + " WHERE question_id = ? ORDER BY created_at ASC, id ASC",
            values: [.text(safeQuestionID)]
        ) { row in
            answers.append(try decodeQuestionAnswer(row))
        }
        return answers
    }

    public func saveQuestionAnswer(
        questionID: String,
        body: String,
        images: [NativeMedia] = []
    ) throws -> NativeQuestionAnswer {
        try prepare()
        let safeQuestionID = try requireSafeSegment(questionID, label: "问题 ID")
        let question = try getQuestion(id: safeQuestionID)
        let content = try normalizedQuestionAnswerContent(body: body, images: images)

        let latestQuestionTimestamp = try db().text("SELECT MAX(updated_at) FROM questions")
        let timestampBaseline = latestQuestionTimestamp.map { max($0, question.updatedAt) } ?? question.updatedAt
        let createdAt = nextQuestionTimestamp(after: timestampBaseline)
        let id = "answer-\(Int(Date().timeIntervalSince1970 * 1_000))-\(UUID().uuidString.lowercased().prefix(8))"
        try db().transaction {
            try db().execute("""
            INSERT INTO question_answers(id, question_id, body, images_json, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """, values: [
                .text(id),
                .text(safeQuestionID),
                .text(content.body),
                .text(try jsonString(content.images)),
                .text(createdAt),
                .text(createdAt),
            ])
            try db().execute(
                "UPDATE questions SET updated_at = ? WHERE id = ?",
                values: [.text(createdAt), .text(safeQuestionID)]
            )
            try replaceMediaReferences(
                ownerType: "answer",
                ownerID: id,
                urls: content.images.map(\.url) + embeddedMediaURLs(in: content.body),
                in: db()
            )
        }
        return NativeQuestionAnswer(
            id: id,
            questionID: safeQuestionID,
            body: content.body,
            images: content.images,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    public func updateQuestionAnswer(
        id: String,
        body: String,
        images: [NativeMedia] = [],
        expectedUpdatedAt: String
    ) throws -> NativeQuestionAnswer {
        try prepare()
        let safeID = try requireSafeSegment(id, label: "回答 ID")
        guard let previous = try questionAnswer(withID: safeID) else {
            throw NativeStoreError.notFound
        }
        _ = try getQuestion(id: previous.questionID)
        guard previous.updatedAt == expectedUpdatedAt else {
            throw NativeStoreError.questionAnswerConflict
        }
        let content = try normalizedQuestionAnswerContent(body: body, images: images)
        let latestQuestionTimestamp = try db().text("SELECT MAX(updated_at) FROM questions")
        let timestampBaseline = latestQuestionTimestamp.map { max($0, previous.updatedAt) }
            ?? previous.updatedAt
        let updatedAt = nextQuestionTimestamp(after: timestampBaseline)
        let updated = NativeQuestionAnswer(
            id: previous.id,
            questionID: previous.questionID,
            body: content.body,
            images: content.images,
            createdAt: previous.createdAt,
            updatedAt: updatedAt
        )

        try db().transaction {
            try db().execute("""
            UPDATE question_answers
            SET body = ?, images_json = ?, updated_at = ?
            WHERE id = ? AND updated_at = ?
            """, values: [
                .text(updated.body),
                .text(try jsonString(updated.images)),
                .text(updated.updatedAt),
                .text(updated.id),
                .text(expectedUpdatedAt),
            ])
            guard try db().integer("SELECT changes()") == 1 else {
                throw NativeStoreError.questionAnswerConflict
            }
            try db().execute(
                "UPDATE questions SET updated_at = ? WHERE id = ?",
                values: [.text(updated.updatedAt), .text(updated.questionID)]
            )
            try replaceMediaReferences(
                ownerType: "answer",
                ownerID: updated.id,
                urls: updated.images.map(\.url) + embeddedMediaURLs(in: updated.body),
                in: db()
            )
        }
        try removeUnreferencedMediaFiles(previous.images, includingDeleted: true)
        return updated
    }

    private func allQuestionAnswers() throws -> [NativeQuestionAnswer] {
        var answers: [NativeQuestionAnswer] = []
        try db().query(questionAnswerSelect) { row in
            answers.append(try decodeQuestionAnswer(row))
        }
        return answers
    }

    private func questionAnswer(withID id: String) throws -> NativeQuestionAnswer? {
        var answer: NativeQuestionAnswer?
        try db().query(
            questionAnswerSelect + " WHERE id = ?",
            values: [.text(id)]
        ) { row in
            answer = try decodeQuestionAnswer(row)
        }
        return answer
    }

    private func normalizedQuestionAnswerContent(
        body: String,
        images: [NativeMedia]
    ) throws -> (body: String, images: [NativeMedia]) {
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedImages = Array(images
            .filter { $0.isImage && !$0.url.isEmpty }
            .map(normalizeMedia)
            .prefix(9))
        guard normalizedBody.count <= 10_000,
              !normalizedBody.isEmpty || !normalizedImages.isEmpty else {
            throw NativeStoreError.invalidAnswer
        }
        return (normalizedBody, normalizedImages)
    }

    private func replaceQuestionTags(questionID: String, tags: [String]) throws {
        try db().execute(
            "DELETE FROM question_tags WHERE question_id = ?",
            values: [.text(questionID)]
        )
        for tag in tags {
            try db().execute("""
            INSERT INTO question_tags(question_id, tag, normalized_tag)
            VALUES (?, ?, ?)
            """, values: [
                .text(questionID),
                .text(tag),
                .text(NativeQuestionTag.identifier(tag)),
            ])
        }
    }

    private func decodeQuestion(_ row: SQLiteRow) throws -> NativeQuestion {
        guard let id = row.text(at: 0),
              let title = row.text(at: 1),
              let body = row.text(at: 2),
              let tagsJSON = row.text(at: 3),
              let createdAt = row.text(at: 4),
              let updatedAt = row.text(at: 5) else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("SQLite：问题记录不完整"))
        }
        return NativeQuestion(
            id: id,
            title: title,
            body: body,
            tags: try decode(tagsJSON),
            createdAt: createdAt,
            updatedAt: updatedAt,
            answerCount: row.integer(at: 6) ?? 0,
            viewCount: row.integer(at: 7) ?? 0,
            isPrivate: row.integer(at: 8) == 1
        )
    }

    private func decodeQuestionAnswer(_ row: SQLiteRow) throws -> NativeQuestionAnswer {
        guard let id = row.text(at: 0),
              let questionID = row.text(at: 1),
              let body = row.text(at: 2),
              let imagesJSON = row.text(at: 3),
              let createdAt = row.text(at: 4),
              let updatedAt = row.text(at: 5) else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("SQLite：问题回答记录不完整"))
        }
        return NativeQuestionAnswer(
            id: id,
            questionID: questionID,
            body: body,
            images: try decode(imagesJSON),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func nextQuestionTimestamp(after previous: String?) -> String {
        let candidate = nextTimestamp(after: previous)
        guard let previous, candidate <= previous,
              let previousDate = NativeTimestamp.date(from: previous) else {
            return candidate
        }
        return timestamp(from: previousDate.addingTimeInterval(0.001))
    }
}
