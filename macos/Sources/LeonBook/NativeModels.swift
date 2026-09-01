import Foundation
import LeonBookSearchModule

public enum NativeWritingMetrics {
    public static func characterCount(of body: String) -> Int {
        NativeBlockHierarchyMetadata.removingMarkers(from: body)
            .trimmingCharacters(in: .whitespacesAndNewlines).count
    }
}

public enum NativeTimestamp {
    private static let formatterLock = NSLock()
    private static let parsedDateCache: NSCache<NSString, NSDate> = {
        let cache = NSCache<NSString, NSDate>()
        cache.countLimit = 20_000
        return cache
    }()
    private static let standardFormatter = ISO8601DateFormatter()
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter
    }()

    public static func date(from timestamp: String) -> Date? {
        if let cached = parsedDateCache.object(forKey: timestamp as NSString) {
            return cached as Date
        }
        formatterLock.lock()
        defer { formatterLock.unlock() }
        if let cached = parsedDateCache.object(forKey: timestamp as NSString) {
            return cached as Date
        }
        let parsed: Date?
        if timestamp.utf8.contains(UInt8(ascii: ".")) {
            parsed = fractionalFormatter.date(from: timestamp)
                ?? standardFormatter.date(from: timestamp)
        } else {
            parsed = standardFormatter.date(from: timestamp)
                ?? fractionalFormatter.date(from: timestamp)
        }
        if let parsed {
            parsedDateCache.setObject(parsed as NSDate, forKey: timestamp as NSString)
        }
        return parsed
    }

    public static func string(from date: Date) -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        return fractionalFormatter.string(from: date)
    }
}

public enum NativeSearchDocumentType: String, Codable, CaseIterable, Hashable, Identifiable {
    case article
    case moment

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .article: return "文章"
        case .moment: return "微博"
        }
    }

    var systemImage: String {
        switch self {
        case .article: return "doc.text"
        case .moment: return "bubble.left.and.text.bubble.right"
        }
    }
}

/// Parsed form of the search box syntax. Unknown operators remain ordinary
/// search terms so typing a colon never makes content silently disappear.
public struct NativeGlobalSearchQuery: Equatable {
    public let rawValue: String
    public let textTerms: [String]
    public let tags: [String]
    public let status: NativeArticleStatus?
    public let types: Set<NativeSearchDocumentType>
    public let after: Date?
    public let before: Date?
    public let propertyFilters: [NativeArticlePropertyFilter]

    public var isEmpty: Bool {
        textTerms.isEmpty && tags.isEmpty && status == nil && types.isEmpty
            && after == nil && before == nil && propertyFilters.isEmpty
    }

    public init(_ rawValue: String, calendar: Calendar = .current) {
        self.rawValue = rawValue
        let parsed = FirstPartySearchQueryParser.parse(
            rawValue,
            calendar: calendar,
            isValidPropertyKey: NativeArticleProperties.isValidKey
        )
        textTerms = parsed.textTerms
        tags = parsed.tags
        status = parsed.status.flatMap(NativeArticleStatus.init(rawValue:))
        types = Set(parsed.types.compactMap(NativeSearchDocumentType.init(rawValue:)))
        after = parsed.after
        before = parsed.before
        propertyFilters = parsed.propertyFilters.map {
            NativeArticlePropertyFilter(key: $0.key, value: $0.value)
        }
    }
}

public struct NativeArticlePropertyFilter: Equatable, Hashable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public struct NativeGlobalSearchResult: Hashable, Identifiable {
    public let documentType: NativeSearchDocumentType
    public let documentID: String
    public let title: String
    public let snippet: String
    public let tags: [String]
    public let category: String?
    public let status: NativeArticleStatus?
    public let timestamp: String

    public var id: String { "\(documentType.rawValue):\(documentID)" }

    public init(
        documentType: NativeSearchDocumentType,
        documentID: String,
        title: String,
        snippet: String,
        tags: [String],
        category: String?,
        status: NativeArticleStatus?,
        timestamp: String
    ) {
        self.documentType = documentType
        self.documentID = documentID
        self.title = title
        self.snippet = snippet
        self.tags = tags
        self.category = category
        self.status = status
        self.timestamp = timestamp
    }
}

public struct NativeUser: Codable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let createdAt: String

    public static let leon = NativeUser(id: "leon", name: "leon", createdAt: "")

    public init(id: String, name: String, createdAt: String) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

public enum NativeArticleStatus: String, Codable, CaseIterable, Identifiable {
    case draft
    case published

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .draft: return "草稿"
        case .published: return "已发布"
        }
    }
}

public struct NativeMedia: Codable, Hashable, Identifiable {
    public let kind: String
    public let name: String
    public let size: Int
    public let url: String

    public var id: String { url }

    public var isVideo: Bool { kind == "video" }
    public var isImage: Bool { kind == "image" }
    public var isFile: Bool { !isVideo && !isImage }

    public init(kind: String, name: String, size: Int, url: String) {
        self.kind = kind
        self.name = name
        self.size = size
        self.url = url
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "image"
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "media"
        size = try container.decodeIfPresent(Int.self, forKey: .size) ?? 0
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
    }
}

public struct NativeBanner: Codable, Hashable {
    public let alt: String
    public let name: String
    public let size: Int
    public let url: String

    public init(alt: String, name: String, size: Int, url: String) {
        self.alt = alt
        self.name = name
        self.size = size
        self.url = url
    }
}

public struct NativeArticleSummary: Codable, Hashable, Identifiable {
    public let aliases: [String]
    public let banner: NativeBanner?
    public let category: String
    public let excerpt: String
    public var pageViews: Int
    public let properties: [String: NativeArticlePropertyValue]
    public let publishedAt: String?
    public let slug: String
    public let sourceRelativePath: String
    public let status: NativeArticleStatus
    public let tags: [String]
    public let title: String
    public let updatedAt: String
    public let wordCount: Int

    public var id: String { slug }

