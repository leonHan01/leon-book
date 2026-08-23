import Foundation

public enum NativeWritingMetrics {
    public static func characterCount(of body: String) -> Int {
        body.trimmingCharacters(in: .whitespacesAndNewlines).count
    }
}

public enum NativeTimestamp {
    private static let formatterLock = NSLock()
    private static let standardFormatter = ISO8601DateFormatter()
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter
    }()

    public static func date(from timestamp: String) -> Date? {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        return standardFormatter.date(from: timestamp)
            ?? fractionalFormatter.date(from: timestamp)
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

    public var isEmpty: Bool {
        textTerms.isEmpty && tags.isEmpty && status == nil && types.isEmpty
            && after == nil && before == nil
    }

    public init(_ rawValue: String, calendar: Calendar = .current) {
        self.rawValue = rawValue
        var textTerms: [String] = []
        var tags: [String] = []
        var status: NativeArticleStatus?
        var types = Set<NativeSearchDocumentType>()
        var after: Date?
        var before: Date?

        for token in Self.tokens(in: rawValue) {
            guard let separator = token.firstIndex(of: ":") else {
                if !token.isEmpty { textTerms.append(token) }
                continue
            }

            let key = token[..<separator].lowercased()
            let value = String(token[token.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                textTerms.append(token)
                continue
            }

            switch key {
            case "tag", "标签":
                let normalized = value.trimmingCharacters(in: CharacterSet(charactersIn: "#＃"))
                if !normalized.isEmpty { tags.append(normalized) }
            case "status", "状态":
                switch value.lowercased() {
                case "draft", "草稿": status = .draft
                case "published", "已发布", "发布": status = .published
                default: textTerms.append(token)
                }
            case "type", "类型":
                switch value.lowercased() {
                case "article", "articles", "文章": types.insert(.article)
                case "moment", "moments", "微博", "动态": types.insert(.moment)
                default: textTerms.append(token)
                }
            case "after", "起始":
                if let date = Self.day(value, calendar: calendar) {
                    after = calendar.startOfDay(for: date)
                } else {
                    textTerms.append(token)
                }
            case "before", "截止":
                if let date = Self.day(value, calendar: calendar) {
                    before = calendar.startOfDay(for: date)
                } else {
                    textTerms.append(token)
                }
            case "date", "日期":
                if let date = Self.day(value, calendar: calendar) {
                    let start = calendar.startOfDay(for: date)
                    after = start
                    before = calendar.date(byAdding: .day, value: 1, to: start)
                } else {
                    textTerms.append(token)
                }
            default:
                textTerms.append(token)
            }
        }

        self.textTerms = textTerms
        self.tags = tags
        self.status = status
        self.types = types
        self.after = after
        self.before = before
    }

    private static func tokens(in source: String) -> [String] {
        var tokens: [String] = []
        var token = ""
        var quote: Character?
        var isEscaping = false

        func finishToken() {
            if !token.isEmpty { tokens.append(token) }
            token = ""
        }

        for character in source {
            if isEscaping {
                token.append(character)
                isEscaping = false
            } else if character == "\\" {
                isEscaping = true
            } else if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    token.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                finishToken()
            } else {
                token.append(character)
            }
        }
        if isEscaping { token.append("\\") }
        finishToken()
        return tokens
    }

    private static func day(_ value: String, calendar: Calendar) -> Date? {
        let components = value.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3,
              components[0] >= 1,
              (1...12).contains(components[1]),
              (1...31).contains(components[2]) else {
            return nil
        }
        return calendar.date(from: DateComponents(
            year: components[0],
            month: components[1],
            day: components[2]
        ))
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
    public let banner: NativeBanner?
    public let category: String
    public let excerpt: String
    public var pageViews: Int
    public let publishedAt: String?
    public let slug: String
    public let status: NativeArticleStatus
    public let tags: [String]
    public let title: String
    public let updatedAt: String
    public let wordCount: Int

    public var id: String { slug }

    public init(
        banner: NativeBanner?,
        category: String,
        excerpt: String,
        pageViews: Int = 0,
        publishedAt: String?,
        slug: String,
        status: NativeArticleStatus,
        tags: [String],
        title: String,
        updatedAt: String,
        wordCount: Int
    ) {
        self.banner = banner
        self.category = category
        self.excerpt = excerpt
        self.pageViews = max(0, pageViews)
        self.publishedAt = publishedAt
        self.slug = slug
        self.status = status
        self.tags = NativeArticleTag.normalized(tags)
        self.title = title
        self.updatedAt = updatedAt
        self.wordCount = wordCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            banner: try container.decodeIfPresent(NativeBanner.self, forKey: .banner),
            category: try container.decodeIfPresent(String.self, forKey: .category) ?? "Uncategorized",
            excerpt: try container.decodeIfPresent(String.self, forKey: .excerpt) ?? "",
            pageViews: try container.decodeIfPresent(Int.self, forKey: .pageViews) ?? 0,
            publishedAt: try container.decodeIfPresent(String.self, forKey: .publishedAt),
            slug: try container.decodeIfPresent(String.self, forKey: .slug) ?? "",
            status: try container.decodeIfPresent(NativeArticleStatus.self, forKey: .status) ?? .published,
            tags: try container.decodeIfPresent([String].self, forKey: .tags) ?? [],
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? "Untitled note",
            updatedAt: try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? "",
            wordCount: try container.decodeIfPresent(Int.self, forKey: .wordCount) ?? 0
        )
    }
}

