import Foundation
@testable import LeonChat

@main
struct IntegrationChecks {
    static func cli(_ method: String, root: String, params: [String: Any] = [:]) throws -> [String: Any] {
        let process = Process()
        process.executableURL = try LeonBlogExporter.executable()
        process.arguments = [method, "--root", root, "--json",
            String(data: try JSONSerialization.data(withJSONObject: params), encoding: .utf8)!]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        guard process.terminationStatus == 0, let result = envelope["result"] as? [String: Any] else {
            throw ClientError.message("Fixture CLI failed: " + String(decoding: data, as: UTF8.self))
        }
        return result
    }

    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("leon-chat-integration-" + UUID().uuidString)
        let previousRoot = ProcessInfo.processInfo.environment["LEON_BOOK_WORKDIR"]
        let defaults = ChatPreferences.defaults
        let pendingKey = ".archive.shared:agent-a"
        let oldPending = defaults.object(forKey: pendingKey)
        let oldDestination = defaults.object(forKey: pendingKey + ".destination")
        defer {
            if let previousRoot { setenv("LEON_BOOK_WORKDIR", previousRoot, 1) }
            else { unsetenv("LEON_BOOK_WORKDIR") }
            defaults.set(oldPending, forKey: pendingKey)
            defaults.set(oldDestination, forKey: pendingKey + ".destination")
            try? FileManager.default.removeItem(at: directory)
        }
        let first = try LeonBlogExporter.destination(root: directory.appendingPathComponent("first").path)
        let second = try LeonBlogExporter.destination(root: directory.appendingPathComponent("second").path)
        let createdUser = try cli("users.create", root: second.root, params: ["name": "Other User"])
        let otherID = (createdUser["user"] as! [String: Any])["id"] as! String
        precondition(otherID != second.user)
        setenv("LEON_BOOK_WORKDIR", first.root, 1)

        let store = ChatStore()
        store.setActive(false)
        func selection(_ library: LeonBlogExporter.Destination?, agent: String = "agent-a") -> ChatStore.ArchiveSelection {
            .init(scope: store.conversationScope, agentID: agent, library: library)
        }
        do {
            _ = try await store.prepareArchive(selection(nil))
            preconditionFailure("A disconnected host must not export to the global default library")
        } catch let error as ClientError {
            precondition(error.localizedDescription.contains("先连接 LeonBook"))
        }
        print("PASS: an unavailable host library cannot silently use a different data root")

        let other = LeonBlogExporter.Destination(root: second.root, user: otherID)
        let firstWindow = try await store.prepareArchive(selection(second))
        let secondWindow = try await store.prepareArchive(selection(other, agent: "agent-b"))
        precondition(firstWindow.destination == second && firstWindow.selection.agentID == "agent-a")
        precondition(secondWindow.destination == other && secondWindow.selection.agentID == "agent-b")
        precondition(firstWindow.selection != secondWindow.selection)
        print("PASS: simultaneous windows resolve their own user and selected Agent")

        store.exportBusy = true
        let switchedWindow = try await store.prepareArchive(selection(first, agent: "agent-b"))
        store.exportBusy = false
        precondition(switchedWindow.destination == first && switchedWindow.selection.agentID == "agent-b")
        precondition(secondWindow.destination == other)
        print("PASS: busy archive leaves its original selection intact while a new window gets a fresh destination")

        defaults.set(UUID().uuidString, forKey: pendingKey)
        defaults.set(try JSONEncoder().encode(second), forKey: pendingKey + ".destination")
        let retry = try await store.prepareArchive(selection(first))
        precondition(retry.destination == second && retry.pendingID != nil)
        print("PASS: unfinished archives remain pinned to the original library and user")

        var generation = UUID()
        let initialGeneration = generation
        var delivered: [Int64] = []
        let events = (1...2).map { ChatNotification(id: Int64($0), room: "shared", title: "Test", text: "Message") }
        let complete = await ChatNotifications.deliverBatch(events, isCurrent: { generation == initialGeneration }) { event in
            delivered.append(event.id)
            await Task.yield()
            generation = UUID()
        }
        precondition(!complete && delivered == [1], "A switched account must discard the rest of the old page and its cursor")
        print("PASS: connection switch during notification delivery drops remaining events and rejects the old cursor")

        let secondStore = ChatStore()
        precondition(store.deviceId == secondStore.deviceId, "Windows must share one integrated device identity")
        precondition(!store.hasConnection && !secondStore.hasConnection,
            "Constructing the integrated store must not connect to a server")
        print("PASS: integrated windows share device identity without eagerly connecting or reading credentials")
    }
}
