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
        "title", "category", "tags", "tag", "slug", "status", "updatedat", "updated_at",
        "publishedat", "published_at", "banner", "banneralt", "banner_alt", "excerpt", "description",
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
        let existingSource: String?
        if fileManager.fileExists(atPath: url.path) {
            do {
                let existingData = try Data(contentsOf: url)
                guard let decoded = String(data: existingData, encoding: .utf8) else {
                    throw NativeStoreError.fileSystem("\(relativePath) 不是 UTF-8 Markdown 文件")
                }
                let hasUTF8ByteOrderMark = existingData.starts(with: [0xEF, 0xBB, 0xBF])
                existingSource = hasUTF8ByteOrderMark && !decoded.hasPrefix("\u{feff}")
                    ? "\u{feff}" + decoded
                    : decoded
            } catch let error as NativeStoreError {
                throw error
            } catch {
                throw NativeStoreError.fileSystem("无法读取 \(relativePath)：\(error.localizedDescription)")
            }
        } else {
            existingSource = nil
        }
        let data = Data(render(article, preserving: existingSource).utf8)
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
        var normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        if normalized.hasPrefix("\u{feff}") { normalized.removeFirst() }
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

    private struct FrontmatterSourceEntry {
        let key: String
        let lineRange: Range<Int>
    }

    /// A source-preserving view over the frontmatter document. It deliberately
    /// records line ranges instead of rebuilding YAML so untouched entries,
    /// comments, ordering and scalar styles survive an article save.
    private struct FrontmatterSourceDocument {
        let hadByteOrderMark: Bool
        let lineEnding: String
        let hadTrailingLineEnding: Bool
        let lines: [String]
        let closingIndex: Int
        let leadingBodyBlankLineCount: Int
        let entries: [FrontmatterSourceEntry]

        init?(_ source: String) {
            hadByteOrderMark = source.hasPrefix("\u{feff}")
            let content = hadByteOrderMark ? String(source.dropFirst()) : source
            lineEnding = content.contains("\r\n") ? "\r\n" : "\n"
            hadTrailingLineEnding = content.hasSuffix(lineEnding)
            let normalized = content
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            let parsedLines = normalized.components(separatedBy: "\n")
            guard parsedLines.first?.trimmingCharacters(in: .whitespaces) == "---",
                  let closingIndex = parsedLines.indices.dropFirst().first(where: {
                      let marker = parsedLines[$0].trimmingCharacters(in: .whitespaces)
                      return marker == "---" || marker == "..."
                  }) else { return nil }
            lines = parsedLines
            self.closingIndex = closingIndex

            var blankLines = 0
            var bodyIndex = closingIndex + 1
            while bodyIndex < lines.count,
                  lines[bodyIndex].trimmingCharacters(in: .whitespaces).isEmpty {
                if bodyIndex == lines.count - 1, hadTrailingLineEnding { break }
                blankLines += 1
                bodyIndex += 1
            }
            leadingBodyBlankLineCount = blankLines

            var entries: [FrontmatterSourceEntry] = []
            var index = 1
            while index < closingIndex {
                guard let key = MarkdownArticleSource.topLevelKey(in: lines[index]) else {
                    index += 1
                    continue
                }
                var end = index + 1
                while end < closingIndex {
                    let candidate = lines[end]
                    let trimmed = candidate.trimmingCharacters(in: .whitespaces)
                    if candidate.first?.isWhitespace == true || trimmed.hasPrefix("-") || trimmed.isEmpty {
                        end += 1
                    } else {
                        break
                    }
                }
                let scanEnd = end
                while end > index + 1,
                      lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                    end -= 1
                }
                entries.append(FrontmatterSourceEntry(key: key, lineRange: index..<end))
                index = scanEnd
            }
            self.entries = entries
        }
    }

    private struct FrontmatterSourcePatch {
        let lineRange: Range<Int>
        let replacement: [String]
    }

    private static func render(_ article: NativeArticle, preserving source: String? = nil) -> String {
        guard let source,
              let document = FrontmatterSourceDocument(source) else {
            return renderCanonical(article)
        }
        return renderPreservingFrontmatter(article, source: source, document: document)
    }

    private static func renderCanonical(_ article: NativeArticle) -> String {

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
           let mediaData = try? canonicalJSONEncoder().encode(article.media),
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

    private static func renderPreservingFrontmatter(
        _ article: NativeArticle,
        source: String,
        document: FrontmatterSourceDocument
    ) -> String {
        let parsed = parseFrontmatter(source)
        var patches: [FrontmatterSourcePatch] = []
        var additions: [String] = []
        var claimedEntryStarts = Set<Int>()

        func matchingEntries(_ aliases: [String]) -> [FrontmatterSourceEntry] {
            document.entries.filter { entry in
                aliases.contains { entry.key.caseInsensitiveCompare($0) == .orderedSame }
            }
        }

        func update(
            aliases: [String],
            canonicalKey: String,
            desiredRawValue: String?,
            isSemanticallyUnchanged: Bool
        ) {
            let matches = matchingEntries(aliases)
            if isSemanticallyUnchanged {
                claimedEntryStarts.formUnion(matches.map(\.lineRange.lowerBound))
                return
            }
            guard let desiredRawValue else {
                for entry in matches {
                    claimedEntryStarts.insert(entry.lineRange.lowerBound)
                    patches.append(FrontmatterSourcePatch(lineRange: entry.lineRange, replacement: []))
                }
                return
            }
            if let first = matches.first {
                claimedEntryStarts.insert(first.lineRange.lowerBound)
                patches.append(FrontmatterSourcePatch(
                    lineRange: first.lineRange,
                    replacement: replacementLines(
                        for: first,
                        desiredRawValue: desiredRawValue,
                        sourceLines: document.lines
                    )
                ))
                for duplicate in matches.dropFirst() {
                    claimedEntryStarts.insert(duplicate.lineRange.lowerBound)
                    patches.append(FrontmatterSourcePatch(lineRange: duplicate.lineRange, replacement: []))
                }
            } else {
                additions.append("\(yamlKey(canonicalKey)): \(desiredRawValue)")
            }
        }

        let sourceFileTitle = URL(fileURLWithPath: article.sourceRelativePath)
            .deletingPathExtension().lastPathComponent
        let sourceFolder = article.sourceRelativePath.split(separator: "/")
            .dropLast().joined(separator: "/")
        let existingTitle = parsed.scalar(for: ["title"]) ?? sourceFileTitle
        let existingCategory = parsed.scalar(for: ["category"])
            ?? (sourceFolder.isEmpty ? "Notes" : sourceFolder)
        let existingExcerpt = parsed.scalar(for: ["excerpt", "description"])
            ?? generatedExcerpt(from: parsed.body)

        update(
            aliases: ["title"],
            canonicalKey: "title",
            desiredRawValue: quoted(article.title),
            isSemanticallyUnchanged: existingTitle == article.title
        )
        update(
            aliases: ["category"],
            canonicalKey: "category",
            desiredRawValue: quoted(article.category),
            isSemanticallyUnchanged: existingCategory == article.category
        )
        update(
            aliases: ["tags", "tag"],
            canonicalKey: "tags",
            desiredRawValue: "[\(article.tags.map(quoted).joined(separator: ", "))]",
            isSemanticallyUnchanged: NativeArticleTag.normalized(parsed.list(for: ["tags", "tag"]))
                == NativeArticleTag.normalized(article.tags)
        )
        update(
            aliases: ["slug"],
            canonicalKey: "slug",
            desiredRawValue: article.slug,
            isSemanticallyUnchanged: parsed.scalar(for: ["slug"]).map { $0 == article.slug } ?? true
        )
        update(
            aliases: ["status"],
            canonicalKey: "status",
            desiredRawValue: article.status.rawValue,
            isSemanticallyUnchanged: (NativeArticleStatus(
                rawValue: parsed.scalar(for: ["status"])?.lowercased() ?? ""
            ) ?? .draft) == article.status
        )
        update(
            aliases: ["updatedAt", "updated_at"],
            canonicalKey: "updatedAt",
            desiredRawValue: article.updatedAt,
            isSemanticallyUnchanged: parsed.scalar(for: ["updatedAt", "updated_at"]) == article.updatedAt
        )
        update(
            aliases: ["excerpt", "description"],
            canonicalKey: "excerpt",
            desiredRawValue: quoted(article.excerpt),
            isSemanticallyUnchanged: existingExcerpt == article.excerpt
        )
        update(
            aliases: ["publishedAt", "published_at"],
            canonicalKey: "publishedAt",
            desiredRawValue: article.publishedAt,
            isSemanticallyUnchanged: parsed.scalar(for: ["publishedAt", "published_at"]) == article.publishedAt
        )
        update(
            aliases: ["banner"],
            canonicalKey: "banner",
            desiredRawValue: article.banner.map { quoted($0.url) },
            isSemanticallyUnchanged: parsed.scalar(for: ["banner"]) == article.banner?.url
        )
        update(
            aliases: ["bannerAlt", "banner_alt"],
            canonicalKey: "bannerAlt",
            desiredRawValue: article.banner.map { quoted($0.alt) },
            isSemanticallyUnchanged: parsed.scalar(for: ["bannerAlt", "banner_alt"]) == article.banner?.alt
        )

        let encodedMedia: String? = {
            guard !article.media.isEmpty,
                  let data = try? canonicalJSONEncoder().encode(article.media),
                  let value = String(data: data, encoding: .utf8) else { return nil }
            return quoted(value)
        }()
        update(
            aliases: ["leonMedia", "leon_media"],
            canonicalKey: "leonMedia",
            desiredRawValue: encodedMedia,
            isSemanticallyUnchanged: decodedMedia(parsed.scalar(for: ["leonMedia", "leon_media"])) == article.media
        )

        let desiredProperties = article.properties.filter { !reservedKeys.contains($0.key.lowercased()) }
        for key in desiredProperties.keys.sorted() {
            guard let value = desiredProperties[key] else { continue }
            let existingKey = parsed.values.keys.first {
                $0.caseInsensitiveCompare(key) == .orderedSame
            }
            let existingValue = existingKey.flatMap { parsed.values[$0] }
            update(
                aliases: [key],
                canonicalKey: key,
                desiredRawValue: value.yamlValue,
                isSemanticallyUnchanged: existingValue.map(NativeArticlePropertyValue.fromYAML) == value
            )
        }

        for entry in document.entries where !claimedEntryStarts.contains(entry.lineRange.lowerBound) {
            guard !reservedKeys.contains(entry.key.lowercased()),
                  NativeArticleProperties.isValidKey(entry.key),
                  !desiredProperties.keys.contains(where: {
                      $0.caseInsensitiveCompare(entry.key) == .orderedSame
                  }) else { continue }
            patches.append(FrontmatterSourcePatch(lineRange: entry.lineRange, replacement: []))
        }

        if !additions.isEmpty {
            patches.append(FrontmatterSourcePatch(
                lineRange: document.closingIndex..<document.closingIndex,
                replacement: additions
            ))
        }

        var frontmatterLines = Array(document.lines[...document.closingIndex])
        for patch in patches.sorted(by: { $0.lineRange.lowerBound > $1.lineRange.lowerBound }) {
            frontmatterLines.replaceSubrange(patch.lineRange, with: patch.replacement)
        }

        let normalizedBody = article.body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: document.lineEnding)
        let separator = String(
            repeating: document.lineEnding,
            count: 1 + document.leadingBodyBlankLineCount
        )
        let trailing = document.hadTrailingLineEnding ? document.lineEnding : ""
        let renderedFrontmatter = (document.hadByteOrderMark ? "\u{feff}" : "")
            + frontmatterLines.joined(separator: document.lineEnding)
        if normalizedBody.isEmpty {
            let emptyBodyLineEndings = String(
                repeating: document.lineEnding,
                count: document.leadingBodyBlankLineCount + (document.hadTrailingLineEnding ? 1 : 0)
            )
            return renderedFrontmatter + emptyBodyLineEndings
        }
        return renderedFrontmatter
            + separator
            + normalizedBody
            + trailing
    }

    private static func replacementLines(
        for entry: FrontmatterSourceEntry,
        desiredRawValue: String,
        sourceLines: [String]
    ) -> [String] {
        if let blockScalar = replacementBlockScalarLines(
            for: entry,
            desiredRawValue: desiredRawValue,
            sourceLines: sourceLines
        ) {
            return blockScalar
        }
        if let blockList = replacementBlockListLines(
            for: entry,
            desiredRawValue: desiredRawValue,
            sourceLines: sourceLines
        ) {
            return blockList
        }
        guard sourceLines.indices.contains(entry.lineRange.lowerBound) else {
            return ["\(yamlKey(entry.key)): \(desiredRawValue)"]
        }
        let line = sourceLines[entry.lineRange.lowerBound]
        guard let colon = line.firstIndex(of: ":") else {
            return ["\(yamlKey(entry.key)): \(desiredRawValue)"]
        }
        let prefix = String(line[...colon])
        let tail = String(line[line.index(after: colon)...])
        let commentIndex = inlineCommentIndex(in: tail)
        let valueAndWhitespace = commentIndex.map { String(tail[..<$0]) } ?? tail
        let comment = commentIndex.map { String(tail[$0...]) } ?? ""
        let leadingWhitespace = String(valueAndWhitespace.prefix { $0.isWhitespace })
        let withoutLeading = valueAndWhitespace.dropFirst(leadingWhitespace.count)
        let trailingWhitespace = String(withoutLeading.reversed().prefix { $0.isWhitespace }.reversed())
        let existingRawValue = String(withoutLeading.dropLast(trailingWhitespace.count))
        let preservedLeadingWhitespace = leadingWhitespace.isEmpty ? " " : leadingWhitespace
        let renderedValue = preservingScalarStyle(
            desiredRawValue,
            existingRawValue: existingRawValue
        )
        return [prefix + preservedLeadingWhitespace + renderedValue + trailingWhitespace + comment]
    }

    private static func replacementBlockScalarLines(
        for entry: FrontmatterSourceEntry,
        desiredRawValue: String,
        sourceLines: [String]
    ) -> [String]? {
        guard entry.lineRange.count > 1,
              sourceLines.indices.contains(entry.lineRange.lowerBound) else { return nil }
        let header = sourceLines[entry.lineRange.lowerBound]
        guard let colon = header.firstIndex(of: ":") else { return nil }
        let headerTail = String(header[header.index(after: colon)...])
        let commentIndex = inlineCommentIndex(in: headerTail)
        let indicatorSource = commentIndex.map { String(headerTail[..<$0]) } ?? headerTail
        let indicator = indicatorSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["|", "|-", "|+", ">", ">-", ">+"].contains(indicator),
              desiredRawValue.hasPrefix("\""), desiredRawValue.hasSuffix("\"") else { return nil }

        let continuation = sourceLines[(entry.lineRange.lowerBound + 1)..<entry.lineRange.upperBound]
        let indentation = continuation.lazy.compactMap { line -> String? in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let prefix = String(line.prefix { $0.isWhitespace })
            return prefix.isEmpty ? nil : prefix
        }.first ?? "  "
        let value = parseScalar(desiredRawValue)
        return [header] + value.components(separatedBy: "\n").map { line in
            line.isEmpty ? "" : indentation + line
        }
    }

    private static func replacementBlockListLines(
        for entry: FrontmatterSourceEntry,
        desiredRawValue: String,
        sourceLines: [String]
    ) -> [String]? {
        guard entry.lineRange.count > 1,
              sourceLines.indices.contains(entry.lineRange.lowerBound) else { return nil }
        let desired = NativeArticlePropertyValue.fromYAML(desiredRawValue)
        guard desired.kind == .list || desired.kind == .tags else { return nil }

        let header = sourceLines[entry.lineRange.lowerBound]
        guard let colon = header.firstIndex(of: ":") else { return nil }
        let headerTail = String(header[header.index(after: colon)...])
        let headerValueEnd = inlineCommentIndex(in: headerTail) ?? headerTail.endIndex
        guard headerTail[..<headerValueEnd]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty else { return nil }

        let continuation = Array(sourceLines[(entry.lineRange.lowerBound + 1)..<entry.lineRange.upperBound])
        let listLineOffsets = continuation.indices.filter {
            continuation[$0].trimmingCharacters(in: .whitespaces).hasPrefix("-")
        }
        guard let lastListOffset = listLineOffsets.last else { return nil }

        var replacement = [header]
        var desiredIndex = 0
        for (offset, line) in continuation.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("-") {
                if desired.listValues.indices.contains(desiredIndex) {
                    replacement.append(replacingBlockListItem(
                        in: line,
                        with: desired.listValues[desiredIndex]
                    ))
                }
                desiredIndex += 1
                if offset == lastListOffset, desiredIndex < desired.listValues.count {
                    for value in desired.listValues[desiredIndex...] {
                        replacement.append(replacingBlockListItem(in: line, with: value))
                    }
                    desiredIndex = desired.listValues.count
                }
            } else {
                replacement.append(line)
            }
        }
        return replacement
    }

    private static func replacingBlockListItem(in line: String, with value: String) -> String {
        guard let dash = line.firstIndex(where: { !$0.isWhitespace }), line[dash] == "-" else {
            return "  - \(quoted(value))"
        }
        let prefix = String(line[...dash])
        let tail = String(line[line.index(after: dash)...])
        let commentIndex = inlineCommentIndex(in: tail)
        let valueAndWhitespace = commentIndex.map { String(tail[..<$0]) } ?? tail
        let comment = commentIndex.map { String(tail[$0...]) } ?? ""
        let leadingWhitespace = String(valueAndWhitespace.prefix { $0.isWhitespace })
        let withoutLeading = valueAndWhitespace.dropFirst(leadingWhitespace.count)
        let trailingWhitespace = String(withoutLeading.reversed().prefix { $0.isWhitespace }.reversed())
        let existingRawValue = String(withoutLeading.dropLast(trailingWhitespace.count))
        let rendered: String
        let existing = existingRawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if existing.hasPrefix("'") && existing.hasSuffix("'") {
            rendered = "'\(value.replacingOccurrences(of: "'", with: "''"))'"
        } else if existing.hasPrefix("\"") && existing.hasSuffix("\"") {
            rendered = quoted(value)
        } else if isSafePlainYAMLScalar(value) {
            rendered = value
        } else {
            rendered = quoted(value)
        }
        return prefix
            + (leadingWhitespace.isEmpty ? " " : leadingWhitespace)
            + rendered
            + trailingWhitespace
            + comment
    }

    private static func isSafePlainYAMLScalar(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == value,
              !trimmed.hasPrefix("-"), !trimmed.hasPrefix("?"), !trimmed.hasPrefix(":"),
              trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: ":#[]{},&*!|>'\"%@`")) == nil else {
            return false
        }
        switch trimmed.lowercased() {
        case "true", "false", "yes", "no", "on", "off", "null", "~": return false
        default: return true
        }
    }

    private static func preservingScalarStyle(_ desiredRawValue: String, existingRawValue: String) -> String {
        let existing = existingRawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard desiredRawValue.count >= 2,
              desiredRawValue.hasPrefix("\""), desiredRawValue.hasSuffix("\"") else {
            return desiredRawValue
        }
        let value = parseScalar(desiredRawValue)
        if existing.hasPrefix("'") && existing.hasSuffix("'") {
            return "'\(value.replacingOccurrences(of: "'", with: "''"))'"
        }
        if existing.hasPrefix("\"") && existing.hasSuffix("\"") {
            return quoted(value)
        }
        return desiredRawValue
    }

    private static func inlineCommentIndex(in value: String) -> String.Index? {
        var quote: Character?
        var previous: Character?
        var escaping = false
        for index in value.indices {
            let character = value[index]
            if escaping {
                escaping = false
            } else if character == "\\", quote == "\"" {
                escaping = true
            } else if character == "\"" || character == "'" {
                if quote == character { quote = nil } else if quote == nil { quote = character }
            } else if character == "#", quote == nil, previous?.isWhitespace == true {
                return index
            }
            previous = character
        }
        return nil
    }

    private static func topLevelKey(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
              line.first?.isWhitespace != true,
              let colon = line.firstIndex(of: ":") else { return nil }
        let key = parseScalar(String(line[..<colon]).trimmingCharacters(in: .whitespaces))
        return NativeArticleProperties.isValidKey(key) ? key : nil
    }

    private static func canonicalJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func quoted(_ value: String) -> String {
        let encoder = canonicalJSONEncoder()
        return (try? String(data: encoder.encode(value), encoding: .utf8)) ?? "\"\""
    }

    private static func yamlKey(_ key: String) -> String {
        key.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) == nil ? quoted(key) : key
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
