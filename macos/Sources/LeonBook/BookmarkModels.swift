import Foundation

public enum NativeBookmarkTarget: Codable, Hashable {
    case article(slug: String)
    case heading(slug: String, heading: String, anchorID: String)
    case search(query: String)
    case graph

    var systemImage: String {
        switch self {
        case .article: return "doc.text"
        case .heading: return "textformat.size"
        case .search: return "magnifyingglass"
        case .graph: return "point.3.connected.trianglepath.dotted"
        }
    }
}

public struct NativeBookmark: Codable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var groupName: String
    public var target: NativeBookmarkTarget
    public var createdAt: String

    public init(
        id: String = UUID().uuidString.lowercased(),
        title: String,
        groupName: String = "",
        target: NativeBookmarkTarget,
        createdAt: String = NativeTimestamp.string(from: Date())
    ) {
        self.id = id
        self.title = title
        self.groupName = groupName
        self.target = target
        self.createdAt = createdAt
    }
}

