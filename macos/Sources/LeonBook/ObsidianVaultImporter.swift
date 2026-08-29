import Foundation

public struct NativeObsidianAttachment: Hashable, Identifiable {
    public let sourceURL: URL
    public let originalToken: String
    public let displayName: String
    public let kind: String

    public var id: String { "\(sourceURL.path)\u{0}\(originalToken)" }
}

public struct NativeObsidianImportNote: Hashable, Identifiable {
    public let sourceURL: URL
    public let relativePath: String
    public let slug: String
    public let title: String
    public let body: String
    public let category: String
    public let excerpt: String
    public let tags: [String]
    public let status: NativeArticleStatus
    public let properties: [String: NativeArticlePropertyValue]
    public let publishedAt: String?
    public let updatedAt: String?
    public let attachments: [NativeObsidianAttachment]
    public let conflictReason: String?

    public var id: String { relativePath }
    public var canImport: Bool { conflictReason == nil }
}

public struct NativeObsidianImportPreview: Hashable, Identifiable {
    public let vaultURL: URL
    public let notes: [NativeObsidianImportNote]
    public let warnings: [String]

    public var id: String { vaultURL.standardizedFileURL.path }
    public var importableNotes: [NativeObsidianImportNote] { notes.filter(\.canImport) }
    public var importableCount: Int { importableNotes.count }
    public var conflictCount: Int { notes.count - importableCount }
    public var attachmentCount: Int { importableNotes.reduce(0) { $0 + $1.attachments.count } }
}

public struct NativeObsidianImportResult: Hashable {
    public let importedCount: Int
    public let skippedCount: Int
    public let attachmentCount: Int
    public let warnings: [String]
}

public enum NativeObsidianVaultImporter {
    public static func scan(
        vaultURL: URL,
        existingSlugs: Set<String> = []
    ) throws -> NativeObsidianImportPreview {
        let root = vaultURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NativeStoreError.fileSystem("选择的 Obsidian Vault 不存在或不是文件夹")
        }

        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw NativeStoreError.fileSystem("无法读取 Obsidian Vault")
        }

        var markdownURLs: [URL] = []
        var fileURLs: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: resourceKeys)
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard isInside(resolved, root: root) else { continue }
            fileURLs.append(resolved)
            if resolved.pathExtension.caseInsensitiveCompare("md") == .orderedSame {
                markdownURLs.append(resolved)
            }
        }
        markdownURLs.sort { relativePath(of: $0, root: root) < relativePath(of: $1, root: root) }

        let attachmentIndex = AttachmentIndex(files: fileURLs, root: root)
        var parsedNotes: [ParsedNote] = []
        var warnings: [String] = []
        var allocatedSlugs = Set<String>()
        for url in markdownURLs {
            do {
                var parsed = try parseNote(at: url, root: root, attachmentIndex: attachmentIndex)
                let baseSlug = sanitizedSlug(parsed.requestedSlug ?? parsed.relativePathWithoutExtension)
                parsed.slug = allocateSlug(base: baseSlug, used: &allocatedSlugs)
                parsedNotes.append(parsed)
                warnings.append(contentsOf: parsed.warnings)
            } catch {
                warnings.append("\(relativePath(of: url, root: root))：\(error.localizedDescription)")
            }
        }

        let linkIndex = LinkIndex(notes: parsedNotes)
        let normalizedExisting = Set(existingSlugs.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) })
        let notes = parsedNotes.map { parsed -> NativeObsidianImportNote in
            let normalizedSlug = parsed.slug.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let conflict = normalizedExisting.contains(normalizedSlug)
                ? "SQLite 中已存在相同 slug，已保护并跳过"
                : nil
            return NativeObsidianImportNote(
                sourceURL: parsed.sourceURL,
                relativePath: parsed.relativePath,
                slug: parsed.slug,
                title: parsed.title,
                body: rewriteWikiLinks(in: parsed.body, from: parsed, index: linkIndex),
                category: parsed.category,
                excerpt: parsed.excerpt,
                tags: parsed.tags,
                status: parsed.status,
                properties: parsed.properties,
                publishedAt: parsed.publishedAt,
                updatedAt: parsed.updatedAt,
                attachments: parsed.attachments,
                conflictReason: conflict
            )
        }

        return NativeObsidianImportPreview(vaultURL: root, notes: notes, warnings: warnings)
    }
}

