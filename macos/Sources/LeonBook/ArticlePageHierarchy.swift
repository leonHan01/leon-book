import Foundation
import SwiftUI

enum NativeArticlePageHierarchy {
    struct Breadcrumb: Identifiable, Hashable {
        let title: String
        let folderPath: String

        var id: String { folderPath }
    }

    static func containerPath(for sourceRelativePath: String) -> String {
        parentFolderPath(for: sourceRelativePath)
    }

    static func parentFolderPath(for sourceRelativePath: String) -> String {
        NativeArticleDirectoryPolicy.displayFolderPath(
            normalize(sourceRelativePath).split(separator: "/").dropLast().joined(separator: "/")
        )
    }

    static func breadcrumbs(folderPath: String) -> [Breadcrumb] {
        var components: [String] = []
        return normalize(folderPath).split(separator: "/").map { component in
            components.append(String(component))
            return Breadcrumb(title: String(component), folderPath: components.joined(separator: "/"))
        }
    }

    private static func normalize(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

struct ArticlePathBreadcrumb: View {
    let sourceRelativePath: String?
    let draftFolderPath: String?
    let showsCreateArticle: Bool
    let onSelectRoot: () -> Void
    let onSelectFolder: (String) -> Void
    let onCreateArticle: (String) -> Void

    private var folderPath: String {
        if let sourceRelativePath {
            return NativeArticlePageHierarchy.parentFolderPath(for: sourceRelativePath)
        }
        return draftFolderPath ?? NativeArticleDirectoryPolicy.defaultFolderPath
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelectRoot) {
                Label("文章", systemImage: "book.closed")
            }
            .buttonStyle(.plain)

            ForEach(NativeArticlePageHierarchy.breadcrumbs(folderPath: folderPath)) { breadcrumb in
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button(breadcrumb.title) { onSelectFolder(breadcrumb.folderPath) }
                    .buttonStyle(.plain)
                    .lineLimit(1)
            }

            if showsCreateArticle {
                Spacer(minLength: 8)
                Button {
                    onCreateArticle(folderPath)
                } label: {
                    Label("在此目录新建文章", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.borderless)
                .help(Text("在 \(folderPath) 下新建文章"))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
