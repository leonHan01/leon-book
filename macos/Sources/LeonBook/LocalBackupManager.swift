import Foundation

/// Creates complete, timestamped snapshots of the local leon-book data root.
public enum LocalBackupManager {
    private static let lockFileName = ".leon-book.lock"

    public static func validateDestination(source: URL, destination: URL) throws {
        let sourceURL = source.standardizedFileURL.resolvingSymlinksInPath()
        let destinationURL = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw NativeStoreError.fileSystem("源数据目录不存在：\(sourceURL.path)")
        }
        guard !isSameOrDescendant(destinationURL, of: sourceURL) else {
            throw NativeStoreError.fileSystem("备份目录不能位于源数据目录内部，请选择另一块磁盘或其他目录。")
        }
    }

    /// Copies the complete source root into a new timestamped child directory.
    /// The temporary directory is removed if any file fails to copy, so callers
    /// never mistake a partial snapshot for a completed backup.
    public static func createSnapshot(source: URL, destination: URL) throws -> URL {
        try validateDestination(source: source, destination: destination)

        let fileManager = FileManager.default
        let sourceURL = source.standardizedFileURL.resolvingSymlinksInPath()
        let destinationURL = destination.standardizedFileURL
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let finalURL = nextSnapshotURL(in: destinationURL)
        let temporaryURL = destinationURL.appendingPathComponent(
            ".in-progress-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: true)

        do {
            let entries = try fileManager.contentsOfDirectory(
                at: sourceURL,
                includingPropertiesForKeys: nil,
                options: []
            )
            for entry in entries {
                let target = temporaryURL.appendingPathComponent(entry.lastPathComponent, isDirectory: entry.hasDirectoryPath)
                try copyEntry(at: entry, to: target, using: fileManager)
            }

            let manifest = NativeBackupManifest(
                formatVersion: 1,
                createdAt: NativeTimestamp.string(from: Date())
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(
                to: temporaryURL.appendingPathComponent("backup-manifest.json"),
                options: .atomic
            )
            try fileManager.moveItem(at: temporaryURL, to: finalURL)
            return finalURL
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw NativeStoreError.fileSystem("备份失败：\(error.localizedDescription)")
        }
    }

    private static func nextSnapshotURL(in destination: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let baseName = formatter.string(from: Date())
        let fileManager = FileManager.default
        var candidate = destination.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = destination.appendingPathComponent("\(baseName)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private static func copyEntry(at source: URL, to destination: URL, using fileManager: FileManager) throws {
        guard source.lastPathComponent != lockFileName else { return }
        if source.hasDirectoryPath {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            let children = try fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: nil,
                options: []
            )
            for child in children {
                let target = destination.appendingPathComponent(child.lastPathComponent, isDirectory: child.hasDirectoryPath)
                try copyEntry(at: child, to: target, using: fileManager)
            }
        } else {
            try fileManager.copyItem(at: source, to: destination)
        }
    }

    private static func isSameOrDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let ancestorPath = ancestor.path.hasSuffix("/") ? ancestor.path : ancestor.path + "/"
        return candidate.path == ancestor.path || candidate.path.hasPrefix(ancestorPath)
    }
}

private struct NativeBackupManifest: Codable {
    let formatVersion: Int
    let createdAt: String
}
