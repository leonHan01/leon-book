import Foundation

extension LocalBlogStore {
    func listWorkspaceResources() throws -> [NativeWorkspaceResourceNode] {
        try prepare()
        let articles = try allArticleSummaries()
        let sourceRecords = try workspaceResourceRecords(
            at: articlesURL,
            storage: .markdownSource,
            placementFolder: { relativePath in
                relativePath.split(separator: "/").dropLast().joined(separator: "/")
            }
        )
        let articleBySlug = Dictionary(uniqueKeysWithValues: articles.map { ($0.slug, $0) })
        let mediaDisplayNames = try workspaceMediaDisplayNames(articles: articles)
        let mediaRecords = try workspaceResourceRecords(
            at: mediaURL,
            storage: .managedMedia,
            includesDirectories: false,
            placementFolder: { relativePath in
                let ownerSlug = relativePath.split(separator: "/").first.map(String.init)
                return ownerSlug.flatMap { articleBySlug[$0]?.sourceFolderPath } ?? ""
            },
            ownerArticleSlug: { relativePath in
                let ownerSlug = relativePath.split(separator: "/").first.map(String.init)
                guard let ownerSlug, articleBySlug[ownerSlug] != nil else { return nil }
                return ownerSlug
            },
            displayName: { relativePath in
                mediaDisplayNames[relativePath]
            }
        ).filter { $0.ownerArticleSlug != nil }
        return NativeWorkspaceResourceTree.build(
            articles: articles,
            records: sourceRecords + mediaRecords
        )
    }

