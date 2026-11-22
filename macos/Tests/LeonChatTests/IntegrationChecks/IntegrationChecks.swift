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
        let pendingKey = ".archive.shared:"
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
        let other = try cli("users.create", root: second.root, params: ["name": "Other User"])
        let otherID = (other["user"] as! [String: Any])["id"] as! String
        precondition(otherID != second.user)
        setenv("LEON_BOOK_WORKDIR", first.root, 1)

        let store = ChatStore()
        store.requiresHostArchiveDestination = true
        store.setActive(false)
        await store.prepareBlogDestination()
        precondition(store.blogDestination == nil && store.exportError != nil,
            "A disconnected host must not export to the CLI's global default library")
        print("PASS: an unavailable host library cannot silently use a different data root")

        store.setArchiveDestination(root: second.root, user: second.user)
        await store.prepareBlogDestination()
        precondition(store.exportError == nil && store.blogDestination == second,
            "The window's root and user must override global and active-user defaults")
        print("PASS: archive destination follows the current window's library and user")

        store.setArchiveDestination(root: second.root, user: otherID)
        precondition(store.blogDestination == nil, "A prepared destination must be invalidated after switching users")
        await store.prepareBlogDestination()
        precondition(store.blogDestination == .init(root: second.root, user: otherID))
        print("PASS: switching workspace users invalidates and resolves the archive destination")

        defaults.set(UUID().uuidString, forKey: pendingKey)
        defaults.set(try JSONEncoder().encode(second), forKey: pendingKey + ".destination")
        store.setArchiveDestination(root: first.root, user: first.user)
        await store.prepareBlogDestination()
        precondition(store.blogDestination == second,
            "An unfinished archive must retry against its pinned root and user")
        print("PASS: unfinished archives remain pinned to the original library and user")

        let secondStore = ChatStore()
        precondition(store.deviceId == secondStore.deviceId, "Windows must share one integrated device identity")
        precondition(!store.hasConnection && !secondStore.hasConnection,
            "Constructing the integrated store must not connect to a server")
        print("PASS: integrated windows share device identity without eagerly connecting or reading credentials")
    }
}
