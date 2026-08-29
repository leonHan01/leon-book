import Foundation

public enum NativeArticleGraphStatusFilter: String, CaseIterable, Identifiable {
    case all
    case published
    case draft

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部状态"
        case .published: return "已发布"
        case .draft: return "草稿"
        }
    }
}

public struct NativeArticleGraphQuery: Equatable {
    public var searchText: String
    public var status: NativeArticleGraphStatusFilter
    public var includesOrphans: Bool
    public var nodeLimit: Int

    public init(
        searchText: String = "",
        status: NativeArticleGraphStatusFilter = .all,
        includesOrphans: Bool = true,
        nodeLimit: Int = 100
    ) {
        self.searchText = searchText
        self.status = status
        self.includesOrphans = includesOrphans
        self.nodeLimit = nodeLimit
    }
}

public struct NativeArticleGraphProjection: Equatable {
    public let graph: NativeArticleGraph
    public let matchingNodeCount: Int
    public let clippedNodeCount: Int

    public var isClipped: Bool { clippedNodeCount > 0 }

    public init(graph: NativeArticleGraph, matchingNodeCount: Int, clippedNodeCount: Int) {
        self.graph = graph
        self.matchingNodeCount = matchingNodeCount
        self.clippedNodeCount = clippedNodeCount
    }
}

/// The graph module's single projection interface. Filtering, orphan removal,
/// degree ranking, node clipping, and edge cleanup stay local to this seam.
public enum NativeArticleGraphProjector {
    public static func project(
        _ source: NativeArticleGraph,
        query: NativeArticleGraphQuery
    ) -> NativeArticleGraphProjection {
        let normalizedSearch = query.searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        var candidates = source.nodes.filter { article in
            let matchesStatus: Bool
            switch query.status {
            case .all: matchesStatus = true
            case .published: matchesStatus = article.status == .published
            case .draft: matchesStatus = article.status == .draft
            }
            guard matchesStatus else { return false }
            guard !normalizedSearch.isEmpty else { return true }

            let searchable = [
                article.title,
                article.slug,
                article.category,
                article.tags.joined(separator: " "),
                article.aliases.joined(separator: " "),
            ]
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return searchable.contains(normalizedSearch)
        }

        var candidateSlugs = Set(candidates.map(\.slug))
        var candidateEdges = source.edges.filter {
            candidateSlugs.contains($0.sourceSlug) && candidateSlugs.contains($0.targetSlug)
        }

        if !query.includesOrphans {
            let connectedSlugs = Set(candidateEdges.flatMap { [$0.sourceSlug, $0.targetSlug] })
            candidates.removeAll { !connectedSlugs.contains($0.slug) }
            candidateSlugs = Set(candidates.map(\.slug))
            candidateEdges.removeAll {
                !candidateSlugs.contains($0.sourceSlug) || !candidateSlugs.contains($0.targetSlug)
            }
        }

        var degree: [String: Int] = [:]
        for edge in candidateEdges {
            degree[edge.sourceSlug, default: 0] += 1
            if edge.targetSlug != edge.sourceSlug {
                degree[edge.targetSlug, default: 0] += 1
            }
        }

        candidates.sort { lhs, rhs in
            let lhsDegree = degree[lhs.slug, default: 0]
            let rhsDegree = degree[rhs.slug, default: 0]
            if lhsDegree != rhsDegree { return lhsDegree > rhsDegree }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        let matchingNodeCount = candidates.count
        let limit = min(max(query.nodeLimit, 10), 500)
        let nodes = Array(candidates.prefix(limit))
        let visibleSlugs = Set(nodes.map(\.slug))
        let edges = candidateEdges.filter {
            visibleSlugs.contains($0.sourceSlug) && visibleSlugs.contains($0.targetSlug)
        }

        return NativeArticleGraphProjection(
            graph: NativeArticleGraph(nodes: nodes, edges: edges),
            matchingNodeCount: matchingNodeCount,
            clippedNodeCount: max(0, matchingNodeCount - nodes.count)
        )
    }
}
