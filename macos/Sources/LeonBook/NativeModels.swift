import Foundation

public enum NativeWritingMetrics {
    public static func characterCount(of body: String) -> Int {
        body.trimmingCharacters(in: .whitespacesAndNewlines).count
    }
}

public enum NativeTimestamp {
    public static func date(from timestamp: String) -> Date? {
        let standardFormatter = ISO8601DateFormatter()
        if let date = standardFormatter.date(from: timestamp) { return date }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions.insert(.withFractionalSeconds)
        return fractionalFormatter.date(from: timestamp)
    }

    public static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.string(from: date)
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
    public let publishedAt: String?
    public let slug: String
    public let status: NativeArticleStatus
    public let tags: [String]
    public let title: String
    public let updatedAt: String
    public let wordCount: Int

    public var id: String { slug }
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
        wordCount: Int?
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
        slug = try container.decodeIfPresent(String.self, forKey: .slug) ?? ""
        status = try container.decodeIfPresent(NativeArticleStatus.self, forKey: .status) ?? .published
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
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

struct NativeMomentMonth: Hashable, Identifiable {
    let year: Int
    let month: Int

    var id: String { "\(year)-\(month)" }
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
    case moments
    case reader
    case editor
    case trash
    case settings
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
