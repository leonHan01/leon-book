import Foundation

struct NativePortableSidecarTombstone: Codable, Equatable, Hashable {
    let id: String
    let deletedAt: String
}

struct NativePortableRevisionRecord: Codable, Equatable, Hashable, Identifiable {
    let id: String
    let draftKey: String
    let articleSlug: String?
    let reason: NativeArticleRevisionReason
    let snapshot: NativeArticleRevisionSnapshot
    let createdAt: String
    let updatedAt: String

    init(revision: NativeArticleRevision) {
        id = revision.syncID
        draftKey = revision.draftKey
        articleSlug = revision.articleSlug
        reason = revision.reason
        snapshot = revision.snapshot
        createdAt = revision.createdAt
        updatedAt = revision.updatedAt
    }
}

struct NativePortableDatabaseState {
    var comments: NativePortableCollection<NativeArticleComment>?
    var revisions: NativePortableCollection<NativePortableRevisionRecord>?
    var bookmarks: NativePortableCollection<NativeBookmark>?

    var hasAnyFile: Bool {
        comments != nil || revisions != nil || bookmarks != nil
    }
}

struct NativePortableLayoutState: Codable, Equatable {
    var profiles: [NativeWorkspaceLayoutProfile]
    var activeProfileID: String
}

struct NativePortableUIState: Codable, Equatable {
    var workspaceLayouts: NativePortableLayoutState
    var readingProfile: NativeReadingProfile
}

struct NativePortableSidecarImportResult: Equatable {
    var importedCommentCount = 0
    var deletedCommentCount = 0
    var importedRevisionCount = 0
    var importedBookmarkCount = 0
    var deletedBookmarkCount = 0
    var foundSidecar = false

    var didChange: Bool {
        importedCommentCount + deletedCommentCount + importedRevisionCount
            + importedBookmarkCount + deletedBookmarkCount > 0
    }
}

struct NativePortableSidecarStatus: Equatable {
    let isEnabled: Bool
    let isWritable: Bool
    let hasSidecar: Bool
    let directoryPath: String
    let lastError: String?
}

struct NativePortableCollection<Record: Codable & Identifiable>: Codable where Record.ID == String {
    var records: [Record]
    var tombstones: [NativePortableSidecarTombstone]

    init(records: [Record] = [], tombstones: [NativePortableSidecarTombstone] = []) {
        self.records = records
        self.tombstones = tombstones
    }
}

/// Versioned filesystem repository for the optional `.leonbook/` directory.
/// Callers see database and UI snapshots; version checks, tombstones, atomic
/// writes, size limits, and the concrete file layout stay behind this seam.
struct NativePortableSidecarRepository {
    static let directoryName = ".leonbook"
    static let currentFormatVersion = 1
    static let maximumFileSize = 256 * 1_024 * 1_024

    private struct Envelope<Value: Codable>: Codable {
        let formatVersion: Int
        let updatedAt: String
        let value: Value
    }

    private struct Manifest: Codable {
        let formatVersion: Int
        let minimumReaderVersion: Int
        let writtenBy: String
        let updatedAt: String
        let files: [String]
    }

    let markdownRootURL: URL

