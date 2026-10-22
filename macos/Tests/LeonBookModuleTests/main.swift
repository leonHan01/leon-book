import Foundation
import LeonBookBackupModule
import LeonBookCaptureModule
import LeonBookKnowledgeGraphModule
import LeonBookModuleKit
import LeonBookPublishingModule
import LeonBookSearchModule
import LeonBookTodoModule

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: FirstPartyModuleEvent?

    func store(_ event: FirstPartyModuleEvent) {
        lock.lock()
        value = event
        lock.unlock()
    }

    func load() -> FirstPartyModuleEvent? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard condition() else { throw TestFailure(description: "\(file):\(line): \(message)") }
}

@main
struct LeonBookModuleTestsMain {
    static func main() throws {
        try testCatalogAndEnablement()
        try testEventBus()
        try testSearchGrammar()
        try testGraphProjection()
        try testPublicationPolicy()
        try testBackupLocationPolicy()
        try testCapturePolicy()
        try testTodos()
        print("LeonBookModuleTests passed (8 suites)")
    }

    private static var descriptors: [FirstPartyModuleDescriptor] {
        [
            SearchFirstPartyModule.descriptor,
            KnowledgeGraphFirstPartyModule.descriptor,
            PublishingFirstPartyModule.descriptor,
            BackupFirstPartyModule.descriptor,
            CaptureFirstPartyModule.descriptor,
            TodoFirstPartyModule.descriptor,
        ]
    }

    private static func testTodos() throws {
        let normalized = try TodoDraft(title: "  Ship checklist  ", notes: "  details  ", priority: .high, dueDay: "2024-02-29").validated()
        try expect(normalized.title == "Ship checklist" && normalized.notes == "details", "task drafts must normalize surrounding whitespace")
        try expect((try? TodoDraft(title: "  ").validated()) == nil, "blank tasks must not be stored")
        try expect((try? TodoDraft(title: String(repeating: "x", count: 201)).validated()) == nil, "task titles must stay bounded")
        try expect((try? TodoDraft(title: "Task", dueDay: "2026-02-29").validated()) == nil, "invalid calendar days must be rejected")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let instant = ISO8601DateFormatter().date(from: "2026-10-21T16:30:00Z")!
        try expect(TodoDay.string(from: instant, calendar: calendar) == "2026-10-22", "today must follow the user's local calendar day")
        let chosenDate = TodoDay.date(from: "2026-10-22", calendar: calendar)!
        try expect(TodoDay.string(from: chosenDate, calendar: calendar) == "2026-10-22", "date picker round trips must retain the chosen day")
        func task(_ id: String, due: String? = nil, priority: TodoPriority = .normal, completed: Bool = false, deleted: Bool = false, notes: String = "") -> TodoItem {
            .init(id: id, title: id, notes: notes, priority: priority, dueDay: due, completedAt: completed ? "2026-10-22T09:00:00Z" : nil, createdAt: "2026-10-21T09:00:00Z", updatedAt: "2026-10-22T09:00:00Z", deletedAt: deleted ? "2026-10-22T10:00:00Z" : nil)
        }
        let tasks = [task("no-date", priority: .high), task("today-low", due: "2026-10-22", priority: .low), task("today-high", due: "2026-10-22", priority: .high, notes: "Review Café design"), task("overdue", due: "2026-10-21"), task("done", due: "2026-10-20", completed: true), task("deleted", deleted: true)]
        let all = TodoListProjection(items: tasks, filter: .all, today: "2026-10-22")
        try expect(all.items.map(\.id) == ["overdue", "today-high", "today-low", "no-date", "done"], "unfinished tasks must sort by due day and priority before completed tasks")
        try expect(all.openCount == 4 && all.todayCount == 2 && all.overdueCount == 1 && all.completedCount == 1, "summary counts must exclude deleted and completed overdue tasks")
        try expect(TodoListProjection(items: tasks, filter: .today, today: "2026-10-22").items.count == 2, "today must include only unfinished tasks due today")
        try expect(TodoListProjection(items: tasks, filter: .overdue, today: "2026-10-22").items.map(\.id) == ["overdue"], "overdue tasks must exclude completed tasks")
        try expect(TodoListProjection(items: tasks, filter: .all, search: "CAFE review", today: "2026-10-22").items.map(\.id) == ["today-high"], "search must match notes, case and accents consistently")
        var runtime = FirstPartyModuleRuntime(catalog: try FirstPartyModuleCatalog(descriptors))
        try expect(runtime.authorization(forCommand: "todo.new").isAllowed, "new TODO module must default to enabled")
        _ = runtime.setEnabled(false, for: TodoFirstPartyModule.id)
        try expect(!runtime.authorization(forCommand: "todo.new").isAllowed && !runtime.authorization(forCommand: "navigation.todos").isAllowed, "disabling TODO must remove its command permissions")
    }

