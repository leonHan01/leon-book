import Foundation

// MARK: - View state

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
    case canvas
    case photos
    case mediaLibrary
    case moments
    case qAndA
    case todos
    case reader
    case editor
    case trash
    case settings

    var showsArticleDirectory: Bool {
        switch self {
        case .articles, .reader, .editor: return true
        default: return false
        }
    }

    var hasNavigationSidebar: Bool {
        showsArticleDirectory || self == .mediaLibrary
    }
}

enum NativeSearchPresentation: String, Identifiable {
    case globalSearch
    case quickOpen
    case commandPalette

    var id: String { rawValue }
}
