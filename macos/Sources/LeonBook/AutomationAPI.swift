import Foundation

/// Versioned wire types shared by the CLI and the app's local socket endpoint.
public enum AutomationValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([AutomationValue]), object([String: AutomationValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: Self].self) { self = .object(v) }
        else { self = .array(try c.decode([Self].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    static func encoded<T: Encodable>(_ value: T) throws -> Self {
        try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }

    func decoded<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

public struct AutomationRequest: Codable, Sendable {
    public var id: AutomationValue?
    public var method: String
    public var params: [String: AutomationValue]?
    public var userID: String?

    public init(id: AutomationValue? = nil, method: String, params: [String: AutomationValue] = [:], userID: String? = nil) {
        self.id = id; self.method = method; self.params = params; self.userID = userID
    }

    private enum CodingKeys: String, CodingKey { case id, method, params, userID }

    public init(from decoder: Decoder) throws {
        // A misspelled userID must never silently fall back to the active user.
        let values = try decoder.singleValueContainer().decode([String: AutomationValue].self)
        let unknown = Set(values.keys).subtracting(["id", "method", "params", "userID"])
        guard unknown.isEmpty else {
            throw AutomationFailure("invalid_request", "Unknown request field(s): \(unknown.sorted().joined(separator: ", ")); use id, method, params and userID.")
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(AutomationValue.self, forKey: .id)
        method = try container.decode(String.self, forKey: .method)
        params = try container.decodeIfPresent([String: AutomationValue].self, forKey: .params)
        userID = try container.decodeIfPresent(String.self, forKey: .userID)
    }
}

public struct AutomationFailure: Error, Codable, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public var errorDescription: String? { message }

    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

public struct AutomationResponse: Codable, Sendable {
    public let apiVersion: Int
    public let id: AutomationValue?
    public let result: AutomationValue?
    public let error: AutomationFailure?

    public init(id: AutomationValue? = nil, result: AutomationValue? = nil, error: AutomationFailure? = nil) {
        apiVersion = 1; self.id = id; self.result = result; self.error = error
    }
}

struct AutomationParameters {
    let values: [String: AutomationValue]

    func optional<T: Decodable>(_ key: String, as: T.Type = T.self) throws -> T? {
        guard let value = values[key], value != .null else { return nil }
        do { return try value.decoded(T.self) }
        catch { throw AutomationFailure("invalid_params", "Invalid value for '\(key)': \(error.localizedDescription)") }
    }

    func required<T: Decodable>(_ key: String, as: T.Type = T.self) throws -> T {
        guard let value: T = try optional(key) else { throw AutomationFailure("invalid_params", "Missing '\(key)'") }
        return value
    }

    func string(_ key: String, default fallback: String = "") throws -> String { try optional(key) ?? fallback }
    func flag(_ key: String, default fallback: Bool = false) throws -> Bool { try optional(key) ?? fallback }
    func integer(_ key: String, default fallback: Int) throws -> Int { try optional(key) ?? fallback }
    func confirm() throws {
        guard try flag("confirm") else { throw AutomationFailure("confirmation_required", "This operation requires confirm: true.") }
    }
}

struct AutomationOperation: Encodable {
    let method: String
    let description: String
    let mutates: Bool
    /// Compact type contract: a trailing ! marks required fields.
    let parameters: [String: String]

    init(_ method: String, _ description: String, _ mutates: Bool = false, _ parameters: [String: String] = [:]) {
        self.method = method; self.description = description; self.mutates = mutates; self.parameters = parameters
    }

    func validate(_ values: [String: AutomationValue]) throws {
        let unknown = Set(values.keys).subtracting(parameters.keys)
        guard unknown.isEmpty else { throw AutomationFailure("invalid_params", "Unknown parameter(s): \(unknown.sorted().joined(separator: ", "))") }
        for (name, type) in parameters where type.hasSuffix("!") {
            guard let value = values[name], value != .null else { throw AutomationFailure("invalid_params", "Missing '\(name)'") }
        }
        for (name, value) in values where value == .null && parameters[name]?.contains("|null") != true {
            throw AutomationFailure("invalid_params", "'\(name)' cannot be null; omit it to preserve its value")
        }
    }
}

enum AutomationCatalog {
    static func examples() throws -> AutomationValue {
        let timestamp = "2026-01-01T00:00:00.000Z"
        return .object([
            "NativeMedia": try .encoded(NativeMedia(kind: "image", name: "photo.png", size: 1024, url: "/media/moments/example.png")),
            "NativeBanner": try .encoded(NativeBanner(alt: "Cover", name: "photo.png", size: 1024, url: "/media/inbox/example.png")),
            "NativeMomentTextRun": try .encoded(NativeMomentTextRun(text: "Hello", bold: true, color: nil)),
            "NativeArticleCommentSelection": try .encoded(NativeArticleCommentSelection(quote: "Quoted text", anchorID: "heading-id")),
            "NativeArticlePropertyValue": try .encoded(["owner": NativeArticlePropertyValue.text("leon"), "score": .number(3), "done": .checkbox(false), "tags": .tags(["AI"])]),
            "NativeSmartCollection": try .encoded(NativeSmartCollection(id: "example-collection", name: "Published", rules: [.init(field: .status, comparison: .equals, value: "published")], createdAt: timestamp, updatedAt: timestamp)),
            "NativeBookmark": try .encoded(NativeBookmark(id: "example-bookmark", title: "An article", target: .article(slug: "example"), createdAt: timestamp)),
        ])
    }

    static let articleFields = ["title": "string", "body": "string (HTML, Markdown or plain text)", "format": "html|markdown|text", "category": "string", "excerpt": "string", "tags": "string[]", "properties": "NativeArticlePropertyValue map", "banner": "NativeBanner|null", "media": "NativeMedia[]", "status": "draft|published"]
    static let operations: [AutomationOperation] = [
        .init("capabilities", "Discover every supported operation and its parameter contract."),
        .init("app.commands", "List commands in an open app window, including availability.", false, ["windowID": "string"]),
        .init("app.execute", "Dispatch a command to an open window. Returns accepted, not async completion.", true, ["command": "string!", "arguments": "string map", "windowID": "string"]),
        .init("workspace.info", "Current user, available users and data paths."),
        .init("users.list", "List local users."),
        .init("users.create", "Create a user and select it in the local registry.", true, ["name": "string!"]),
        .init("users.select", "Select the default user for subsequent requests.", true, ["id": "string!"]),
        .init("articles.list", "List article summaries; defaults: offset 0, limit 100.", false, ["includeDrafts": "boolean", "offset": "integer", "limit": "integer"]),
        .init("articles.get", "Read full content and updatedAt for optimistic concurrency.", false, ["slug": "string!"]),
        .init("articles.create", "Create a saved article. Defaults to draft; body is converted to native HTML.", true, articleFields.merging(["title": "string!", "body": "string!", "slug": "string", "sourceRelativePath": "string"]) { _, new in new }),
        .init("articles.update", "Patch supplied fields, preserving all omitted metadata.", true, articleFields.merging(["slug": "string!", "expectedUpdatedAt": "string!"]) { _, new in new }),
        .init("articles.publish", "Publish an existing article to this app's local library.", true, ["slug": "string!", "expectedUpdatedAt": "string!"]),
        .init("articles.unpublish", "Move a published article back to drafts.", true, ["slug": "string!", "expectedUpdatedAt": "string!"]),
        .init("articles.delete", "Move an article to trash.", true, ["slug": "string!", "expectedUpdatedAt": "string!"]),
        .init("articles.move", "Move/rename the article's source file.", true, ["slug": "string!", "path": "string!", "expectedUpdatedAt": "string!"]),
        .init("articles.revisions", "Read saved versions including snapshots.", false, ["slug": "string!"]),
        .init("articles.restoreRevision", "Save a historical snapshot as the current article.", true, ["slug": "string!", "revisionID": "integer!", "expectedUpdatedAt": "string!"]),
        .init("articles.relations", "Read backlinks, outgoing links and unlinked mentions.", false, ["slug": "string!"]),
        .init("articles.graph", "Read the article graph."),
        .init("properties.rename", "Rename an article property throughout the workspace.", true, ["from": "string!", "to": "string!"]),
        .init("articleComments.list", "List article comments and replies.", false, ["slug": "string!"]),
        .init("articleComments.create", "Comment or reply on an article.", true, ["slug": "string!", "text": "string!", "parentID": "string", "selection": "NativeArticleCommentSelection"]),
        .init("articleComments.delete", "Delete a comment and its replies.", true, ["slug": "string!", "id": "string!"]),
        .init("moments.list", "List local microblog posts, newest first.", false, ["offset": "integer", "limit": "integer"]),
        .init("moments.get", "Read a local microblog post.", false, ["id": "string!"]),
        .init("moments.create", "Publish to the app's local microblog timeline (not sina.com).", true, ["text": "string", "textRuns": "NativeMomentTextRun[]", "images": "NativeMedia[]"]),
        .init("moments.update", "Patch a microblog post with version protection.", true, ["id": "string!", "expectedUpdatedAt": "string!", "text": "string", "textRuns": "NativeMomentTextRun[]", "images": "NativeMedia[]"]),
        .init("moments.favorite", "Set a microblog favorite.", true, ["id": "string!", "isFavorite": "boolean!"]),
        .init("moments.delete", "Move a microblog post to trash with version protection.", true, ["id": "string!", "expectedUpdatedAt": "string!"]),
        .init("momentComments.list", "List microblog comments.", false, ["momentID": "string!"]),
        .init("momentComments.create", "Comment or reply on a microblog post.", true, ["momentID": "string!", "text": "string!", "parentID": "string"]),
        .init("momentComments.delete", "Delete a comment and its replies.", true, ["momentID": "string!", "id": "string!"]),
        .init("questions.list", "Find questions.", false, ["search": "string", "tag": "string"]),
        .init("questions.get", "Read a question.", false, ["id": "string!"]),
        .init("questions.create", "Publish a question.", true, ["title": "string!", "body": "string", "tags": "string[]"]),
        .init("answers.list", "Read answers to a question.", false, ["questionID": "string!"]),
        .init("answers.create", "Publish an answer.", true, ["questionID": "string!", "body": "string", "images": "NativeMedia[]"]),
        .init("answers.update", "Replace answer body and images with version protection.", true, ["id": "string!", "body": "string!", "images": "NativeMedia[]!", "expectedUpdatedAt": "string!"]),
        .init("todos.list", "List tasks, including completed tasks."),
        .init("todos.get", "Read a task and its revision.", false, ["id": "string!"]),
        .init("todos.create", "Create a task; priority: 0 low, 1 normal, 2 high.", true, ["title": "string!", "notes": "string", "priority": "integer", "dueDay": "YYYY-MM-DD|null"]),
        .init("todos.update", "Patch a task, retaining omitted fields.", true, ["id": "string!", "expectedRevision": "integer!", "title": "string", "notes": "string", "priority": "integer", "dueDay": "YYYY-MM-DD|null"]),
        .init("todos.complete", "Complete or reopen a task.", true, ["id": "string!", "expectedRevision": "integer!", "completed": "boolean!"]),
        .init("todos.delete", "Delete a task, returning the revision needed to restore it.", true, ["id": "string!", "expectedRevision": "integer!"]),
        .init("todos.restore", "Restore a deleted task.", true, ["id": "string!", "expectedRevision": "integer!"]),
        .init("search", "Full-text search across content.", false, ["query": "string!", "limit": "integer"]),
        .init("resources.list", "List folders, article files and attachments."),
        .init("folders.create", "Create a folder (maximum depth 5).", true, ["path": "string!"]),
        .init("resources.move", "Move source files or folders.", true, ["from": "string!", "to": "string!"]),
        .init("resources.trash", "Move source files/folders to trash.", true, ["paths": "string[]!"]),
        .init("media.upload", "Copy a local media file into this user's workspace.", true, ["path": "absolute path!", "kind": "image|video|audio|file!", "slug": "string"]),
        .init("collections.list", "List smart collection definitions."),
        .init("collections.save", "Create or replace a smart collection.", true, ["collection": "NativeSmartCollection!"]),
        .init("collections.query", "Read articles matching a saved collection.", false, ["id": "string!"]),
        .init("collections.delete", "Delete a collection definition.", true, ["id": "string!"]),
        .init("bookmarks.list", "List bookmarks."),
        .init("bookmarks.save", "Create or replace a bookmark.", true, ["bookmark": "NativeBookmark!"]),
        .init("bookmarks.delete", "Delete a bookmark.", true, ["id": "string!"]),
        .init("trash.list", "List restorable articles and microblog posts."),
        .init("trash.restore", "Restore an item by its trash id.", true, ["id": "string!"]),
        .init("trash.delete", "Permanently delete one trash item.", true, ["id": "string!", "confirm": "boolean!"]),
        .init("trash.empty", "Permanently empty trash.", true, ["confirm": "boolean!"]),
        .init("activity.list", "Read daily activity since an ISO-8601 timestamp.", false, ["since": "string!"]),
        .init("workspace.sync", "Refresh external source files and sidecars.", true),
        .init("backup.create", "Create a consistent snapshot of the entire data root, including all users.", true, ["destination": "absolute path!"]),
        .init("backup.list", "List snapshots in a backup directory.", false, ["destination": "absolute path!"]),
        .init("backup.validate", "Validate a snapshot's checksums.", false, ["path": "absolute path!"]),
    ]
}
