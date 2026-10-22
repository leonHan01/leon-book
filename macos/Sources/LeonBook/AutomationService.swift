import Foundation
import LeonBookBackupModule
import LeonBookModuleKit
import LeonBookTodoModule

/// No UI dependency: all automation writes pass through the same store as the app.
public actor AutomationService {
    public let rootURL: URL
    private let users: UserWorkspaceStore
    private var stores: [String: LocalBlogStore] = [:]
    private let defaults: UserDefaults
    private var handlingRequest = false
    var didMutate: (@Sendable (URL) async -> Void)?

    public init(rootURL: URL, defaults: UserDefaults = .standard) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        users = UserWorkspaceStore(rootURL: self.rootURL)
        self.defaults = defaults
    }

    func setMutationHandler(_ handler: @escaping @Sendable (URL) async -> Void) { didMutate = handler }

    public func close() async {
        for store in stores.values { await store.closeForRestore() }
        stores.removeAll()
        await users.closeForRestore()
    }

    public func handle(_ request: AutomationRequest) async -> AutomationResponse {
        // Actors are reentrant across store awaits. Reject overlapping calls rather
        // than allowing a backup or multi-step operation to interleave with writes.
        guard !handlingRequest else { return .init(id: request.id, error: .init("busy", "Another automation request is running.")) }
        handlingRequest = true
        defer { handlingRequest = false }
        do {
            guard let operation = AutomationCatalog.operations.first(where: { $0.method == request.method }) else {
                throw AutomationFailure("method_not_found", "Unknown method '\(request.method)'; call capabilities.")
            }
            let p = AutomationParameters(values: request.params ?? [:])
            try operation.validate(p.values)
            if request.method == "capabilities" {
                return .init(id: request.id, result: .object([
                    "operations": try .encoded(AutomationCatalog.operations),
                    "microblogDestination": .string("local LeonBook timeline"),
                    "request": .string("{id?, method, params?, userID?}; one response per request"),
                    "examples": try AutomationCatalog.examples(),
                ]))
            }
            try validateDataRoot()
            try authorize(request.method, p)
            if request.method.hasPrefix("app.") {
                let result = try await NativeWorkspaceWindows.automationCommand(request, root: rootURL)
                return .init(id: request.id, result: result)
            }
            let state = try await users.prepare()
            if request.method == "users.list" { return .init(id: request.id, result: try .encoded(state.users)) }
            if request.method == "users.create" || request.method == "users.select" {
                let next = request.method == "users.create"
                    ? try await users.createUser(named: p.required("name"))
                    : try await users.selectUser(id: p.required("id"))
                return .init(id: request.id, result: try workspaceInfo(next))
            }
            let userID = request.userID ?? state.activeUser.id
            guard let user = state.users.first(where: { $0.id == userID }) else {
                throw AutomationFailure("not_found", "Unknown userID '\(userID)'.")
            }
            let workspace = rootURL.appendingPathComponent("workspaces", isDirectory: true).appendingPathComponent(user.id, isDirectory: true)
            let store: LocalBlogStore
            if let existing = stores[user.id] { store = existing }
            else { store = LocalBlogStore(rootURL: workspace); stores[user.id] = store }
            if request.method == "workspace.info" {
                return .init(id: request.id, result: .object([
                    "root": .string(rootURL.path), "workspace": .string(workspace.path),
                    "user": try .encoded(user), "users": try .encoded(state.users),
                ]))
            }
            let result = try await execute(request.method, p, store, user)
            if operation.mutates { await didMutate?(workspace) }
            return .init(id: request.id, result: result)
        } catch {
            return .init(id: request.id, error: Self.failure(error))
        }
    }

    private func workspaceInfo(_ state: NativeWorkspaceState) throws -> AutomationValue {
        .object(["root": .string(rootURL.path), "workspace": .string(state.workspaceURL.path), "user": try .encoded(state.activeUser), "users": try .encoded(state.users)])
    }

    private func validateDataRoot() throws {
        // UserWorkspaceStore.prepare migrates legacy content into workspaces/leon.
        // Detect a registered workspace (including its descendants) before that
        // code can interpret an accidental --root as a legacy data root.
        var candidate = rootURL
        while candidate.path != "/" {
            let parent = candidate.deletingLastPathComponent()
            let registryRoot = candidate.lastPathComponent == "workspaces" ? parent : parent.deletingLastPathComponent()
            if candidate.lastPathComponent == "workspaces" || parent.lastPathComponent == "workspaces" {
                let registry = registryRoot.appendingPathComponent("users.json")
                if let data = try? Data(contentsOf: registry),
                   let registered = try? JSONDecoder().decode([NativeUser].self, from: data),
                   !registered.isEmpty,
                   candidate.lastPathComponent == "workspaces" || registered.contains(where: { $0.id == candidate.lastPathComponent }) {
                    throw AutomationFailure("invalid_root", "--root must be the data root '\(registryRoot.path)', not workspaces/ or a user's workspace. Select the user with --user.")
                }
            }
            candidate = parent
        }
    }

    private func authorize(_ method: String, _ p: AutomationParameters) throws {
        let module: String?
        if method.hasPrefix("todos.") { module = "todo" }
        else if method == "search" { module = "search" }
        else if method == "articles.graph" || method == "articles.relations" { module = "knowledge-graph" }
        else if method.hasPrefix("backup.") { module = "backup" }
        else if try ["articles.publish", "articles.restoreRevision", "moments.create", "moments.update", "questions.create", "answers.create", "answers.update"].contains(method) || p.optional("status", as: String.self) == "published" { module = "publishing" }
        else { module = nil }
        if let module, !NativeFirstPartyModules.loadRuntime(defaults: defaults).isEnabled(FirstPartyModuleID(rawValue: module)) {
            throw AutomationFailure("module_disabled", "The '\(module)' module is disabled in app settings.")
        }
    }

    private func execute(_ method: String, _ p: AutomationParameters, _ store: LocalBlogStore, _ user: NativeUser) async throws -> AutomationValue {
        switch method {
        case "articles.list": return try page(await store.listArticles(includeDrafts: p.flag("includeDrafts", default: true)), p)
        case "articles.get": return try .encoded(await store.getArticle(slug: p.required("slug")))
        case "articles.create", "articles.update", "articles.publish", "articles.unpublish":
            if method == "articles.update", try p.optional("status", as: String.self) != "draft",
               try await store.getArticle(slug: p.required("slug")).status == .published {
                try authorize("articles.publish", p)
            }
            return try .encoded(await store.automationSaveArticle(method: method, parameters: p))
        case "articles.delete": try await store.deleteArticle(slug: p.required("slug"), expectedUpdatedAt: p.required("expectedUpdatedAt"))
        case "articles.move": return try .encoded(await store.moveArticleSource(slug: p.required("slug"), to: p.required("path"), expectedUpdatedAt: p.required("expectedUpdatedAt")))
        case "articles.revisions":
            let slug: String = try p.required("slug")
            return .array(try await store.listArticleRevisions(articleSlug: slug, draftKey: slug).map { revision in
                .object(["id": .number(Double(revision.id)), "reason": .string(revision.reason.rawValue), "createdAt": .string(revision.createdAt), "updatedAt": .string(revision.updatedAt), "snapshot": try .encoded(revision.snapshot)])
            })
        case "articles.restoreRevision": return try .encoded(await store.automationRestoreRevision(p))
        case "articles.relations":
            let relations = try await store.articleRelations(for: p.required("slug"))
            return .object(["incoming": try .encoded(relations.incoming), "outgoing": try .encoded(relations.outgoing), "unlinkedMentions": .array(try relations.unlinkedMentions.map { .object(["article": try .encoded($0.article), "count": .number(Double($0.count)), "snippet": .string($0.snippet)]) })])
        case "articles.graph":
            let graph = try await store.articleGraph()
            return .object(["nodes": try .encoded(graph.nodes), "edges": .array(graph.edges.map { .object(["sourceSlug": .string($0.sourceSlug), "targetSlug": .string($0.targetSlug)]) })])
        case "properties.rename": return .number(Double(try await store.renameArticleProperty(from: p.required("from"), to: p.required("to"))))
        case "articleComments.list": return try .encoded(await store.listArticleComments(articleSlug: p.required("slug")))
        case "articleComments.create": return try .encoded(await store.createArticleComment(articleSlug: p.required("slug"), authorName: user.name, text: p.required("text"), selection: p.optional("selection"), parentID: p.optional("parentID")))
        case "articleComments.delete": try await store.deleteArticleComment(id: p.required("id"), articleSlug: p.required("slug"))
        case "moments.list": return try page(await store.listMoments(), p)
        case "moments.get": return try .encoded(await store.getMoment(id: p.required("id")))
        case "moments.create": return try .encoded(await store.saveMoment(text: p.string("text"), textRuns: p.optional("textRuns") ?? [], images: p.optional("images") ?? []))
        case "moments.update", "moments.delete": return try await store.automationMutateMoment(method: method, parameters: p)
        case "moments.favorite": return try .encoded(await store.setMomentFavorite(id: p.required("id"), isFavorite: p.required("isFavorite")))
        case "momentComments.list": return try .encoded(await store.listMomentComments(momentID: p.required("momentID")))
        case "momentComments.create": return try .encoded(await store.createMomentComment(momentID: p.required("momentID"), authorName: user.name, text: p.required("text"), parentID: p.optional("parentID")))
        case "momentComments.delete": try await store.deleteMomentComment(id: p.required("id"), momentID: p.required("momentID"))
        case "questions.list": return try .encoded(await store.listQuestions(searchText: p.string("search"), tag: p.optional("tag")))
        case "questions.get": return try .encoded(await store.getQuestion(id: p.required("id")))
        case "questions.create": return try .encoded(await store.saveQuestion(title: p.required("title"), body: p.string("body"), tags: p.optional("tags") ?? []))
        case "answers.list": return try .encoded(await store.listQuestionAnswers(questionID: p.required("questionID")))
        case "answers.create": return try .encoded(await store.saveQuestionAnswer(questionID: p.required("questionID"), body: p.string("body"), images: p.optional("images") ?? []))
        case "answers.update": return try .encoded(await store.updateQuestionAnswer(id: p.required("id"), body: p.required("body"), images: p.required("images"), expectedUpdatedAt: p.required("expectedUpdatedAt")))
        case "todos.list": return try .encoded(await store.listTodos())
        case "todos.get": return try .encoded(await store.getTodo(id: p.required("id")))
        case "todos.create", "todos.update": return try .encoded(await store.automationSaveTodo(p))
        case "todos.complete": return try .encoded(await store.setTodoCompleted(id: p.required("id"), completed: p.required("completed"), expectedRevision: p.required("expectedRevision")))
        case "todos.delete": return try .encoded(await store.deleteTodo(id: p.required("id"), expectedRevision: p.required("expectedRevision")))
        case "todos.restore": return try .encoded(await store.restoreTodo(id: p.required("id"), expectedRevision: p.required("expectedRevision")))
        case "search":
            let limit = try p.integer("limit", default: 60)
            guard (1...1000).contains(limit) else { throw AutomationFailure("invalid_params", "limit must be 1...1000") }
            return .array(try await store.search(p.required("query"), limit: limit).map { item in
                .object(["documentType": .string(item.documentType.rawValue), "documentID": .string(item.documentID), "title": .string(item.title), "snippet": .string(item.snippet), "tags": try .encoded(item.tags), "timestamp": .string(item.timestamp)])
            })
        case "resources.list": return .array(try await store.listWorkspaceResources().map(resource))
        case "folders.create": try await store.createWorkspaceFolder(relativePath: p.required("path"))
        case "resources.move": _ = try await store.moveWorkspaceSourceItems([.init(sourceRelativePath: p.required("from"), destinationRelativePath: p.required("to"))])
        case "resources.trash": _ = try await store.trashWorkspaceSourceItems(relativePaths: p.required("paths"))
        case "media.upload":
            let kind: String = try p.required("kind")
            guard ["image", "video", "audio", "file"].contains(kind) else { throw AutomationFailure("invalid_params", "kind must be image, video, audio or file") }
            return try .encoded(await store.uploadMedia(fileURL: absoluteURL(p.required("path")), kind: kind, slug: p.optional("slug")))
        case "collections.list": return try .encoded(await store.listSmartCollections())
        case "collections.save": return try .encoded(await store.saveSmartCollection(p.required("collection")))
        case "collections.query":
            let id: String = try p.required("id")
            guard let collection = try await store.listSmartCollections().first(where: { $0.id == id }) else { throw NativeStoreError.notFound }
            return try .encoded(await store.listArticles(in: collection))
        case "collections.delete": try await store.deleteSmartCollection(id: p.required("id"))
        case "bookmarks.list": return try .encoded(await store.listBookmarks())
        case "bookmarks.save": return try .encoded(await store.saveBookmark(p.required("bookmark")))
        case "bookmarks.delete": try await store.deleteBookmark(id: p.required("id"))
        case "trash.list": return .array(try await store.listTrash().map { .object(["id": .string($0.id), "kind": .string($0.kind.rawValue), "key": .string($0.key), "title": .string($0.title), "deletedAt": .string($0.deletedAt), "expiresAt": .string($0.expiresAt)]) })
        case "trash.restore", "trash.delete":
            if method == "trash.delete" { try p.confirm() }
            let id: String = try p.required("id")
            guard let item = try await store.listTrash().first(where: { $0.id == id }) else { throw NativeStoreError.notFound }
            if method == "trash.restore" { try await store.restoreTrash(item) }
            else { try await store.permanentlyDeleteTrash(item) }
        case "trash.empty": try p.confirm(); try await store.emptyTrash()
        case "activity.list":
            guard let date = NativeTimestamp.date(from: try p.required("since")) else { throw AutomationFailure("invalid_params", "since must be an ISO-8601 timestamp") }
            return .array(try await store.listActivity(since: date).map { .object(["date": .string($0.date), "count": .number(Double($0.count))]) })
        case "workspace.sync":
            let sync = try await store.refreshMarkdownSources()
            _ = try await store.synchronizePortableSidecar()
            return .object(["changed": .bool(sync.didChange), "warnings": try .encoded(sync.warnings)])
        case "backup.create":
            let destination = try absoluteURL(p.required("destination"))
            try LocalBackupManager.validateDestination(source: rootURL, destination: destination)
            // Keep an independent registry lease while suspending/closing all
            // user and content connections. This matches whole-library UI backups.
            let lease = try ExclusiveDirectoryLock(directory: rootURL)
            let suspension = try WorkspaceStorageLifecycle.suspend(in: rootURL)
            defer { suspension.finish(); withExtendedLifetime(lease) {} }
            try await suspension.prepareAndClose()
            let snapshot = try LocalBackupManager.createSnapshot(source: rootURL, destination: destination)
            return .object(["path": .string(snapshot.path), "scope": .string("entire data root")])
        case "backup.list": return .array(try LocalBackupManager.listSnapshots(in: absoluteURL(p.required("destination"))).map { .object(["path": .string($0.url.path), "createdAt": .string(NativeTimestamp.string(from: $0.createdAt)), "fileCount": .number(Double($0.fileCount))]) })
        case "backup.validate":
            let validation = try LocalBackupManager.validateSnapshot(at: absoluteURL(p.required("path")))
            return .object(["verifiedChecksums": .bool(validation.verifiedChecksums), "checkedFileCount": .number(Double(validation.checkedFileCount))])
        default: throw AutomationFailure("method_not_found", "Unknown method")
        }
        return .object(["ok": .bool(true)])
    }

    private func resource(_ node: NativeWorkspaceResourceNode) -> AutomationValue {
        .object(["id": .string(node.id), "kind": .string(node.kind.rawValue), "name": .string(node.name), "relativePath": .string(node.relativePath), "absolutePath": .string(node.absolutePath), "articleSlug": node.articleSlug.map(AutomationValue.string) ?? .null, "children": .array(node.children.map(resource))])
    }

    private func page<T: Encodable>(_ items: [T], _ p: AutomationParameters) throws -> AutomationValue {
        let offset = try p.integer("offset", default: 0), limit = try p.integer("limit", default: 100)
        guard offset >= 0, (1...1000).contains(limit) else { throw AutomationFailure("invalid_params", "offset must be >= 0 and limit must be 1...1000") }
        let slice = Array(items.dropFirst(offset).prefix(limit))
        return .object(["items": try .encoded(slice), "total": .number(Double(items.count)), "offset": .number(Double(offset)), "hasMore": .bool(offset < items.count && slice.count < items.count - offset)])
    }

    private func absoluteURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/") else { throw AutomationFailure("invalid_params", "An absolute local path is required.") }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }

    static func failure(_ error: Error) -> AutomationFailure {
        if let failure = error as? AutomationFailure { return failure }
        let code: String
        switch error {
        case NativeStoreError.conflict, NativeStoreError.questionAnswerConflict, TodoError.conflict: code = "conflict"
        case NativeStoreError.notFound, TodoError.notFound: code = "not_found"
        case NativeStoreError.readOnlyArticleSource: code = "read_only"
        case NativeStoreError.slugTaken, NativeStoreError.userAlreadyExists: code = "already_exists"
        case NativeStoreError.fileSystem: code = "storage_error"
        case is DecodingError: code = "invalid_params"
        case is NativeStoreError, is TodoError: code = "validation_error"
        default: code = "operation_failed"
        }
        return .init(code, error.localizedDescription)
    }
}

