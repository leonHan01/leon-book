import Foundation
import LeonBookModuleKit

enum NativeBackupTimestamp {
    private static let lock = NSLock()
    private static let standard = ISO8601DateFormatter()
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter
    }()

    static func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return fractional.string(from: date)
    }

    static func date(from value: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return standard.date(from: value) ?? fractional.date(from: value)
    }
}

public enum BackupFirstPartyModule: FirstPartyModule {
    public static let id = FirstPartyModuleID(rawValue: "backup")
    public static let descriptor = FirstPartyModuleDescriptor(
        id: id,
        name: "备份",
        summary: "快照创建、校验、保留与恢复。",
        systemImage: "externaldrive.badge.timemachine",
        permissions: [.fileRead, .fileWrite, .backupRead, .backupWrite],
        commands: [
            .init(
                id: "backup.create",
                title: "立即备份",
                detail: "使用当前备份策略创建资料库快照",
                keywords: "backup snapshot 备份",
                systemImage: "externaldrive.badge.timemachine",
                availability: .storageReadyAndIdle,
                surfaces: [.palette],
                requiredPermissions: [.backupWrite]
            ),
        ],
        eventNames: ["backup.requested", "backup.completed", "backup.failed", "backup.restored"]
    )
}

public enum FirstPartyBackupLocationError: LocalizedError, Equatable {
    case missingSource(String)
    case destinationInsideSource

    public var errorDescription: String? {
        switch self {
        case let .missingSource(path): return "源数据目录不存在：\(path)"
        case .destinationInsideSource: return "备份目录不能位于源数据目录内部，请选择另一块磁盘或其他目录。"
        }
    }
}

public enum NativeBackupError: LocalizedError, Equatable {
    case fileSystem(String)

    public var errorDescription: String? {
        switch self {
        case let .fileSystem(message): return message
        }
    }
}

/// Filesystem boundary policy kept independent from the snapshot implementation.
public enum FirstPartyBackupLocationPolicy {
    public static func validate(
        source: URL,
        destination: URL,
        fileManager: FileManager = .default
    ) throws {
        let sourceURL = source.standardizedFileURL.resolvingSymlinksInPath()
        let destinationURL = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw FirstPartyBackupLocationError.missingSource(sourceURL.path)
        }
        guard !isSameOrDescendant(destinationURL, of: sourceURL) else {
            throw FirstPartyBackupLocationError.destinationInsideSource
        }
    }

    public static func isSameOrDescendant(_ candidate: URL, of parent: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let parentPath = parent.standardizedFileURL.resolvingSymlinksInPath().path
        return candidatePath == parentPath || candidatePath.hasPrefix(parentPath + "/")
    }
}
