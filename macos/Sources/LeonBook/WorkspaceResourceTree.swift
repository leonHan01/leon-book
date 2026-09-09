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
    var canContainPages: Bool { kind == .folder || kind == .article }

    /// Markdown stays authoritative: a folder page uses `folder/index.md`, while
    /// a regular `page.md` owns children from the adjacent `page/` directory.
    var pageContainerPath: String {
        if kind == .folder { return relativePath }
        guard kind == .article, let sourceRelativePath else { return relativePath }
        return NativeArticlePageHierarchy.containerPath(for: sourceRelativePath)
    }

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
            let filename = URL(fileURLWithPath: record.relativePath).lastPathComponent
            guard URL(fileURLWithPath: filename).pathExtension
                .caseInsensitiveCompare("json") != .orderedSame else { continue }
            let targetFolder = folder(record.placementFolderPath)
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
        folderPaths(for: flattened(roots))
    }

    static func folderPaths(for items: [NativeWorkspaceResourceNode]) -> [String] {
        Array(Set(items.compactMap { resource -> String? in
            switch resource.kind {
            case .folder:
                return resource.sourceRelativePath
            case .article:
                return resource.pageContainerPath
            case .attachment:
                return nil
            }
        })).sorted()
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
                let nextParents = node.canContainPages ? parents + [node.id] : parents
                if let match = search(node.children, parents: nextParents) { return match }
            }
            return nil
        }
        return search(roots, parents: []) ?? []
    }

    private static func materializeChildren(
        of folder: FolderBox,
        excludingLeafID: String? = nil
    ) -> [NativeWorkspaceResourceNode] {
        var folderNodes = folder.childFolders.values.map { child -> NativeWorkspaceResourceNode in
            let indexPage = child.leaves.first(where: isFolderIndexPage)
            let children = materializeChildren(of: child, excludingLeafID: indexPage?.id)
            if let indexPage {
                return pageNode(indexPage, children: children)
            }
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

        var leaves = folder.leaves.filter { $0.id != excludingLeafID }
        // `Project.md` + `Project/` is the second portable representation of a
        // page with subpages. Merge the two in navigation without moving files.
        for leafIndex in leaves.indices.reversed() {
            let leaf = leaves[leafIndex]
            guard leaf.kind == .article,
                  let matchingFolderIndex = folderNodes.firstIndex(where: {
                      $0.kind == .folder
                          && $0.name.caseInsensitiveCompare(articleStem(leaf)) == .orderedSame
                  }) else { continue }
            let matchingFolder = folderNodes.remove(at: matchingFolderIndex)
            folderNodes.append(pageNode(leaf, children: matchingFolder.children))
            leaves.remove(at: leafIndex)
        }

        let nodes = folderNodes + leaves
        return nodes.sorted { lhs, rhs in
            let lhsContainer = lhs.kind == .folder || !lhs.children.isEmpty
            let rhsContainer = rhs.kind == .folder || !rhs.children.isEmpty
            if lhsContainer != rhsContainer { return lhsContainer }
            let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    private static func isFolderIndexPage(_ node: NativeWorkspaceResourceNode) -> Bool {
        guard node.kind == .article, let path = node.sourceRelativePath else { return false }
        return URL(fileURLWithPath: path)
            .deletingPathExtension().lastPathComponent
            .caseInsensitiveCompare("index") == .orderedSame
    }

    private static func articleStem(_ node: NativeWorkspaceResourceNode) -> String {
        guard let path = node.sourceRelativePath else { return node.name }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    private static func pageNode(
        _ article: NativeWorkspaceResourceNode,
        children: [NativeWorkspaceResourceNode]
    ) -> NativeWorkspaceResourceNode {
        NativeWorkspaceResourceNode(
            id: article.id,
            kind: .article,
            storage: article.storage,
            name: article.name,
            relativePath: article.relativePath,
            sourceRelativePath: article.sourceRelativePath,
            absolutePath: article.absolutePath,
            articleSlug: article.articleSlug,
            articleTitle: article.articleTitle,
            children: children,
            articleCount: 1 + children.reduce(0) { $0 + $1.articleCount }
        )
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
