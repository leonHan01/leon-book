import Foundation

struct NativeUser: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let createdAt: String

    static let leon = NativeUser(id: "leon", name: "leon", createdAt: "")

    init(id: String, name: String, createdAt: String) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

enum NativeArticleStatus: String, Codable, CaseIterable, Identifiable {
    case draft
    case published

    var id: String { rawValue }

    var label: String {
        switch self {
        case .draft: return "草稿"
        case .published: return "已发布"
        }
    }
}

struct NativeMedia: Codable, Hashable, Identifiable {
    let kind: String
    let name: String
    let size: Int
    let url: String

    var id: String { url }

    var isVideo: Bool { kind == "video" }

    init(kind: String, name: String, size: Int, url: String) {
        self.kind = kind
        self.name = name
        self.size = size
        self.url = url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "image"
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "media"
        size = try container.decodeIfPresent(Int.self, forKey: .size) ?? 0
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
    }
}

struct NativeBanner: Codable, Hashable {
    let alt: String
    let name: String
    let size: Int
    let url: String
}

struct NativeArticleSummary: Codable, Hashable, Identifiable {
    let banner: NativeBanner?
    let category: String
    let excerpt: String
    let publishedAt: String?
    let slug: String
    let status: NativeArticleStatus
    let tags: [String]
    let title: String
    let updatedAt: String
    let wordCount: Int

    var id: String { slug }
}

struct NativeActivityDay: Hashable, Identifiable {
    let date: String
    let count: Int

    var id: String { date }
}

struct NativeArticle: Codable, Hashable, Identifiable {
    let banner: NativeBanner?
    let body: String
    let category: String
    let excerpt: String
    let media: [NativeMedia]
    let slug: String
    let status: NativeArticleStatus
    let tags: [String]
    let title: String
    let updatedAt: String
    let publishedAt: String?
    let wordCount: Int?

    var id: String { slug }

    init(
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

    init(from decoder: Decoder) throws {
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

struct NativeSaveArticle: Encodable {
    let banner: NativeBanner?
    let body: String
    let category: String
    let excerpt: String
    let media: [NativeMedia]
    let slug: String
    let status: NativeArticleStatus
    let tags: [String]
    let title: String
    let expectedUpdatedAt: String?
}

struct NativeUploadedMedia: Codable {
    let key: String
    let kind: String
    let name: String
    let size: Int
    let url: String
}

enum NativeMomentTextColor: String, Codable, CaseIterable, Hashable, Identifiable {
    case red
    case orange
    case green
    case blue
    case purple
    case pink

    var id: String { rawValue }

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

struct NativeMomentTextRun: Codable, Hashable {
    let text: String
    let bold: Bool
    let color: NativeMomentTextColor?
}

struct NativeMoment: Codable, Hashable, Identifiable {
    let createdAt: String
    let id: String
    let images: [NativeMedia]
    let text: String
    let textRuns: [NativeMomentTextRun]
    let updatedAt: String

    init(
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        images = try container.decodeIfPresent([NativeMedia].self, forKey: .images) ?? []
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        textRuns = try container.decodeIfPresent([NativeMomentTextRun].self, forKey: .textRuns) ?? []
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? createdAt
    }
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
    case settings
}

enum NativeStoreError: LocalizedError {
    case conflict
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
