import Foundation
import LeonBookBackupModule

private let savedWorkDirectoryKey = "leonBook.workDirectoryPath"
private let savedBackupDirectoryKey = "leonBook.backupDirectoryPath"
private let savedBackupPolicyKey = "leonBook.backupPolicy.v2"

extension LocalBlogStore {
    public static let defaultWorkDirectoryURL = URL(
        fileURLWithPath: "/Volumes/T7Shield/myblog",
        isDirectory: true
    )

    static var applicationSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("leon-book", isDirectory: true)
    }

    public static var defaultRootURL: URL {
        if let configured = ProcessInfo.processInfo.environment["LEON_BOOK_WORKDIR"],
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        if let saved = UserDefaults.standard.string(forKey: savedWorkDirectoryKey),
           !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: saved, isDirectory: true)
        }
        return defaultWorkDirectoryURL
    }

    public static var needsWorkDirectorySelection: Bool {
        let hasConfiguredDirectory = ProcessInfo.processInfo.environment["LEON_BOOK_WORKDIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard !hasConfiguredDirectory else { return false }
        return !FileManager.default.fileExists(atPath: defaultRootURL.path)
    }

    public static func rememberWorkDirectory(_ url: URL) {
        UserDefaults.standard.set(url.standardizedFileURL.path, forKey: savedWorkDirectoryKey)
    }

    public static var savedBackupDirectoryURL: URL? {
        guard let saved = UserDefaults.standard.string(forKey: savedBackupDirectoryKey),
              !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: saved, isDirectory: true)
    }

    public static func rememberBackupDirectory(_ url: URL) {
        UserDefaults.standard.set(url.standardizedFileURL.path, forKey: savedBackupDirectoryKey)
    }

    public static func clearBackupDirectory() {
        UserDefaults.standard.removeObject(forKey: savedBackupDirectoryKey)
    }

    public static var savedBackupPolicy: NativeBackupPolicy {
        guard let data = UserDefaults.standard.data(forKey: savedBackupPolicyKey),
              let policy = try? JSONDecoder().decode(NativeBackupPolicy.self, from: data) else {
            return .standard
        }
        return policy
    }

    public static func rememberBackupPolicy(_ policy: NativeBackupPolicy) {
        guard let data = try? JSONEncoder().encode(policy) else { return }
        UserDefaults.standard.set(data, forKey: savedBackupPolicyKey)
    }
}
