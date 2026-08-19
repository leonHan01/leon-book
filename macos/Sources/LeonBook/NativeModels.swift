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
}

public struct NativeMoment: Codable, Hashable, Identifiable {
    public let createdAt: String
    public let id: String
    public let images: [NativeMedia]
    public let text: String
    public let textRuns: [NativeMomentTextRun]
    public let updatedAt: String

    public init(
        createdAt: String,
        id: String,
        images: [NativeMedia],
        text: String,
        textRuns: [NativeMomentTextRun],
        updatedAt: String
    ) {
        self.createdAt = createdAt
        self.id = id
        self.images = images
        self.text = text
        self.textRuns = textRuns
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        images = try container.decodeIfPresent([NativeMedia].self, forKey: .images) ?? []
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        textRuns = try container.decodeIfPresent([NativeMomentTextRun].self, forKey: .textRuns) ?? []
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? createdAt
    }
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
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty
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