    var directoryURL: URL {
        markdownRootURL.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    var exists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: directoryURL.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    func readDatabaseState() throws -> NativePortableDatabaseState {
        try validateExistingDirectoryIfNeeded()
        return NativePortableDatabaseState(
            comments: try read("comments.json"),
            revisions: try read("history.json"),
            bookmarks: try read("bookmarks.json")
        )
    }

    func writeDatabaseState(
        comments: [NativeArticleComment],
        commentTombstones: [NativePortableSidecarTombstone],
        revisions: [NativePortableRevisionRecord],
        bookmarks: [NativeBookmark],
        bookmarkTombstones: [NativePortableSidecarTombstone],
        updatedAt: String
    ) throws {
        try prepareDirectoryForWriting()

        let existingComments: NativePortableCollection<NativeArticleComment> =
            try read("comments.json") ?? NativePortableCollection()
        let mergedComments = mergedCollection(
            current: comments,
            existing: existingComments,
            newTombstones: commentTombstones
        )

        let existingBookmarks: NativePortableCollection<NativeBookmark> =
            try read("bookmarks.json") ?? NativePortableCollection()
        let mergedBookmarks = mergedCollection(
            current: bookmarks,
            existing: existingBookmarks,
            newTombstones: bookmarkTombstones
        )

        let existingHistory: NativePortableCollection<NativePortableRevisionRecord> =
            try read("history.json") ?? NativePortableCollection()
        var historyByID = existingHistory.records.reduce(
            into: [String: NativePortableRevisionRecord]()
        ) { $0[$1.id] = $1 }
        for revision in revisions {
            if let existing = historyByID[revision.id], existing.updatedAt > revision.updatedAt {
                continue
            }
            historyByID[revision.id] = revision
        }
        let mergedHistory = NativePortableCollection(
            records: Array(historyByID.values).sorted(by: revisionSort).prefix(5_000).map { $0 },
            tombstones: []
        )

        try write(mergedComments, named: "comments.json", updatedAt: updatedAt)
        try write(mergedHistory, named: "history.json", updatedAt: updatedAt)
        try write(mergedBookmarks, named: "bookmarks.json", updatedAt: updatedAt)
        try writeManifest(updatedAt: updatedAt)
    }

    func readUIState() throws -> NativePortableUIState? {
        try validateExistingDirectoryIfNeeded()
        return try read("layouts.json")
    }

    func writeUIState(_ state: NativePortableUIState, updatedAt: String) throws {
        try prepareDirectoryForWriting()
        let existing: NativePortableUIState? = try read("layouts.json")
        guard existing != state else { return }
        try write(state, named: "layouts.json", updatedAt: updatedAt)
        try writeManifest(updatedAt: updatedAt)
    }

    private func mergedCollection<Record: Codable & Identifiable>(
        current: [Record],
        existing: NativePortableCollection<Record>,
        newTombstones: [NativePortableSidecarTombstone]
    ) -> NativePortableCollection<Record> where Record.ID == String {
        var records = existing.records.reduce(into: [String: Record]()) { $0[$1.id] = $1 }
        for record in current { records[record.id] = record }
        var tombstones = existing.tombstones.reduce(
            into: [String: NativePortableSidecarTombstone]()
        ) { $0[$1.id] = $1 }
        for tombstone in newTombstones {
            if let existing = tombstones[tombstone.id], existing.deletedAt > tombstone.deletedAt {
                continue
            }
            tombstones[tombstone.id] = tombstone
        }
        for id in tombstones.keys { records.removeValue(forKey: id) }
        return NativePortableCollection(
            records: records.values.sorted { $0.id < $1.id },
            tombstones: tombstones.values.sorted { $0.id < $1.id }
        )
    }

    private func revisionSort(
        _ lhs: NativePortableRevisionRecord,
        _ rhs: NativePortableRevisionRecord
    ) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id < rhs.id
    }

    private func read<Value: Codable>(_ filename: String) throws -> Value? {
        let url = directoryURL.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= Self.maximumFileSize else {
            throw NativeStoreError.fileSystem(".leonbook/\(filename) 不是可读取的普通文件或体积过大")
        }
        do {
            let envelope = try JSONDecoder().decode(
                Envelope<Value>.self,
                from: Data(contentsOf: url, options: .mappedIfSafe)
            )
            guard envelope.formatVersion <= Self.currentFormatVersion else {
                throw NativeStoreError.fileSystem(
                    ".leonbook/\(filename) 来自更高版本的 LeonBook（格式 \(envelope.formatVersion)）"
                )
            }
            return envelope.value
        } catch let error as NativeStoreError {
            throw error
        } catch {
            throw NativeStoreError.fileSystem(
                "无法解析 .leonbook/\(filename)：\(error.localizedDescription)"
            )
        }
    }

    private func write<Value: Codable>(
        _ value: Value,
        named filename: String,
        updatedAt: String
    ) throws {
        let envelope = Envelope(
            formatVersion: Self.currentFormatVersion,
            updatedAt: updatedAt,
            value: value
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(envelope).write(
                to: directoryURL.appendingPathComponent(filename),
                options: .atomic
            )
        } catch {
            throw NativeStoreError.fileSystem(
                "无法写入 .leonbook/\(filename)：\(error.localizedDescription)"
            )
        }
    }

    private func writeManifest(updatedAt: String) throws {
        let files = ["comments.json", "history.json", "bookmarks.json", "layouts.json"]
            .filter { FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent($0).path) }
        let manifest = Manifest(
            formatVersion: Self.currentFormatVersion,
            minimumReaderVersion: 1,
            writtenBy: "leon-book",
            updatedAt: updatedAt,
            files: files
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(
                to: directoryURL.appendingPathComponent("manifest.json"),
                options: .atomic
            )
        } catch {
            throw NativeStoreError.fileSystem(
                "无法写入 .leonbook/manifest.json：\(error.localizedDescription)"
            )
        }
    }

    private func prepareDirectoryForWriting() throws {
        let root = markdownRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = directoryURL.standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw NativeStoreError.fileSystem(".leonbook 目录超出 Markdown 工作区")
        }
        if FileManager.default.fileExists(atPath: candidate.path) {
            try validateExistingDirectoryIfNeeded()
            return
        }
        do {
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
            try validateExistingDirectoryIfNeeded()
        } catch let error as NativeStoreError {
            throw error
        } catch {
            throw NativeStoreError.fileSystem(
                "无法创建 .leonbook 目录：\(error.localizedDescription)"
            )
        }
    }

    private func validateExistingDirectoryIfNeeded() throws {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        let values = try directoryURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        let root = markdownRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              resolved.path.hasPrefix(root.path + "/") else {
            throw NativeStoreError.fileSystem(".leonbook 必须是 Markdown 工作区内的普通目录")
        }
    }
}
