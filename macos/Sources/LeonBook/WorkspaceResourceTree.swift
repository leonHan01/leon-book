import Foundation

enum NativeWorkspaceResourceStorage: String, Hashable, Sendable {
    case markdownSource
    case managedMedia
}

struct NativeWorkspaceResourceRecord: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case folder
        case file
    }

    let kind: Kind
    let storage: NativeWorkspaceResourceStorage
    let relativePath: String
    let placementFolderPath: String
    let absolutePath: String
    let ownerArticleSlug: String?
    let displayName: String?

    init(
        kind: Kind,
        storage: NativeWorkspaceResourceStorage,
        relativePath: String,
        placementFolderPath: String,
        absolutePath: String,
        ownerArticleSlug: String? = nil,
        displayName: String? = nil
    ) {
        self.kind = kind
        self.storage = storage
        self.relativePath = relativePath
        self.placementFolderPath = placementFolderPath
        self.absolutePath = absolutePath
        self.ownerArticleSlug = ownerArticleSlug
        self.displayName = displayName
    }
}

struct NativeWorkspaceResourceMove: Hashable, Sendable {
    let sourceRelativePath: String
    let destinationRelativePath: String
}

struct NativeWorkspaceResourceNode: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case folder
        case article
        case attachment
    }

    let id: String
    let kind: Kind
    let storage: NativeWorkspaceResourceStorage
    let name: String
    let relativePath: String
    let sourceRelativePath: String?
    let absolutePath: String
    let articleSlug: String?
    let articleTitle: String?
    var children: [NativeWorkspaceResourceNode]
    var articleCount: Int

    var isFolder: Bool { kind == .folder }
    var canMutateSource: Bool { storage == .markdownSource && sourceRelativePath != nil }

    var systemImage: String {
        switch kind {
        case .folder:
            return "folder.fill"
        case .article:
            return "doc.text"
        case .attachment:
            switch URL(fileURLWithPath: name).pathExtension.lowercased() {
            case "png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "svg":
                return "photo"
            case "mov", "mp4", "m4v", "webm":
                return "film"
            case "mp3", "m4a", "aac", "wav", "aiff", "flac", "ogg":
                return "waveform"
            case "pdf":
                return "doc.richtext"
            case "base":
                return "tablecells"
            default:
                return "doc"
            }
        }
    }

    func flattened() -> [NativeWorkspaceResourceNode] {
        [self] + children.flatMap { $0.flattened() }
    }
}

enum NativeWorkspaceResourceTree {
    private final class FolderBox {
        let name: String
        let path: String
        var absolutePath: String
        var childFolders: [String: FolderBox] = [:]
        var leaves: [NativeWorkspaceResourceNode] = []

        init(name: String, path: String, absolutePath: String = "") {
            self.name = name
            self.path = path
            self.absolutePath = absolutePath
        }
    }