extension LocalBlogStore {
    /// Keep read/patch/write on one actor turn. The underlying store also checks
    /// SQLite/file revisions to protect against other app windows and file edits.
    func automationSaveArticle(method: String, parameters p: AutomationParameters) throws -> NativeArticle {
        let previous = method == "articles.create" ? nil : try getArticle(slug: p.required("slug"))
        let title = try p.optional("title", as: String.self) ?? previous?.title ?? ""
        let slug = try previous?.slug ?? p.optional("slug") ?? allocateSlug(from: title)
        let body: String
        if let supplied: String = try p.optional("body") {
            let inferredFormat = supplied.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") ? "html" : "markdown"
            switch try p.string("format", default: inferredFormat) {
            case "html": body = RichArticleDocument.isHTML(supplied) ? supplied : RichArticleDocument.opening + supplied + "</article>"
            case "markdown": body = RichArticleDocument.convertingLegacyBody(supplied)
            case "text": body = RichArticleDocument.opening + supplied.components(separatedBy: "\n").map { "<p>\(RichArticleDocument.escape($0))</p>" }.joined() + "</article>"
            default: throw AutomationFailure("invalid_params", "format must be html, markdown or text")
            }
        } else { body = previous?.body ?? "" }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, RichArticleDocument.hasContent(body) else { throw NativeStoreError.invalidArticle }
        let status: NativeArticleStatus
        if method == "articles.publish" { status = .published }
        else if method == "articles.unpublish" { status = .draft }
        else { status = try p.optional("status") ?? previous?.status ?? .draft }
        return try saveArticle(.init(
            banner: p.values["banner"] == nil ? previous?.banner : p.optional("banner"),
            body: body, category: p.optional("category") ?? previous?.category ?? "Uncategorized",
            excerpt: p.optional("excerpt") ?? previous?.excerpt ?? "",
            media: p.optional("media") ?? previous?.media ?? [], slug: slug, status: status,
            tags: p.optional("tags") ?? previous?.tags ?? [], title: title,
            expectedUpdatedAt: previous == nil ? nil : p.required("expectedUpdatedAt"),
            properties: p.optional("properties") ?? previous?.properties ?? [:],
            sourceRelativePath: previous == nil ? p.optional("sourceRelativePath") : nil
        ))
    }

