import Foundation

public struct NativeQuestion: Codable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let body: String
    public let tags: [String]
    public let createdAt: String
    public let updatedAt: String
    public let answerCount: Int

    public init(
        id: String,
        title: String,
        body: String,
        tags: [String],
        createdAt: String,
        updatedAt: String,
        answerCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.answerCount = answerCount
    }
}

public struct NativeQuestionAnswer: Codable, Hashable, Identifiable {
    public let id: String
    public let questionID: String
    public let body: String
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        questionID: String,
        body: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.questionID = questionID
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct NativeQuestionTagFacet: Hashable, Identifiable {
    public let tag: String
    public let count: Int

    public var id: String { NativeQuestionTag.identifier(tag) }

    public init(tag: String, count: Int) {
        self.tag = tag
        self.count = count
    }
}

public enum NativeQuestionTag {
    public static func parse(_ source: String) -> [String] {
        let normalizedSeparators = source
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "；", with: ",")
            .replacingOccurrences(of: ";", with: ",")
            .replacingOccurrences(of: "\n", with: ",")
        return normalized(normalizedSeparators.split(separator: ",").map(String.init))
    }

    public static func normalized(_ tags: [String]) -> [String] {
        var identifiers = Set<String>()
        var result: [String] = []
        for rawTag in tags {
            let tag = rawTag
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .drop(while: { $0 == "#" })
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { continue }
            let clipped = String(tag.prefix(30))
            guard identifiers.insert(identifier(clipped)).inserted else { continue }
            result.append(clipped)
            if result.count == 8 { break }
        }
        return result
    }

    static func identifier(_ tag: String) -> String {
        tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
