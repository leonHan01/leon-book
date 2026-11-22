import Foundation

enum ChatResources {
    static let bundle: Bundle = {
        let name = "LeonBookMac_LeonChat.bundle"
        for url in [Bundle.main.resourceURL?.appendingPathComponent(name),
                    Bundle.main.bundleURL.appendingPathComponent(name)].compactMap({ $0 }) {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return .module
    }()
}

/// The integrated client has its own device identity, outbox and credentials.
/// Running the standalone Leon app alongside LeonBook cannot overwrite either.
enum ChatPreferences {
    static let defaults = UserDefaults(suiteName:
        ProcessInfo.processInfo.environment["LEON_CHAT_DEFAULTS_SUITE"] ?? "com.leon-book.chat")!
}
