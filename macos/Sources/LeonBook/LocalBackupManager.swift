import CryptoKit
import Darwin
import Foundation

public struct NativeBackupPolicy: Codable, Equatable, Sendable {
    public static let standard = NativeBackupPolicy()

    public let automaticInterval: TimeInterval
    public let retentionDays: Int
    public let maximumSnapshotCount: Int
    public let minimumFreeSpaceBytes: Int64

    public init(
        automaticInterval: TimeInterval = 60 * 60,
        retentionDays: Int = 90,
        maximumSnapshotCount: Int = 60,
        minimumFreeSpaceBytes: Int64 = 10 * 1_024 * 1_024 * 1_024
    ) {
        self.automaticInterval = max(15 * 60, automaticInterval)
        self.retentionDays = min(max(retentionDays, 1), 3_650)
        self.maximumSnapshotCount = min(max(maximumSnapshotCount, 1), 1_000)
        self.minimumFreeSpaceBytes = max(0, minimumFreeSpaceBytes)
    }

    private enum CodingKeys: String, CodingKey {
        case automaticInterval
        case retentionDays
        case maximumSnapshotCount
        case minimumFreeSpaceBytes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            automaticInterval: try values.decodeIfPresent(TimeInterval.self, forKey: .automaticInterval) ?? 60 * 60,
            retentionDays: try values.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 90,
            maximumSnapshotCount: try values.decodeIfPresent(Int.self, forKey: .maximumSnapshotCount) ?? 60,
            minimumFreeSpaceBytes: try values.decodeIfPresent(Int64.self, forKey: .minimumFreeSpaceBytes) ?? 10 * 1_024 * 1_024 * 1_024
        )
    }
}

public struct NativeBackupSnapshot: Hashable, Identifiable, Sendable {
    public let url: URL
    public let createdAt: Date
    public let logicalSizeBytes: Int64
    public let storedSizeBytes: Int64
    public let fileCount: Int
    public let formatVersion: Int
    public let reusedFileCount: Int
    public let isManifestReadable: Bool

    public var id: String { url.standardizedFileURL.path }
}

public struct NativeBackupCreationResult: Sendable {
    public let snapshot: NativeBackupSnapshot
    public let reusedFileCount: Int
    public let clonedFileCount: Int
    public let copiedFileCount: Int
    public let removedSnapshotCount: Int
}

public struct NativeBackupValidationResult: Sendable {
    public let snapshot: NativeBackupSnapshot
    public let checkedFileCount: Int
    public let verifiedChecksums: Bool
}

public struct NativeBackupStorageEstimate: Sendable {
    public let sourceSizeBytes: Int64
    public let estimatedAdditionalBytes: Int64
    public let availableBytes: Int64?
    public let reusableFileCount: Int
}

/// Creates bounded, verifiable snapshots of the complete leon-book data root.
/// Unchanged files are cloned from the preceding snapshot (or hard-linked when
/// cloning is unavailable), so frequent snapshots do not duplicate media data.
public enum LocalBackupManager {
    private static let lockFileName = ".leon-book.lock"
    private static let manifestFileName = "backup-manifest.json"
    private static let currentFormatVersion = 2
    private static let temporaryPrefix = ".in-progress-"
    private static let restorePrefix = ".leon-book-restore-"
    private static let previousPrefix = ".leon-book-before-restore-"
    private static let checksumChunkSize = 4 * 1_024 * 1_024

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

    /// Compatibility entry point used by store checks and older callers.
    /// Managed app backups use `createManagedSnapshot` with the saved policy.
    public static func createSnapshot(source: URL, destination: URL) throws -> URL {
        try createManagedSnapshot(
            source: source,
            destination: destination,
            policy: NativeBackupPolicy(minimumFreeSpaceBytes: 0)
        ).snapshot.url
    }

