import CryptoKit
import Foundation

/// The Markdown source module owns the on-disk article format and path safety.
/// SQLite callers receive parsed records and never need to understand YAML or
/// filesystem layout details.
struct MarkdownArticleSourceRecord: Hashable {
    let relativePath: String
    let contentHash: String
    let modifiedAt: String
    let declaredUpdatedAt: String?
    let slug: String?
    let title: String
    let body: String
    let category: String
    let excerpt: String
    let banner: NativeBanner?
    let media: [NativeMedia]
    let status: NativeArticleStatus
    let tags: [String]
    let publishedAt: String?
    let properties: [String: NativeArticlePropertyValue]
}

enum MarkdownArticleSource {
    private static let reservedKeys = Set([
        "title", "category", "tags", "slug", "status", "updatedat", "updated_at",
        "publishedat", "published_at", "banner", "banneralt", "excerpt", "description",
        "leonmedia", "leon_media",
    ])

    static func defaultRelativePath(for slug: String) -> String {
        "\(slug).md"
    }

    static func scan(in articlesURL: URL) throws -> [MarkdownArticleSourceRecord] {
        let root = articlesURL.standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try scanExistingDirectory(root, articlesRoot: root)
    }

    static func scan(
        in articlesURL: URL,
        beneath relativeDirectoryPath: String,
        fileManager: FileManager = .default
    ) throws -> [MarkdownArticleSourceRecord] {
        let safeDirectory = try validatedRelativeDirectoryPath(relativeDirectoryPath)
        let root = articlesURL.standardizedFileURL.resolvingSymlinksInPath()
        let directory = safeDirectory.isEmpty
            ? root
            : root.appendingPathComponent(safeDirectory, isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
        guard isInside(directory, root: root) else {
            throw NativeStoreError.fileSystem("Markdown 目录路径超出资料库")
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }
        let values = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else { return [] }
        return try scanExistingDirectory(directory, articlesRoot: root, fileManager: fileManager)
    }

    static func readIfPresent(
        relativePath: String,
        in articlesURL: URL,
        fileManager: FileManager = .default
    ) throws -> MarkdownArticleSourceRecord? {
        let safePath = try validatedRelativePath(relativePath)
        let root = articlesURL.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(safePath)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard isInside(url, root: root) else {
            throw NativeStoreError.fileSystem("Markdown 文章路径超出资料库")
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return nil }
        return try read(at: url, relativePath: safePath, fileManager: fileManager)
    }

    private static func scanExistingDirectory(
        _ directory: URL,
        articlesRoot root: URL,
        fileManager: FileManager = .default
    ) throws -> [MarkdownArticleSourceRecord] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw NativeStoreError.fileSystem("无法扫描 Markdown 文章目录")
        }

