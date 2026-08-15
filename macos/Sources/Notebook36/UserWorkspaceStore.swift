import Foundation

struct NativeWorkspaceState {
    let activeUser: NativeUser
    let users: [NativeUser]
    let workspaceURL: URL
}

/// Manages the local user registry and maps each user to an isolated workspace.
actor UserWorkspaceStore {
    private struct ActiveUserSelection: Codable {
        let userID: String
    }

    let rootURL: URL

    private var usersURL: URL { rootURL.appendingPathComponent("users.json") }
    private var activeUserURL: URL { rootURL.appendingPathComponent("active-user.json") }
    private var workspacesURL: URL { rootURL.appendingPathComponent("workspaces", isDirectory: true) }

    init(rootURL: URL = LocalBlogStore.defaultRootURL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    func prepare() throws -> NativeWorkspaceState {
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: workspacesURL, withIntermediateDirectories: true)
            try migrateLegacyWorkspaceIfNeeded()

            var users = try readUsers()
            if users.isEmpty {
                users = [NativeUser.leon]
                try writeJSON(users, to: usersURL)
            }

            let activeUserID = try readActiveUserID() ?? users[0].id
            let activeUser = users.first(where: { $0.id == activeUserID }) ?? users[0]
            if activeUser.id != activeUserID || !FileManager.default.fileExists(atPath: activeUserURL.path) {
                try writeJSON(ActiveUserSelection(userID: activeUser.id), to: activeUserURL)
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
        try writeJSON(ActiveUserSelection(userID: user.id), to: activeUserURL)
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
        try writeJSON(users, to: usersURL)
        try writeJSON(ActiveUserSelection(userID: user.id), to: activeUserURL)

        let workspaceURL = try workspaceURL(for: user)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        return NativeWorkspaceState(activeUser: user, users: users, workspaceURL: workspaceURL)
    }

    private func migrateLegacyWorkspaceIfNeeded() throws {
        let leonWorkspaceURL = try workspaceURL(for: .leon)
        let legacyDirectories = ["articles", "drafts", "media", "moments", "activity"]
        let fileManager = FileManager.default
        let directoriesToMigrate = legacyDirectories.filter {
            fileManager.fileExists(atPath: rootURL.appendingPathComponent($0, isDirectory: true).path)
        }
        guard !directoriesToMigrate.isEmpty else { return }

        let occupiedDestinations = directoriesToMigrate.filter {
            fileManager.fileExists(atPath: leonWorkspaceURL.appendingPathComponent($0, isDirectory: true).path)
        }
        guard occupiedDestinations.isEmpty else {
            throw NativeStoreError.fileSystem("检测到未完成的 leon 工作空间迁移，请先检查根目录和 workspaces/leon 中的文件。")
        }

        try fileManager.createDirectory(at: leonWorkspaceURL, withIntermediateDirectories: true)
        for directory in directoriesToMigrate {
            let sourceURL = rootURL.appendingPathComponent(directory, isDirectory: true)
            try fileManager.moveItem(at: sourceURL, to: leonWorkspaceURL.appendingPathComponent(directory, isDirectory: true))
        }
    }

    private func readUsers() throws -> [NativeUser] {
        guard FileManager.default.fileExists(atPath: usersURL.path) else { return [] }
        do {
            return try JSONDecoder().decode([NativeUser].self, from: Data(contentsOf: usersURL))
        } catch {
            throw NativeStoreError.fileSystem("无法读取 users.json：\(error.localizedDescription)")
        }
    }

    private func readActiveUserID() throws -> String? {
        guard FileManager.default.fileExists(atPath: activeUserURL.path) else { return nil }
        do {
            return try JSONDecoder().decode(ActiveUserSelection.self, from: Data(contentsOf: activeUserURL)).userID
        } catch {
            throw NativeStoreError.fileSystem("无法读取 active-user.json：\(error.localizedDescription)")
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
