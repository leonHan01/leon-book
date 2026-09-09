import Foundation

/// Coordinates replacement of a data directory across all of its actor-owned
/// connections. The gate also covers stores opened while a restore is running.
enum WorkspaceStorageLifecycle {
    fileprivate final class Entry {
        let root: URL
        weak var articles: LocalBlogStore?
        weak var users: UserWorkspaceStore?

        init(root: URL, articles: LocalBlogStore? = nil, users: UserWorkspaceStore? = nil) {
            self.root = root.standardizedFileURL.resolvingSymlinksInPath()
            self.articles = articles
            self.users = users
        }
    }

    final class Suspension {
        private let id: UUID
        private let entries: [Entry]

        fileprivate init(id: UUID, entries: [Entry]) {
            self.id = id
            self.entries = entries
        }

        /// Actor hops drain synchronous mutations that were already executing.
        /// Every connection is closed even if one compatibility export fails.
        func prepareAndClose() async throws {
            var failure: Error?
            for entry in entries {
                do {
                    if let store = entry.articles { try await store.prepareAndCloseForRestore() }
                    if let store = entry.users { try await store.prepareAndCloseForRestore() }
                } catch {
                    if failure == nil { failure = error }
                }
            }
            if let failure { throw failure }
        }

        func finish() {
            lock.lock()
            suspendedRoots.removeValue(forKey: id)
            lock.unlock()
        }

        deinit { finish() }
    }

    final class AsyncWriteLease {
        private let id: UUID
        fileprivate init(id: UUID) { self.id = id }
        deinit {
            lock.lock()
            asyncWrites.removeValue(forKey: id)
            lock.unlock()
        }
    }

    private static let lock = NSLock()
    private static var entries: [Entry] = []
    private static var suspendedRoots: [UUID: URL] = [:]
    private static var asyncWrites: [UUID: URL] = [:]

    static func register(_ store: LocalBlogStore, root: URL) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.articles == nil && $0.users == nil }
        entries.append(Entry(root: root, articles: store))
    }

    static func register(_ store: UserWorkspaceStore, root: URL) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.articles == nil && $0.users == nil }
        entries.append(Entry(root: root, users: store))
    }

    static func requireAvailable(_ root: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        try checkAvailable(root)
    }

    static func beginAsyncWrite(in root: URL) throws -> AsyncWriteLease {
        lock.lock()
        defer { lock.unlock() }
        try checkAvailable(root)
        let id = UUID()
        asyncWrites[id] = root.standardizedFileURL.resolvingSymlinksInPath()
        return AsyncWriteLease(id: id)
    }

    static func suspend(in root: URL) throws -> Suspension {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        lock.lock()
        defer { lock.unlock() }
        guard !suspendedRoots.values.contains(where: { overlaps($0, root) }),
              !asyncWrites.values.contains(where: { overlaps($0, root) }) else {
            throw NativeStoreError.fileSystem("资料库仍有恢复、导入或媒体写入操作，请完成后重试。")
        }
        let id = UUID()
        suspendedRoots[id] = root
        let affected = entries.filter { contains(root, $0.root) }
        return Suspension(id: id, entries: affected)
    }

    private static func checkAvailable(_ root: URL) throws {
        guard !suspendedRoots.isEmpty else { return }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        guard !suspendedRoots.values.contains(where: { contains($0, root) }) else {
            throw NativeStoreError.fileSystem("资料库正在恢复，请稍后重试。")
        }
    }

    private static func overlaps(_ lhs: URL, _ rhs: URL) -> Bool {
        contains(lhs, rhs) || contains(rhs, lhs)
    }

    private static func contains(_ parent: URL, _ child: URL) -> Bool {
        child.path == parent.path || child.path.hasPrefix(parent.path + "/")
    }
}