    static func build(
        articles: [NativeArticleSummary],
        records: [NativeWorkspaceResourceRecord]
    ) -> [NativeWorkspaceResourceNode] {
        let root = FolderBox(name: "", path: "")
        let articleByPath = articles.reduce(into: [String: NativeArticleSummary]()) {
            $0[normalized($1.sourceRelativePath)] = $1
        }
        var includedArticleSlugs = Set<String>()

        func folder(_ rawPath: String) -> FolderBox {
            let path = normalized(rawPath)
            guard !path.isEmpty else { return root }
            var current = root
            var components: [String] = []
            for component in path.split(separator: "/").map(String.init) {
                components.append(component)
                let childPath = components.joined(separator: "/")
                if let existing = current.childFolders[component] {
                    current = existing
                } else {
                    let created = FolderBox(name: component, path: childPath)
                    current.childFolders[component] = created
                    current = created
                }
            }
            return current
        }

        for record in records where record.kind == .folder && record.storage == .markdownSource {
            let target = folder(record.relativePath)
            target.absolutePath = record.absolutePath
        }

        for record in records where record.kind == .file {
            let targetFolder = folder(record.placementFolderPath)
            let filename = URL(fileURLWithPath: record.relativePath).lastPathComponent
            let displayName = record.displayName ?? filename
            let normalizedPath = normalized(record.relativePath)
            if record.storage == .markdownSource,
               filename.lowercased().hasSuffix(".md"),
               let article = articleByPath[normalizedPath] {
                includedArticleSlugs.insert(article.slug)
                targetFolder.leaves.append(articleNode(article, absolutePath: record.absolutePath))
            } else {
                let logicalPath = joined(record.placementFolderPath, displayName)
                targetFolder.leaves.append(NativeWorkspaceResourceNode(
                    id: record.storage == .markdownSource
                        ? "workspace-source:\(normalizedPath)"
                        : "workspace-media:\(record.absolutePath)",
                    kind: .attachment,
                    storage: record.storage,
                    name: displayName,
                    relativePath: logicalPath,
                    sourceRelativePath: record.storage == .markdownSource ? normalizedPath : nil,
                    absolutePath: record.absolutePath,
                    articleSlug: record.ownerArticleSlug,
                    articleTitle: nil,
                    children: [],
                    articleCount: 0
                ))
            }
        }

        // A missing source record should be temporary (for example while an
        // external move is being coalesced), but keeping it visible prevents
        // the tree from making an indexed article disappear without warning.
        for article in articles where !includedArticleSlugs.contains(article.slug) {
            folder(article.sourceFolderPath).leaves.append(articleNode(article, absolutePath: ""))
        }

        return materializeChildren(of: root)
    }

    static func flattened(_ roots: [NativeWorkspaceResourceNode]) -> [NativeWorkspaceResourceNode] {
        roots.flatMap { $0.flattened() }
    }

    static func folderPaths(in roots: [NativeWorkspaceResourceNode]) -> [String] {
        flattened(roots).compactMap { $0.kind == .folder ? $0.sourceRelativePath : nil }
    }

    static func ancestors(
        of resourceID: String,
        in roots: [NativeWorkspaceResourceNode]
    ) -> [String] {
        func search(
            _ nodes: [NativeWorkspaceResourceNode],
            parents: [String]
        ) -> [String]? {
            for node in nodes {
                if node.id == resourceID { return parents }
                let nextParents = node.kind == .folder ? parents + [node.id] : parents
                if let match = search(node.children, parents: nextParents) { return match }
            }
            return nil
        }
        return search(roots, parents: []) ?? []
    }

    private static func materializeChildren(of folder: FolderBox) -> [NativeWorkspaceResourceNode] {
        let folders = folder.childFolders.values.map { child -> NativeWorkspaceResourceNode in
            let children = materializeChildren(of: child)
            return NativeWorkspaceResourceNode(
                id: "workspace-folder:\(child.path)",
                kind: .folder,
                storage: .markdownSource,
                name: child.name,
                relativePath: child.path,
                sourceRelativePath: child.path,
                absolutePath: child.absolutePath,
                articleSlug: nil,
                articleTitle: nil,
                children: children,
                articleCount: children.reduce(0) { $0 + $1.articleCount }
            )
        }
        let nodes = folders + folder.leaves
        return nodes.sorted { lhs, rhs in
            if lhs.kind == .folder, rhs.kind != .folder { return true }
            if lhs.kind != .folder, rhs.kind == .folder { return false }
            let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    private static func articleNode(
        _ article: NativeArticleSummary,
        absolutePath: String
    ) -> NativeWorkspaceResourceNode {
        NativeWorkspaceResourceNode(
            id: "workspace-article:\(article.slug)",
            kind: .article,
            storage: .markdownSource,
            name: URL(fileURLWithPath: article.sourceRelativePath)
                .deletingPathExtension().lastPathComponent,
            relativePath: normalized(article.sourceRelativePath),
            sourceRelativePath: normalized(article.sourceRelativePath),
            absolutePath: absolutePath,
            articleSlug: article.slug,
            articleTitle: article.title,
            children: [],
            articleCount: 1
        )
    }

    private static func normalized(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .precomposedStringWithCanonicalMapping
    }

    private static func joined(_ folder: String, _ name: String) -> String {
        let folder = normalized(folder)
        return folder.isEmpty ? name : "\(folder)/\(name)"
    }
}