    public init(
        aliases: [String] = [],
        banner: NativeBanner?,
        category: String,
        excerpt: String,
        pageViews: Int = 0,
        properties: [String: NativeArticlePropertyValue] = [:],
        publishedAt: String?,
        slug: String,
        sourceRelativePath: String = "",
        status: NativeArticleStatus,
        tags: [String],
        title: String,
        updatedAt: String,
        wordCount: Int
    ) {
        self.aliases = NativeArticleAlias.normalized(aliases)
        self.banner = banner
        self.category = category
        self.excerpt = excerpt
        self.pageViews = max(0, pageViews)
        self.properties = properties
        self.publishedAt = publishedAt
        self.slug = slug
        self.sourceRelativePath = sourceRelativePath.isEmpty ? "\(slug).md" : sourceRelativePath
        self.status = status
        self.tags = NativeArticleTag.normalized(tags)
        self.title = title
        self.updatedAt = updatedAt
        self.wordCount = wordCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            aliases: try container.decodeIfPresent([String].self, forKey: .aliases) ?? [],
            banner: try container.decodeIfPresent(NativeBanner.self, forKey: .banner),
            category: try container.decodeIfPresent(String.self, forKey: .category) ?? "Uncategorized",
            excerpt: try container.decodeIfPresent(String.self, forKey: .excerpt) ?? "",
            pageViews: try container.decodeIfPresent(Int.self, forKey: .pageViews) ?? 0,
            properties: try container.decodeIfPresent([String: NativeArticlePropertyValue].self, forKey: .properties) ?? [:],
            publishedAt: try container.decodeIfPresent(String.self, forKey: .publishedAt),
            slug: try container.decodeIfPresent(String.self, forKey: .slug) ?? "",
            sourceRelativePath: try container.decodeIfPresent(String.self, forKey: .sourceRelativePath) ?? "",
            status: try container.decodeIfPresent(NativeArticleStatus.self, forKey: .status) ?? .published,
            tags: try container.decodeIfPresent([String].self, forKey: .tags) ?? [],
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? "Untitled note",
            updatedAt: try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? "",
            wordCount: try container.decodeIfPresent(Int.self, forKey: .wordCount) ?? 0
        )
    }

    public var sourceFolderPath: String {
        sourceRelativePath.split(separator: "/").dropLast().joined(separator: "/")
    }
}

public struct NativeMarkdownSyncResult: Equatable {
    public let insertedCount: Int
    public let updatedCount: Int
    public let movedCount: Int
    public let deletedCount: Int
    public let unchangedCount: Int
    public let affectedArticleSlugs: [String]
    public let warnings: [String]

    public var didChange: Bool {
        insertedCount + updatedCount + movedCount + deletedCount > 0
    }

    public init(
        insertedCount: Int = 0,
        updatedCount: Int = 0,
        movedCount: Int = 0,
        deletedCount: Int = 0,
        unchangedCount: Int = 0,
        affectedArticleSlugs: [String] = [],
        warnings: [String] = []
    ) {
        self.insertedCount = insertedCount
        self.updatedCount = updatedCount
        self.movedCount = movedCount
        self.deletedCount = deletedCount
        self.unchangedCount = unchangedCount
        self.affectedArticleSlugs = affectedArticleSlugs
        self.warnings = warnings
    }
}

public struct NativeArticleTab: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public private(set) var slug: String
    public var isPinned: Bool
    public private(set) var backStack: [String]
    public private(set) var forwardStack: [String]

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    public init(
        id: UUID = UUID(),
        slug: String,
        isPinned: Bool = false,
        backStack: [String] = [],
        forwardStack: [String] = []
    ) {
        self.id = id
        self.slug = slug
        self.isPinned = isPinned
        self.backStack = Array(backStack.suffix(50))
        self.forwardStack = Array(forwardStack.suffix(50))
    }

    public mutating func navigate(to nextSlug: String) {
        guard !nextSlug.isEmpty, nextSlug != slug else { return }
        backStack.append(slug)
        backStack = Array(backStack.suffix(50))
        slug = nextSlug
        forwardStack = []
    }

    @discardableResult
    public mutating func goBack() -> String? {
        guard let previousSlug = backStack.popLast() else { return nil }
        forwardStack.append(slug)
        forwardStack = Array(forwardStack.suffix(50))
        slug = previousSlug
        return previousSlug
    }

    @discardableResult
    public mutating func goForward() -> String? {
        guard let nextSlug = forwardStack.popLast() else { return nil }
        backStack.append(slug)
        backStack = Array(backStack.suffix(50))
        slug = nextSlug
        return nextSlug
    }
}

public struct NativeArticleCommentSelection: Codable, Hashable {
    public let quote: String
    public let anchorID: String

    public init(quote: String, anchorID: String) {
        self.quote = quote
        self.anchorID = anchorID
    }
}

public enum NativeArticleCommentAnchor {
    public static let articleTopID = "article-comment-top"

    public static func selection(for rawQuote: String, in markdown: String) -> NativeArticleCommentSelection? {
        let quote = rawQuote
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !quote.isEmpty else { return nil }

        let storedQuote = String(quote.prefix(800))
        let normalizedQuote = normalizedText(storedQuote)
        guard !normalizedQuote.isEmpty else { return nil }
        let searchNeedle = String(normalizedQuote.prefix(120))

        var sections: [(anchorID: String, source: String)] = []
        var currentAnchorID = articleTopID
        var currentLines: [String] = []
        var headingIndex = 0

        let lines = markdown.components(separatedBy: .newlines)
        var lineIndex = 0
        var activeFence: (marker: Character, length: Int)?
        while lineIndex < lines.count {
            let line = lines[lineIndex]
            if let fence = activeFence {
                currentLines.append(line)
                if closesFence(line, fence: fence) {
                    activeFence = nil
                }
                lineIndex += 1
                continue
            }
            if let fence = opensFence(line) {
                activeFence = fence
                currentLines.append(line)
                lineIndex += 1
                continue
            }

            let isSetextHeading = lineIndex + 1 < lines.count
                && !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && isSetextMarker(lines[lineIndex + 1])
            if isHeading(line) || isSetextHeading {
                if !currentLines.isEmpty {
                    sections.append((currentAnchorID, currentLines.joined(separator: "\n")))
                }
                currentAnchorID = "markdown-heading-\(headingIndex)"
                headingIndex += 1
                currentLines = [line]
                if isSetextHeading {
                    currentLines.append(lines[lineIndex + 1])
                    lineIndex += 1
                }
            } else {
                currentLines.append(line)
            }
            lineIndex += 1
        }
        sections.append((currentAnchorID, currentLines.joined(separator: "\n")))

        let anchorID = sections.first(where: {
            normalizedText($0.source).contains(searchNeedle)
        })?.anchorID ?? articleTopID
        return NativeArticleCommentSelection(quote: storedQuote, anchorID: anchorID)
    }

