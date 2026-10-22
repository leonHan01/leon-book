import AppKit
import Foundation
import SwiftUI
import LeonBookTodoModule
@testable import LeonBook

private struct TodoTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func todoExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TodoTestFailure(description: message) }
}

private func todoTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("leon-todo-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

final class TodoTests {
    func testTodoPersistenceCompletionDeletionAndConflicts() async throws {
        let root = try todoTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = LocalBlogStore(rootURL: root)
        let created = try await first.saveTodo(.init(title: "  Review 'SQL' %_ 查询  ", notes: "保留备注", priority: .high, dueDay: "2026-10-22"))
        try todoExpect(created.title == "Review 'SQL' %_ 查询" && created.revision == 1 && !created.isCompleted, "new tasks must normalize and retain their metadata")
        let second = LocalBlogStore(rootURL: root)
        let stale = try await second.getTodo(id: created.id)
        let edited = try await first.saveTodo(.init(title: "更新标题", notes: "新的备注", priority: .low, dueDay: "2026-10-23"), id: created.id, expectedRevision: created.revision)
        do {
            _ = try await second.setTodoCompleted(id: stale.id, completed: true, expectedRevision: stale.revision)
            throw TodoTestFailure(description: "stale task completion must be rejected")
        } catch TodoError.conflict {}
        let current = try await second.getTodo(id: created.id)
        try todoExpect(current == edited && current.notes == "新的备注" && !current.isCompleted, "conflicts must preserve changes from the other window")
        let completed = try await second.setTodoCompleted(id: edited.id, completed: true, expectedRevision: edited.revision)
        try todoExpect(completed.isCompleted && completed.revision == 3 && completed.title == edited.title && completed.dueDay == edited.dueDay && completed.createdAt == created.createdAt, "completing a task must not overwrite its details")
        let reopened = try await first.setTodoCompleted(id: completed.id, completed: false, expectedRevision: completed.revision)
        try todoExpect(!reopened.isCompleted && reopened.completedAt == nil, "completed tasks must be reopenable")
        let deleted = try await first.deleteTodo(id: reopened.id, expectedRevision: reopened.revision)
        let afterDelete = try await first.listTodos()
        try todoExpect(afterDelete.isEmpty && deleted.deletedAt != nil, "deleted tasks must leave the active list")
        do {
            _ = try await second.saveTodo(edited.draft, id: edited.id, expectedRevision: edited.revision)
            throw TodoTestFailure(description: "editing a stale deleted task must fail")
        } catch TodoError.conflict {}
        let restored = try await first.restoreTodo(id: deleted.id, expectedRevision: deleted.revision)
        try todoExpect(restored.deletedAt == nil && restored.title == edited.title && restored.revision > deleted.revision, "undo deletion must restore metadata without rewinding the revision")
        do {
            _ = try await first.saveTodo(.init(title: " "))
            throw TodoTestFailure(description: "blank tasks must be rejected")
        } catch TodoError.invalidTitle {}
        do {
            _ = try await first.saveTodo(.init(title: "错误日期", dueDay: "2026-02-30"))
            throw TodoTestFailure(description: "invalid due days must be rejected")
        } catch TodoError.invalidDueDay {}
        let count = try await first.listTodos().count
        try todoExpect(count == 1, "validation errors must not add partial tasks")
        await first.closeForRestore(); await second.closeForRestore()
        let next = LocalBlogStore(rootURL: root)
        let persisted = try await next.getTodo(id: restored.id)
        try todoExpect(persisted == restored, "tasks must survive closing and reopening the SQLite workspace")
        await next.closeForRestore()
    }

    func testTodoWorkspaceIsolationAndBackup() async throws {
        let root = try todoTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("first-user"), other = root.appendingPathComponent("second-user")
        let store = LocalBlogStore(rootURL: source), second = LocalBlogStore(rootURL: other)
        let item = try await store.saveTodo(.init(title: "需要保留的任务", notes: "备份应包含备注", priority: .high, dueDay: "2026-10-22"))
        let completed = try await store.setTodoCompleted(id: item.id, completed: true, expectedRevision: item.revision)
        let otherItems = try await second.listTodos()
        try todoExpect(otherItems.isEmpty, "separate user workspaces must not share tasks")
        try await store.prepareForBackup()
        let snapshot = try LocalBackupManager.createSnapshot(source: source, destination: root.appendingPathComponent("backups"))
        _ = try LocalBackupManager.validateSnapshot(at: snapshot)
        let restoredRoot = root.appendingPathComponent("restored-user")
        try FileManager.default.copyItem(at: snapshot, to: restoredRoot)
        let restored = LocalBlogStore(rootURL: restoredRoot)
        let restoredItem = try await restored.getTodo(id: completed.id)
        try todoExpect(restoredItem == completed, "workspace snapshots must preserve task details, completion and revision")
        await store.closeForRestore(); await second.closeForRestore(); await restored.closeForRestore()
    }

    @MainActor
    func testTodoAppCommandsFilteringAndModuleLifecycle() async throws {
        let root = try todoTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "TodoAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false, store: LocalBlogStore(rootURL: root))
        defer {
            model.compatibilityExportTask?.cancel()
            model.backupTask?.cancel()
        }
        model.firstPartyModuleRuntime = NativeFirstPartyModules.loadRuntime(defaults: defaults)
        model.storageReady = true
        model.isLoading = false
        model.backupDirectoryPath = ""
        model.executeCommand(.todos)
        try todoExpect(model.section == .todos, "TODO navigation command must open its page")
        let oldFocus = model.todoSession.focusRequest
        model.executeCommand(.newTodo)
        try todoExpect(model.todoSession.focusRequest != oldFocus, "new-task command must focus quick entry")
        model.todoSession.quickTitle = "  完成 TODO 模块  "
        let added = await model.addQuickTodo()
        try todoExpect(added && model.todoSession.quickTitle.isEmpty && model.todoSession.items.count == 1, "quick entry must save and clear only the submitted draft")
        guard let original = model.todoSession.items.first else { throw TodoTestFailure(description: "expected saved task") }
        let today = TodoDay.string(from: Date())
        let saved = await model.saveTodoDraft(.init(title: original.title, notes: "检查筛选、完成与重新打开", priority: .high, dueDay: today), editing: original)
        try todoExpect(saved, "task details must be editable")
        let edited = model.todoSession.items[0]
        let toggled = await model.toggleTodo(edited)
        try todoExpect(toggled && model.todoSession.items[0].isCompleted, "checkbox action must persist completion")
        let reopened = await model.toggleTodo(model.todoSession.items[0])
        try todoExpect(reopened && !model.todoSession.items[0].isCompleted, "checkbox action must reopen a completed task")
        let deleted = await model.deleteTodo(model.todoSession.items[0])
        try todoExpect(deleted && model.todoSession.items.isEmpty && model.todoSession.lastDeleted != nil, "delete action must offer an undo record")
        let restored = await model.undoTodoDeletion()
        try todoExpect(restored && model.todoSession.items.count == 1 && model.todoSession.lastDeleted == nil, "undo action must restore the task and dismiss the undo record")
        try todoExpect(model.latestFirstPartyModuleEvent?.name == "todo.restored", "task operations must emit their module events")
        let projection = TodoListProjection(items: model.todoSession.items, filter: .today, search: "筛选", today: today)
        try todoExpect(projection.items.count == 1 && projection.todayCount == 1, "saved details must participate in task search and date filters")

        if let path = ProcessInfo.processInfo.environment["LEON_TODO_PREVIEW_PATH"] {
            let yesterday = TodoDay.string(from: Calendar.current.date(byAdding: .day, value: -1, to: Date())!)
            _ = await model.saveTodoDraft(.init(title: "整理本周的阅读笔记", notes: "把文章中的想法整理为可执行的下一步", priority: .normal, dueDay: today))
            _ = await model.saveTodoDraft(.init(title: "确认项目交付清单", notes: "检查尚未完成的细节", priority: .high, dueDay: yesterday))
            _ = await model.saveTodoDraft(.init(title: "完成编辑器体验优化", priority: .low))
            if let done = model.todoSession.items.first(where: { $0.title == "完成编辑器体验优化" }) { _ = await model.toggleTodo(done) }
            model.todoSession.filter = .all
            try await snapshotTodoView(model, path: path)
        }

        model.todoSession.isSaving = true
        try todoExpect(model.commandContext.isBusy && !NativeFirstPartyModules.canDeactivate(TodoFirstPartyModule.id, in: model), "module disable and workspace commands must respect an in-flight task write")
        let rejectedWhileBusy = await model.saveTodoDraft(.init(title: "不应添加"))
        try todoExpect(!rejectedWhileBusy, "task writes must be serialized")
        model.todoSession.isSaving = false
        model.todoSession.quickTitle = "保留未提交的输入"
        let beforeDisable = try await model.store.listTodos().count
        var runtime = model.firstPartyModuleRuntime
        _ = runtime.setEnabled(false, for: TodoFirstPartyModule.id)
        model.firstPartyModuleRuntime = runtime
        NativeFirstPartyModules.deactivate(TodoFirstPartyModule.id, in: model)
        try todoExpect(model.section == .dashboard && model.todoSession.quickTitle == "保留未提交的输入", "disabling TODO must leave the page while retaining its unsent quick entry")
        try todoExpect(model.commandRegistry.definition(for: .todos) == nil && !model.canExecuteCommand(.newTodo), "disabled module commands must leave the command registry")
        let rejected = await model.saveTodoDraft(.init(title: "禁用时不应添加"))
        let afterDisable = try await model.store.listTodos().count
        try todoExpect(!rejected && beforeDisable == afterDisable, "disabled TODO modules must not mutate stored tasks")
        await model.store.closeForRestore()
        await model.userWorkspaces.closeForRestore()
    }

    @MainActor
    private func snapshotTodoView(_ model: NativeAppModel, path: String) async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 740), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let view = NSHostingView(rootView: TodoListView(model: model).environment(\.colorScheme, .light))
        window.contentView = view
        view.setFrameSize(NSSize(width: 940, height: 740))
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 250_000_000)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw TodoTestFailure(description: "could not render TODO page") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw TodoTestFailure(description: "could not encode TODO preview") }
        try data.write(to: URL(fileURLWithPath: path))
    }
}