private extension NativeObsidianVaultImporter {
    struct ParsedNote {
        let sourceURL: URL
        let relativePath: String
        let relativePathWithoutExtension: String
        let requestedSlug: String?
        var slug = ""
        let title: String
        let aliases: [String]
        let body: String
        let category: String
        let excerpt: String
        let tags: [String]
        let status: NativeArticleStatus
        let properties: [String: NativeArticlePropertyValue]
        let publishedAt: String?
        let updatedAt: String?
        let attachments: [NativeObsidianAttachment]
        let warnings: [String]
    }

    struct Frontmatter {
        let body: String
        let values: [String: String]

        func rawValue(for keys: [String]) -> String? {
            for key in keys {
                if let match = values.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
                    return match.value
                }
            }
            return nil
        }

        func scalar(for keys: [String]) -> String? {
            rawValue(for: keys).map(parseScalar)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func list(for keys: [String]) -> [String] {
            guard let raw = rawValue(for: keys) else { return [] }
            return parseList(raw)
        }
    }

    struct AttachmentIndex {
        let byRelativePath: [String: URL]
        let byFilename: [String: [URL]]
        let root: URL

        init(files: [URL], root: URL) {
            self.root = root
            var paths: [String: URL] = [:]
            var names: [String: [URL]] = [:]
            for file in files where file.pathExtension.caseInsensitiveCompare("md") != .orderedSame {
                paths[normalizedPath(relativePath(of: file, root: root))] = file
                names[file.lastPathComponent.lowercased(), default: []].append(file)
            }
            byRelativePath = paths
            byFilename = names
        }

        func resolve(_ reference: String, relativeTo noteURL: URL) -> URL? {
            let cleaned = decodedAttachmentPath(reference)
            guard !cleaned.isEmpty else { return nil }
            let relativeCandidate = noteURL.deletingLastPathComponent()
                .appendingPathComponent(cleaned)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            if Self.fileExistsInside(relativeCandidate, root: root) { return relativeCandidate }

            let rootCandidate = root.appendingPathComponent(cleaned)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            if Self.fileExistsInside(rootCandidate, root: root) { return rootCandidate }

            if let exact = byRelativePath[normalizedPath(cleaned)] { return exact }
            let matches = byFilename[URL(fileURLWithPath: cleaned).lastPathComponent.lowercased()] ?? []
            return matches.count == 1 ? matches[0] : nil
        }

        private static func fileExistsInside(_ url: URL, root: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return isInside(url, root: root)
                && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
    }

    struct LinkIndex {
        let slugsByReference: [String: String]
        let ambiguousReferences: Set<String>

        init(notes: [ParsedNote]) {
            var values: [String: Set<String>] = [:]
            for note in notes {
                let references = [
                    note.relativePathWithoutExtension,
                    URL(fileURLWithPath: note.relativePathWithoutExtension).lastPathComponent,
                    note.title,
                ] + note.aliases
                for reference in references where !reference.isEmpty {
                    values[normalizeReference(reference), default: []].insert(note.slug)
                }
            }
            slugsByReference = values.compactMapValues { $0.count == 1 ? $0.first : nil }
            ambiguousReferences = Set(values.compactMap { $0.value.count > 1 ? $0.key : nil })
        }

        func slug(for target: String, from note: ParsedNote) -> String? {
            let normalized = normalizeReference(target)
            if let direct = slugsByReference[normalized] { return direct }
            let sourceDirectory = URL(fileURLWithPath: note.relativePathWithoutExtension).deletingLastPathComponent().path
            let relative = sourceDirectory == "." ? target : "\(sourceDirectory)/\(target)"
            let relativeKey = normalizeReference(relative)
            guard !ambiguousReferences.contains(relativeKey) else { return nil }
            return slugsByReference[relativeKey]
        }
    }

