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

    private var databaseURL: URL { rootURL.appendingPathComponent("leon-book.sqlite") }
    private var usersURL: URL { rootURL.appendingPathComponent("users.json") }
    private var activeUserURL: URL { rootURL.appendingPathComponent("active-user.json") }
    private var workspacesURL: URL { rootURL.appendingPathComponent("workspaces", isDirectory: true) }

    public init(rootURL: URL = LocalBlogStore.defaultRootURL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public func prepare() throws -> NativeWorkspaceState {
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: workspacesURL, withIntermediateDirectories: true)
            if directoryLock == nil {
                directoryLock = try ExclusiveDirectoryLock(directory: rootURL)
            }
            try migrateLegacyWorkspaceIfNeeded()
            try prepareDatabase()

            var users = try readUsers()
            if users.isEmpty {
                users = [NativeUser.leon]
                try saveUsers(users)
            }

            let storedActiveUserID = try readActiveUserID()
            let activeUserID = storedActiveUserID ?? users[0].id
            let activeUser = users.first(where: { $0.id == activeUserID }) ?? users[0]
            if activeUser.id != activeUserID || storedActiveUserID == nil {
                try saveActiveUserID(activeUser.id)
            }

            let workspaceURL = try workspaceURL(for: activeUser)
            try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
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
        try saveActiveUserID(user.id)
        let workspaceURL = try workspaceURL(for: user)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
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
        try saveUsers(users)
        try saveActiveUserID(user.id)

        let workspaceURL = try workspaceURL(for: user)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
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
            for user in legacyUsers { try insertUser(user, into: nextDatabase) }
        }

        if try nextDatabase.text("SELECT value FROM app_settings WHERE key = 'active_user_id'") == nil,
           let legacyActiveUserID = try readActiveUserFile() {
            try saveActiveUserID(legacyActiveUserID)
        }
    }

    private func db() throws -> SQLiteDatabase {
        guard let database else { throw NativeStoreError.fileSystem("SQLite：用户数据库尚未准备好") }
        return database
    }

    private func readUsers() throws -> [NativeUser] {
        var users: [NativeUser] = []
        try db().query("SELECT id, name, created_at FROM users ORDER BY rowid") { row in
            guard let id = row.text(at: 0),
                  let name = row.text(at: 1),
                  let createdAt = row.text(at: 2) else {
                throw NativeStoreError.fileSystem("SQLite：用户记录不完整")
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
            throw NativeStoreError.fileSystem("无法读取 users.json：\(error.localizedDescription)")
        }
    }

    private func readActiveUserFile() throws -> String? {
        guard FileManager.default.fileExists(atPath: activeUserURL.path) else { return nil }
        do {
            return try JSONDecoder().decode(ActiveUserSelection.self, from: Data(contentsOf: activeUserURL)).userID
        } catch {
            throw NativeStoreError.fileSystem("无法读取 active-user.json：\(error.localizedDescription)")
        }
    }

    private func migrateLegacyWorkspaceIfNeeded() throws {
        let leonWorkspaceURL = try workspaceURL(for: .leon)
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
                throw NativeStoreError.fileSystem("检测到未完成的 leon 工作空间迁移，请先检查根目录和 workspaces/leon 中的文件。")
            }

            try fileManager.createDirectory(at: leonWorkspaceURL, withIntermediateDirectories: true)
            for directory in directoriesToMigrate {
                let sourceURL = rootURL.appendingPathComponent(directory)
                try fileManager.moveItem(at: sourceURL, to: leonWorkspaceURL.appendingPathComponent(directory, isDirectory: true))
            }
        }

        try migrateLegacyContentDatabaseIfNeeded(into: leonWorkspaceURL)
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
            throw NativeStoreError.fileSystem("根目录数据库同时包含用户表和文章表，请先手动分离后再打开。")
        }
        guard hasArticles else { return }

        try fileManager.createDirectory(at: leonWorkspaceURL, withIntermediateDirectories: true)
        let destination = leonWorkspaceURL.appendingPathComponent("leon-book.sqlite")
        if fileManager.fileExists(atPath: destination.path) {
            throw NativeStoreError.fileSystem("workspaces/leon 已有数据库，无法移入根目录中的旧内容库。")
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
        guard user.id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw NativeStoreError.fileSystem("用户工作空间无效")
        }
        return workspacesURL.appendingPathComponent(user.id, isDirectory: true)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            throw NativeStoreError.fileSystem("无法写入 \(url.lastPathComponent)：\(error.localizedDescription)")
        }
    }
}