    private static func isHeading(_ line: String) -> Bool {
        line.range(of: #"^#{1,6}[ \t]+\S"#, options: .regularExpression) != nil
    }

    private static func isSetextMarker(_ line: String) -> Bool {
        let marker = line.trimmingCharacters(in: .whitespaces)
        return !marker.isEmpty && (marker.allSatisfy { $0 == "=" } || marker.allSatisfy { $0 == "-" })
    }

    private static func opensFence(_ line: String) -> (marker: Character, length: Int)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let run = trimmed.prefix { $0 == marker }
        return run.count >= 3 ? (marker, run.count) : nil
    }

    private static func closesFence(_ line: String, fence: (marker: Character, length: Int)) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let run = trimmed.prefix { $0 == fence.marker }
        return run.count >= fence.length
            && trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func normalizedText(_ source: String) -> String {
        var result = source
        let replacements: [(String, String)] = [
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),
            (#"\[\[([^\]]+)\]\]"#, "$1"),
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
            (#"(?m)^[ \t]*(?:#{1,6}|>|[-+*]|\d+[.)])[ \t]+"#, ""),
            (#"[*_~`]"#, ""),
        ]
        for (pattern, template) in replacements {
            result = result.replacingOccurrences(
                of: pattern,
                with: template,
                options: .regularExpression
            )
        }
        return result
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

public struct NativeArticleComment: Codable, Hashable, Identifiable {
    public let id: String
    public let articleSlug: String
    public let parentID: String?
    public let authorName: String
    public let text: String
    public let selection: NativeArticleCommentSelection?
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        articleSlug: String,
        parentID: String?,
        authorName: String,
        text: String,
        selection: NativeArticleCommentSelection?,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.articleSlug = articleSlug
        self.parentID = parentID
        self.authorName = authorName
        self.text = text
        self.selection = selection
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct NativeArticleRelations: Equatable {
    public let outgoing: [NativeArticleSummary]
    public let incoming: [NativeArticleSummary]
    public let unlinkedMentions: [NativeArticleMention]

    public static let empty = NativeArticleRelations(outgoing: [], incoming: [], unlinkedMentions: [])

    public var isEmpty: Bool {
        outgoing.isEmpty && incoming.isEmpty && unlinkedMentions.isEmpty
    }

    public init(
        outgoing: [NativeArticleSummary],
        incoming: [NativeArticleSummary],
        unlinkedMentions: [NativeArticleMention] = []
    ) {
        self.outgoing = outgoing
        self.incoming = incoming
        self.unlinkedMentions = unlinkedMentions
    }
}

public struct NativeArticleMention: Equatable, Hashable, Identifiable {
    public let article: NativeArticleSummary
    public let count: Int
    public let snippet: String

    public var id: String { article.slug }

    public init(article: NativeArticleSummary, count: Int, snippet: String) {
        self.article = article
        self.count = max(1, count)
        self.snippet = snippet
    }
}

public struct NativeArticleGraph: Equatable {
    public let nodes: [NativeArticleSummary]
    public let edges: [NativeArticleGraphEdge]

    public static let empty = NativeArticleGraph(nodes: [], edges: [])

    public init(nodes: [NativeArticleSummary], edges: [NativeArticleGraphEdge]) {
        self.nodes = nodes
        self.edges = edges
    }
}

public struct NativeArticleGraphEdge: Hashable, Identifiable {
    public let sourceSlug: String
    public let targetSlug: String

    public var id: String { "\(sourceSlug)->\(targetSlug)" }

    public init(sourceSlug: String, targetSlug: String) {
        self.sourceSlug = sourceSlug
        self.targetSlug = targetSlug
    }
}

public enum NativeArticleLink {
    public struct Reference: Equatable, Hashable {
        public let target: String
        public let heading: String?
        public let label: String

        public init(rawValue: String) {
            let components = rawValue.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let destination = String(components[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let destinationComponents = destination.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            target = String(destinationComponents[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            if destinationComponents.count == 2 {
                let value = String(destinationComponents[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                heading = value.isEmpty ? nil : value
            } else {
                heading = nil
            }
            if components.count == 2 {
                let alias = String(components[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                label = alias.isEmpty ? target : alias
            } else if let heading {
                label = target.isEmpty ? "#\(heading)" : "\(target)#\(heading)"
            } else {
                label = target
            }
        }
    }

    public static func references(in text: String) -> [String] {
        parsedReferences(in: text).compactMap { $0.target.isEmpty ? nil : $0.target }
    }

    public static func parsedReferences(in text: String) -> [Reference] {
        let expression = try! NSRegularExpression(pattern: #"(?<!!)\[\[([^\[\]\r\n]+)\]\]"#)
        let searchRange = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: searchRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return Reference(rawValue: String(text[range]))
        }
    }

    public static func resolve(
        _ reference: String,
        in articles: [NativeArticleSummary]
    ) -> NativeArticleSummary? {
        let normalized = Reference(rawValue: reference).target
        guard !normalized.isEmpty else { return nil }

        if let direct = articles.first(where: {
            $0.title.caseInsensitiveCompare(normalized) == .orderedSame
        }) ?? articles.first(where: {
            $0.slug.caseInsensitiveCompare(normalized) == .orderedSame
        }) {
            return direct
        }

        let normalizedPath = normalized
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPathWithoutExtension = normalizedPath.lowercased().hasSuffix(".md")
            ? String(normalizedPath.dropLast(3)) : normalizedPath
        let pathMatches = articles.filter { article in
            let sourcePath = article.sourceRelativePath
                .replacingOccurrences(of: "\\", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let sourceWithoutExtension = sourcePath.lowercased().hasSuffix(".md")
                ? String(sourcePath.dropLast(3)) : sourcePath
            return sourcePath.caseInsensitiveCompare(normalizedPath) == .orderedSame
                || sourceWithoutExtension.caseInsensitiveCompare(normalizedPathWithoutExtension) == .orderedSame
        }
        if pathMatches.count == 1 { return pathMatches[0] }

        let aliasMatches = articles.filter { article in
            article.aliases.contains { $0.caseInsensitiveCompare(normalized) == .orderedSame }
        }
        return aliasMatches.count == 1 ? aliasMatches[0] : nil
    }

    public static func retargetingWikiLinks(
        in body: String,
        from oldSourcePath: String,
        to newSourcePath: String
    ) -> String {
        func normalized(_ path: String) -> String {
            path.replacingOccurrences(of: "\\", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "./"))
        }
        func withoutMarkdownExtension(_ path: String) -> String {
            path.lowercased().hasSuffix(".md") ? String(path.dropLast(3)) : path
        }

        let oldPath = normalized(oldSourcePath)
        let oldPathWithoutExtension = withoutMarkdownExtension(oldPath)
        let newPath = normalized(newSourcePath)
        let newPathWithoutExtension = withoutMarkdownExtension(newPath)
        let expression = try! NSRegularExpression(pattern: #"!?\[\[([^\[\]\r\n]+)\]\]"#)
        let output = NSMutableString(string: body)
        let matches = expression.matches(in: body, range: NSRange(body.startIndex..., in: body))

        for match in matches.reversed() {
            guard let innerRange = Range(match.range(at: 1), in: body) else { continue }
            let inner = String(body[innerRange])
            let aliasParts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let destination = String(aliasParts[0])
            let headingParts = destination.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let target = normalized(String(headingParts[0]))
            let targetWithoutExtension = withoutMarkdownExtension(target)
            guard target.caseInsensitiveCompare(oldPath) == .orderedSame
                    || targetWithoutExtension.caseInsensitiveCompare(oldPathWithoutExtension) == .orderedSame else {
                continue
            }

            let keepsExtension = target.lowercased().hasSuffix(".md")
            var replacement = keepsExtension ? newPath : newPathWithoutExtension
            if headingParts.count == 2 { replacement += "#\(headingParts[1])" }
            if aliasParts.count == 2 { replacement += "|\(aliasParts[1])" }
            output.replaceCharacters(in: match.range(at: 1), with: replacement)
        }
        return output as String
    }

    public static func destination(
        for rawReference: String,
        in articles: [NativeArticleSummary]
    ) -> NativeArticleLinkDestination? {
        let reference = Reference(rawValue: rawReference)
        guard !reference.target.isEmpty || reference.heading != nil else { return nil }
        return NativeArticleLinkDestination(
            target: reference.target,
            resolvedSlug: resolve(rawReference, in: articles)?.slug,
            heading: reference.heading,
            label: reference.label
        )
    }

    public static func linkingUnlinkedMentions(
        of rawTitle: String,
        to targetSlug: String,
        in body: String
    ) -> (body: String, count: Int) {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 2, !targetSlug.isEmpty else { return (body, 0) }

        let protectedExpression = try! NSRegularExpression(
            pattern: #"(?s)```.*?```|~~~.*?~~~|`[^`\r\n]*`|\[\[[^\[\]\r\n]+\]\]|\[[^\]\r\n]+\]\([^\)\r\n]+\)"#
        )
        let protectedMatches = protectedExpression.matches(
            in: body,
            range: NSRange(body.startIndex..., in: body)
        )
        var output = ""
        var cursor = body.startIndex
        var count = 0

        func isASCIIWord(_ character: Character) -> Bool {
            character.unicodeScalars.allSatisfy {
                ($0.value >= 48 && $0.value <= 57)
                    || ($0.value >= 65 && $0.value <= 90)
                    || ($0.value >= 97 && $0.value <= 122)
                    || $0.value == 95
            }
        }

        func replace(in segment: Substring) -> String {
            var remaining = String(segment)
            var result = ""
            while let range = remaining.range(
                of: title,
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            ) {
                let before = range.lowerBound > remaining.startIndex
                    ? remaining[remaining.index(before: range.lowerBound)] : nil
                let after = range.upperBound < remaining.endIndex ? remaining[range.upperBound] : nil
                let requiresBoundary = title.first.map(isASCIIWord) == true
                let hasValidStart = !requiresBoundary || before.map { !isASCIIWord($0) } != false
                let requiresEndBoundary = title.last.map(isASCIIWord) == true
                let hasValidEnd = !requiresEndBoundary || after.map { !isASCIIWord($0) } != false

                result += remaining[..<range.lowerBound]
                if hasValidStart && hasValidEnd {
                    let label = String(remaining[range])
                    result += "[[\(targetSlug)|\(label)]]"
                    count += 1
                    remaining = String(remaining[range.upperBound...])
                } else {
                    result.append(remaining[range.lowerBound])
                    remaining = String(remaining[remaining.index(after: range.lowerBound)...])
                }
            }
            return result + remaining
        }

        for match in protectedMatches {
            guard let range = Range(match.range, in: body) else { continue }
            output += replace(in: body[cursor..<range.lowerBound])
            output += body[range]
            cursor = range.upperBound
        }
        output += replace(in: body[cursor...])
        return (output, count)
    }
}

public struct NativeArticleLinkDestination: Equatable, Hashable {
    public let target: String
    public let resolvedSlug: String?
    public let heading: String?
    public let label: String

    public init(target: String, resolvedSlug: String?, heading: String?, label: String) {
        self.target = target
        self.resolvedSlug = resolvedSlug
        self.heading = heading
        self.label = label
    }
}

public enum NativeArticleAlias {
    public static func values(from properties: [String: NativeArticlePropertyValue]) -> [String] {
        normalized(properties.compactMap { key, value in
            ["alias", "aliases"].contains(key.lowercased()) ? value : nil
        }.flatMap { value in
            switch value.kind {
            case .list, .tags: return value.listValues
            default: return parse(value.value)
            }
        })
    }

    public static func normalized(_ aliases: [String]) -> [String] {
        var result: [String] = []
        for alias in aliases {
            let value = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  !result.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else {
                continue
            }
            result.append(value)
        }
        return Array(result.prefix(40))
    }

    private static func parse(_ rawValue: String) -> [String] {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let decoded = try? JSONDecoder().decode([String].self, from: Data(value.utf8)) {
            return decoded
        }
        if let decoded = try? JSONDecoder().decode(String.self, from: Data(value.utf8)) {
            return [decoded]
        }
        return value.components(separatedBy: .newlines).flatMap { line in
            line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: " -\t\"'")) }
        }
    }
}

public enum NativeArticleTag {
    public static func parse(_ input: String) -> [String] {
        var tags: [String] = []

        for segment in input.split(whereSeparator: { ",，\n".contains($0) }) {
            let value = String(segment).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            if value.contains(where: isTagMarker) {
                appendHashtags(from: value, to: &tags)
            } else {
                append(value, to: &tags)
            }
        }

        return Array(tags.prefix(12))
    }

    public static func normalized(_ tags: [String]) -> [String] {
        var normalized: [String] = []
        for tag in tags {
            for parsed in parse(tag) {
                append(parsed, to: &normalized)
            }
        }
        return Array(normalized.prefix(12))
    }

    private static func appendHashtags(from value: String, to tags: inout [String]) {
        let characters = Array(value)
        var index = 0

        while index < characters.count {
            guard isTagMarker(characters[index]) else {
                index += 1
                continue
            }

            var end = index + 1
            while end < characters.count,
                  !isTagMarker(characters[end]),
                  !characters[end].isWhitespace,
                  !isTagTerminator(characters[end]) {
                end += 1
            }
            append(String(characters[(index + 1)..<end]), to: &tags)
            index = max(end, index + 1)
        }
    }

    private static func append(_ value: String, to tags: inout [String]) {
        let tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty,
              !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else {
            return
        }
        tags.append(tag)
    }

    private static func isTagMarker(_ character: Character) -> Bool {
        character == "#" || character == "＃"
    }

    private static func isTagTerminator(_ character: Character) -> Bool {
        let terminators = CharacterSet(charactersIn: ",，.。!！?？;；:：、()（）[]【】{}<>《》\"“”'‘’")
        return character.unicodeScalars.allSatisfy(terminators.contains)
    }
}

public struct NativeActivityDay: Hashable, Identifiable {
    public let date: String
    public let count: Int

    public var id: String { date }
}

public struct NativeArticle: Codable, Hashable, Identifiable {
    public let banner: NativeBanner?
    public let body: String
    public let category: String
    public let excerpt: String
    public let media: [NativeMedia]
    public let pageViews: Int
    public let properties: [String: NativeArticlePropertyValue]
    public let slug: String
    public let sourceContentHash: String?
    public let sourceImportedAt: String?
    public let sourceRelativePath: String
    public let status: NativeArticleStatus
    public let tags: [String]
    public let title: String
    public let updatedAt: String
    public let publishedAt: String?
    public let wordCount: Int?

    public var id: String { slug }

    public init(
        banner: NativeBanner?,
        body: String,
        category: String,
        excerpt: String,
        media: [NativeMedia],
        slug: String,
        status: NativeArticleStatus,
        tags: [String],
        title: String,
        updatedAt: String,
        publishedAt: String?,
        wordCount: Int?,
        pageViews: Int = 0,
        properties: [String: NativeArticlePropertyValue] = [:],
        sourceRelativePath: String = "",
        sourceContentHash: String? = nil,
        sourceImportedAt: String? = nil
    ) {
        self.banner = banner
        self.body = body
        self.category = category
        self.excerpt = excerpt
        self.media = media
        self.pageViews = max(0, pageViews)
        self.properties = properties
        self.slug = slug
        self.sourceContentHash = sourceContentHash
        self.sourceImportedAt = sourceImportedAt
        self.sourceRelativePath = sourceRelativePath.isEmpty ? "\(slug).md" : sourceRelativePath
        self.status = status
        self.tags = NativeArticleTag.normalized(tags)
        self.title = title
        self.updatedAt = updatedAt
        self.publishedAt = publishedAt
        self.wordCount = wordCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        banner = try container.decodeIfPresent(NativeBanner.self, forKey: .banner)
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? "Uncategorized"
        excerpt = try container.decodeIfPresent(String.self, forKey: .excerpt) ?? ""
        media = try container.decodeIfPresent([NativeMedia].self, forKey: .media) ?? []
        pageViews = max(0, try container.decodeIfPresent(Int.self, forKey: .pageViews) ?? 0)
        properties = try container.decodeIfPresent([String: NativeArticlePropertyValue].self, forKey: .properties) ?? [:]
        slug = try container.decodeIfPresent(String.self, forKey: .slug) ?? ""
        sourceContentHash = try container.decodeIfPresent(String.self, forKey: .sourceContentHash)
        sourceImportedAt = try container.decodeIfPresent(String.self, forKey: .sourceImportedAt)
        sourceRelativePath = try container.decodeIfPresent(String.self, forKey: .sourceRelativePath) ?? "\(slug).md"
        status = try container.decodeIfPresent(NativeArticleStatus.self, forKey: .status) ?? .published
        tags = NativeArticleTag.normalized(try container.decodeIfPresent([String].self, forKey: .tags) ?? [])
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Untitled note"
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        publishedAt = try container.decodeIfPresent(String.self, forKey: .publishedAt)
        wordCount = try container.decodeIfPresent(Int.self, forKey: .wordCount)
    }

    public var sourceFolderPath: String {
        sourceRelativePath.split(separator: "/").dropLast().joined(separator: "/")
    }

    var summary: NativeArticleSummary {
        NativeArticleSummary(
            aliases: NativeArticleAlias.values(from: properties),
            banner: banner,
            category: category,
            excerpt: excerpt,
            pageViews: pageViews,
            properties: properties,
            publishedAt: publishedAt,
            slug: slug,
            sourceRelativePath: sourceRelativePath,
            status: status,
            tags: tags,
            title: title,
            updatedAt: updatedAt,
            wordCount: wordCount ?? NativeWritingMetrics.characterCount(of: body)
        )
    }
}

public struct NativeSaveArticle: Encodable {
    public let banner: NativeBanner?
    public let body: String
    public let category: String
    public let excerpt: String
    public let media: [NativeMedia]
    public let properties: [String: NativeArticlePropertyValue]
    public let slug: String
    public let status: NativeArticleStatus
    public let tags: [String]
    public let title: String
    public let expectedUpdatedAt: String?
    public let sourceRelativePath: String?

    public init(
        banner: NativeBanner?,
        body: String,
        category: String,
        excerpt: String,
        media: [NativeMedia],
        slug: String,
        status: NativeArticleStatus,
        tags: [String],
        title: String,
        expectedUpdatedAt: String?,
        properties: [String: NativeArticlePropertyValue] = [:],
        sourceRelativePath: String? = nil
    ) {
        self.banner = banner
        self.body = body
        self.category = category
        self.excerpt = excerpt
        self.media = media
        self.properties = properties
        self.slug = slug
        self.status = status
        self.tags = tags
        self.title = title
        self.expectedUpdatedAt = expectedUpdatedAt
        self.sourceRelativePath = sourceRelativePath
    }
}

public struct NativeArticleBodyUpdate: Sendable {
    public let slug: String
    public let body: String
    public let expectedUpdatedAt: String

    public init(slug: String, body: String, expectedUpdatedAt: String) {
        self.slug = slug
        self.body = body
        self.expectedUpdatedAt = expectedUpdatedAt
    }
}

public enum NativeArticleRevisionReason: String, Codable, Hashable {
    case autosave
    case savedVersion

    var label: String {
        switch self {
        case .autosave: return "自动保存"
        case .savedVersion: return "正式保存前"
        }
    }
}

public struct NativeArticleRevisionSnapshot: Codable, Hashable {
    public let banner: NativeBanner?
    public let body: String
    public let category: String
    public let excerpt: String
    public let media: [NativeMedia]
    public let properties: [String: NativeArticlePropertyValue]
    public let status: NativeArticleStatus
    public let tags: [String]
    public let title: String
    public let articleUpdatedAt: String?

    public init(
        banner: NativeBanner?,
        body: String,
        category: String,
        excerpt: String,
        media: [NativeMedia],
        status: NativeArticleStatus,
        tags: [String],
        title: String,
        articleUpdatedAt: String?,
        properties: [String: NativeArticlePropertyValue] = [:]
    ) {
        self.banner = banner
        self.body = body
        self.category = category
        self.excerpt = excerpt
        self.media = media
        self.properties = properties
        self.status = status
        self.tags = NativeArticleTag.normalized(tags)
        self.title = title
        self.articleUpdatedAt = articleUpdatedAt
    }

    public init(article: NativeArticle) {
        self.init(
            banner: article.banner,
            body: article.body,
            category: article.category,
            excerpt: article.excerpt,
            media: article.media,
            status: article.status,
            tags: article.tags,
            title: article.title,
            articleUpdatedAt: article.updatedAt,
            properties: article.properties
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        banner = try container.decodeIfPresent(NativeBanner.self, forKey: .banner)
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? "Notes"
        excerpt = try container.decodeIfPresent(String.self, forKey: .excerpt) ?? ""
        media = try container.decodeIfPresent([NativeMedia].self, forKey: .media) ?? []
        properties = try container.decodeIfPresent([String: NativeArticlePropertyValue].self, forKey: .properties) ?? [:]
        status = try container.decodeIfPresent(NativeArticleStatus.self, forKey: .status) ?? .draft
        tags = NativeArticleTag.normalized(try container.decodeIfPresent([String].self, forKey: .tags) ?? [])
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Untitled note"
        articleUpdatedAt = try container.decodeIfPresent(String.self, forKey: .articleUpdatedAt)
    }
}

public struct NativeArticleRevision: Hashable, Identifiable {
    public let id: Int
    public let syncID: String
    public let draftKey: String
    public let articleSlug: String?
    public let reason: NativeArticleRevisionReason
    public let snapshot: NativeArticleRevisionSnapshot
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: Int,
        syncID: String = UUID().uuidString.lowercased(),
        draftKey: String,
        articleSlug: String?,
        reason: NativeArticleRevisionReason,
        snapshot: NativeArticleRevisionSnapshot,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.syncID = syncID
        self.draftKey = draftKey
        self.articleSlug = articleSlug
        self.reason = reason
        self.snapshot = snapshot
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct NativeArticleLineDiff: Equatable {
    public let addedLineOffsets: Set<Int>
    public let removedLineOffsets: Set<Int>

    public init(previous: String, current: String) {
        let previousLines = previous.components(separatedBy: .newlines)
        let currentLines = current.components(separatedBy: .newlines)
        let difference = currentLines.difference(from: previousLines)
        var added: Set<Int> = []
        var removed: Set<Int> = []

        for change in difference {
            switch change {
            case .insert(let offset, _, _):
                added.insert(offset)
            case .remove(let offset, _, _):
                removed.insert(offset)
            }
        }

        addedLineOffsets = added
        removedLineOffsets = removed
    }

    public var isEmpty: Bool {
        addedLineOffsets.isEmpty && removedLineOffsets.isEmpty
    }
}

struct NativeUploadedMedia: Codable {
    let key: String
    let kind: String
    let name: String
    let size: Int
    let url: String
}

public enum NativeMomentTextColor: String, Codable, CaseIterable, Hashable, Identifiable {
    case red
    case orange
    case green
    case blue
    case purple
    case pink

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .red: return "红色"
        case .orange: return "橙色"
        case .green: return "绿色"
        case .blue: return "蓝色"
        case .purple: return "紫色"
        case .pink: return "粉色"
        }
    }
}

public struct NativeMomentTextRun: Codable, Hashable {
    public let text: String
    public let bold: Bool
    public let color: NativeMomentTextColor?

    public init(text: String, bold: Bool, color: NativeMomentTextColor?) {
        self.text = text
        self.bold = bold
        self.color = color
    }
}

public enum NativeMomentTag {
    public static func extract(from text: String) -> [String] {
        parsedTags(in: Array(text)).tags
    }

    public static func content(
        from text: String,
        textRuns: [NativeMomentTextRun]
    ) -> (text: String, tags: [String], runs: [NativeMomentTextRun]) {
        let characters = Array(text)
        let parsed = parsedTags(in: characters)
        guard !parsed.removedCharacterIndexes.isEmpty else {
            return (text, parsed.tags, resolvedRuns(text: text, runs: textRuns))
        }

        var retainedIndexes = characters.indices.filter { !parsed.removedCharacterIndexes.contains($0) }
        while let first = retainedIndexes.first, characters[first].isWhitespace {
            retainedIndexes.removeFirst()
        }
        while let last = retainedIndexes.last, characters[last].isWhitespace {
            retainedIndexes.removeLast()
        }

        let retainedIndexSet = Set(retainedIndexes)
        let body = String(retainedIndexes.map { characters[$0] })
        let sourceRuns = resolvedRuns(text: text, runs: textRuns)
        guard sourceRuns.map(\.text).joined() == text else {
            return body.isEmpty
                ? (body, parsed.tags, [])
                : (body, parsed.tags, [NativeMomentTextRun(text: body, bold: false, color: nil)])
        }

        var position = 0
        var bodyRuns: [NativeMomentTextRun] = []
        for run in sourceRuns {
            for character in run.text {
                if retainedIndexSet.contains(position) {
                    append(
                        character,
                        bold: run.bold,
                        color: run.color,
                        to: &bodyRuns
                    )
                }
                position += 1
            }
        }

        return bodyRuns.map(\.text).joined() == body
            ? (body, parsed.tags, bodyRuns)
            : (body, parsed.tags, body.isEmpty ? [] : [
                NativeMomentTextRun(text: body, bold: false, color: nil),
            ])
    }

    private static func parsedTags(in characters: [Character]) -> (tags: [String], removedCharacterIndexes: Set<Int>) {
        var tags: [String] = []
        var removedCharacterIndexes = Set<Int>()
        var index = 0

        func appendTag(_ tag: String) {
            guard !tag.isEmpty,
                  !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else {
                return
            }
            tags.append(tag)
        }

        while index < characters.count {
            guard isTagMarker(characters[index]) else {
                index += 1
                continue
            }

            var tagEnd = index + 1
            while tagEnd < characters.count,
                  !isTagMarker(characters[tagEnd]),
                  !characters[tagEnd].isWhitespace,
                  !isTagTerminator(characters[tagEnd]) {
                tagEnd += 1
            }

            let tag = String(characters[(index + 1)..<tagEnd])
            if !tag.isEmpty {
                appendTag(tag)
                var removalStart = index
                if removalStart > 0,
                   characters[removalStart - 1] == " " || characters[removalStart - 1] == "\t" {
                    removalStart -= 1
                }
                removedCharacterIndexes.formUnion(removalStart..<tagEnd)
            }
            index = max(tagEnd, index + 1)
        }
        return (tags, removedCharacterIndexes)
    }

    private static func resolvedRuns(text: String, runs: [NativeMomentTextRun]) -> [NativeMomentTextRun] {
        guard !text.isEmpty else { return [] }
        return runs.map(\.text).joined() == text && !runs.isEmpty
            ? runs
            : [NativeMomentTextRun(text: text, bold: false, color: nil)]
    }

    private static func append(
        _ character: Character,
        bold: Bool,
        color: NativeMomentTextColor?,
        to runs: inout [NativeMomentTextRun]
    ) {
        guard let previous = runs.last,
              previous.bold == bold,
              previous.color == color else {
            runs.append(NativeMomentTextRun(text: String(character), bold: bold, color: color))
            return
        }
        runs[runs.count - 1] = NativeMomentTextRun(
            text: previous.text + String(character),
            bold: bold,
            color: color
        )
    }

    private static func isTagMarker(_ character: Character) -> Bool {
        character == "#" || character == "＃"
    }

    private static func isTagTerminator(_ character: Character) -> Bool {
        let terminators = CharacterSet(charactersIn: ",，.。!！?？;；:：、()（）[]【】{}<>《》\"“”'‘’")
        return character.unicodeScalars.allSatisfy(terminators.contains)
    }
}

public struct NativeMoment: Codable, Hashable, Identifiable {
    public let createdAt: String
    public let id: String
    public let images: [NativeMedia]
    public let isFavorite: Bool
    public let tags: [String]
    public let text: String
    public let textRuns: [NativeMomentTextRun]
    public let updatedAt: String

    public init(
        createdAt: String,
        id: String,
        images: [NativeMedia],
        isFavorite: Bool = false,
        tags: [String] = [],
        text: String,
        textRuns: [NativeMomentTextRun],
        updatedAt: String
    ) {
        self.createdAt = createdAt
        self.id = id
        self.images = images
        self.isFavorite = isFavorite
        self.tags = tags
        self.text = text
        self.textRuns = textRuns
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        images = try container.decodeIfPresent([NativeMedia].self, forKey: .images) ?? []
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? NativeMomentTag.extract(from: text)
        textRuns = try container.decodeIfPresent([NativeMomentTextRun].self, forKey: .textRuns) ?? []
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? createdAt
    }

    public var displayContent: (text: String, runs: [NativeMomentTextRun]) {
        let content = NativeMomentTag.content(from: text, textRuns: textRuns)
        return (content.text, content.runs)
    }

    public func matches(search query: String) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return true }

        let searchableValues = [displayContent.text, tags.joined(separator: " "), createdAt] + searchableDateLabels
        return searchableValues.contains { value in
            value.range(
                of: normalizedQuery,
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            ) != nil
        }
    }

    private var searchableDateLabels: [String] {
        guard let date = NativeTimestamp.date(from: createdAt) else { return [] }
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return [date.formatted(date: .abbreviated, time: .omitted)]
        }
        return [
            String(format: "%04d-%02d-%02d", year, month, day),
            "\(year)-\(month)-\(day)",
            "\(year)/\(month)/\(day)",
            "\(year)年\(month)月\(day)日",
            date.formatted(date: .abbreviated, time: .omitted),
        ]
    }
}

public struct NativeMomentCursor: Codable, Equatable {
    public let createdAt: String
    public let id: String

    public init(createdAt: String, id: String) {
        self.createdAt = createdAt
        self.id = id
    }
}

public struct NativeMomentFilter: Equatable {
    public let searchText: String
    public let tags: [String]
    public let dateFilter: NativeMomentDateFilter
    public let favoritesOnly: Bool

    public static let all = NativeMomentFilter()

    public init(
        searchText: String = "",
        tags: [String] = [],
        dateFilter: NativeMomentDateFilter = .all,
        favoritesOnly: Bool = false
    ) {
        self.searchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tags = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.dateFilter = dateFilter
        self.favoritesOnly = favoritesOnly
    }

    public var isEmpty: Bool {
        searchText.isEmpty && tags.isEmpty && dateFilter == .all && !favoritesOnly
    }

    public func matches(_ moment: NativeMoment) -> Bool {
        let matchesTags = tags.isEmpty || moment.tags.contains { tag in
            tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
        return matchesTags
            && (!favoritesOnly || moment.isFavorite)
            && dateFilter.includes(timestamp: moment.createdAt)
            && moment.matches(search: searchText)
    }
}

public struct NativeMomentPage: Equatable {
    public let moments: [NativeMoment]
    public let nextCursor: NativeMomentCursor?

    public init(moments: [NativeMoment], nextCursor: NativeMomentCursor?) {
        self.moments = moments
        self.nextCursor = nextCursor
    }
}

public struct NativeMomentFacetRecord: Hashable {
    public let createdAt: String
    public let tags: [String]

    public init(createdAt: String, tags: [String]) {
        self.createdAt = createdAt
        self.tags = tags
    }
}

public enum NativeMomentDateFilter: Equatable {
    case all
    case today
    case thisWeek
    case month(year: Int, month: Int)
    case year(Int)

    var label: String {
        switch self {
        case .all: return "全部时间"
        case .today: return "今天"
        case .thisWeek: return "本周"
        case let .month(year, month): return "\(year)年\(month)月"
        case let .year(year): return "\(year)年"
        }
    }

    public func includes(
        timestamp: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard self != .all, let date = NativeTimestamp.date(from: timestamp) else {
            return self == .all
        }

        switch self {
        case .all:
            return true
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .thisWeek:
            return calendar.dateInterval(of: .weekOfYear, for: now)?.contains(date) ?? false
        case let .month(year, month):
            let components = calendar.dateComponents([.year, .month], from: date)
            return components.year == year && components.month == month
        case let .year(year):
            return calendar.component(.year, from: date) == year
        }
    }
}

public struct NativeMomentMonth: Hashable, Identifiable {
    public let year: Int
    public let month: Int

    public init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    public var id: String { "\(year)-\(month)" }
    var label: String { "\(year)年\(month)月" }
}

enum NativeTrashKind: String, Hashable, Identifiable {
    case article
    case moment

    var id: String { rawValue }

    var label: String {
        switch self {
        case .article: return "文章"
        case .moment: return "微博"
        }
    }

    var systemImage: String {
        switch self {
        case .article: return "doc.text.fill"
        case .moment: return "rectangle.3.group.fill"
        }
    }
}

struct NativeTrashItem: Hashable, Identifiable {
    let kind: NativeTrashKind
    let key: String
    let title: String
    let preview: String
    let deletedAt: String
    let expiresAt: String

    var id: String { "\(kind.rawValue):\(key)" }
}

struct NativeMomentDraft: Equatable {
    var text = ""
    var textRuns: [NativeMomentTextRun] = []
    var images: [NativeMedia] = []

    var isEmpty: Bool {
        NativeMomentTag.content(from: text, textRuns: textRuns).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty && images.isEmpty
    }
}

struct NativeEditorDraft: Equatable {
    var recoveryID = UUID().uuidString.lowercased()
    var slug = ""
    var title = ""
    var category = "Notes"
    var excerpt = ""
    var tags = ""
    var body = ""
    var banner: NativeBanner?
    var media: [NativeMedia] = []
    var properties: [String: NativeArticlePropertyValue] = [:]
    var status: NativeArticleStatus = .draft
    var updatedAt: String?

    var isNew: Bool { slug.isEmpty }
}

enum NativeSection: Hashable {
    case dashboard
    case articles
    case graph
    case moments
    case qAndA
    case reader
    case editor
    case trash
    case settings
}

enum NativeSearchPresentation: String, Identifiable {
    case globalSearch
    case quickOpen
    case commandPalette

    var id: String { rawValue }
}

enum NativeStoreError: LocalizedError {
    case conflict
    case readOnlyArticleSource
    case reservedSlug
    case slugTaken
    case invalidArticle
    case invalidArticleSelection
    case noLevel2Sections
    case invalidArticleMerge
    case invalidMoment
    case invalidQuestion
    case invalidAnswer
    case questionAnswerConflict
    case invalidComment
    case invalidUser
    case notFound
    case userAlreadyExists
    case fileSystem(String)

    var errorDescription: String? {
        switch self {
        case .conflict:
            return "这篇文章已在其他窗口中更新，请重新加载后再保存。"
        case .readOnlyArticleSource:
            return "当前 Markdown 目录以只读方式挂载；请切换为“直接编辑”后再修改文章。"
        case .reservedSlug:
            return "不能使用 inbox 或 moments 作为文章地址。"
        case .slugTaken:
            return "已有相同地址的文章，包括回收站中的文章。"
        case .invalidArticle:
            return "标题和正文不能为空。"
        case .invalidArticleSelection:
            return "请先在正文中选择要提取的非空文字。"
        case .noLevel2Sections:
            return "正文中没有可拆分的二级标题（##）。"
        case .invalidArticleMerge:
            return "不能将文章合并到自身，或合并目标已经不存在。"
        case .invalidMoment:
            return "微博需要文字或至少一张图片。"
        case .invalidQuestion:
            return "问题标题需要 1 到 200 个字符。"
        case .invalidAnswer:
            return "回答需要文字或至少一张图片，文字最多 10000 个字符。"
        case .questionAnswerConflict:
            return "这条回答已在其他窗口中更新，请重新载入后再编辑。"
        case .invalidComment:
            return "评论需要 1 到 2000 个字符。"
        case .invalidUser:
            return "请输入 1 到 40 个字符的用户名。"
        case .notFound:
            return "找不到这篇文章或本地媒体文件。"
        case .userAlreadyExists:
            return "该用户名已经存在。"
        case let .fileSystem(message):
            return "本地文件操作失败：\(message)"
        }
    }
}
