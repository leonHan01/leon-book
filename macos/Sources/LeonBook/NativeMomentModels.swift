import Foundation

// MARK: - Moments

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

public enum NativeMomentHighlightColor: String, Codable, CaseIterable, Hashable, Identifiable {
    case yellow, green, blue, pink, purple, orange

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .yellow: return "淡黄色"
        case .green: return "淡绿色"
        case .blue: return "淡蓝色"
        case .pink: return "淡粉色"
        case .purple: return "淡紫色"
        case .orange: return "淡橙色"
        }
    }

    var rgb: UInt32 {
        switch self {
        case .yellow: return 0xF4C34F
        case .green: return 0x6BCC9B
        case .blue: return 0x70A7EB
        case .pink: return 0xE898B3
        case .purple: return 0xB194DC
        case .orange: return 0xF0AF79
        }
    }
}

public struct NativeMomentTextRun: Codable, Hashable {
    public let text: String
    public let bold: Bool
    public let color: NativeMomentTextColor?
    public let highlighted: Bool?
    public let highlightColor: NativeMomentHighlightColor?
    public let headingLevel: Int?
    public let italic: Bool?
    public let strikethrough: Bool?
    public let code: Bool?

    public init(text: String, bold: Bool, color: NativeMomentTextColor?, highlighted: Bool? = nil,
                headingLevel: Int? = nil, italic: Bool? = nil, strikethrough: Bool? = nil, code: Bool? = nil,
                highlightColor: NativeMomentHighlightColor? = nil) {
        self.text = text
        self.bold = bold
        self.color = color
        self.highlighted = highlighted == true || highlightColor != nil ? true : nil
        // Yellow remains the legacy representation, avoiding rewrites of old runs.
        self.highlightColor = highlightColor == .yellow ? nil : highlightColor
        self.headingLevel = headingLevel.flatMap { (1...4).contains($0) ? $0 : nil }
        self.italic = italic == true ? true : nil
        self.strikethrough = strikethrough == true ? true : nil
        self.code = code == true ? true : nil
    }

    public var resolvedHighlightColor: NativeMomentHighlightColor? {
        highlighted == true ? (highlightColor ?? .yellow) : nil
    }

    func replacingText(_ text: String) -> Self {
        Self(text: text, bold: bold, color: color, highlighted: highlighted, headingLevel: headingLevel,
             italic: italic, strikethrough: strikethrough, code: code, highlightColor: highlightColor)
    }

    func hasSameStyle(as other: Self) -> Bool {
        replacingText("") == other.replacingText("")
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
                        style: run,
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
        style: NativeMomentTextRun,
        to runs: inout [NativeMomentTextRun]
    ) {
        guard let previous = runs.last,
              previous.hasSameStyle(as: style) else {
            runs.append(style.replacingText(String(character)))
            return
        }
        runs[runs.count - 1] = style.replacingText(previous.text + String(character))
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
    static let maximumTextLength = 5_000

    public var commentCount: Int
    public let createdAt: String
    public let id: String
    public let images: [NativeMedia]
    public let isFavorite: Bool
    public let isPrivate: Bool
    public let tags: [String]
    public let text: String
    public let textRuns: [NativeMomentTextRun]
    public let updatedAt: String

    public init(
        commentCount: Int = 0,
        createdAt: String,
        id: String,
        images: [NativeMedia],
        isFavorite: Bool = false,
        tags: [String] = [],
        text: String,
        textRuns: [NativeMomentTextRun],
        updatedAt: String,
        isPrivate: Bool = false
    ) {
        self.isPrivate = isPrivate
        self.commentCount = commentCount
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
        commentCount = try container.decodeIfPresent(Int.self, forKey: .commentCount) ?? 0
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        images = try container.decodeIfPresent([NativeMedia].self, forKey: .images) ?? []
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
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

    public var imageAttachments: [NativeMedia] {
        images.filter(\.isImage)
    }

    public var audioAttachments: [NativeMedia] {
        images.filter(\.isAudio)
    }

    public var videoAttachments: [NativeMedia] {
        images.filter(\.isVideo)
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