public struct NativeArticleRelations: Equatable {
    public let outgoing: [NativeArticleSummary]
    public let incoming: [NativeArticleSummary]

    public static let empty = NativeArticleRelations(outgoing: [], incoming: [])

    public var isEmpty: Bool {
        outgoing.isEmpty && incoming.isEmpty
    }

    public init(outgoing: [NativeArticleSummary], incoming: [NativeArticleSummary]) {
        self.outgoing = outgoing
        self.incoming = incoming
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
    public static func references(in text: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"\[\[([^\[\]\r\n]+)\]\]"#)
        let searchRange = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: searchRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            let reference = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            return reference.isEmpty ? nil : reference
        }
    }

    public static func resolve(
        _ reference: String,
        in articles: [NativeArticleSummary]
    ) -> NativeArticleSummary? {
        let normalized = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        return articles.first {
            $0.title.caseInsensitiveCompare(normalized) == .orderedSame
        } ?? articles.first {
            $0.slug.caseInsensitiveCompare(normalized) == .orderedSame
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
    public let slug: String
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
        pageViews: Int = 0
    ) {
        self.banner = banner
        self.body = body
        self.category = category
        self.excerpt = excerpt
        self.media = media
        self.pageViews = max(0, pageViews)
        self.slug = slug
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
        slug = try container.decodeIfPresent(String.self, forKey: .slug) ?? ""
        status = try container.decodeIfPresent(NativeArticleStatus.self, forKey: .status) ?? .published
        tags = NativeArticleTag.normalized(try container.decodeIfPresent([String].self, forKey: .tags) ?? [])
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Untitled note"
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        publishedAt = try container.decodeIfPresent(String.self, forKey: .publishedAt)
        wordCount = try container.decodeIfPresent(Int.self, forKey: .wordCount)
    }
}

public struct NativeSaveArticle: Encodable {
    public let banner: NativeBanner?
    public let body: String
    public let category: String
    public let excerpt: String
    public let media: [NativeMedia]
    public let slug: String
    public let status: NativeArticleStatus
    public let tags: [String]
    public let title: String
    public let expectedUpdatedAt: String?

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
        expectedUpdatedAt: String?
    ) {
        self.banner = banner
        self.body = body
        self.category = category
        self.excerpt = excerpt
        self.media = media
        self.slug = slug
        self.status = status
        self.tags = tags
        self.title = title
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
        articleUpdatedAt: String?
    ) {
        self.banner = banner
        self.body = body
        self.category = category
        self.excerpt = excerpt
        self.media = media
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
            articleUpdatedAt: article.updatedAt
        )
    }
}

public struct NativeArticleRevision: Hashable, Identifiable {
    public let id: Int
    public let draftKey: String
    public let articleSlug: String?
    public let reason: NativeArticleRevisionReason
    public let snapshot: NativeArticleRevisionSnapshot
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: Int,
        draftKey: String,
        articleSlug: String?,
        reason: NativeArticleRevisionReason,
        snapshot: NativeArticleRevisionSnapshot,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
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
    public let pageViews: Int
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
        updatedAt: String,
        pageViews: Int = 0
    ) {
        self.createdAt = createdAt
        self.id = id
        self.images = images
        self.isFavorite = isFavorite
        self.pageViews = max(0, pageViews)
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
        pageViews = max(0, try container.decodeIfPresent(Int.self, forKey: .pageViews) ?? 0)
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
    var status: NativeArticleStatus = .draft
    var updatedAt: String?

    var isNew: Bool { slug.isEmpty }
}

enum NativeSection: Hashable {
    case dashboard
    case articles
    case graph
    case moments
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

enum NativeCommandID: String, CaseIterable, Identifiable {
    case globalSearch
    case quickOpen
    case newArticle
    case dashboard
    case articles
    case graph
    case moments
    case trash
    case settings
    case reload

    var id: String { rawValue }
}

enum NativeStoreError: LocalizedError {
    case conflict
    case reservedSlug
    case slugTaken
    case invalidArticle
    case invalidMoment
    case invalidUser
    case notFound
    case userAlreadyExists
    case fileSystem(String)

    var errorDescription: String? {
        switch self {
        case .conflict:
            return "这篇文章已在其他窗口中更新，请重新加载后再保存。"
        case .reservedSlug:
            return "不能使用 inbox 或 moments 作为文章地址。"
        case .slugTaken:
            return "已有相同地址的文章，包括回收站中的文章。"
        case .invalidArticle:
            return "标题和正文不能为空。"
        case .invalidMoment:
            return "微博需要文字或至少一张图片。"
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
