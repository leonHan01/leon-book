import Foundation
import LeonBookTodoModule

struct NativeTodoSession {
    var items: [TodoItem] = []
    var quickTitle = ""
    var filter = TodoFilter.open
    var search = ""
    var isLoading = false
    var loadError: String?
    var isSaving = false
    var hasLoaded = false
    var lastDeleted: TodoItem?
    var focusRequest = UUID()
}

extension NativeAppModel {
    var isTodoModuleEnabled: Bool { isFirstPartyModuleEnabled(TodoFirstPartyModule.id) }
    var isSavingTodo: Bool { todoSession.isSaving }
    var canWriteTodos: Bool { storageReady && isTodoModuleEnabled && !isSavingTodo && !isBackingUp && !isRestoringBackup && !isSwitchingWorkspace }

    func openTodos(focusComposer: Bool = false) {
        guard authorizeFirstPartyModule(TodoFirstPartyModule.id, permission: .contentRead, action: "打开待办") else { return }
        section = .todos
        if focusComposer { todoSession.focusRequest = UUID() }
        recordFirstPartyModuleEvent(moduleID: TodoFirstPartyModule.id, name: "todo.opened")
    }

    func reloadTodos() async throws {
        guard isTodoModuleEnabled else { return }
        let activeStore = store, workspace = workspaceGeneration
        todoLoadGeneration += 1
        let request = todoLoadGeneration
        todoSession.isLoading = true
        defer { if workspace == workspaceGeneration, request == todoLoadGeneration { todoSession.isLoading = false } }
        let items: [TodoItem]
        do { items = try await activeStore.listTodos() }
        catch {
            if workspace == workspaceGeneration, request == todoLoadGeneration { todoSession.loadError = error.localizedDescription }
            throw error
        }
        guard !Task.isCancelled, workspace == workspaceGeneration, request == todoLoadGeneration, isTodoModuleEnabled else { return }
        todoSession.items = items
        todoSession.loadError = nil
        todoSession.hasLoaded = true
    }

    func addQuickTodo() async -> Bool {
        let title = todoSession.quickTitle
        let saved = await saveTodoDraft(.init(title: title))
        if saved, todoSession.quickTitle == title { todoSession.quickTitle = "" }
        return saved
    }

    func saveTodoDraft(_ draft: TodoDraft, editing item: TodoItem? = nil) async -> Bool {
        await writeTodo(event: item == nil ? "todo.created" : "todo.updated") { store in
            try await store.saveTodo(draft, id: item?.id, expectedRevision: item?.revision)
        }
    }

    func toggleTodo(_ item: TodoItem) async -> Bool {
        await writeTodo(event: item.isCompleted ? "todo.reopened" : "todo.completed") { store in
            try await store.setTodoCompleted(id: item.id, completed: !item.isCompleted, expectedRevision: item.revision)
        }
    }

    func deleteTodo(_ item: TodoItem) async -> Bool {
        await writeTodo(event: "todo.deleted") { store in
            try await store.deleteTodo(id: item.id, expectedRevision: item.revision)
        }
    }

    func undoTodoDeletion() async -> Bool {
        guard let item = todoSession.lastDeleted else { return false }
        return await writeTodo(event: "todo.restored") { store in
            try await store.restoreTodo(id: item.id, expectedRevision: item.revision)
        }
    }

    func deactivateTodos() {
        todoLoadGeneration += 1
        todoSession.items = []
        todoSession.isLoading = false
        todoSession.hasLoaded = false
        todoSession.lastDeleted = nil
        if section == .todos { section = .dashboard }
    }

    private func writeTodo(event: String, operation: (LocalBlogStore) async throws -> TodoItem) async -> Bool {
        guard authorizeFirstPartyModule(TodoFirstPartyModule.id, permission: .contentWrite, action: "修改待办"), canWriteTodos else { return false }
        let activeStore = store, workspace = workspaceGeneration
        todoLoadGeneration += 1
        todoSession.isSaving = true
        defer { if workspace == workspaceGeneration { todoSession.isSaving = false } }
        do {
            let item = try await operation(activeStore)
            guard workspace == workspaceGeneration else { return false }
            todoSession.items.removeAll { $0.id == item.id }
            if item.deletedAt == nil { todoSession.items.append(item) }
            if event == "todo.deleted" { todoSession.lastDeleted = item }
            if event == "todo.restored" { todoSession.lastDeleted = nil }
            todoSession.hasLoaded = true
            errorMessage = nil
            do { try await reloadTodos() }
            catch { errorMessage = "待办已保存，刷新列表失败：\(error.localizedDescription)" }
            guard workspace == workspaceGeneration else { return true }
            recordFirstPartyModuleEvent(moduleID: TodoFirstPartyModule.id, name: event, payload: ["id": item.id])
            scheduleBackup()
            NativeWorkspaceWindows.reloadTodos(in: activeStore.rootURL, excluding: self)
            return true
        } catch {
            guard workspace == workspaceGeneration else { return false }
            try? await reloadTodos()
            errorMessage = error.localizedDescription
            return false
        }
    }
}