    func automationRestoreRevision(_ p: AutomationParameters) throws -> NativeArticle {
        let slug: String = try p.required("slug"), id: Int = try p.required("revisionID")
        guard let revision = try listArticleRevisions(articleSlug: slug, draftKey: slug).first(where: { $0.id == id && $0.articleSlug == slug }) else { throw NativeStoreError.notFound }
        let s = revision.snapshot
        return try saveArticle(.init(banner: s.banner, body: RichArticleDocument.convertingLegacyBody(s.body), category: s.category, excerpt: s.excerpt, media: s.media, slug: slug, status: s.status, tags: s.tags, title: s.title, expectedUpdatedAt: p.required("expectedUpdatedAt"), properties: s.properties))
    }

    func automationMutateMoment(method: String, parameters p: AutomationParameters) throws -> AutomationValue {
        let current = try getMoment(id: p.required("id"))
        let expected: String = try p.required("expectedUpdatedAt")
        if method == "moments.delete" {
            try deleteMoment(id: current.id, expectedUpdatedAt: expected)
            return .object(["ok": .bool(true)])
        }
        return try .encoded(updateMoment(id: current.id, text: p.optional("text") ?? current.text, textRuns: p.optional("textRuns") ?? (p.values["text"] == nil ? current.textRuns : []), images: p.optional("images") ?? current.images, expectedUpdatedAt: expected))
    }

    func automationSaveTodo(_ p: AutomationParameters) throws -> TodoItem {
        let id: String? = try p.optional("id")
        let previous = try id.map { try getTodo(id: $0) }
        return try saveTodo(.init(title: p.optional("title") ?? previous?.title ?? "", notes: p.optional("notes") ?? previous?.notes ?? "", priority: p.optional("priority") ?? previous?.priority ?? .normal, dueDay: p.values["dueDay"] == nil ? previous?.dueDay : p.optional("dueDay")), id: id, expectedRevision: p.optional("expectedRevision"))
    }
}