    func createWorkspaceFolder(relativePath: String) throws {
        try prepare()
        try requireWritableArticleSource()
        let safePath = try MarkdownArticleSource.validatedRelativeDirectoryPath(relativePath)
        guard !safePath.isEmpty else {
            throw NativeStoreError.fileSystem("不能新建资料库根目录")
        }
        let root = articlesURL.standardizedFileURL.resolvingSymlinksInPath()
        let destination = root.appendingPathComponent(safePath, isDirectory: true).standardizedFileURL
        let resolvedParent = destination.deletingLastPathComponent().resolvingSymlinksInPath()
        guard workspaceURL(destination, isInside: root),
              workspaceURL(resolvedParent, isInside: root) else {
            throw NativeStoreError.fileSystem("文件夹路径超出资料库")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw NativeStoreError.fileSystem("同名文件或文件夹已存在")
        }
        do {
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: false
            )
        } catch {
            throw NativeStoreError.fileSystem("无法新建文件夹：\(error.localizedDescription)")
        }
    }

    @discardableResult
    func moveWorkspaceSourceItems(
        _ requestedMoves: [NativeWorkspaceResourceMove]
    ) throws -> NativeMarkdownSyncResult {
        try prepare()
        try requireWritableArticleSource()
        let root = articlesURL.standardizedFileURL.resolvingSymlinksInPath()
        let moves = try normalizedWorkspaceMoves(requestedMoves, root: root)
        guard !moves.isEmpty else { return NativeMarkdownSyncResult() }

        var completed: [(source: URL, destination: URL)] = []
        do {
            for move in moves {
                try FileManager.default.createDirectory(
                    at: move.destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: move.source, to: move.destination)
                completed.append((move.source, move.destination))
            }
            let result = try refreshMarkdownSources()
            for move in completed {
                removeEmptyWorkspaceParents(
                    startingAt: move.source.deletingLastPathComponent(),
                    root: root
                )
            }
            return result
        } catch {
            for move in completed.reversed() where FileManager.default.fileExists(atPath: move.destination.path) {
                try? FileManager.default.createDirectory(
                    at: move.source.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? FileManager.default.moveItem(at: move.destination, to: move.source)
            }
            _ = try? refreshMarkdownSources()
            if let storeError = error as? NativeStoreError { throw storeError }
            throw NativeStoreError.fileSystem("无法移动资源：\(error.localizedDescription)")
        }
    }

    @discardableResult
    func trashWorkspaceSourceItems(
        relativePaths requestedPaths: [String]
    ) throws -> NativeMarkdownSyncResult {
        try prepare()
        try requireWritableArticleSource()
        let root = articlesURL.standardizedFileURL.resolvingSymlinksInPath()
        let paths = try normalizedTopLevelWorkspacePaths(requestedPaths)
        guard !paths.isEmpty else { return NativeMarkdownSyncResult() }

        for path in paths {
            let url = root.appendingPathComponent(path).standardizedFileURL
            let resolved = url.resolvingSymlinksInPath()
            guard workspaceURL(url, isInside: root),
                  workspaceURL(resolved, isInside: root),
                  url.path != root.path else {
                throw NativeStoreError.fileSystem("不能删除资料库根目录")
            }
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard FileManager.default.fileExists(atPath: url.path), values?.isSymbolicLink != true else {
                throw NativeStoreError.notFound
            }
        }

        do {
            for path in paths {
                let url = root.appendingPathComponent(path).standardizedFileURL
                _ = try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            return try refreshMarkdownSources()
        } catch {
            _ = try? refreshMarkdownSources()
            if let storeError = error as? NativeStoreError { throw storeError }
            throw NativeStoreError.fileSystem("无法移入 macOS 废纸篓：\(error.localizedDescription)")
        }
    }

    private func workspaceResourceRecords(
        at rootURL: URL,
        storage: NativeWorkspaceResourceStorage,
        includesDirectories: Bool = true,
        placementFolder: (String) -> String,
        ownerArticleSlug: (String) -> String? = { _ in nil },
        displayName: (String) -> String? = { _ in nil }
    ) throws -> [NativeWorkspaceResourceRecord] {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw NativeStoreError.fileSystem("无法扫描文件资源")
        }

        var records: [NativeWorkspaceResourceRecord] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values?.isDirectory == true || values?.isRegularFile == true else { continue }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard workspaceURL(resolved, isInside: root), resolved.path != root.path else { continue }
            let relativePath = String(resolved.path.dropFirst(root.path.count + 1))
                .precomposedStringWithCanonicalMapping
            if values?.isDirectory == true {
                if includesDirectories {
                    records.append(NativeWorkspaceResourceRecord(
                        kind: .folder,
                        storage: storage,
                        relativePath: relativePath,
                        placementFolderPath: relativePath,
                        absolutePath: resolved.path
                    ))
                }
            } else {
                records.append(NativeWorkspaceResourceRecord(
                    kind: .file,
                    storage: storage,
                    relativePath: relativePath,
                    placementFolderPath: placementFolder(relativePath),
                    absolutePath: resolved.path,
                    ownerArticleSlug: ownerArticleSlug(relativePath),
                    displayName: displayName(relativePath)
                ))
            }
        }
        return records
    }

    private func workspaceMediaDisplayNames(
        articles: [NativeArticleSummary]
    ) throws -> [String: String] {
        var names: [String: String] = [:]
        for article in articles {
            if let banner = article.banner,
               let path = workspaceManagedMediaRelativePath(banner.url) {
                names[path] = banner.name
            }
        }
        try db().query("SELECT media_json FROM articles WHERE deleted_at IS NULL") { row in
            guard let raw = row.text(at: 0) else { return }
            let media: [NativeMedia] = try decode(raw)
            for item in media {
                if let path = workspaceManagedMediaRelativePath(item.url) {
                    names[path] = item.name
                }
            }
        }
        return names
    }

    private func workspaceManagedMediaRelativePath(_ storedPath: String) -> String? {
        let normalized = storedPath.replacingOccurrences(of: "\\", with: "/")
        guard let range = normalized.range(of: "/media/") else { return nil }
        let components = normalized[range.upperBound...]
            .split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == 2 else { return nil }
        return components.map(String.init).joined(separator: "/")
    }

    private func normalizedWorkspaceMoves(
        _ requestedMoves: [NativeWorkspaceResourceMove],
        root: URL
    ) throws -> [(sourcePath: String, destinationPath: String, source: URL, destination: URL)] {
        let topLevelSources = try normalizedTopLevelWorkspacePaths(
            requestedMoves.map(\.sourceRelativePath)
        )
        let requestedBySource = requestedMoves.reduce(into: [String: String]()) { result, move in
            result[normalizedWorkspacePath(move.sourceRelativePath)] = move.destinationRelativePath
        }
        var results: [(String, String, URL, URL)] = []
        var destinations = Set<String>()

        for sourcePath in topLevelSources {
            guard let requestedDestination = requestedBySource[sourcePath] else { continue }
            let destinationPath = try validatedWorkspacePath(requestedDestination)
            guard sourcePath != destinationPath else { continue }
            let source = root.appendingPathComponent(sourcePath).standardizedFileURL
            let destination = root.appendingPathComponent(destinationPath).standardizedFileURL
            let resolvedSource = source.resolvingSymlinksInPath()
            let resolvedDestinationParent = destination.deletingLastPathComponent()
                .resolvingSymlinksInPath()
            guard workspaceURL(source, isInside: root),
                  workspaceURL(destination, isInside: root),
                  workspaceURL(resolvedSource, isInside: root),
                  workspaceURL(resolvedDestinationParent, isInside: root) else {
                throw NativeStoreError.fileSystem("资源路径超出资料库")
            }
            let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true,
                  values?.isDirectory == true || values?.isRegularFile == true else {
                throw NativeStoreError.notFound
            }
            if values?.isDirectory == true,
               destinationPath.hasPrefix(sourcePath + "/") {
                throw NativeStoreError.fileSystem("不能把文件夹移动到其自身内部")
            }
            if source.pathExtension.caseInsensitiveCompare("md") == .orderedSame,
               destination.pathExtension.caseInsensitiveCompare("md") != .orderedSame {
                throw NativeStoreError.fileSystem("Markdown 文件必须保留 .md 扩展名")
            }
            guard destinations.insert(destinationPath).inserted else {
                throw NativeStoreError.fileSystem("多个资源将产生同一个目标路径")
            }
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw NativeStoreError.fileSystem("目标位置已存在“\(destination.lastPathComponent)”")
            }
            results.append((sourcePath, destinationPath, source, destination))
        }
        return results
    }

    private func normalizedTopLevelWorkspacePaths(_ requestedPaths: [String]) throws -> [String] {
        let paths = try Set(requestedPaths.map(validatedWorkspacePath)).sorted {
            let leftDepth = $0.split(separator: "/").count
            let rightDepth = $1.split(separator: "/").count
            if leftDepth != rightDepth { return leftDepth < rightDepth }
            return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        var selected: [String] = []
        for path in paths where !selected.contains(where: { path.hasPrefix($0 + "/") }) {
            selected.append(path)
        }
        return selected
    }

    private func validatedWorkspacePath(_ rawPath: String) throws -> String {
        var value = rawPath.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("/") { value.removeFirst() }
        while value.hasSuffix("/") { value.removeLast() }
        let segments = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !segments.isEmpty,
              segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }) else {
            throw NativeStoreError.fileSystem("资源相对路径无效")
        }
        return segments.joined(separator: "/").precomposedStringWithCanonicalMapping
    }

    private func normalizedWorkspacePath(_ rawPath: String) -> String {
        rawPath.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .precomposedStringWithCanonicalMapping
    }

    private func workspaceURL(_ url: URL, isInside root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private func removeEmptyWorkspaceParents(startingAt start: URL, root: URL) {
        var directory = start.standardizedFileURL
        while directory.path != root.path, workspaceURL(directory, isInside: root) {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
                  contents.isEmpty else { return }
            try? FileManager.default.removeItem(at: directory)
            directory.deleteLastPathComponent()
        }
    }
}
