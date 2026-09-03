import Foundation
import LeonBookModuleKit

public enum KnowledgeGraphFirstPartyModule: FirstPartyModule {
    public static let id = FirstPartyModuleID(rawValue: "knowledge-graph")
    public static let descriptor = FirstPartyModuleDescriptor(
        id: id,
        name: "知识图谱",
        summary: "文章关系投影、过滤与节点裁剪。",
        systemImage: "point.3.connected.trianglepath.dotted",
        permissions: [.contentRead],
        commands: [
            .init(
                id: "navigation.graph",
                title: "前往关系图",
                detail: "查看文章链接关系",
                keywords: "graph link",
                systemImage: "point.3.connected.trianglepath.dotted",
                requiredPermissions: [.contentRead]
            ),
        ],
        eventNames: ["graph.requested", "graph.projected"]
    )
}

public struct FirstPartyGraphNode: Equatable, Sendable {
    public let id: String
    public let status: String
    public let searchableText: String
    public let updatedAt: Date

    public init(id: String, status: String, searchableText: String, updatedAt: Date) {
        self.id = id
        self.status = status
        self.searchableText = searchableText
        self.updatedAt = updatedAt
    }
}

public struct FirstPartyGraphEdge: Equatable, Hashable, Sendable {
    public let sourceID: String
    public let targetID: String

    public init(sourceID: String, targetID: String) {
        self.sourceID = sourceID
        self.targetID = targetID
    }
}

public struct FirstPartyGraphQuery: Equatable, Sendable {
    public let searchText: String
    public let status: String?
    public let includesOrphans: Bool
    public let nodeLimit: Int

    public init(searchText: String, status: String?, includesOrphans: Bool, nodeLimit: Int) {
        self.searchText = searchText
        self.status = status
        self.includesOrphans = includesOrphans
        self.nodeLimit = nodeLimit
    }
}

public struct FirstPartyGraphProjection: Equatable, Sendable {
    public let orderedNodeIDs: [String]
    public let edges: [FirstPartyGraphEdge]
    public let matchingNodeCount: Int

    public var clippedNodeCount: Int {
        max(0, matchingNodeCount - orderedNodeIDs.count)
    }
}

public struct FirstPartyGraphPath: Equatable, Sendable {
    public let nodeIDs: [String]

    public var hopCount: Int {
        max(0, nodeIDs.count - 1)
    }

    public var edges: [FirstPartyGraphEdge] {
        zip(nodeIDs, nodeIDs.dropFirst()).map {
            FirstPartyGraphEdge(sourceID: $0.0, targetID: $0.1)
        }
    }

    public init(nodeIDs: [String]) {
        self.nodeIDs = nodeIDs
    }
}

/// Finds the shortest authored route through directed article references.
/// A breadth-first traversal guarantees the fewest number of reference hops.
public enum FirstPartyKnowledgeGraphPathFinder {
    public static func shortestPath(
        from sourceID: String,
        to targetID: String,
        nodes: [FirstPartyGraphNode],
        edges: [FirstPartyGraphEdge]
    ) -> FirstPartyGraphPath? {
        let nodeIDs = Set(nodes.map(\.id))
        guard nodeIDs.contains(sourceID), nodeIDs.contains(targetID) else { return nil }
        guard sourceID != targetID else { return FirstPartyGraphPath(nodeIDs: [sourceID]) }

        var adjacency: [String: Set<String>] = [:]
        for edge in edges where nodeIDs.contains(edge.sourceID) && nodeIDs.contains(edge.targetID) {
            adjacency[edge.sourceID, default: []].insert(edge.targetID)
        }

        var queue = [sourceID]
        var nextIndex = 0
        var visited: Set<String> = [sourceID]
        var predecessor: [String: String] = [:]

        while nextIndex < queue.count {
            let current = queue[nextIndex]
            nextIndex += 1

            for neighbor in (adjacency[current] ?? []).sorted() where visited.insert(neighbor).inserted {
                predecessor[neighbor] = current
                if neighbor == targetID {
                    return FirstPartyGraphPath(
                        nodeIDs: reconstructedPath(
                            from: sourceID,
                            to: targetID,
                            predecessor: predecessor
                        )
                    )
                }
                queue.append(neighbor)
            }
        }

        return nil
    }

    private static func reconstructedPath(
        from sourceID: String,
        to targetID: String,
        predecessor: [String: String]
    ) -> [String] {
        var reversedPath = [targetID]
        var current = targetID
        while current != sourceID, let previous = predecessor[current] {
            reversedPath.append(previous)
            current = previous
        }
        return Array(reversedPath.reversed())
    }
}

/// A storage-agnostic graph projection engine. SQLite/domain models are only
/// adapted at the LeonBook boundary.
public enum FirstPartyKnowledgeGraphProjector {
    public static func project(
        nodes sourceNodes: [FirstPartyGraphNode],
        edges sourceEdges: [FirstPartyGraphEdge],
        query: FirstPartyGraphQuery
    ) -> FirstPartyGraphProjection {
        let normalizedSearch = normalized(query.searchText)
        var candidates = sourceNodes.filter { node in
            let matchesStatus = query.status == nil || node.status == query.status
            return matchesStatus && (normalizedSearch.isEmpty || normalized(node.searchableText).contains(normalizedSearch))
        }

        var candidateIDs = Set(candidates.map(\.id))
        var candidateEdges = sourceEdges.filter {
            candidateIDs.contains($0.sourceID) && candidateIDs.contains($0.targetID)
        }

        if !query.includesOrphans {
            let connectedIDs = Set(candidateEdges.flatMap { [$0.sourceID, $0.targetID] })
            candidates.removeAll { !connectedIDs.contains($0.id) }
            candidateIDs = Set(candidates.map(\.id))
            candidateEdges.removeAll {
                !candidateIDs.contains($0.sourceID) || !candidateIDs.contains($0.targetID)
            }
        }

        var degree: [String: Int] = [:]
        for edge in candidateEdges {
            degree[edge.sourceID, default: 0] += 1
            if edge.targetID != edge.sourceID { degree[edge.targetID, default: 0] += 1 }
        }
        candidates.sort { lhs, rhs in
            let lhsDegree = degree[lhs.id, default: 0]
            let rhsDegree = degree[rhs.id, default: 0]
            if lhsDegree != rhsDegree { return lhsDegree > rhsDegree }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
        }

        let matchingNodeCount = candidates.count
        let visible = Array(candidates.prefix(min(max(query.nodeLimit, 10), 500)))
        let visibleIDs = Set(visible.map(\.id))
        return FirstPartyGraphProjection(
            orderedNodeIDs: visible.map(\.id),
            edges: candidateEdges.filter {
                visibleIDs.contains($0.sourceID) && visibleIDs.contains($0.targetID)
            },
            matchingNodeCount: matchingNodeCount
        )
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
