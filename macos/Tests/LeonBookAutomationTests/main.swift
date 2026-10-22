import Darwin
import Foundation
import LeonBookTodoModule
@testable import LeonBook

private struct Failure: Error, CustomStringConvertible { let description: String }
private func expect(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
private func call(_ service: AutomationService, _ method: String, _ params: [String: AutomationValue] = [:], user: String? = nil) async throws -> AutomationValue {
    let response = await service.handle(.init(id: .string("test"), method: method, params: params, userID: user))
    if let error = response.error { throw Failure(description: "\(method): \(error.code): \(error.message)") }
    try expect(response.id == .string("test") && response.apiVersion == 1, "response correlation/version")
    guard let result = response.result else { throw Failure(description: "missing result") }
    return result
}
private func object(_ value: AutomationValue) throws -> [String: AutomationValue] {
    guard case .object(let object) = value else { throw Failure(description: "expected object") }
    return object
}
private func expectError(_ service: AutomationService, _ method: String, _ params: [String: AutomationValue], _ code: String) async throws {
    let response = await service.handle(.init(method: method, params: params))
    try expect(response.error?.code == code, "\(method): expected \(code), got \(String(describing: response.error))")
}

@main
struct AutomationTests {
    static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leon-automation-tests-\(UUID().uuidString)")
        let suite = "leon.automation.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let service = AutomationService(rootURL: root, defaults: defaults)
        do {
            try await articles(service, root)
            try await timelineAndTasks(service)
            try await workspaceAndBackup(service, root)
            try await wrongRoot(root, defaults)
            try await transport(service, root)
            try await cli(root)
            var runtime = NativeFirstPartyModules.loadRuntime(defaults: defaults)
            _ = runtime.setEnabled(false, for: TodoFirstPartyModule.id)
            NativeFirstPartyModules.save(runtime.state, defaults: defaults)
            try await expectError(service, "todos.create", ["title": .string("blocked")], "module_disabled")
            await service.close()
            try FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
            print("PASS Automation: content lifecycle, concurrency, user isolation, backup, validation, local socket and module permissions")
        } catch {
            await service.close()
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
            fputs("FAIL Automation: \(error)\n", stderr)
            exit(1)
        }
    }

    static func articles(_ service: AutomationService, _ root: URL) async throws {
        _ = try await call(service, "capabilities")
        try expect(!FileManager.default.fileExists(atPath: root.path), "discovery must not initialize a library")
        try await expectError(service, "unknown", [:], "method_not_found")
        try await expectError(service, "articles.create", ["title": .string("missing body")], "invalid_params")
        try await expectError(service, "articles.create", ["title": .string("empty"), "body": .string("<p><br></p>")], "validation_error")
        let article: NativeArticle = try await call(service, "articles.create", ["title": .string("AI 写作测试"), "slug": .string("ai-test"), "body": .string("<h2>标题</h2><p>原始正文</p>"), "tags": .array([.string("保留标签")]), "properties": .object(["owner": .string("leon")])]).decoded()
        try expect(article.status == .draft && article.sourceRelativePath.hasSuffix(".html") && article.body.contains("<h2>标题</h2>") && !article.body.contains("&lt;h2&gt;"), "native HTML must remain rich text")
        let updated: NativeArticle = try await call(service, "articles.update", ["slug": .string(article.slug), "expectedUpdatedAt": .string(article.updatedAt), "body": .string("## 更新\n\n新的正文"), "format": .string("markdown")]).decoded()
        try expect(updated.tags == article.tags && updated.properties == article.properties && updated.title == article.title, "partial update must preserve metadata")
        try expect(updated.body.contains("<h2"), "Markdown input must convert to HTML")
        try await expectError(service, "articles.publish", ["slug": .string(article.slug), "expectedUpdatedAt": .string(article.updatedAt)], "conflict")
        let published: NativeArticle = try await call(service, "articles.publish", ["slug": .string(updated.slug), "expectedUpdatedAt": .string(updated.updatedAt)]).decoded()
        try expect(published.status == .published, "publish saved draft")
        let revisions = try await call(service, "articles.revisions", ["slug": .string(article.slug)])
        guard case .array(let history) = revisions, let first = history.last else { throw Failure(description: "missing revision history") }
        let restored: NativeArticle = try await call(service, "articles.restoreRevision", ["slug": .string(article.slug), "expectedUpdatedAt": .string(published.updatedAt), "revisionID": try object(first)["id"]!]).decoded()
        try expect(restored.updatedAt != published.updatedAt, "restore must create a new revision")
        _ = try await call(service, "articleComments.create", ["slug": .string(article.slug), "text": .string("评论")])
        _ = try await call(service, "articles.delete", ["slug": .string(article.slug), "expectedUpdatedAt": .string(restored.updatedAt)])
        try await expectError(service, "articles.get", ["slug": .string(article.slug)], "not_found")
        _ = try await call(service, "trash.restore", ["id": .string("article:" + article.slug)])
        let reopened: NativeArticle = try await call(service, "articles.get", ["slug": .string(article.slug)]).decoded()
        try expect(reopened.slug == article.slug, "restore from trash")
        try await expectError(service, "folders.create", ["path": .string("../escape")], "storage_error")
        try await expectError(service, "articles.update", ["slug": .string(article.slug), "expectedUpdatedAt": .string(reopened.updatedAt), "titel": .string("typo")], "invalid_params")
        try await expectError(service, "articles.update", ["slug": .string(article.slug), "expectedUpdatedAt": .string(reopened.updatedAt), "title": .null], "invalid_params")
        let source = root.appendingPathComponent("readonly-vault")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let other = LocalBlogStore(rootURL: root.appendingPathComponent("workspaces/leon"))
        _ = try await other.configureMarkdownWorkspaceSource(mode: .readOnlyMount, directoryURL: source)
        try await expectError(service, "articles.create", ["title": .string("readonly"), "body": .string("blocked")], "read_only")
        _ = try await other.configureMarkdownWorkspaceSource(mode: .copyImport)
        await other.closeForRestore()
    }

    static func timelineAndTasks(_ service: AutomationService) async throws {
        let post: NativeMoment = try await call(service, "moments.create", ["text": .string("第一条 #测试")]).decoded()
        let edited: NativeMoment = try await call(service, "moments.update", ["id": .string(post.id), "expectedUpdatedAt": .string(post.updatedAt), "text": .string("修改微博")]).decoded()
        try await expectError(service, "moments.update", ["id": .string(post.id), "expectedUpdatedAt": .string(post.updatedAt), "text": .string("stale")], "conflict")
        try await expectError(service, "moments.delete", ["id": .string(post.id), "expectedUpdatedAt": .string(post.updatedAt)], "conflict")
        let comment: NativeMomentComment = try await call(service, "momentComments.create", ["momentID": .string(post.id), "text": .string("评论")]).decoded()
        _ = try await call(service, "momentComments.create", ["momentID": .string(post.id), "text": .string("回复"), "parentID": .string(comment.id)])
        _ = try await call(service, "moments.delete", ["id": .string(post.id), "expectedUpdatedAt": .string(edited.updatedAt)])
        _ = try await call(service, "trash.restore", ["id": .string("moment:" + post.id)])
        let comments: [NativeMomentComment] = try await call(service, "momentComments.list", ["momentID": .string(post.id)]).decoded()
        try expect(comments.count == 2, "trash restore must preserve comment thread")
        let task: TodoItem = try await call(service, "todos.create", ["title": .string("写文章"), "notes": .string("保留备注"), "dueDay": .string("2026-10-23")]).decoded()
        let updated: TodoItem = try await call(service, "todos.update", ["id": .string(task.id), "expectedRevision": .number(Double(task.revision)), "title": .string("完成文章"), "dueDay": .null]).decoded()
        try expect(updated.notes == task.notes && updated.dueDay == nil, "task patch/null semantics")
        try await expectError(service, "todos.complete", ["id": .string(task.id), "expectedRevision": .number(Double(task.revision)), "completed": .bool(true)], "conflict")
        let removed: TodoItem = try await call(service, "todos.delete", ["id": .string(task.id), "expectedRevision": .number(Double(updated.revision))]).decoded()
        _ = try await call(service, "todos.restore", ["id": .string(task.id), "expectedRevision": .number(Double(removed.revision))])
        let question: NativeQuestion = try await call(service, "questions.create", ["title": .string("如何用 CLI？")]).decoded()
        let answer: NativeQuestionAnswer = try await call(service, "answers.create", ["questionID": .string(question.id), "body": .string("先读取 capabilities")]).decoded()
        _ = try await call(service, "answers.update", ["id": .string(answer.id), "expectedUpdatedAt": .string(answer.updatedAt), "body": .string("再读取文章"), "images": .array([])])
        try await expectError(service, "answers.update", ["id": .string(answer.id), "expectedUpdatedAt": .string(answer.updatedAt), "body": .string("stale"), "images": .array([])], "conflict")
    }

    static func workspaceAndBackup(_ service: AutomationService, _ root: URL) async throws {
        let other = try object(await call(service, "users.create", ["name": .string("other")]))
        let user: NativeUser = try other["user"]!.decoded()
        let empty: [TodoItem] = try await call(service, "todos.list", user: user.id).decoded()
        try expect(empty.isEmpty, "users must be isolated")
        let original: [TodoItem] = try await call(service, "todos.list", user: "leon").decoded()
        try expect(original.count == 1, "explicit user must address original workspace")
        _ = try await call(service, "users.select", ["id": .string("leon")])
        let destination = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-backups")
        defer { try? FileManager.default.removeItem(at: destination) }
        let backup = try object(await call(service, "backup.create", ["destination": .string(destination.path)]))
        let validation = try object(await call(service, "backup.validate", ["path": backup["path"]!]))
        try expect(validation["verifiedChecksums"] == .bool(true), "consistent backup must validate")
        let snapshotPath: String = try backup["path"]!.decoded()
        try expect(FileManager.default.fileExists(atPath: snapshotPath + "/users.json"), "backup must contain the user registry")
        try expect(FileManager.default.fileExists(atPath: snapshotPath + "/workspaces/" + user.id), "backup must include other users")
        _ = try await call(service, "todos.create", ["title": .string("after backup")])
        try await expectError(service, "trash.empty", ["confirm": .bool(false)], "confirmation_required")
    }

    static func transport(_ service: AutomationService, _ root: URL) async throws {
        let server = try AutomationSocketServer(root: root, service: service)
        defer { withExtendedLifetime(server) {} }
        let response = try await Task.detached {
            try AutomationSocket.call(.init(id: .number(7), method: "moments.create", params: ["text": .string("socket round trip")]), root: root)
        }.value
        try expect(response?.error == nil && response?.id == .number(7), "socket must return correlated response")
        let post: NativeMoment = try response!.result!.decoded()
        let fetched: NativeMoment = try await call(service, "moments.get", ["id": .string(post.id)]).decoded()
        try expect(fetched.text == "socket round trip", "socket mutation must persist through shared store")
        let attrs = try FileManager.default.attributesOfItem(atPath: AutomationSocket.path(for: root))
        try expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "socket permissions must be private")
        let missing = try await Task.detached { try AutomationSocket.call(.init(method: "capabilities"), root: root.appendingPathComponent("absent")) }.value
        try expect(missing == nil, "absent socket must permit offline fallback")
        let oversized = AutomationRequest(method: "articles.create", params: ["title": .string("too large"), "body": .string(String(repeating: "\"", count: AutomationSocket.maximumMessageBytes / 2))])
        for target in [root, root.appendingPathComponent("absent")] {
            do {
                _ = try await Task.detached { try AutomationSocket.call(oversized, root: target) }.value
                throw Failure(description: "encoded request limit must apply before online/offline routing")
            } catch let error as AutomationFailure {
                try expect(error.code == "message_too_large", "oversized request must have a specific error")
            }
        }
        // A real CLI process must route into the app-owned store even while the
        // registry lock is held by this process. Offline fallback would fail.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("LeonBookCLI")
        let reply = try await Task.detached {
            try runCLI(executable, ["moments.create", "--root", root.path, "--json", "{\"text\":\"external process\"}"])
        }.value
        try expect(reply.status == 0, "CLI must route to live socket: \(reply.text)")
        let rpc = try JSONDecoder().decode(AutomationResponse.self, from: Data(reply.text.utf8))
        let fromCLI: NativeMoment = try rpc.result!.decoded()
        let found: NativeMoment = try await call(service, "moments.get", ["id": .string(fromCLI.id)]).decoded()
        try expect(found.text == "external process", "external CLI write must be visible")
    }

    static func wrongRoot(_ root: URL, _ defaults: UserDefaults) async throws {
        let workspace = root.appendingPathComponent("workspaces/leon")
        let articleDirectory = workspace.appendingPathComponent("articles")
        try expect(FileManager.default.fileExists(atPath: articleDirectory.path), "fixture needs existing articles")
        let alias = root.appendingPathComponent("workspace-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: workspace)
        for wrong in [workspace, articleDirectory, workspace.deletingLastPathComponent(), alias] {
            let misplaced = AutomationService(rootURL: wrong, defaults: defaults)
            try await expectError(misplaced, "workspace.info", [:], "invalid_root")
            await misplaced.close()
            try expect(!FileManager.default.fileExists(atPath: wrong.appendingPathComponent("workspaces").path), "invalid root must not initialize or migrate anything")
        }
        try expect(FileManager.default.fileExists(atPath: articleDirectory.path), "wrong root must leave content in place")
        try FileManager.default.removeItem(at: alias)
    }

    static func cli(_ root: URL) async throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("LeonBookCLI")
        let isolated = root.appendingPathComponent("cli-offline")
        let reply = try await Task.detached {
            try runCLI(executable, ["--stdio", "--root", isolated.path], input: "not-json\n{\"id\":1,\"method\":\"articles.create\",\"params\":{\"title\":\"stdio\",\"body\":\"hello\"}}\n{\"id\":2,\"method\":\"articles.list\"}\n")
        }.value
        let responses = try reply.text.split(separator: "\n").map { try JSONDecoder().decode(AutomationResponse.self, from: Data($0.utf8)) }
        try expect(reply.status == 0 && responses.count == 3 && responses[0].error != nil && responses[1].error == nil && responses[2].error == nil, "stdio must recover after malformed JSON and keep stdout clean")
        let invalid = try await Task.detached { try runCLI(executable, ["articles.update", "--root", isolated.path]) }.value
        try expect(invalid.status == 1, "API errors must produce nonzero exit status")
        let usage = try await Task.detached { try runCLI(executable, ["--unknown"]) }.value
        try expect(usage.status == 2, "CLI errors must produce exit 2")

        let untouched = root.appendingPathComponent("rejected-input")
        let rejected = try await Task.detached {
            try runCLI(executable, ["--stdio", "--root", untouched.path], input:
                "{\"method\":\"articles.create\",\"userId\":\"missing\",\"params\":{\"title\":\"wrong user\",\"body\":\"must not save\"}}\n" +
                String(repeating: " ", count: AutomationSocket.maximumMessageBytes + 1) + "\n" +
                "{\"id\":\"after-error\",\"method\":\"capabilities\"}")
        }.value
        let rejectedResponses = try rejected.text.split(separator: "\n").map { try JSONDecoder().decode(AutomationResponse.self, from: Data($0.utf8)) }
        try expect(rejected.status == 0 && rejectedResponses.count == 3 && rejectedResponses[0].error?.code == "invalid_request" && rejectedResponses[1].error?.code == "message_too_large" && rejectedResponses[2].id == .string("after-error") && rejectedResponses[2].error == nil, "stdio must reject misspelled targeting, drain oversized lines, and accept a final line without newline")
        try expect(!FileManager.default.fileExists(atPath: untouched.path), "rejected targeting must not initialize the default user")

        let bodyFile = root.appendingPathComponent("oversized-body.txt")
        try String(repeating: "\"", count: AutomationSocket.maximumMessageBytes / 2).write(to: bodyFile, atomically: true, encoding: .utf8)
        let large = try await Task.detached { try runCLI(executable, ["articles.create", "--root", untouched.path, "--json", "{\"title\":\"large\",\"format\":\"text\"}", "--body-file", bodyFile.path]) }.value
        let largeResponse = try JSONDecoder().decode(AutomationResponse.self, from: Data(large.text.utf8))
        try expect(large.status == 1 && largeResponse.error?.code == "message_too_large" && !FileManager.default.fileExists(atPath: untouched.path), "body-file plus envelope escaping must be bounded before an offline write")
        try FileManager.default.removeItem(at: bodyFile)
        try interactiveCLI(executable, untouched)
    }

    static func interactiveCLI(_ executable: URL, _ root: URL) throws {
        let process = Process(), output = Pipe(), input = Pipe()
        process.executableURL = executable
        process.arguments = ["--stdio", "--root", root.path]
        process.standardOutput = output; process.standardInput = input
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        try input.fileHandleForWriting.write(contentsOf: Data("{\"id\":\"live\",\"method\":\"capabilities\"}\n".utf8))
        var readiness = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        try expect(poll(&readiness, 1, 5_000) > 0 && readiness.revents & Int16(POLLIN) != 0, "stdio must respond without waiting for EOF or a full input chunk")
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let response = try JSONDecoder().decode(AutomationResponse.self, from: data)
        try expect(response.id == .string("live") && response.error == nil, "interactive response correlation")
    }

    static func runCLI(_ executable: URL, _ arguments: [String], input: String? = nil) throws -> (status: Int32, text: String) {
        let process = Process(), output = Pipe(), stdin = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = output; process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
