import Foundation

enum NativePlayableMediaKind: String, Sendable {
    case video, audio

    static func kind(for url: URL) -> Self? {
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "m4v": return .video
        case "mp3", "m4a", "aac", "wav", "aif", "aiff", "caf": return .audio
        default: return nil
        }
    }
}

struct NativeLibraryMedia: Identifiable, Hashable, Sendable {
    let media: NativeMedia
    let modifiedAt: Date
    let introduction: String
    let groupID: String?
    var id: String { media.url }

    init(media: NativeMedia, modifiedAt: Date, introduction: String = "", groupID: String? = nil) {
        self.media = media
        self.modifiedAt = modifiedAt
        self.introduction = introduction
        self.groupID = groupID
    }
}

struct NativeMediaGroup: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

struct NativeMediaLibrarySnapshot: Sendable {
    let groups: [NativeMediaGroup]
    let items: [NativeLibraryMedia]
}

enum NativeMediaLibraryScope: Hashable {
    case all
    case defaultGroup
    case group(String)

    var groupID: String? {
        if case let .group(id) = self { return id }
        return nil
    }

    func contains(_ item: NativeLibraryMedia) -> Bool {
        switch self {
        case .all: return true
        case .defaultGroup: return item.groupID == nil
        case let .group(id): return item.groupID == id
        }
    }
}

enum NativeMediaLibraryFilter: String, CaseIterable, Identifiable {
    case all, video, audio
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "全部影音"
        case .video: return "视频"
        case .audio: return "音频"
        }
    }
}

enum NativeMediaLibrarySort: String, CaseIterable, Identifiable {
    case newest, oldest, name
    var id: String { rawValue }
    var label: String {
        switch self {
        case .newest: return "最新在前"
        case .oldest: return "最早在前"
        case .name: return "按名称"
        }
    }
}

enum NativeMediaLibraryProjection {
    static func items(
        _ items: [NativeLibraryMedia], scope: NativeMediaLibraryScope = .all, filter: NativeMediaLibraryFilter,
        search: String, sort: NativeMediaLibrarySort
    ) -> [NativeLibraryMedia] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter {
            scope.contains($0) && (filter == .all || $0.media.kind == filter.rawValue)
                && (query.isEmpty || $0.media.name.localizedStandardContains(query)
                    || $0.introduction.localizedStandardContains(query))
        }.sorted { left, right in
            if sort == .name {
                let order = left.media.name.localizedStandardCompare(right.media.name)
                if order != .orderedSame { return order == .orderedAscending }
            } else if left.modifiedAt != right.modifiedAt {
                return sort == .newest ? left.modifiedAt > right.modifiedAt : left.modifiedAt < right.modifiedAt
            }
            return left.id < right.id
        }
    }
}
