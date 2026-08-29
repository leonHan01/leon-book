import Foundation
import LeonBookBackupModule
import LeonBookCaptureModule
import LeonBookKnowledgeGraphModule
import LeonBookModuleKit
import LeonBookPublishingModule
import LeonBookSearchModule

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
        print("LeonBookModuleTests passed (7 suites)")
    }

    private static var descriptors: [FirstPartyModuleDescriptor] {
        [
            SearchFirstPartyModule.descriptor,
            KnowledgeGraphFirstPartyModule.descriptor,
            PublishingFirstPartyModule.descriptor,
            BackupFirstPartyModule.descriptor,
            CaptureFirstPartyModule.descriptor,
        ]
    }

    private static func testCatalogAndEnablement() throws {
        let catalog = try FirstPartyModuleCatalog(descriptors)
        try expect(catalog.modules.count == 5, "all first-party modules must be discoverable")
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
        try expect(commands.count == 6, "all feature commands must be declared by their owning module")
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
