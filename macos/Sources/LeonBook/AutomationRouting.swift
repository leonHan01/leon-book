import Foundation

public enum NativeAutomationRoute: Codable, Equatable, Sendable {
    case newArticle(title: String?, content: String?, sourceURL: String?)
    case openArticle(slug: String)
    case search(query: String)
    case today

    public var commandInvocation: NativeCommandInvocation {
        switch self {
        case let .newArticle(title, content, sourceURL):
            return .newArticle(title: title, content: content, sourceURL: sourceURL)
        case let .openArticle(slug):
            return .openArticle(slug: slug)
        case let .search(query):
            return .search(query: query)
        case .today:
            return .today
        }
    }
}

public enum NativeAutomationURLError: LocalizedError, Equatable {
    case unsupportedScheme
    case unknownAction(String)
    case missingParameter(String)
    case parameterTooLong(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedScheme:
            return "只支持 leonbook:// 自动化链接。"
        case let .unknownAction(action):
            return "不支持 leonbook://\(action) 自动化操作。"
        case let .missingParameter(name):
            return "自动化链接缺少参数“\(name)”。"
        case let .parameterTooLong(name):
            return "自动化链接参数“\(name)”过长。"
        }
    }
}

public enum NativeAutomationURL {
    private static let titleLimit = 200
    private static let contentLimit = 200_000
    private static let URLLimit = 4_096
    private static let searchLimit = 1_000
    private static let slugLimit = 200

    public static func route(from url: URL) throws -> NativeAutomationRoute {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.caseInsensitiveCompare("leonbook") == .orderedSame else {
            throw NativeAutomationURLError.unsupportedScheme
        }
        let action = (components.host ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let values = Dictionary(
            components.queryItems?.map { ($0.name.lowercased(), $0.value ?? "") } ?? [],
            uniquingKeysWith: { first, _ in first }
        )

        switch action {
        case "new":
            let title = try optionalValue(values["title"] ?? values["name"], limit: titleLimit, name: "title")
            let content = try optionalPreservingValue(
                values["content"] ?? values["text"],
                limit: contentLimit,
                name: "content"
            )
            let sourceURL = try optionalValue(
                values["url"] ?? values["source"],
                limit: URLLimit,
                name: "url"
            )
            return .newArticle(title: title, content: content, sourceURL: sourceURL)

        case "open":
            guard let slug = try optionalValue(values["slug"], limit: slugLimit, name: "slug") else {
                throw NativeAutomationURLError.missingParameter("slug")
            }
            return .openArticle(slug: slug)

        case "search":
            let query = try optionalValue(
                values["q"] ?? values["query"],
                limit: searchLimit,
                name: "q"
            ) ?? ""
            return .search(query: query)

        case "today":
            return .today

        default:
            throw NativeAutomationURLError.unknownAction(action.isEmpty ? "未知" : action)
        }
    }

    public static func command(from url: URL) throws -> NativeCommandInvocation {
        try route(from: url).commandInvocation
    }

    private static func optionalValue(
        _ rawValue: String?,
        limit: Int,
        name: String
    ) throws -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= limit else { throw NativeAutomationURLError.parameterTooLong(name) }
        return value.isEmpty ? nil : value
    }

    private static func optionalPreservingValue(
        _ rawValue: String?,
        limit: Int,
        name: String
    ) throws -> String? {
        guard let rawValue else { return nil }
        guard rawValue.count <= limit else { throw NativeAutomationURLError.parameterTooLong(name) }
        return rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : rawValue
    }
}

/// Persists intent deliveries until the main app model is ready. The notification
/// handles a running app; the UserDefaults queue handles a cold launch.
public enum NativeAutomationInbox {
    public static let didEnqueueNotification = Notification.Name(
        "com.leon-book.macos.automation-route-enqueued"
    )

    private static let defaultsKey = "leon-book.pending-command-invocations.v2"
    private static let legacyDefaultsKey = "leon-book.pending-automation-routes.v1"
    private static let maximumPendingRouteCount = 12
    private static let lock = NSLock()

    public static func enqueue(_ command: NativeCommandInvocation) {
        lock.lock()
        var commands = storedCommands()
        commands.append(command)
        commands = Array(commands.suffix(maximumPendingRouteCount))
        if let data = try? JSONEncoder().encode(commands) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        lock.unlock()
        NotificationCenter.default.post(name: didEnqueueNotification, object: nil)
    }

    public static func drain() -> [NativeCommandInvocation] {
        lock.lock()
        defer { lock.unlock() }
        let commands = storedCommands()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        return commands
    }

    private static func storedCommands() -> [NativeCommandInvocation] {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let commands = try? JSONDecoder().decode([NativeCommandInvocation].self, from: data) {
            return commands
        }
        guard let data = UserDefaults.standard.data(forKey: legacyDefaultsKey),
              let routes = try? JSONDecoder().decode([NativeAutomationRoute].self, from: data) else {
            return []
        }
        return routes.map(\.commandInvocation)
    }
}
