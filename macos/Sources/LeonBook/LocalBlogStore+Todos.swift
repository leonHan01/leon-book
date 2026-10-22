import Foundation
import LeonBookTodoModule

extension LocalBlogStore {
    public func listTodos() throws -> [TodoItem] {
        try prepare()
        var items: [TodoItem] = []
        try db().query(todoSelect + " WHERE deleted_at IS NULL ORDER BY created_at DESC, id") { items.append(decodeTodo($0)) }
        return items
    }

    public func getTodo(id: String) throws -> TodoItem {
        try prepare()
        return try readTodo(id: id, includesDeleted: false)
    }

    @discardableResult
    public func saveTodo(_ draft: TodoDraft, id: String? = nil, expectedRevision: Int? = nil) throws -> TodoItem {
        let draft = try draft.validated()
        try prepare()
        if let id {
            guard let expectedRevision, expectedRevision > 0 else { throw TodoError.conflict }
            return try mutateTodo(id: id, revision: expectedRevision,
                assignments: "title = ?, notes = ?, priority = ?, due_day = ?",
                values: [.text(draft.title), .text(draft.notes), .integer(draft.priority.rawValue), draft.dueDay.map(SQLiteValue.text) ?? .null])
        }
        let id = UUID().uuidString.lowercased(), timestamp = NativeTimestamp.string(from: Date())
        try db().execute("""
        INSERT INTO todos(id, title, notes, priority, due_day, created_at, updated_at, revision)
        VALUES (?, ?, ?, ?, ?, ?, ?, 1)
        """, values: [.text(id), .text(draft.title), .text(draft.notes), .integer(draft.priority.rawValue), draft.dueDay.map(SQLiteValue.text) ?? .null, .text(timestamp), .text(timestamp)])
        return try readTodo(id: id, includesDeleted: false)
    }

    @discardableResult
    public func setTodoCompleted(id: String, completed: Bool, expectedRevision: Int) throws -> TodoItem {
        try prepare()
        return try mutateTodo(id: id, revision: expectedRevision, assignments: "completed_at = ?", values: [completed ? .text(NativeTimestamp.string(from: Date())) : .null])
    }

    @discardableResult
    public func deleteTodo(id: String, expectedRevision: Int) throws -> TodoItem {
        try prepare()
        return try mutateTodo(id: id, revision: expectedRevision, assignments: "deleted_at = ?", values: [.text(NativeTimestamp.string(from: Date()))])
    }

    @discardableResult
    public func restoreTodo(id: String, expectedRevision: Int) throws -> TodoItem {
        try prepare()
        return try mutateTodo(id: id, revision: expectedRevision, assignments: "deleted_at = NULL", values: [], restoring: true)
    }

    private var todoSelect: String { "SELECT id, title, notes, priority, due_day, completed_at, created_at, updated_at, revision, deleted_at FROM todos" }

    private func readTodo(id: String, includesDeleted: Bool) throws -> TodoItem {
        var item: TodoItem?
        try db().query(todoSelect + " WHERE id = ?" + (includesDeleted ? "" : " AND deleted_at IS NULL"), values: [.text(id)]) { item = decodeTodo($0) }
        guard let item else { throw TodoError.notFound }
        return item
    }

    private func decodeTodo(_ row: SQLiteRow) -> TodoItem {
        TodoItem(id: row.text(at: 0) ?? "", title: row.text(at: 1) ?? "", notes: row.text(at: 2) ?? "",
                 priority: TodoPriority(rawValue: row.integer(at: 3) ?? 1) ?? .normal, dueDay: row.text(at: 4), completedAt: row.text(at: 5),
                 createdAt: row.text(at: 6) ?? "", updatedAt: row.text(at: 7) ?? "", revision: row.integer(at: 8) ?? 1, deletedAt: row.text(at: 9))
    }

    private func mutateTodo(id: String, revision: Int, assignments: String, values: [SQLiteValue], restoring: Bool = false) throws -> TodoItem {
        var result: TodoItem?
        try db().transaction {
            try db().execute("UPDATE todos SET \(assignments), updated_at = ?, revision = revision + 1 WHERE id = ? AND revision = ? AND deleted_at IS \(restoring ? "NOT NULL" : "NULL")",
                             values: values + [.text(NativeTimestamp.string(from: Date())), .text(id), .integer(revision)])
            guard try db().integer("SELECT changes()") == 1 else { throw TodoError.conflict }
            result = try readTodo(id: id, includesDeleted: true)
        }
        guard let result else { throw TodoError.notFound }
        return result
    }
}