    static func parseNote(at url: URL, root: URL, attachmentIndex: AttachmentIndex) throws -> ParsedNote {
        var source = try String(contentsOf: url, encoding: .utf8)
        if source.hasPrefix("\u{feff}") { source.removeFirst() }
        let frontmatter = parseFrontmatter(source)
        let relative = relativePath(of: url, root: root)
        let relativeWithoutExtension = String(relative.dropLast(url.pathExtension.count + 1))
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let title = frontmatter.scalar(for: ["title"]).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle
        let aliases = frontmatter.list(for: ["aliases", "alias"])
        let tags = NativeArticleTag.normalized(frontmatter.list(for: ["tags", "tag"]))
        let category = frontmatter.scalar(for: ["category", "folder"]).flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(fileURLWithPath: relativeWithoutExtension).deletingLastPathComponent().lastPathComponent.nonEmpty
            ?? "Notes"
        let excerpt = frontmatter.scalar(for: ["excerpt", "description", "summary"]).flatMap { $0.isEmpty ? nil : $0 }
            ?? excerpt(from: frontmatter.body)
        let status = articleStatus(from: frontmatter)
        let publishedAt = timestamp(from: frontmatter.scalar(for: ["publishedAt", "published_at", "published", "date", "created"]))
        let updatedAt = timestamp(from: frontmatter.scalar(for: ["updatedAt", "updated_at", "updated", "modified"]))
            ?? modificationTimestamp(for: url)
        let attachmentsResult = attachments(in: frontmatter.body, noteURL: url, index: attachmentIndex)

        let canonicalKeys = Set([
            "title", "tag", "tags", "category", "folder", "excerpt", "description", "summary",
            "status", "draft", "publish", "published", "publishedat", "published_at", "date", "created",
            "updated", "updatedat", "updated_at", "modified", "slug", "permalink", "alias", "aliases",
        ])
        var properties = frontmatter.values
            .filter { !canonicalKeys.contains($0.key.lowercased()) }
            .mapValues(NativeArticlePropertyValue.fromYAML)
        if !aliases.isEmpty { properties["aliases"] = .list(aliases) }

        return ParsedNote(
            sourceURL: url,
            relativePath: relative,
            relativePathWithoutExtension: relativeWithoutExtension,
            requestedSlug: frontmatter.scalar(for: ["slug", "permalink"]),
            title: title,
            aliases: aliases,
            body: frontmatter.body,
            category: category,
            excerpt: excerpt,
            tags: tags,
            status: status,
            properties: properties,
            publishedAt: publishedAt,
            updatedAt: updatedAt,
            attachments: attachmentsResult.attachments,
            warnings: attachmentsResult.warnings.map { "\(relative)：\($0)" }
        )
    }

