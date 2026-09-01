import Foundation
import SwiftUI

enum NativeArticlePageHierarchy {
    struct Breadcrumb: Identifiable, Hashable {
        let title: String
        let folderPath: String

        var id: String { folderPath }
    }

    static func containerPath(for sourceRelativePath: String) -> String {
        let normalized = normalize(sourceRelativePath)
        let components = normalized.split(separator: "/").map(String.init)
        guard let filename = components.last else { return "" }
        let folder = components.dropLast().joined(separator: "/")
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        if stem.caseInsensitiveCompare("index") == .orderedSame { return folder }
        return [folder, stem].filter { !$0.isEmpty }.joined(separator: "/")
    }

    static func parentFolderPath(for sourceRelativePath: String) -> String {
        normalize(sourceRelativePath).split(separator: "/").dropLast().joined(separator: "/")
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
    let showsCreateSubpage: Bool
    let onSelectRoot: () -> Void
    let onSelectFolder: (String) -> Void
    let onCreateSubpage: (String) -> Void

    private var folderPath: String {
        if let sourceRelativePath {
            return NativeArticlePageHierarchy.parentFolderPath(for: sourceRelativePath)
        }
        return draftFolderPath ?? ""
    }

    private var containerPath: String {
        sourceRelativePath.map(NativeArticlePageHierarchy.containerPath(for:))
            ?? draftFolderPath
            ?? ""
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelectRoot) {
                Label("页面", systemImage: "book.closed")
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

            if showsCreateSubpage {
                Spacer(minLength: 8)
                Button {
                    onCreateSubpage(containerPath)
                } label: {
                    Label("新建子页面", systemImage: "plus.square.on.square")
                }
                .buttonStyle(.borderless)
                .help(containerPath.isEmpty ? "在资料库根目录新建页面" : "在 \(containerPath) 下新建子页面")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
