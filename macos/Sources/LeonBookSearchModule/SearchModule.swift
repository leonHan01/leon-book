import Foundation
import LeonBookModuleKit

public enum SearchFirstPartyModule: FirstPartyModule {
    public static let id = FirstPartyModuleID(rawValue: "search")
    public static let descriptor = FirstPartyModuleDescriptor(
        id: id,
        name: "搜索",
        summary: "全文搜索、查询语法与快速打开。",
        systemImage: "magnifyingglass",
        permissions: [.contentRead],
        commands: [
            .init(
                id: "search.global",
                title: "全文搜索",
                detail: "搜索文章正文、摘要和微博",
                keywords: "查找 find search",
                systemImage: "magnifyingglass",
                defaultShortcut: .init(key: "f", modifiers: [.command, .shift]),
                requiredPermissions: [.contentRead]
            ),
            .init(
                id: "search.quick-open",
                title: "快速打开文章",
                detail: "按标题或正文切换文章",
                keywords: "open switch article",
                systemImage: "doc.text.magnifyingglass",
                defaultShortcut: .init(key: "o", modifiers: [.command]),
                requiredPermissions: [.contentRead]
            ),
        ],
        eventNames: ["search.requested", "search.completed"]
    )
}

public struct FirstPartySearchPropertyFilter: Equatable, Hashable, Sendable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public struct FirstPartySearchQuery: Equatable, Sendable {
    public let textTerms: [String]
    public let tags: [String]
    public let status: String?
    public let types: Set<String>
    public let after: Date?
    public let before: Date?
    public let propertyFilters: [FirstPartySearchPropertyFilter]
}

/// Owns the complete user-facing query grammar. The app adapter maps strings
/// to its domain enums without duplicating tokenization or date semantics.
public enum FirstPartySearchQueryParser {
    public static func parse(
        _ rawValue: String,
        calendar: Calendar = .current,
        isValidPropertyKey: (String) -> Bool = { !$0.isEmpty }
    ) -> FirstPartySearchQuery {
        var textTerms: [String] = []
        var tags: [String] = []
        var status: String?
        var types = Set<String>()
        var after: Date?
        var before: Date?
        var propertyFilters: [FirstPartySearchPropertyFilter] = []

        for token in tokens(in: rawValue) {
            if token.hasPrefix("["), token.hasSuffix("]") {
                let expression = String(token.dropFirst().dropLast())
                if let separator = expression.firstIndex(of: ":") {
                    let key = String(expression[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = String(expression[expression.index(after: separator)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if isValidPropertyKey(key), !value.isEmpty {
                        propertyFilters.append(.init(key: key, value: value))
                        continue
                    }
                }
            }
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
                case "draft", "草稿": status = "draft"
                case "published", "已发布", "发布": status = "published"
                default: textTerms.append(token)
                }
            case "type", "类型":
                switch value.lowercased() {
                case "article", "articles", "文章": types.insert("article")
                case "moment", "moments", "微博", "动态": types.insert("moment")
                default: textTerms.append(token)
                }
            case "after", "起始":
                if let date = day(value, calendar: calendar) {
                    after = calendar.startOfDay(for: date)
                } else {
                    textTerms.append(token)
                }
            case "before", "截止":
                if let date = day(value, calendar: calendar) {
                    before = calendar.startOfDay(for: date)
                } else {
                    textTerms.append(token)
                }
            case "date", "日期":
                if let date = day(value, calendar: calendar) {
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

        return FirstPartySearchQuery(
            textTerms: textTerms,
            tags: tags,
            status: status,
            types: types,
            after: after,
            before: before,
            propertyFilters: propertyFilters
        )
    }

    private static func tokens(in source: String) -> [String] {
        var tokens: [String] = []
        var token = ""
        var quote: Character?
        var isEscaping = false
        var bracketDepth = 0

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
                if character == activeQuote { quote = nil } else { token.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "[" {
                bracketDepth += 1
                token.append(character)
            } else if character == "]", bracketDepth > 0 {
                bracketDepth -= 1
                token.append(character)
            } else if character.isWhitespace, bracketDepth == 0 {
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
        let segments = value.split(separator: "-", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let year = Int(segments[0]),
              let month = Int(segments[1]),
              let day = Int(segments[2]),
              year >= 1,
              (1...12).contains(month),
              (1...31).contains(day),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return nil
        }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == year, resolved.month == month, resolved.day == day else { return nil }
        return date
    }
}
