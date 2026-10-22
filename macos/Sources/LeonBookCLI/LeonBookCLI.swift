import Darwin
import Foundation
import LeonBook

@main
struct LeonBookCLI {
    static func main() async {
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            if options.help { print(help); return }
            if options.stdio {
                // JSON Lines: one complete request per line, no prompts/banners.
                var input = AutomationInput(.standardInput)
                while true {
                    let data: Data
                    do {
                        guard let line = try input.nextLine() else { break }
                        data = line
                    } catch let error as AutomationFailure where error.code == "message_too_large" {
                        output(.init(error: error)); continue
                    }
                    do {
                        var request = try JSONDecoder().decode(AutomationRequest.self, from: data)
                        if request.userID == nil { request.userID = options.userID }
                        output(await dispatch(request, root: options.root))
                    } catch { output(.init(error: failure(error))) }
                }
            } else {
                var params: [String: AutomationValue] = [:]
                if let json = options.json {
                    let data = json == "-" ? try AutomationInput.readAll(.standardInput)
                        : json.hasPrefix("@") ? try AutomationInput.readFile(String(json.dropFirst())) : Data(json.utf8)
                    guard data.count <= AutomationSocket.maximumMessageBytes else { throw AutomationFailure("message_too_large", "Request exceeds 8 MiB") }
                    params = try JSONDecoder().decode([String: AutomationValue].self, from: data)
                }
                if let path = options.bodyFile {
                    guard params["body"] == nil else { throw AutomationFailure("invalid_params", "Use body or --body-file, not both") }
                    let data = try AutomationInput.readFile(path)
                    guard let body = String(data: data, encoding: .utf8) else { throw AutomationFailure("invalid_params", "Body file must be UTF-8") }
                    params["body"] = .string(body)
                }
                let response = await dispatch(.init(method: options.method, params: params, userID: options.userID), root: options.root)
                output(response)
                if response.error != nil { exit(1) }
            }
        } catch { output(.init(error: failure(error))); exit(2) }
    }

    private static func dispatch(_ request: AutomationRequest, root: URL) async -> AutomationResponse {
        do {
            // Blocking socket I/O stays off the main actor, also in --stdio mode.
            if let response = try await Task.detached(operation: { try AutomationSocket.call(request, root: root) }).value { return response }
            let service = AutomationService(rootURL: root, defaults: appDefaults)
            let response = await service.handle(request)
            await service.close()
            return response
        } catch { return .init(id: request.id, error: failure(error)) }
    }

    private static func output(_ response: AutomationResponse) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            var data = try encoder.encode(response)
            data.append(10)
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch {
            FileHandle.standardError.write(Data("Cannot write JSON response: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func failure(_ error: Error) -> AutomationFailure {
        if let failure = error as? AutomationFailure { return failure }
        return .init(error is DecodingError ? "invalid_request" : "cli_error", error.localizedDescription)
    }

    private static var appDefaults: UserDefaults {
        // Inside the .app, standard already resolves to the app's domain.
        // SwiftPM's standalone CLI needs to select that domain explicitly.
        Bundle.main.bundleIdentifier == "com.leon-book.macos"
            ? .standard : UserDefaults(suiteName: "com.leon-book.macos") ?? .standard
    }

    private struct Options {
        var root = LocalBlogStore.defaultRootURL
        var userID: String?
        var method = "capabilities"
        var json: String?
        var bodyFile: String?
        var stdio = false
        var help = false

        init(_ arguments: [String]) throws {
            if ProcessInfo.processInfo.environment["LEON_BOOK_WORKDIR"] == nil,
               let saved = LeonBookCLI.appDefaults.string(forKey: "leonBook.workDirectoryPath") {
                root = URL(fileURLWithPath: saved, isDirectory: true)
            }
            var index = 0, hasMethod = false
            var seen = Set<String>()
            while index < arguments.count {
                let argument = arguments[index]
                if argument.hasPrefix("--"), !seen.insert(argument).inserted { throw AutomationFailure("invalid_params", "Duplicate option \(argument)") }
                switch argument {
                case "--help", "-h", "help": help = true
                case "--stdio": stdio = true
                case "--root", "--user", "--json", "--body-file":
                    index += 1
                    guard index < arguments.count else { throw AutomationFailure("invalid_params", "Missing value for \(argument)") }
                    let value = arguments[index]
                    switch argument {
                    case "--root": root = URL(fileURLWithPath: value, isDirectory: true)
                    case "--user": userID = value
                    case "--json": json = value
                    default: bodyFile = value
                    }
                default:
                    guard !argument.hasPrefix("-"), !hasMethod else { throw AutomationFailure("invalid_params", "Unexpected argument '\(argument)'") }
                    method = argument; hasMethod = true
                }
                index += 1
            }
            guard !stdio || (!hasMethod && json == nil && bodyFile == nil) else { throw AutomationFailure("invalid_params", "--stdio cannot be combined with a method, --json or --body-file") }
        }
    }

    private static let help = """
    leonbook — local AI automation, JSON API v1

    leonbook capabilities
    leonbook METHOD [--json '{...}' | --json @file.json | --json -]
                    [--body-file article.html] [--root DATA_ROOT] [--user USER_ID]
    leonbook --stdio [--root DATA_ROOT] [--user USER_ID]

    Examples:
      leonbook articles.create --json '{"title":"Hello","body":"<p>World</p>"}'
      leonbook articles.get --json '{"slug":"hello"}'
      leonbook moments.create --json '{"text":"Hello #LeonBook"}'

    Uses the running app's same-user Unix socket, or the local store if it is closed.
    --root is the DATA ROOT containing workspaces/, not an individual workspace.
    Edits require the updatedAt/ revision returned by the preceding read.
    stdout contains JSON only. One-shot exit codes: 0 success, 1 operation error,
    2 invalid CLI/request. --stdio reads and returns one JSON object per line.
    Run capabilities for the complete operation catalog. This is not MCP.
    """
}
