import Foundation

/// One navigation index per resource-tree snapshot. Nodes share their child
/// arrays with the tree; lookup tables and parent links store only offsets.
@MainActor
final class NativeWorkspaceResourceIndex {
    let items: [NativeWorkspaceResourceNode]
    private let indexByID: [String: Int]
    private let indexByArticleSlug: [String: Int]
    private let parentIndices: [Int?]

    // Folder destinations are only needed when moving or creating pages.
    // Avoid deriving every article's container path during normal navigation.
    private(set) lazy var folderPaths = NativeWorkspaceResourceTree.folderPaths(for: items)

    init(roots: [NativeWorkspaceResourceNode]) {
        var items: [NativeWorkspaceResourceNode] = []
        var indexByID: [String: Int] = [:]
        var indexByArticleSlug: [String: Int] = [:]
        var parentIndices: [Int?] = []
        var pending: [(node: NativeWorkspaceResourceNode, parentIndex: Int?)] = roots.reversed().map { ($0, nil) }
        while let (node, parentIndex) = pending.popLast() {
            let index = items.count
            items.append(node)
            parentIndices.append(parentIndex)
            if indexByID[node.id] == nil { indexByID[node.id] = index }
            if node.kind == .article, let slug = node.articleSlug, indexByArticleSlug[slug] == nil {
                indexByArticleSlug[slug] = index
            }
            let nextParent = node.canContainPages ? index : parentIndex
            for child in node.children.reversed() {
                pending.append((child, nextParent))
            }
        }
        self.items = items
        self.indexByID = indexByID
        self.indexByArticleSlug = indexByArticleSlug
        self.parentIndices = parentIndices
    }

    func resource(id: String) -> NativeWorkspaceResourceNode? {
        indexByID[id].map { items[$0] }
    }

    func resources(ids: Set<String>) -> [NativeWorkspaceResourceNode] {
        ids.compactMap { indexByID[$0] }.sorted().map { items[$0] }
    }

    func resourceID(articleSlug: String) -> String? {
        indexByArticleSlug[articleSlug].map { items[$0].id }
    }

    func ancestorIDs(resourceID: String) -> [String] {
        guard let index = indexByID[resourceID] else { return [] }
        var result: [String] = []
        var parent = parentIndices[index]
        while let index = parent {
            result.append(items[index].id)
            parent = parentIndices[index]
        }
        return result.reversed()
    }
}
