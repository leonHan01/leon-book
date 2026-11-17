import Foundation

extension LocalBlogStore {
    func listAIReadingMessages(context: AIReadingContext) throws -> [AIReadingMessage] {
        try prepare()
        var result: [AIReadingMessage] = []
        try db().query("""
        SELECT id, role, content, provider, model, created_at, is_complete FROM ai_reading_messages
        WHERE context_kind = ? AND context_id = ? ORDER BY sequence ASC
        """, values: [.text(context.kind.rawValue), .text(context.id)]) { row in
            guard let id = row.text(at: 0), let role = row.text(at: 1).flatMap(AIReadingMessage.Role.init(rawValue:)),
                  let content = row.text(at: 2), let provider = row.text(at: 3).flatMap(AIReadingProvider.init(rawValue:)),
                  let model = row.text(at: 4), let createdAt = row.text(at: 5) else { throw AIReadingError.invalidResponse }
            result.append(.init(id: id, role: role, content: content, provider: provider, model: model,
                                createdAt: createdAt, isComplete: row.integer(at: 6) == 1))
        }
        return result
    }

    func saveAIReadingMessage(_ message: AIReadingMessage, context: AIReadingContext) throws {
        try prepare()
        guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              message.content.utf8.count <= AIReadingClient.maximumBytes else { throw AIReadingError.contextTooLarge }
        switch context.kind {
        case .article: _ = try getArticle(slug: context.id)
        case .question: _ = try getQuestion(id: context.id)
        }
        try db().execute("""
        INSERT INTO ai_reading_messages(id, context_kind, context_id, role, content, provider, model, created_at, is_complete)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, values: [.text(message.id), .text(context.kind.rawValue), .text(context.id), .text(message.role.rawValue),
                       .text(message.content), .text(message.provider.rawValue), .text(message.model),
                       .text(message.createdAt), .integer(message.isComplete ? 1 : 0)])
    }

    func clearAIReadingMessages(context: AIReadingContext) throws {
        try prepare()
        try db().execute("DELETE FROM ai_reading_messages WHERE context_kind = ? AND context_id = ?",
                         values: [.text(context.kind.rawValue), .text(context.id)])
    }
}