    public static func createManagedSnapshot(
        source: URL,
        destination: URL,
        policy: NativeBackupPolicy = .standard,
        enforceRetention shouldEnforceRetention: Bool = true
    ) throws -> NativeBackupCreationResult {
        try validateDestination(source: source, destination: destination)

        let fileManager = FileManager.default
        let sourceURL = source.standardizedFileURL.resolvingSymlinksInPath()
        let destinationURL = destination.standardizedFileURL
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        removeAbandonedTemporaryDirectories(in: destinationURL, using: fileManager)
        var removedSnapshots = shouldEnforceRetention
            ? try enforceRetention(in: destinationURL, policy: policy)
            : []

        let sourceFiles = try files(in: sourceURL, excludingManifest: false)
        let precedingSnapshot = try listSnapshots(in: destinationURL).first
        let precedingManifest = precedingSnapshot.flatMap { try? readManifest(at: $0.url) }
        let precedingRecords = Dictionary(
            uniqueKeysWithValues: (precedingManifest?.files ?? []).map { ($0.relativePath, $0) }
        )
        let estimate = storageEstimate(
            sourceFiles: sourceFiles,
            precedingSnapshot: precedingSnapshot,
            precedingRecords: precedingRecords,
            destination: destinationURL
        )
        if let availableBytes = estimate.availableBytes {
            try ensureSufficientCapacity(
                availableBytes: availableBytes,
                estimatedAdditionalBytes: estimate.estimatedAdditionalBytes,
                minimumFreeSpaceBytes: policy.minimumFreeSpaceBytes
            )
        }

        let finalURL = nextSnapshotURL(in: destinationURL)
        let temporaryURL = destinationURL.appendingPathComponent(
            "\(temporaryPrefix)\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: true)

        var records: [NativeBackupFileRecord] = []
        var reusedFileCount = 0
        var clonedFileCount = 0
        var copiedFileCount = 0

        do {
            for sourceFile in sourceFiles {
                let targetURL = temporaryURL.appendingPathComponent(sourceFile.relativePath)
                try fileManager.createDirectory(
                    at: targetURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                let precedingRecord = precedingRecords[sourceFile.relativePath]
                let precedingFileURL = precedingSnapshot?.url.appendingPathComponent(sourceFile.relativePath)
                let canReuse = precedingRecord.map { recordMatchesSource($0, source: sourceFile) } == true
                    && precedingFileURL.map { fileManager.fileExists(atPath: $0.path) } == true
                let checksum: String

                if canReuse, let precedingRecord, let precedingFileURL {
                    if cloneFile(at: precedingFileURL, to: targetURL) {
                        clonedFileCount += 1
                    } else if (try? fileManager.linkItem(at: precedingFileURL, to: targetURL)) != nil {
                        // Hard links are the portable incremental fallback. The app
                        // never edits files inside a snapshot.
                    } else if cloneFile(at: sourceFile.url, to: targetURL) {
                        clonedFileCount += 1
                    } else {
                        try fileManager.copyItem(at: sourceFile.url, to: targetURL)
                        copiedFileCount += 1
                    }
                    reusedFileCount += 1
                    checksum = precedingRecord.sha256.isEmpty
                        ? try sha256(of: targetURL)
                        : precedingRecord.sha256
                } else {
                    if cloneFile(at: sourceFile.url, to: targetURL) {
                        clonedFileCount += 1
                    } else {
                        try fileManager.copyItem(at: sourceFile.url, to: targetURL)
                        copiedFileCount += 1
                    }
                    checksum = try sha256(of: targetURL)
                }

                records.append(NativeBackupFileRecord(
                    relativePath: sourceFile.relativePath,
                    sizeBytes: sourceFile.sizeBytes,
                    allocatedSizeBytes: sourceFile.allocatedSizeBytes,
                    modificationTime: sourceFile.modificationTime,
                    sha256: checksum
                ))
            }

            let createdAt = Date()
            let manifest = NativeBackupManifest(
                formatVersion: currentFormatVersion,
                createdAt: NativeTimestamp.string(from: createdAt),
                logicalSizeBytes: records.reduce(0) { $0 + $1.sizeBytes },
                storedSizeBytes: records.reduce(0) { $0 + $1.allocatedSizeBytes },
                reusedFileCount: reusedFileCount,
                clonedFileCount: clonedFileCount,
                copiedFileCount: copiedFileCount,
                files: records.sorted { $0.relativePath < $1.relativePath }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(manifest).write(
                to: temporaryURL.appendingPathComponent(manifestFileName),
                options: .atomic
            )
            try fileManager.moveItem(at: temporaryURL, to: finalURL)

            if shouldEnforceRetention {
                removedSnapshots.append(contentsOf: try enforceRetention(in: destinationURL, policy: policy))
            }
            guard let snapshot = try listSnapshots(in: destinationURL).first(where: { $0.url == finalURL }) else {
                throw NativeStoreError.fileSystem("备份完成，但无法重新读取快照清单")
            }
            return NativeBackupCreationResult(
                snapshot: snapshot,
                reusedFileCount: reusedFileCount,
                clonedFileCount: clonedFileCount,
                copiedFileCount: copiedFileCount,
                removedSnapshotCount: Set(removedSnapshots).count
            )
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            if let error = error as? NativeStoreError { throw error }
            throw NativeStoreError.fileSystem("备份失败：\(error.localizedDescription)")
        }
    }

    public static func listSnapshots(in destination: URL) throws -> [NativeBackupSnapshot] {
        let fileManager = FileManager.default
        let destinationURL = destination.standardizedFileURL
        guard fileManager.fileExists(atPath: destinationURL.path) else { return [] }
        let children = try fileManager.contentsOfDirectory(
            at: destinationURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsSubdirectoryDescendants]
        )

        return children.compactMap { url -> NativeBackupSnapshot? in
            guard !url.lastPathComponent.hasPrefix("."),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            if let manifest = try? readManifest(at: url) {
                return snapshot(from: manifest, at: url, manifestReadable: true)
            }
            guard fileManager.fileExists(atPath: url.appendingPathComponent(manifestFileName).path) else {
                return nil
            }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return NativeBackupSnapshot(
                url: url,
                createdAt: modified,
                logicalSizeBytes: 0,
                storedSizeBytes: 0,
                fileCount: 0,
                formatVersion: 0,
                reusedFileCount: 0,
                isManifestReadable: false
            )
        }
        .sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.url.lastPathComponent > $1.url.lastPathComponent
        }
    }

    @discardableResult
    public static func enforceRetention(
        in destination: URL,
        policy: NativeBackupPolicy,
        now: Date = Date()
    ) throws -> [URL] {
        let snapshots = try listSnapshots(in: destination)
        guard snapshots.count > 1 else { return [] }
        let cutoff = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: -policy.retentionDays,
            to: now
        ) ?? .distantPast
        var removed: [URL] = []

        // Always retain the newest valid snapshot. Older snapshots expire when
        // either the age or count boundary is exceeded.
        for (index, snapshot) in snapshots.enumerated() where index > 0 {
            guard index >= policy.maximumSnapshotCount || snapshot.createdAt < cutoff else { continue }
            try FileManager.default.removeItem(at: snapshot.url)
            removed.append(snapshot.url)
        }
        return removed
    }

