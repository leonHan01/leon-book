import SwiftUI

/// Article actions share the same icon renderer as navigation and other pages.
struct ArticleActionIcon: View {
    enum Kind {
        case newArticle, bookmark, workspace, inspector, more
        case writing, saved, document, tag, image, attachment, statistics, publish, template

        var symbol: String {
            switch self {
            case .newArticle: return "doc.badge.plus"
            case .bookmark: return "bookmark"
            case .workspace: return "rectangle.3.group"
            case .inspector: return "sidebar.right"
            case .more: return "ellipsis"
            case .writing: return "square.and.pencil"
            case .saved: return "checkmark.circle"
            case .document: return "doc.text"
            case .tag: return "tag"
            case .image: return "photo"
            case .attachment: return "paperclip"
            case .statistics: return "chart.bar"
            case .publish: return "paperplane"
            case .template: return "doc.on.doc"
            }
        }
    }

    let kind: Kind
    var size: CGFloat = NativeIcon.Size.toolbar

    static func menuImage(kind: Kind, size: CGFloat = NativeIcon.Size.toolbar) -> Image {
        NativeIcon.image(kind.symbol, size: size)
    }

    var body: some View {
        NativeIcon.image(kind.symbol, size: size)
            .accessibilityHidden(true)
    }
}