        var records: [MarkdownArticleSourceRecord] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true,
                  values?.isSymbolicLink != true,
                  url.pathExtension.caseInsensitiveCompare("md") == .orderedSame else { continue }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard isInside(resolved, root: root) else { continue }
            let relativePath = String(resolved.path.dropFirst(root.path.count + 1))
            records.append(try read(at: resolved, relativePath: relativePath))
        }
        return records.sorted {
            $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending
        }
    }

    static func read(
        at url: URL,
        relativePath: String,
        fileManager: FileManager = .default
    ) throws -> MarkdownArticleSourceRecord {
        let safePath = try validatedRelativePath(relativePath)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw NativeStoreError.fileSystem("无法读取 \(safePath)：\(error.localizedDescription)")
        }
        guard var source = String(data: data, encoding: .utf8) else {
            throw NativeStoreError.fileSystem("\(safePath) 不是 UTF-8 Markdown 文件")
        }
        if source.hasPrefix("\u{feff}") { source.removeFirst() }

        let frontmatter = parseFrontmatter(source)
        let fileTitle = url.deletingPathExtension().lastPathComponent
        let folder = safePath.split(separator: "/").dropLast().joined(separator: "/")
        let title = frontmatter.scalar(for: ["title"]).flatMap(nonEmpty) ?? fileTitle
        let category = frontmatter.scalar(for: ["category"]).flatMap(nonEmpty)
            ?? (folder.isEmpty ? "Notes" : folder)
        let tags = NativeArticleTag.normalized(frontmatter.list(for: ["tags", "tag"]))
        let status = NativeArticleStatus(
            rawValue: frontmatter.scalar(for: ["status"])?.lowercased() ?? ""
        ) ?? .draft
        let excerpt = frontmatter.scalar(for: ["excerpt", "description"]).flatMap(nonEmpty)
            ?? generatedExcerpt(from: frontmatter.body)
        let bannerURL = frontmatter.scalar(for: ["banner"]).flatMap(nonEmpty)
        let banner = bannerURL.map {
            NativeBanner(
                alt: frontmatter.scalar(for: ["bannerAlt", "banner_alt"]) ?? "",
                name: URL(fileURLWithPath: $0).lastPathComponent,
                size: 0,
                url: $0
            )
        }
        let media = decodedMedia(frontmatter.scalar(for: ["leonMedia", "leon_media"]))
        var properties: [String: NativeArticlePropertyValue] = [:]
        for (key, value) in frontmatter.values where !reservedKeys.contains(key.lowercased()) {
            guard NativeArticleProperties.isValidKey(key) else { continue }
            properties[key] = NativeArticlePropertyValue.fromYAML(value)
        }
        let modificationDate = (try? url.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate) ?? Date()

        return MarkdownArticleSourceRecord(
            relativePath: safePath,
            contentHash: hash(data),
            modifiedAt: NativeTimestamp.string(from: modificationDate),
            declaredUpdatedAt: frontmatter.scalar(for: ["updatedAt", "updated_at"]).flatMap(nonEmpty),
            slug: frontmatter.scalar(for: ["slug"]).flatMap(nonEmpty),
            title: title,
            body: frontmatter.body,
            category: category,
            excerpt: excerpt,
            banner: banner,
            media: media,
            status: status,
            tags: tags,
            publishedAt: frontmatter.scalar(for: ["publishedAt", "published_at"]).flatMap(nonEmpty),
            properties: try NativeArticleProperties.validated(properties)
        )
    }

    @discardableResult
    static func write(
        _ article: NativeArticle,
        relativePath requestedPath: String,
        in articlesURL: URL,
        fileManager: FileManager = .default
    ) throws -> MarkdownArticleSourceRecord {
        let relativePath = try validatedRelativePath(requestedPath)
        let root = articlesURL.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard isInside(url, root: root) else {
            throw NativeStoreError.fileSystem("Markdown 文章路径超出资料库")
        }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = Data(render(article).utf8)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw NativeStoreError.fileSystem("无法写入 \(relativePath)：\(error.localizedDescription)")
        }
        return try read(at: url, relativePath: relativePath, fileManager: fileManager)
    }

    @discardableResult
    static func move(
        from sourcePath: String,
        to destinationPath: String,
        in articlesURL: URL,
        fileManager: FileManager = .default
    ) throws -> MarkdownArticleSourceRecord {
        let sourceRelativePath = try validatedRelativePath(sourcePath)
        let destinationRelativePath = try validatedRelativePath(destinationPath)
        guard sourceRelativePath != destinationRelativePath else {
            let url = articlesURL.appendingPathComponent(sourceRelativePath)
            return try read(at: url, relativePath: sourceRelativePath, fileManager: fileManager)
        }

        let root = articlesURL.standardizedFileURL.resolvingSymlinksInPath()
        let sourceURL = root.appendingPathComponent(sourceRelativePath).standardizedFileURL.resolvingSymlinksInPath()
        let destinationURL = root.appendingPathComponent(destinationRelativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard isInside(sourceURL, root: root), isInside(destinationURL, root: root) else {
            throw NativeStoreError.fileSystem("Markdown 文章路径超出资料库")
        }
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw NativeStoreError.notFound
        }
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw NativeStoreError.fileSystem("目标 Markdown 文件已存在")
        }
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            throw NativeStoreError.fileSystem("无法移动 Markdown 文件：\(error.localizedDescription)")
        }
        removeEmptyParentDirectories(
            startingAt: sourceURL.deletingLastPathComponent(),
            root: root,
            fileManager: fileManager
        )
        return try read(
            at: destinationURL,
            relativePath: destinationRelativePath,
            fileManager: fileManager
        )
    }

    static func remove(
        relativePath: String,
        in articlesURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let safePath = try validatedRelativePath(relativePath)
        let root = articlesURL.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(safePath).standardizedFileURL.resolvingSymlinksInPath()
        guard isInside(url, root: root) else {
            throw NativeStoreError.fileSystem("Markdown 文章路径超出资料库")
        }
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw NativeStoreError.fileSystem("无法删除 \(safePath)：\(error.localizedDescription)")
        }
        removeEmptyParentDirectories(
            startingAt: url.deletingLastPathComponent(),
            root: root,
            fileManager: fileManager
        )
    }

    static func validatedRelativePath(_ rawPath: String) throws -> String {
        var value = rawPath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("/") { value.removeFirst() }
        let segments = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !segments.isEmpty,
              segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }),
              segments.last?.lowercased().hasSuffix(".md") == true else {
            throw NativeStoreError.fileSystem("Markdown 相对路径无效")
        }
        return segments.joined(separator: "/").precomposedStringWithCanonicalMapping
    }

    static func validatedRelativeDirectoryPath(_ rawPath: String) throws -> String {
        var value = rawPath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("/") { value.removeFirst() }
        while value.hasSuffix("/") { value.removeLast() }
        guard !value.isEmpty else { return "" }
        let segments = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }) else {
            throw NativeStoreError.fileSystem("Markdown 目录相对路径无效")
        }
        return segments.joined(separator: "/").precomposedStringWithCanonicalMapping
    }

    private struct Frontmatter {
        let body: String
        let values: [String: String]

        func rawValue(for keys: [String]) -> String? {
            for key in keys {
                if let pair = values.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
                    return pair.value
                }
            }
            return nil
        }

        func scalar(for keys: [String]) -> String? {
            rawValue(for: keys).map(MarkdownArticleSource.parseScalar)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func list(for keys: [String]) -> [String] {
            guard let raw = rawValue(for: keys) else { return [] }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = NativeArticlePropertyValue.fromYAML(value)
            if parsed.kind == .list || parsed.kind == .tags { return parsed.listValues }
            return MarkdownArticleSource.parseScalar(value)
                .split(whereSeparator: { ",，".contains($0) })
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }

    private static func parseFrontmatter(_ source: String) -> Frontmatter {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closingIndex = lines.indices.dropFirst().first(where: {
                  let marker = lines[$0].trimmingCharacters(in: .whitespaces)
                  return marker == "---" || marker == "..."
              }) else {
            return Frontmatter(body: normalized, values: [:])
        }

        var values: [String: String] = [:]
        var index = 1
        while index < closingIndex {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let colon = line.firstIndex(of: ":") else {
                index += 1
                continue
            }
            let key = parseScalar(String(line[..<colon]).trimmingCharacters(in: .whitespaces))
            guard NativeArticleProperties.isValidKey(key) else {
                index += 1
                continue
            }
            var raw = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            var childLines: [String] = []
            var next = index + 1
            while next < closingIndex {
                let candidate = lines[next]
                let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                if candidate.first?.isWhitespace == true || candidateTrimmed.hasPrefix("-") || candidateTrimmed.isEmpty {
                    childLines.append(candidate)
                    next += 1
                } else {
                    break
                }
            }
            if !childLines.isEmpty {
                raw += (raw.isEmpty ? "" : "\n") + childLines.joined(separator: "\n")
            }
            values[key] = raw
            index = next
        }
        let bodyStart = closingIndex + 1
        let body = bodyStart < lines.count
            ? lines[bodyStart...].joined(separator: "\n").trimmingCharacters(in: .newlines)
            : ""
        return Frontmatter(body: body, values: values)
    }

    private static func render(_ article: NativeArticle) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func quoted(_ value: String) -> String {
            (try? String(data: encoder.encode(value), encoding: .utf8)) ?? "\"\""
        }
        func yamlKey(_ key: String) -> String {
            key.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) == nil ? quoted(key) : key
        }

        var lines = [
            "---",
            "title: \(quoted(article.title))",
            "category: \(quoted(article.category))",
            "tags: [\(article.tags.map(quoted).joined(separator: ", "))]",
            "slug: \(article.slug)",
            "status: \(article.status.rawValue)",
            "updatedAt: \(article.updatedAt)",
            "excerpt: \(quoted(article.excerpt))",
        ]
        if let publishedAt = article.publishedAt { lines.append("publishedAt: \(publishedAt)") }
        if let banner = article.banner {
            lines.append("banner: \(quoted(banner.url))")
            lines.append("bannerAlt: \(quoted(banner.alt))")
        }
        if !article.media.isEmpty,
           let mediaData = try? encoder.encode(article.media),
           let mediaJSON = String(data: mediaData, encoding: .utf8) {
            lines.append("leonMedia: \(quoted(mediaJSON))")
        }
        for key in article.properties.keys.sorted() {
            guard !reservedKeys.contains(key.lowercased()), let value = article.properties[key] else { continue }
            lines.append("\(yamlKey(key)): \(value.yamlValue)")
        }
        lines.append(contentsOf: ["---", "", article.body, ""])
        return lines.joined(separator: "\n")
    }

    private static func decodedMedia(_ value: String?) -> [NativeMedia] {
        guard let value,
              let data = parseScalar(value).data(using: .utf8),
              let media = try? JSONDecoder().decode([NativeMedia].self, from: data) else { return [] }
        return media
    }

    private static func parseScalar(_ raw: String) -> String {
        let value = stripComment(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2 else { return value }
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            return (try? JSONDecoder().decode(String.self, from: Data(value.utf8)))
                ?? String(value.dropFirst().dropLast())
        }
        if value.hasPrefix("'") && value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value
    }

    private static func stripComment(_ value: String) -> String {
        var quote: Character?
        var previous: Character?
        for index in value.indices {
            let character = value[index]
            if character == "\"" || character == "'" {
                if quote == character { quote = nil } else if quote == nil { quote = character }
            } else if character == "#", quote == nil, previous?.isWhitespace == true {
                return String(value[..<index])
            }
            previous = character
        }
        return value
    }

    private static func generatedExcerpt(from body: String) -> String {
        let line = body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("!") } ?? ""
        return String(line.replacingOccurrences(
            of: #"[*_`>]"#,
            with: "",
            options: .regularExpression
        ).prefix(180))
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func removeEmptyParentDirectories(
        startingAt start: URL,
        root: URL,
        fileManager: FileManager
    ) {
        var directory = start.standardizedFileURL
        let root = root.standardizedFileURL
        while directory.path != root.path, isInside(directory, root: root) {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path), contents.isEmpty else {
                return
            }
            try? fileManager.removeItem(at: directory)
            directory.deleteLastPathComponent()
        }
    }
}