    public static func estimateStorage(
        source: URL,
        destination: URL
    ) throws -> NativeBackupStorageEstimate {
        try validateDestination(source: source, destination: destination)
        let destinationURL = destination.standardizedFileURL
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        let sourceFiles = try files(in: source.standardizedFileURL.resolvingSymlinksInPath(), excludingManifest: false)
        let precedingSnapshot = try listSnapshots(in: destinationURL).first
        let precedingManifest = precedingSnapshot.flatMap { try? readManifest(at: $0.url) }
        let records = Dictionary(uniqueKeysWithValues: (precedingManifest?.files ?? []).map { ($0.relativePath, $0) })
        return storageEstimate(
            sourceFiles: sourceFiles,
            precedingSnapshot: precedingSnapshot,
            precedingRecords: records,
            destination: destinationURL
        )
    }

    public static func ensureSufficientCapacity(
        availableBytes: Int64,
        estimatedAdditionalBytes: Int64,
        minimumFreeSpaceBytes: Int64
    ) throws {
        let remaining = availableBytes - max(0, estimatedAdditionalBytes)
        guard remaining >= max(0, minimumFreeSpaceBytes) else {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let available = formatter.string(fromByteCount: availableBytes)
            let estimated = formatter.string(fromByteCount: estimatedAdditionalBytes)
            let minimum = formatter.string(fromByteCount: minimumFreeSpaceBytes)
            throw NativeStoreError.fileSystem(
                "备份会使目标磁盘剩余空间低于 \(minimum)（当前可用 \(available)，预计新增 \(estimated)）"
            )
        }
    }

