import Foundation

extension LocalBlogStore {
    // MARK: - Media

    func uploadMedia(fileURL: URL, kind: String, slug: String? = nil) async throws -> NativeUploadedMedia {
        try prepare()
        let writeLease = try WorkspaceStorageLifecycle.beginAsyncWrite(in: rootURL)
        defer { withExtendedLifetime(writeLease) {} }
        let targetSlug = try requireSafeSegment(slug?.isEmpty == false ? slug! : "inbox", label: "媒体目录")
        if kind == "video", targetSlug == "moments",
           fileURL.pathExtension.caseInsensitiveCompare("mp4") != .orderedSame {
            throw NativeStoreError.fileSystem(NativeLocalization.text("微博视频仅支持 MP4 格式"))
        }
        if kind == "audio", targetSlug == "moments",
           fileURL.pathExtension.caseInsensitiveCompare("mp3") != .orderedSame {
            throw NativeStoreError.fileSystem(NativeLocalization.text("微博音频仅支持 MP3 格式"))
        }
        let targetDirectory = mediaURL.appendingPathComponent(targetSlug, isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

        let originalName = fileURL.lastPathComponent.isEmpty ? "media" : fileURL.lastPathComponent
        let extensionName = fileURL.pathExtension.isEmpty ? "bin" : fileURL.pathExtension.lowercased()
        let filename = "\(UUID().uuidString.lowercased()).\(extensionName)"
        let targetURL = targetDirectory.appendingPathComponent(filename)
        do {
            // Large videos can take seconds to copy. Suspending on a detached
            // utility task keeps the LocalBlogStore actor responsive for reads,
            // search, and unrelated saves while the filesystem does the work.
            let size = try await Task.detached(priority: .utility) {
                try FileManager.default.copyItem(at: fileURL, to: targetURL)
                return (try FileManager.default.attributesOfItem(atPath: targetURL.path)[.size] as? NSNumber)?
                    .intValue ?? 0
            }.value
            let mediaKind = ["image", "video", "audio", "file"].contains(kind) ? kind : "file"
            if mediaKind == "image" { try recordActivity(type: "image_published", at: Date()) }
            return NativeUploadedMedia(
                key: "\(targetSlug)/\(filename)",
                kind: mediaKind,
                name: originalName,
                size: size,
                url: "/media/\(targetSlug)/\(filename)"
            )
        } catch {
            try? FileManager.default.removeItem(at: targetURL)
            throw NativeStoreError.fileSystem(error.localizedDescription)
        }
    }

    public func mediaURL(
        for storedPath: String,
        relativeToMarkdownSource sourceRelativePath: String? = nil
    ) -> URL? {
        let normalized = normalizeMediaURL(storedPath)
        if let range = normalized.range(of: "/media/") {
            let parts = normalized[range.upperBound...].split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count == 2,
                  let slug = try? requireSafeSegment(String(parts[0]), label: "媒体目录"),
                  let filename = try? requireSafeSegment(String(parts[1]), label: "媒体文件") else {
                return nil
            }
            return mediaURL.appendingPathComponent(slug).appendingPathComponent(filename)
        }

        guard let sourceRelativePath,
              URL(string: storedPath)?.scheme == nil else { return nil }
        let decoded = (storedPath.removingPercentEncoding ?? storedPath)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .replacingOccurrences(of: "\\", with: "/")
        guard !decoded.isEmpty else { return nil }
        let root = articlesURL.standardizedFileURL.resolvingSymlinksInPath()
        let noteURL = root.appendingPathComponent(sourceRelativePath).standardizedFileURL
        let candidate = decoded.hasPrefix("/")
            ? root.appendingPathComponent(String(decoded.dropFirst()))
            : noteURL.deletingLastPathComponent().appendingPathComponent(decoded)
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved.path.hasPrefix(rootPrefix),
              FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        return resolved
    }

    func discardUnreferencedMedia(_ media: [NativeMedia]) throws {
        try prepare()
        guard !media.isEmpty else { return }

        try removeUnreferencedMediaFiles(media, includingDeleted: true)
    }

    func removeUnreferencedMediaFiles(
        _ media: [NativeMedia],
        includingDeleted: Bool
    ) throws {
        for item in media {
            let normalizedURL = normalizeMediaURL(item.url)
            if try db().integer("SELECT COUNT(*) FROM photo_library_items WHERE url = ?", values: [.text(normalizedURL)]) == 1 {
                continue
            }
            if try db().integer("SELECT COUNT(*) FROM media_library_items WHERE url = ?", values: [.text(normalizedURL)]) == 1 {
                continue
            }
            // Whiteboard revisions can still be referenced by draft/undo/history
            // snapshots. They are retained with the workspace's backup data.
            if normalizedURL.hasPrefix("/media/whiteboards/") || normalizedURL.hasPrefix("/media/canvases/") { continue }
            // Homepage imports belong to the workspace, including while a layout
            // is being edited. Removing a module must not delete its local media.
            if normalizedURL.hasPrefix("/media/dashboard/") { continue }
            let referenceCount = try db().integer(
                "SELECT COUNT(*) FROM media_references WHERE normalized_url = ?",
                values: [.text(normalizedURL)]
            ) ?? 0
            guard referenceCount == 0, let fileURL = mediaURL(for: normalizedURL) else {
                continue
            }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
