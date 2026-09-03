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
    public let images: [NativeMedia]
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        questionID: String,
        body: String,
        images: [NativeMedia] = [],
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.questionID = questionID
        self.body = body
        self.images = images
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        questionID = try container.decode(String.self, forKey: .questionID)
        body = try container.decode(String.self, forKey: .body)
        images = try container.decodeIfPresent([NativeMedia].self, forKey: .images) ?? []
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
    }
}

struct NativeQuestionAnswerDraft: Equatable {
    var body = ""
    var textRuns: [NativeMomentTextRun] = []
    var images: [NativeMedia] = []

    var isEmpty: Bool {
        body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty
    }
}

/// Cohesive value state for the question feature. Mutations that must keep the
/// selection, answer draft, and editing identity aligned live at this seam.
struct NativeQuestionSessionState: Equatable {
    var questions: [NativeQuestion] = []
    var totalCount = 0
    var tagFacets: [NativeQuestionTagFacet] = []
    var selectedQuestion: NativeQuestion?
    var answers: [NativeQuestionAnswer] = []
    var isLoadingAnswers = false
    var answerDraft = NativeQuestionAnswerDraft()
    var editingAnswerID: String?
    var editingAnswerUpdatedAt: String?
    var isPublishingQuestion = false
    var isPublishingAnswer = false
    var searchText = ""
    var selectedTag: String?

    var isFiltering: Bool {
        selectedTag != nil
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    mutating func applyReload(
        questions: [NativeQuestion],
        totalCount: Int,
        tagFacets: [NativeQuestionTagFacet],
        selectedQuestion: NativeQuestion?,
        answers: [NativeQuestionAnswer]
    ) -> [NativeMedia] {
        let changesSelection = selectedQuestion?.id != self.selectedQuestion?.id
        let discardedMedia = changesSelection ? discardAnswerDraft() : []
        self.questions = questions
        self.totalCount = totalCount
        self.tagFacets = tagFacets
        self.selectedQuestion = selectedQuestion
        self.answers = answers
        isLoadingAnswers = false
        return discardedMedia
    }

    mutating func beginSelecting(_ question: NativeQuestion) -> [NativeMedia] {
        let discardedMedia = discardAnswerDraft()
        selectedQuestion = question
        answers = []
        isLoadingAnswers = true
        return discardedMedia
    }

    mutating func beginEditing(_ answer: NativeQuestionAnswer) -> [NativeMedia] {
        let discardedMedia = answerDraft.images
        editingAnswerID = answer.id
        editingAnswerUpdatedAt = answer.updatedAt
        answerDraft = NativeQuestionAnswerDraft(
            body: answer.body,
            textRuns: answer.body.isEmpty ? [] : [
                NativeMomentTextRun(text: answer.body, bold: false, color: nil),
            ],
            images: answer.images
        )
        return discardedMedia
    }

    @discardableResult
    mutating func discardAnswerDraft() -> [NativeMedia] {
        let discardedMedia = answerDraft.images
        answerDraft = NativeQuestionAnswerDraft()
        editingAnswerID = nil
        editingAnswerUpdatedAt = nil
        return discardedMedia
    }

    mutating func reset() {
        self = NativeQuestionSessionState()
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