    public static func validateSnapshot(at snapshot: URL) throws -> NativeBackupValidationResult {
        let snapshotURL = snapshot.standardizedFileURL.resolvingSymlinksInPath()
        let manifest: NativeBackupManifest
        do {
            manifest = try readManifest(at: snapshotURL)
        } catch {
            throw NativeStoreError.fileSystem("快照校验失败：无法读取备份清单")
        }
        let info = self.snapshot(from: manifest, at: snapshotURL, manifestReadable: true)
        let actualFiles = try files(in: snapshotURL, excludingManifest: true)

        guard manifest.formatVersion >= currentFormatVersion, !manifest.files.isEmpty else {
            guard actualFiles.contains(where: { $0.relativePath == "leon-book.sqlite" }) else {
                throw NativeStoreError.fileSystem("快照校验失败：旧格式快照缺少 leon-book.sqlite")
            }
            return NativeBackupValidationResult(
                snapshot: info,
                checkedFileCount: actualFiles.count,
                verifiedChecksums: false
            )
        }

        let actualByPath = Dictionary(uniqueKeysWithValues: actualFiles.map { ($0.relativePath, $0) })
        let expectedPaths = Set(manifest.files.map(\.relativePath))
        guard expectedPaths.count == manifest.files.count,
              Set(actualByPath.keys) == expectedPaths else {
            throw NativeStoreError.fileSystem("快照校验失败：文件列表与备份清单不一致")
        }

        for record in manifest.files {
            guard isSafeRelativePath(record.relativePath),
                  let file = actualByPath[record.relativePath],
                  file.sizeBytes == record.sizeBytes,
                  try sha256(of: file.url) == record.sha256 else {
                throw NativeStoreError.fileSystem("快照校验失败：\(record.relativePath) 已损坏或被修改")
            }
        }
        return NativeBackupValidationResult(
            snapshot: info,
            checkedFileCount: manifest.files.count,
            verifiedChecksums: true
        )
    }

    /// Restores a validated snapshot through a sibling staging directory. The
    /// caller must close SQLite connections and directory locks before invoking
    /// this operation. Backup metadata and lock files are never restored.
    public static func restoreSnapshot(
        at snapshot: URL,
        to destination: URL,
        minimumFreeSpaceBytes: Int64
    ) throws {
        _ = try validateSnapshot(at: snapshot)
        let fileManager = FileManager.default
        let snapshotURL = snapshot.standardizedFileURL.resolvingSymlinksInPath()
        let destinationURL = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard !isSameOrDescendant(snapshotURL, of: destinationURL),
              !isSameOrDescendant(destinationURL, of: snapshotURL) else {
            throw NativeStoreError.fileSystem("恢复来源与数据目录不能相互包含")
        }

        let parentURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let incomingFiles = try files(in: snapshotURL, excludingManifest: true)
        let requiredBytes = incomingFiles.reduce(0) { $0 + $1.allocatedSizeBytes }
        if let availableBytes = availableCapacity(at: parentURL) {
            try ensureSufficientCapacity(
                availableBytes: availableBytes,
                estimatedAdditionalBytes: requiredBytes,
                minimumFreeSpaceBytes: minimumFreeSpaceBytes
            )
        }

        let identifier = UUID().uuidString.lowercased()
        let stagingURL = parentURL.appendingPathComponent("\(restorePrefix)\(identifier)", isDirectory: true)
        let previousURL = parentURL.appendingPathComponent("\(previousPrefix)\(identifier)", isDirectory: true)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        var movedLiveData = false

        do {
            for sourceFile in incomingFiles {
                let targetURL = stagingURL.appendingPathComponent(sourceFile.relativePath)
                try fileManager.createDirectory(
                    at: targetURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if !cloneFile(at: sourceFile.url, to: targetURL) {
                    try fileManager.copyItem(at: sourceFile.url, to: targetURL)
                }
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.moveItem(at: destinationURL, to: previousURL)
                movedLiveData = true
            }
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
            if movedLiveData { try? fileManager.removeItem(at: previousURL) }
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            if movedLiveData, fileManager.fileExists(atPath: previousURL.path) {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try? fileManager.removeItem(at: destinationURL)
                }
                try? fileManager.moveItem(at: previousURL, to: destinationURL)
            }
            if let error = error as? NativeStoreError { throw error }
            throw NativeStoreError.fileSystem("恢复失败，原数据已保留：\(error.localizedDescription)")
        }
    }
}

