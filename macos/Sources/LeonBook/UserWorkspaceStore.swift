import Foundation

public struct NativeWorkspaceState {
    public let activeUser: NativeUser
    public let users: [NativeUser]
    public let workspaceURL: URL
}

/// Manages the local SQLite user registry and maps each user to an isolated workspace.
public actor UserWorkspaceStore {
    private struct ActiveUserSelection: Codable {
        let userID: String
    }

    let rootURL: URL
    private var database: SQLiteDatabase?
    private var directoryLock: ExclusiveDirectoryLock?
    private var isPreparingForRestore = false

    private var databaseURL: URL { rootURL.appendingPathComponent("leon-book.sqlite") }
    private var usersURL: URL { rootURL.appendingPathComponent("users.json") }
    private var activeUserURL: URL { rootURL.appendingPathComponent("active-user.json") }
    private var workspacesURL: URL { rootURL.appendingPathComponent("workspaces", isDirectory: true) }

    public init(rootURL: URL = LocalBlogStore.defaultRootURL) {
        self.rootURL = rootURL.standardizedFileURL
        WorkspaceStorageLifecycle.register(self, root: self.rootURL)
    }

    public func prepareForBackup() throws {
        _ = try prepare()
        try db().execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    public func closeForRestore() {
        database?.close()
        database = nil
        directoryLock = nil
    }

    func prepareAndCloseForRestore() throws {
        isPreparingForRestore = true
        defer {
            closeForRestore()
            isPreparingForRestore = false
        }
        if database != nil { try prepareForBackup() }
    }

    public func prepare() throws -> NativeWorkspaceState {
        if !isPreparingForRestore { try WorkspaceStorageLifecycle.requireAvailable(rootURL) }
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: workspacesURL, withIntermediateDirectories: true)
            if directoryLock == nil {
                directoryLock = try ExclusiveDirectoryLock(directory: rootURL)
            }
            try migrateLegacyWorkspaceIfNeeded()
            try prepareDatabase()

            var users = try readUsers()
            let validUsers = users.filter { isValidUserID($0.id) }
            if validUsers.count != users.count {
                users = validUsers
                try saveUsers(users)
            }
            if users.isEmpty {
                users = [NativeUser.leon]
                try saveUsers(users)
            }

            let storedActiveUserID = try readActiveUserID()
            let activeUserID = storedActiveUserID ?? users[0].id
            let activeUser = users.first(where: { $0.id == activeUserID }) ?? users[0]
            let workspaceURL = try workspaceURL(for: activeUser)
            try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
            if activeUser.id != activeUserID || storedActiveUserID == nil {
                try saveActiveUserID(activeUser.id)
            }
            return NativeWorkspaceState(activeUser: activeUser, users: users, workspaceURL: workspaceURL)
        } catch let error as NativeStoreError {
            throw error
        } catch {
            throw NativeStoreError.fileSystem(error.localizedDescription)
        }
    }

    func selectUser(id: String) throws -> NativeWorkspaceState {
        let state = try prepare()
        guard let user = state.users.first(where: { $0.id == id }) else {
            throw NativeStoreError.notFound
        }
        let workspaceURL = try workspaceURL(for: user)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try saveActiveUserID(user.id)
        return NativeWorkspaceState(activeUser: user, users: state.users, workspaceURL: workspaceURL)
    }

    func createUser(named rawName: String) throws -> NativeWorkspaceState {
        let current = try prepare()
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { throw NativeStoreError.invalidUser }
        guard !current.users.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw NativeStoreError.userAlreadyExists
        }

        let user = NativeUser(
            id: "user-\(UUID().uuidString.lowercased())",
            name: name,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        let users = current.users + [user]
        let workspaceURL = try workspaceURL(for: user)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try saveUsers(users)
        try saveActiveUserID(user.id)
        return NativeWorkspaceState(activeUser: user, users: users, workspaceURL: workspaceURL)
    }

    private func prepareDatabase() throws {
        guard database == nil else { return }
        let nextDatabase = try SQLiteDatabase(url: databaseURL)
        try nextDatabase.execute("""
        CREATE TABLE IF NOT EXISTS users (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS app_settings (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        """)
        database = nextDatabase

        if try nextDatabase.integer("SELECT COUNT(*) FROM users") == 0,
           FileManager.default.fileExists(atPath: usersURL.path) {
            let legacyUsers = try readUsersFile()
            for user in legacyUsers {
                try requireValidUserID(user.id, source: "users.json")
            }
            try nextDatabase.transaction {
                for user in legacyUsers { try insertUser(user, into: nextDatabase) }
            }
        }

        if try nextDatabase.text("SELECT value FROM app_settings WHERE key = 'active_user_id'") == nil,
           let legacyActiveUserID = try readActiveUserFile() {
            try saveActiveUserID(legacyActiveUserID)
        }
    }

    private func db() throws -> SQLiteDatabase {
        guard let database else { throw NativeStoreError.fileSystem(NativeLocalization.text("SQLite：用户数据库尚未准备好")) }
        return database
    }

    private func readUsers() throws -> [NativeUser] {
        var users: [NativeUser] = []
        try db().query("SELECT id, name, created_at FROM users ORDER BY rowid") { row in
            guard let id = row.text(at: 0),
                  let name = row.text(at: 1),
                  let createdAt = row.text(at: 2) else {
                throw NativeStoreError.fileSystem(NativeLocalization.text("SQLite：用户记录不完整"))
            }
            users.append(NativeUser(id: id, name: name, createdAt: createdAt))
        }
        return users
    }

    private func saveUsers(_ users: [NativeUser]) throws {
        let database = try db()
        try database.transaction {
            try database.execute("DELETE FROM users")
            for user in users { try insertUser(user, into: database) }
        }
        try writeJSON(users, to: usersURL)
    }

    private func insertUser(_ user: NativeUser, into database: SQLiteDatabase) throws {
        try database.execute(
            "INSERT OR REPLACE INTO users(id, name, created_at) VALUES(?, ?, ?)",
            values: [.text(user.id), .text(user.name), .text(user.createdAt)]
        )
    }

    private func readActiveUserID() throws -> String? {
        try db().text("SELECT value FROM app_settings WHERE key = 'active_user_id'")
    }

    private func saveActiveUserID(_ id: String) throws {
        try db().execute(
            "INSERT OR REPLACE INTO app_settings(key, value) VALUES('active_user_id', ?)",
            values: [.text(id)]
        )
        try writeJSON(ActiveUserSelection(userID: id), to: activeUserURL)
    }

    private func readUsersFile() throws -> [NativeUser] {
        do {
            return try JSONDecoder().decode([NativeUser].self, from: Data(contentsOf: usersURL))
        } catch {
            throw NativeStoreError.fileSystem(NativeLocalization.text("无法读取 users.json：\(error.localizedDescription)"))
        }
    }

    private func readActiveUserFile() throws -> String? {
        guard FileManager.default.fileExists(atPath: activeUserURL.path) else { return nil }
        do {
            return try JSONDecoder().decode(ActiveUserSelection.self, from: Data(contentsOf: activeUserURL)).userID
        } catch {
            throw NativeStoreError.fileSystem(NativeLocalization.text("无法读取 active-user.json：\(error.localizedDescription)"))
        }
    }

    private func migrateLegacyWorkspaceIfNeeded() throws {
        let leonWorkspaceURL = try workspaceURL(for: .leon)
        // An early homepage load in the affected build initialized an empty
        // content store over the existing user registry. Leave those artifacts
        // untouched and use the registered workspace only after verifying that
        // they contain no user content. Real mixed/partial migrations still fail.
        if try hasOnlyEmptyStartupArtifacts(alongside: leonWorkspaceURL) { return }
        let legacyDirectories = ["articles", "drafts", "media", "moments", "activity"]
        let fileManager = FileManager.default
        let directoriesToMigrate = legacyDirectories.filter {
            fileManager.fileExists(atPath: rootURL.appendingPathComponent($0, isDirectory: true).path)
        }

        if !directoriesToMigrate.isEmpty {
            let occupiedDestinations = directoriesToMigrate.filter {
                fileManager.fileExists(atPath: leonWorkspaceURL.appendingPathComponent($0, isDirectory: true).path)
            }
            guard occupiedDestinations.isEmpty else {
                throw NativeStoreError.fileSystem(NativeLocalization.text("检测到未完成的 leon 工作空间迁移，请先检查根目录和 workspaces/leon 中的文件。"))
            }

            try fileManager.createDirectory(at: leonWorkspaceURL, withIntermediateDirectories: true)
            for directory in directoriesToMigrate {
                let sourceURL = rootURL.appendingPathComponent(directory)
                try fileManager.moveItem(at: sourceURL, to: leonWorkspaceURL.appendingPathComponent(directory, isDirectory: true))
            }
        }

        try migrateLegacyContentDatabaseIfNeeded(into: leonWorkspaceURL)
    }

    private func hasOnlyEmptyStartupArtifacts(alongside workspace: URL) throws -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: databaseURL.path),
              fileManager.fileExists(atPath: workspace.appendingPathComponent("leon-book.sqlite").path) else { return false }
        let probe = try SQLiteDatabase(url: databaseURL)
        defer { probe.close() }
        var tables: [String] = []
        // FTS shadow tables contain internal configuration even when the logical
        // search tables are empty. Check the logical tables, never their storage.
        try probe.query("PRAGMA main.table_list") { row in
            guard row.text(at: 0) == "main", let name = row.text(at: 1),
                  row.text(at: 2) != "shadow", !name.hasPrefix("sqlite_") else { return }
            tables.append(name)
        }
        guard ["users", "app_settings", "articles", "metadata"].allSatisfy(tables.contains),
              try probe.integer("SELECT COUNT(*) FROM users WHERE id = 'leon'") == 1 else { return false }
        for table in tables where !["users", "app_settings", "metadata"].contains(table) {
            let quoted = table.replacingOccurrences(of: "\"", with: "\"\"")
            guard try probe.integer("SELECT COUNT(*) FROM \"\(quoted)\"") == 0 else { return false }
        }
        let bootstrapKeys: Set<String> = [
            "legacy_migration_v1", "markdown_source_v1", "moment_tags_v1",
            "article_derived_indexes_v1", "search_acceleration_v1", "media_references_v1",
            "content_search_v2", "json_export_v1", "json_export_v2",
        ]
        var containsOnlyBootstrapFlags = true
        try probe.query("SELECT key FROM metadata") { row in
            // Values are schema-version tokens (some are "done", others carry
            // an index version), not user-authored settings or dashboard data.
            if !bootstrapKeys.contains(row.text(at: 0) ?? "") {
                containsOnlyBootstrapFlags = false
            }
        }
        guard containsOnlyBootstrapFlags else { return false }
        for name in ["articles", "drafts", "media", "moments", "activity", "trash"] {
            let directory = rootURL.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { return false }
            for file in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { return false }
                if file.lastPathComponent.hasPrefix("._") || file.lastPathComponent == ".DS_Store" { continue }
                let path = "\(name)/\(file.lastPathComponent)"
                if ["articles/.sidecars-v1", "moments/.sidecars-v1"].contains(path) {
                    guard attributes.fileSize == 0 else { return false }
                } else if ["moments/index.json", "activity/events.json", "trash/index.json"].contains(path) {
                    guard (attributes.fileSize ?? Int.max) <= 16_384,
                          let json = try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) else { return false }
                    if path == "trash/index.json" {
                        guard let entries = json as? [String: [Any]],
                              Set(entries.keys).isSubset(of: ["articles", "moments"]),
                              entries.values.allSatisfy(\.isEmpty) else { return false }
                    } else {
                        guard let entries = json as? [Any], entries.isEmpty else { return false }
                    }
                } else {
                    return false
                }
            }
        }
        return true
    }

    private func migrateLegacyContentDatabaseIfNeeded(into leonWorkspaceURL: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: databaseURL.path) else { return }

        let probe = try SQLiteDatabase(url: databaseURL)
        var hasArticles = false
        var hasUsers = false
        try probe.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('articles', 'users')") { row in
            switch row.text(at: 0) {
            case "articles": hasArticles = true
            case "users": hasUsers = true
            default: break
            }
        }
        probe.close()

        if hasArticles && hasUsers {
            throw NativeStoreError.fileSystem(NativeLocalization.text("根目录数据库同时包含用户表和文章表，请先手动分离后再打开。"))
        }
        guard hasArticles else { return }

        try fileManager.createDirectory(at: leonWorkspaceURL, withIntermediateDirectories: true)
        let destination = leonWorkspaceURL.appendingPathComponent("leon-book.sqlite")
        if fileManager.fileExists(atPath: destination.path) {
            throw NativeStoreError.fileSystem(NativeLocalization.text("workspaces/leon 已有数据库，无法移入根目录中的旧内容库。"))
        }
        try moveSQLiteDatabase(from: databaseURL, to: destination)
    }

    private func moveSQLiteDatabase(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: source.path + suffix)
            guard fileManager.fileExists(atPath: from.path) else { continue }
            let to = URL(fileURLWithPath: destination.path + suffix)
            try fileManager.moveItem(at: from, to: to)
        }
    }

    private func workspaceURL(for user: NativeUser) throws -> URL {
        try requireValidUserID(user.id, source: "用户工作空间")
        return workspacesURL.appendingPathComponent(user.id, isDirectory: true)
    }

    private func isValidUserID(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    private func requireValidUserID(_ id: String, source: String) throws {
        guard isValidUserID(id) else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("\(source) 中包含无效的用户 ID"))
        }
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            throw NativeStoreError.fileSystem(NativeLocalization.text("无法写入 \(url.lastPathComponent)：\(error.localizedDescription)"))
        }
    }
}