    static func parseFrontmatter(_ source: String) -> Frontmatter {
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
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  !line.trimmingCharacters(in: .whitespaces).hasPrefix("#"),
                  let colon = line.firstIndex(of: ":") else {
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
                if candidate.first?.isWhitespace == true || candidate.trimmingCharacters(in: .whitespaces).hasPrefix("-") {
                    childLines.append(candidate)
                    next += 1
                } else if candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                    childLines.append(candidate)
                    next += 1
                } else {
                    break
                }
            }
            if !childLines.isEmpty {
                if raw.isEmpty, childLines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("-") }) {
                    let items = childLines.compactMap { child -> String? in
                        let trimmed = child.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("-") else { return nil }
                        return parseScalar(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                    }
                    raw = yamlInlineList(items)
                } else {
                    raw += "\n" + childLines.joined(separator: "\n")
                }
            }
            values[key] = raw.isEmpty ? "\"\"" : raw
            index = next
        }
        let bodyStart = closingIndex + 1
        let body = bodyStart < lines.count
            ? lines[bodyStart...].joined(separator: "\n").trimmingCharacters(in: .newlines)
            : ""
        return Frontmatter(body: body, values: values)
    }

    static func articleStatus(from frontmatter: Frontmatter) -> NativeArticleStatus {
        if let draft = frontmatter.scalar(for: ["draft"]), let value = parseBoolean(draft) {
            return value ? .draft : .published
        }
        if let publish = frontmatter.scalar(for: ["publish", "published"]), let value = parseBoolean(publish) {
            return value ? .published : .draft
        }
        guard let value = frontmatter.scalar(for: ["status"])?.lowercased() else { return .draft }
        return ["published", "publish", "public", "已发布"].contains(value) ? .published : .draft
    }

    static func attachments(
        in body: String,
        noteURL: URL,
        index: AttachmentIndex
    ) -> (attachments: [NativeObsidianAttachment], warnings: [String]) {
        let patterns = [
            (#"!\[\[([^\]\r\n]+)\]\]"#, true),
            (#"!\[([^\]]*)\]\(([^)\r\n]+)\)"#, false),
        ]
        var attachments: [NativeObsidianAttachment] = []
        var warnings: [String] = []
        var seen = Set<String>()
        for (pattern, isWikiEmbed) in patterns {
            let expression = try! NSRegularExpression(pattern: pattern)
            let range = NSRange(body.startIndex..., in: body)
            for match in expression.matches(in: body, range: range) {
                guard let matchRange = Range(match.range, in: body) else { continue }
                let token = String(body[matchRange])
                let referenceIndex = isWikiEmbed ? 1 : 2
                guard let referenceRange = Range(match.range(at: referenceIndex), in: body) else { continue }
                var reference = String(body[referenceRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if isWikiEmbed { reference = String(reference.split(separator: "|", maxSplits: 1)[0]) }
                guard !reference.lowercased().hasPrefix("http://"),
                      !reference.lowercased().hasPrefix("https://"),
                      !reference.lowercased().hasPrefix("data:"),
                      !reference.hasPrefix("/media/") else { continue }
                guard let sourceURL = index.resolve(reference, relativeTo: noteURL) else {
                    let extensionName = URL(fileURLWithPath: decodedAttachmentPath(reference)).pathExtension
                    if !extensionName.isEmpty, extensionName.caseInsensitiveCompare("md") != .orderedSame {
                        warnings.append("找不到附件 \(reference)")
                    }
                    continue
                }
                let identity = "\(sourceURL.path.lowercased())\u{0}\(token)"
                guard seen.insert(identity).inserted else { continue }
                let alt: String
                if !isWikiEmbed, let altRange = Range(match.range(at: 1), in: body) {
                    let value = String(body[altRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    alt = value.isEmpty ? sourceURL.lastPathComponent : value
                } else {
                    alt = sourceURL.lastPathComponent
                }
                attachments.append(NativeObsidianAttachment(
                    sourceURL: sourceURL,
                    originalToken: token,
                    displayName: alt,
                    kind: attachmentKind(for: sourceURL)
                ))
            }
        }
        return (attachments, warnings)
    }

    static func rewriteWikiLinks(in body: String, from note: ParsedNote, index: LinkIndex) -> String {
        let expression = try! NSRegularExpression(pattern: #"(?<!!)\[\[([^\[\]\r\n]+)\]\]"#)
        let matches = expression.matches(in: body, range: NSRange(body.startIndex..., in: body))
        guard !matches.isEmpty else { return body }
        var result = body
        for match in matches.reversed() {
            guard let wholeRange = Range(match.range, in: result),
                  let valueRange = Range(match.range(at: 1), in: result) else { continue }
            let reference = NativeArticleLink.Reference(rawValue: String(result[valueRange]))
            guard let slug = index.slug(for: reference.target, from: note) else { continue }
            let originalTarget = reference.heading.map { "\(reference.target)#\($0)" } ?? reference.target
            let originalValue = String(result[valueRange])
            let hasAlias = originalValue.contains("|")
            let label = hasAlias ? reference.label : originalTarget
            let destination = reference.heading.map { "\(slug)#\($0)" } ?? slug
            result.replaceSubrange(wholeRange, with: "[[\(destination)|\(label)]]")
        }
        return result
    }

    static func parseScalar(_ raw: String) -> String {
        let value = stripYAMLComment(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2 else { return value }
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            return (try? JSONDecoder().decode(String.self, from: Data(value.utf8))) ?? String(value.dropFirst().dropLast())
        }
        if value.hasPrefix("'") && value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value
    }

    static func parseList(_ raw: String) -> [String] {
        let value = stripYAMLComment(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("[") && value.hasSuffix("]") {
            return splitYAMLList(String(value.dropFirst().dropLast())).map(parseScalar).filter { !$0.isEmpty }
        }
        if value.contains("\n") {
            return value.components(separatedBy: .newlines).compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("-") ? parseScalar(String(trimmed.dropFirst())) : nil
            }.filter { !$0.isEmpty }
        }
        let scalar = parseScalar(value)
        return scalar.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func splitYAMLList(_ value: String) -> [String] {
        var results: [String] = []
        var current = ""
        var quote: Character?
        for character in value {
            if character == "\"" || character == "'" {
                if quote == character { quote = nil } else if quote == nil { quote = character }
                current.append(character)
            } else if character == ",", quote == nil {
                results.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        results.append(current.trimmingCharacters(in: .whitespaces))
        return results
    }

    static func stripYAMLComment(_ value: String) -> String {
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

    static func yamlInlineList(_ values: [String]) -> String {
        let encoder = JSONEncoder()
        let encoded = values.map { value -> String in
            (try? String(data: encoder.encode(value), encoding: .utf8)) ?? "\"\""
        }
        return "[\(encoded.joined(separator: ", "))]"
    }

    static func parseBoolean(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return nil
        }
    }

    static func excerpt(from body: String) -> String {
        let visible = body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("!") }
            ?? ""
        let stripped = visible
            .replacingOccurrences(of: #"\[\[([^\]|]+)\|([^\]]+)\]\]"#, with: "$2", options: .regularExpression)
            .replacingOccurrences(of: #"\[\[([^\]]+)\]\]"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"[*_`>]"#, with: "", options: .regularExpression)
        return String(stripped.prefix(180))
    }

    static func timestamp(from value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if let date = NativeTimestamp.date(from: value) { return NativeTimestamp.string(from: date) }
        let formats = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return NativeTimestamp.string(from: date) }
        }
        return nil
    }

    static func modificationTimestamp(for url: URL) -> String? {
        guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
        return NativeTimestamp.string(from: date)
    }

    static func sanitizedSlug(_ rawValue: String) -> String {
        let decoded = rawValue.removingPercentEncoding ?? rawValue
        let value = decoded.folding(options: .diacriticInsensitive, locale: .current).lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
        var slug = String(value).split(separator: "-").joined(separator: "-")
        if slug.isEmpty { slug = "obsidian-note" }
        if ["inbox", "moments"].contains(slug) { slug += "-note" }
        return String(slug.prefix(80))
    }

    static func allocateSlug(base: String, used: inout Set<String>) -> String {
        var candidate = base
        var suffix = 2
        while !used.insert(candidate.lowercased()).inserted {
            let suffixText = "-\(suffix)"
            candidate = String(base.prefix(max(1, 80 - suffixText.count))) + suffixText
            suffix += 1
        }
        return candidate
    }

    static func attachmentKind(for url: URL) -> String {
        let extensionName = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp", "svg"].contains(extensionName) {
            return "image"
        }
        if ["mov", "mp4", "m4v", "webm", "avi", "mkv"].contains(extensionName) {
            return "video"
        }
        return "file"
    }

    static func decodedAttachmentPath(_ reference: String) -> String {
        var value = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<"), value.hasSuffix(">") { value = String(value.dropFirst().dropLast()) }
        if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]) }
        return value.removingPercentEncoding ?? value
    }

    static func normalizedPath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    static func normalizeReference(_ reference: String) -> String {
        var value = reference.replacingOccurrences(of: "\\", with: "/")
        if value.lowercased().hasSuffix(".md") { value.removeLast(3) }
        return normalizedPath(value)
    }

    static func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    static func isInside(_ url: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