private extension LocalBackupManager {
    struct SourceFile {
        let url: URL
        let relativePath: String
        let sizeBytes: Int64
        let allocatedSizeBytes: Int64
        let modificationTime: TimeInterval
    }

    struct NativeBackupFileRecord: Codable {
        let relativePath: String
        let sizeBytes: Int64
        let allocatedSizeBytes: Int64
        let modificationTime: TimeInterval
        let sha256: String
    }

    struct NativeBackupManifest: Codable {
        let formatVersion: Int
        let createdAt: String
        let logicalSizeBytes: Int64
        let storedSizeBytes: Int64
        let reusedFileCount: Int
        let clonedFileCount: Int
        let copiedFileCount: Int
        let files: [NativeBackupFileRecord]

        init(
            formatVersion: Int,
            createdAt: String,
            logicalSizeBytes: Int64,
            storedSizeBytes: Int64,
            reusedFileCount: Int,
            clonedFileCount: Int,
            copiedFileCount: Int,
            files: [NativeBackupFileRecord]
        ) {
            self.formatVersion = formatVersion
            self.createdAt = createdAt
            self.logicalSizeBytes = logicalSizeBytes
            self.storedSizeBytes = storedSizeBytes
            self.reusedFileCount = reusedFileCount
            self.clonedFileCount = clonedFileCount
            self.copiedFileCount = copiedFileCount
            self.files = files
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
            createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
            logicalSizeBytes = try container.decodeIfPresent(Int64.self, forKey: .logicalSizeBytes) ?? 0
            storedSizeBytes = try container.decodeIfPresent(Int64.self, forKey: .storedSizeBytes) ?? 0
            reusedFileCount = try container.decodeIfPresent(Int.self, forKey: .reusedFileCount) ?? 0
            clonedFileCount = try container.decodeIfPresent(Int.self, forKey: .clonedFileCount) ?? 0
            copiedFileCount = try container.decodeIfPresent(Int.self, forKey: .copiedFileCount) ?? 0
            files = try container.decodeIfPresent([NativeBackupFileRecord].self, forKey: .files) ?? []
        }
    }

    static func files(in root: URL, excludingManifest: Bool) throws -> [SourceFile] {
        let fileManager = FileManager.default
        var results: [SourceFile] = []

        func visit(_ directory: URL, relativeDirectory: String) throws {
            let children = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                    .totalFileAllocatedSizeKey,
                    .contentModificationDateKey,
                ],
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }

