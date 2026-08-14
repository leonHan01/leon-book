import Foundation

public enum AppConfiguration {
    public static let storedSiteURLKey = "notebook36.siteURL"
    public static let fallbackSiteURL = URL(string: "http://localhost:3000")!

    public static var initialSiteURL: URL {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--url"), arguments.indices.contains(index + 1),
           let url = normalizedSiteURL(arguments[index + 1]) {
            return url
        }

        if let value = ProcessInfo.processInfo.environment["NOTEBOOK36_URL"],
           let url = normalizedSiteURL(value) {
            return url
        }

        if let value = UserDefaults.standard.string(forKey: storedSiteURLKey),
           let url = normalizedSiteURL(value) {
            return url
        }

        if let value = Bundle.main.object(forInfoDictionaryKey: "Notebook36DefaultURL") as? String,
           let url = normalizedSiteURL(value) {
            return url
        }

        return fallbackSiteURL
    }

    public static func normalizedSiteURL(_ rawValue: String) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let candidate: String
        if value.contains("://") {
            candidate = value
        } else if value.hasPrefix("localhost") || value.hasPrefix("127.0.0.1") || value.hasPrefix("[::1]") {
            candidate = "http://\(value)"
        } else {
            candidate = "https://\(value)"
        }

        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              let url = components.url else {
            return nil
        }

        return url
    }
}
