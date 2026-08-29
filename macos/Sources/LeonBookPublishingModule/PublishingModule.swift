import Foundation
import LeonBookModuleKit

public enum PublishingFirstPartyModule: FirstPartyModule {
    public static let id = FirstPartyModuleID(rawValue: "publishing")
    public static let descriptor = FirstPartyModuleDescriptor(
        id: id,
        name: "发布",
        summary: "文章与动态的发布校验和发布命令。",
        systemImage: "paperplane",
        permissions: [.contentRead, .contentWrite, .contentPublish],
        commands: [
            .init(
                id: "article.publish",
                title: "发布当前文章",
                detail: "保存并发布当前编辑器内容",
                keywords: "publish post",
                systemImage: "paperplane.fill",
                availability: .articleEditorAndIdle,
                requiredPermissions: [.contentRead, .contentWrite, .contentPublish]
            ),
        ],
        eventNames: ["publishing.requested", "publishing.completed", "publishing.rejected"]
    )
}

public enum FirstPartyPublicationKind: String, Codable, Sendable {
    case article
    case moment
    case question
    case answer
}

public struct FirstPartyPublicationContent: Equatable, Sendable {
    public let kind: FirstPartyPublicationKind
    public let title: String
    public let body: String
    public let attachmentCount: Int

    public init(
        kind: FirstPartyPublicationKind,
        title: String = "",
        body: String,
        attachmentCount: Int = 0
    ) {
        self.kind = kind
        self.title = title
        self.body = body
        self.attachmentCount = attachmentCount
    }
}

public enum FirstPartyPublicationValidationError: LocalizedError, Equatable {
    case missingTitle
    case missingBody
    case emptyMoment

    public var errorDescription: String? {
        switch self {
        case .missingTitle: return "标题不能为空。"
        case .missingBody: return "正文不能为空。"
        case .emptyMoment: return "动态需要文字或至少一个附件。"
        }
    }
}

/// Central publication policy shared by UI commands and storage adapters.
public enum FirstPartyPublicationPolicy {
    public static func validate(_ content: FirstPartyPublicationContent) throws {
        let title = content.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = content.body.trimmingCharacters(in: .whitespacesAndNewlines)
        switch content.kind {
        case .article, .question:
            guard !title.isEmpty else { throw FirstPartyPublicationValidationError.missingTitle }
            guard !body.isEmpty else { throw FirstPartyPublicationValidationError.missingBody }
        case .answer:
            guard !body.isEmpty else { throw FirstPartyPublicationValidationError.missingBody }
        case .moment:
            guard !body.isEmpty || content.attachmentCount > 0 else {
                throw FirstPartyPublicationValidationError.emptyMoment
            }
        }
    }
}
