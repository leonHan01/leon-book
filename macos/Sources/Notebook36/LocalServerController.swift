import Foundation

@MainActor
final class LocalServerController {
    private var process: Process?
    private var logHandle: FileHandle?

    func ensureRunning(for siteURL: URL) async throws {
        guard Self.isLocal(siteURL) else { return }
        if await isReachable(siteURL) { return }
        try start(siteURL: siteURL)

        for _ in 0..<100 {
            if await isReachable(siteURL) { return }
            if let process, !process.isRunning {
                throw LocalServerError.exited(process.terminationStatus)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw LocalServerError.timedOut
    }

    func stop() {
        if let process, process.isRunning {
            process.terminate()
        }
        try? logHandle?.close()
        logHandle = nil
        process = nil
    }

    private func start(siteURL: URL) throws {
        guard process == nil else { return }
        guard let projectPath = Bundle.main.object(forInfoDictionaryKey: "Notebook36ProjectPath") as? String,
              FileManager.default.fileExists(atPath: projectPath) else {
            throw LocalServerError.projectMissing
        }
        guard let nodePath = Self.nodeExecutable() else {
            throw LocalServerError.nodeMissing
        }

        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notebook 36", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let logURL = supportDirectory.appendingPathComponent("local-server.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()

        let server = Process()
        server.executableURL = URL(fileURLWithPath: nodePath)
        server.currentDirectoryURL = URL(fileURLWithPath: projectPath, isDirectory: true)
        server.arguments = [
            "scripts/dev-with-storage.mjs",
            "--production",
            "--hostname", "127.0.0.1",
            "--port", String(siteURL.port ?? 3000),
        ]
        server.standardOutput = handle
        server.standardError = handle
        try server.run()
        process = server
        logHandle = handle
    }

    private func isReachable(_ siteURL: URL) async -> Bool {
        guard let statusURL = URL(string: "/api/status", relativeTo: siteURL)?.absoluteURL else { return false }
        var request = URLRequest(url: statusURL)
        request.timeoutInterval = 0.75
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private static func isLocal(_ url: URL) -> Bool {
        ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")
    }

    private static func nodeExecutable() -> String? {
        ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }
}

enum LocalServerError: LocalizedError {
    case exited(Int32)
    case nodeMissing
    case projectMissing
    case timedOut

    var errorDescription: String? {
        switch self {
        case .exited(let status):
            return "本地博客服务意外停止（状态码 \(status)）。"
        case .nodeMissing:
            return "没有找到 Node.js，无法启动本地博客服务。"
        case .projectMissing:
            return "没有找到 Notebook 36 项目目录，请重新构建应用。"
        case .timedOut:
            return "本地博客服务启动超时。"
        }
    }
}