            for child in children {
                guard child.lastPathComponent != lockFileName else { continue }
                if excludingManifest, relativeDirectory.isEmpty, child.lastPathComponent == manifestFileName {
                    continue
                }
                let values = try child.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                    .totalFileAllocatedSizeKey,
                    .contentModificationDateKey,
                ])
                guard values.isSymbolicLink != true else {
                    throw NativeStoreError.fileSystem("备份不跟随符号链接：\(child.lastPathComponent)")
                }
                let relativePath = relativeDirectory.isEmpty
                    ? child.lastPathComponent
                    : "\(relativeDirectory)/\(child.lastPathComponent)"
                guard isSafeRelativePath(relativePath) else {
                    throw NativeStoreError.fileSystem("备份中发现不安全路径：\(relativePath)")
                }
                if values.isDirectory == true {
                    try visit(child, relativeDirectory: relativePath)
                } else if values.isRegularFile == true {
                    let size = Int64(values.fileSize ?? 0)
                    results.append(SourceFile(
                        url: child,
                        relativePath: relativePath,
                        sizeBytes: size,
                        allocatedSizeBytes: Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0),
                        modificationTime: values.contentModificationDate?.timeIntervalSince1970 ?? 0
                    ))
                }
            }
        }

        try visit(root, relativeDirectory: "")
        return results
    }

    static func storageEstimate(
        sourceFiles: [SourceFile],
        precedingSnapshot: NativeBackupSnapshot?,
        precedingRecords: [String: NativeBackupFileRecord],
        destination: URL
    ) -> NativeBackupStorageEstimate {
        var additional: Int64 = 1 * 1_024 * 1_024 // directory entries and manifest reserve
        var reusable = 0
        for file in sourceFiles {
            if let record = precedingRecords[file.relativePath],
               recordMatchesSource(record, source: file),
               precedingSnapshot.map({ FileManager.default.fileExists(atPath: $0.url.appendingPathComponent(file.relativePath).path) }) == true {
                reusable += 1
            } else {
                additional += file.allocatedSizeBytes
            }
        }
        return NativeBackupStorageEstimate(
            sourceSizeBytes: sourceFiles.reduce(0) { $0 + $1.sizeBytes },
            estimatedAdditionalBytes: additional,
            availableBytes: availableCapacity(at: destination),
            reusableFileCount: reusable
        )
    }

    static func recordMatchesSource(_ record: NativeBackupFileRecord, source: SourceFile) -> Bool {
        record.sizeBytes == source.sizeBytes
            && abs(record.modificationTime - source.modificationTime) < 0.001
            && !record.sha256.isEmpty
    }

    static func readManifest(at snapshot: URL) throws -> NativeBackupManifest {
        try JSONDecoder().decode(
            NativeBackupManifest.self,
            from: Data(contentsOf: snapshot.appendingPathComponent(manifestFileName))
        )
    }

    static func snapshot(
        from manifest: NativeBackupManifest,
        at url: URL,
        manifestReadable: Bool
    ) -> NativeBackupSnapshot {
        NativeBackupSnapshot(
            url: url.standardizedFileURL,
            createdAt: NativeTimestamp.date(from: manifest.createdAt) ?? .distantPast,
            logicalSizeBytes: manifest.logicalSizeBytes,
            storedSizeBytes: manifest.storedSizeBytes,
            fileCount: manifest.files.count,
            formatVersion: manifest.formatVersion,
            reusedFileCount: manifest.reusedFileCount,
            isManifestReadable: manifestReadable
        )
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: checksumChunkSize), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func cloneFile(at source: URL, to destination: URL) -> Bool {
        source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                clonefile(sourcePath, destinationPath, 0) == 0
            }
        }
    }

    static func availableCapacity(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values?.volumeAvailableCapacityForImportantUsage,
              capacity > 0 else { return nil }
        return capacity
    }

    static func nextSnapshotURL(in destination: URL) -> URL {
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

    static func removeAbandonedTemporaryDirectories(in destination: URL, using fileManager: FileManager) {
        guard let children = try? fileManager.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsSubdirectoryDescendants]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for child in children where child.lastPathComponent.hasPrefix(temporaryPrefix) {
            let modified = try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if modified == nil || modified! < cutoff { try? fileManager.removeItem(at: child) }
        }
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    static func isSameOrDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let ancestorPath = ancestor.standardizedFileURL.path
        let prefix = ancestorPath.hasSuffix("/") ? ancestorPath : ancestorPath + "/"
        return candidatePath == ancestorPath || candidatePath.hasPrefix(prefix)
    }
}
