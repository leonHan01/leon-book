import Foundation
import LeonBookKnowledgeGraphModule

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

public struct NativeArticleGraphPath: Equatable {
    public let nodes: [NativeArticleSummary]
    public let edges: [NativeArticleGraphEdge]

    public var hopCount: Int {
        edges.count
    }

    public init(nodes: [NativeArticleSummary], edges: [NativeArticleGraphEdge]) {
        self.nodes = nodes
        self.edges = edges
    }
}

public enum NativeArticleGraphPathFinder {
    public static func shortestPath(
        in graph: NativeArticleGraph,
        from sourceSlug: String,
        to targetSlug: String
    ) -> NativeArticleGraphPath? {
        let moduleNodes = graph.nodes.map { article in
            FirstPartyGraphNode(
                id: article.slug,
                status: article.status.rawValue,
                searchableText: article.title,
                updatedAt: NativeTimestamp.date(from: article.updatedAt) ?? .distantPast
            )
        }
        let moduleEdges = graph.edges.map {
            FirstPartyGraphEdge(sourceID: $0.sourceSlug, targetID: $0.targetSlug)
        }
        guard let path = FirstPartyKnowledgeGraphPathFinder.shortestPath(
            from: sourceSlug,
            to: targetSlug,
            nodes: moduleNodes,
            edges: moduleEdges
        ) else {
            return nil
        }

        let nodesBySlug = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.slug, $0) })
        return NativeArticleGraphPath(
            nodes: path.nodeIDs.compactMap { nodesBySlug[$0] },
            edges: path.edges.map {
                NativeArticleGraphEdge(sourceSlug: $0.sourceID, targetSlug: $0.targetID)
            }
        )
    }
}

/// The graph module's single projection interface. Filtering, orphan removal,
/// degree ranking, node clipping, and edge cleanup stay local to this seam.
public enum NativeArticleGraphProjector {
    public static func project(
        _ source: NativeArticleGraph,
        query: NativeArticleGraphQuery
    ) -> NativeArticleGraphProjection {
        let projected = FirstPartyKnowledgeGraphProjector.project(
            nodes: source.nodes.map { article in
                FirstPartyGraphNode(
                    id: article.slug,
                    status: article.status.rawValue,
                    searchableText: [
                        article.title,
                        article.slug,
                        article.category,
                        article.tags.joined(separator: " "),
                        article.aliases.joined(separator: " "),
                    ].joined(separator: " "),
                    updatedAt: NativeTimestamp.date(from: article.updatedAt) ?? .distantPast
                )
            },
            edges: source.edges.map {
                FirstPartyGraphEdge(sourceID: $0.sourceSlug, targetID: $0.targetSlug)
            },
            query: FirstPartyGraphQuery(
                searchText: query.searchText,
                status: query.status == .all ? nil : query.status.rawValue,
                includesOrphans: query.includesOrphans,
                nodeLimit: query.nodeLimit
            )
        )
        let nodesBySlug = Dictionary(uniqueKeysWithValues: source.nodes.map { ($0.slug, $0) })
        let edgeSet = Set(projected.edges)

        return NativeArticleGraphProjection(
            graph: NativeArticleGraph(
                nodes: projected.orderedNodeIDs.compactMap { nodesBySlug[$0] },
                edges: source.edges.filter {
                    edgeSet.contains(FirstPartyGraphEdge(
                        sourceID: $0.sourceSlug,
                        targetID: $0.targetSlug
                    ))
                }
            ),
            matchingNodeCount: projected.matchingNodeCount,
            clippedNodeCount: projected.clippedNodeCount
        )
    }
}