    private static func testCatalogAndEnablement() throws {
        let catalog = try FirstPartyModuleCatalog(descriptors)
        try expect(catalog.modules.count == 6, "all first-party modules must be discoverable")
        try expect(
            catalog.module(owningCommand: "navigation.graph")?.id == KnowledgeGraphFirstPartyModule.id,
            "command ownership must resolve through the catalog"
        )
        try expect(
            catalog.module(owningCommand: "backup.create")?.id == BackupFirstPartyModule.id,
            "modules without navigation screens must still own executable commands"
        )
        try expect(
            catalog.canPublishEvent("module.disabled", from: CaptureFirstPartyModule.id),
            "all modules must expose common lifecycle events"
        )
        let commands = descriptors.flatMap(\.commands)
        try expect(commands.count == 8, "all feature commands must be declared by their owning module")
        try expect(
            commands.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty && !$0.systemImage.isEmpty },
            "module commands must carry complete native presentation metadata"
        )
        let searchCommand = try unwrap(
            commands.first(where: { $0.id == "search.global" }),
            "global search command must be declared"
        )
        try expect(
            searchCommand.defaultShortcut == .init(key: "f", modifiers: [.command, .shift]),
            "module-owned shortcuts must stay with command metadata"
        )
        let backupCommand = try unwrap(
            commands.first(where: { $0.id == "backup.create" }),
            "backup command must be declared"
        )
        try expect(
            backupCommand.availability == .storageReadyAndIdle && backupCommand.surfaces == [.palette],
            "module-owned availability and surfaces must remain intact"
        )
        var runtime = FirstPartyModuleRuntime(catalog: catalog)
        try expect(runtime.authorization(forCommand: "search.global").isAllowed, "modules default to enabled")
        try expect(runtime.setEnabled(false, for: SearchFirstPartyModule.id), "state change must be reported")
        try expect(!runtime.authorization(forCommand: "search.global").isAllowed, "disabled commands must be denied")
        try expect(runtime.authorization(forCommand: "article.new").isAllowed, "core commands stay available")
        try expect(
            !runtime.authorization(for: SearchFirstPartyModule.id, permission: .contentWrite).isAllowed,
            "undeclared permissions must be denied"
        )
    }

    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw TestFailure(description: message) }
        return value
    }

    private static func testEventBus() throws {
        let bus = FirstPartyModuleEventBus()
        let received = EventBox()
        let token = bus.subscribe { received.store($0) }
        let sent = FirstPartyModuleEvent(moduleID: SearchFirstPartyModule.id, name: "search.completed")
        bus.publish(sent)
        try expect(received.load() == sent, "event bus must deliver typed module events")
        bus.unsubscribe(token)
    }

    private static func testSearchGrammar() throws {
        let parsed = FirstPartySearchQueryParser.parse(
            "\"exact phrase\" 标签:#Swift 状态:已发布 类型:文章 日期:2026-08-29 [rating:5]",
            calendar: Calendar(identifier: .gregorian),
            isValidPropertyKey: { $0 == "rating" }
        )
        try expect(parsed.textTerms == ["exact phrase"], "quoted search terms must stay intact")
        try expect(parsed.tags == ["Swift"], "localized tag syntax must parse")
        try expect(parsed.status == "published", "localized status must normalize")
        try expect(parsed.types == ["article"], "localized type must normalize")
        try expect(parsed.after != nil && parsed.before != nil, "date operator must create a day range")
        try expect(parsed.propertyFilters == [.init(key: "rating", value: "5")], "property filters must parse")
    }

    private static func testGraphProjection() throws {
        let now = Date()
        let projection = FirstPartyKnowledgeGraphProjector.project(
            nodes: [
                .init(id: "a", status: "published", searchableText: "Alpha", updatedAt: now),
                .init(id: "b", status: "published", searchableText: "Beta", updatedAt: now.addingTimeInterval(-1)),
                .init(id: "orphan", status: "published", searchableText: "Orphan", updatedAt: now),
            ],
            edges: [.init(sourceID: "a", targetID: "b")],
            query: .init(searchText: "", status: "published", includesOrphans: false, nodeLimit: 10)
        )
        try expect(Set(projection.orderedNodeIDs) == ["a", "b"], "orphan filtering must remain inside graph module")
        try expect(projection.edges == [.init(sourceID: "a", targetID: "b")], "visible edges must be preserved")

        let pathNodes = ["a", "b", "c", "d", "isolated"].map {
            FirstPartyGraphNode(id: $0, status: "published", searchableText: $0, updatedAt: now)
        }
        let pathEdges: [FirstPartyGraphEdge] = [
            .init(sourceID: "a", targetID: "c"),
            .init(sourceID: "c", targetID: "d"),
            .init(sourceID: "a", targetID: "b"),
            .init(sourceID: "b", targetID: "d"),
        ]
        let shortestPath = FirstPartyKnowledgeGraphPathFinder.shortestPath(
            from: "a",
            to: "d",
            nodes: pathNodes,
            edges: pathEdges
        )
        try expect(shortestPath?.nodeIDs == ["a", "b", "d"], "path finder must return a deterministic shortest directed route")
        try expect(shortestPath?.hopCount == 2, "path finder must report the number of reference hops")
        try expect(
            FirstPartyKnowledgeGraphPathFinder.shortestPath(
                from: "d",
                to: "a",
                nodes: pathNodes,
                edges: pathEdges
            ) == nil,
            "path finder must respect reference direction"
        )
        try expect(
            FirstPartyKnowledgeGraphPathFinder.shortestPath(
                from: "isolated",
                to: "isolated",
                nodes: pathNodes,
                edges: pathEdges
            )?.nodeIDs == ["isolated"],
            "a node must have a zero-hop path to itself"
        )
    }

    private static func testPublicationPolicy() throws {
        try FirstPartyPublicationPolicy.validate(.init(kind: .article, title: "Title", body: "Body"))
        try FirstPartyPublicationPolicy.validate(.init(kind: .moment, body: "", attachmentCount: 1))
        do {
            try FirstPartyPublicationPolicy.validate(.init(kind: .article, title: "", body: "Body"))
            throw TestFailure(description: "untitled article should be rejected")
        } catch FirstPartyPublicationValidationError.missingTitle {}
    }

    private static func testBackupLocationPolicy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("leon-module-test-\(UUID().uuidString)", isDirectory: true)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("leon-module-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FirstPartyBackupLocationPolicy.validate(source: root, destination: destination)
        do {
            try FirstPartyBackupLocationPolicy.validate(
                source: root,
                destination: root.appendingPathComponent("nested", isDirectory: true)
            )
            throw TestFailure(description: "nested backup destination should be rejected")
        } catch FirstPartyBackupLocationError.destinationInsideSource {}
    }

    private static func testCapturePolicy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("leon-capture-test-\(UUID().uuidString)", isDirectory: true)
        let notes = root.appendingPathComponent("Notes", isDirectory: true)
        let markdownURL = notes.appendingPathComponent("a.md")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try Data("note".utf8).write(to: markdownURL)
        defer { try? FileManager.default.removeItem(at: root) }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let regular = try markdownURL.resourceValues(forKeys: keys)
        let markdown = FirstPartyCaptureFilePolicy.candidate(
            for: markdownURL,
            root: root,
            resourceValues: regular
        )
        try expect(markdown?.isMarkdown == true, "markdown candidates inside root must be accepted")

        let symlinkURL = root.appendingPathComponent("escape.md")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: markdownURL)
        let symlink = try symlinkURL.resourceValues(forKeys: keys)
        try expect(
            FirstPartyCaptureFilePolicy.candidate(
                for: symlinkURL,
                root: root,
                resourceValues: symlink
            ) == nil,
            "symlinks must be rejected"
        )
    }
}
