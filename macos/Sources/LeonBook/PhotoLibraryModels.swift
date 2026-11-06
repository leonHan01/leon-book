import Foundation

struct NativePhotoAlbum: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

struct NativeLibraryPhoto: Identifiable, Hashable, Sendable {
    let media: NativeMedia
    let modifiedAt: Date
    let albumID: String?
    var id: String { media.url }
}

struct NativePhotoLibrarySnapshot {
    let albums: [NativePhotoAlbum]
    let photos: [NativeLibraryPhoto]
}

enum NativePhotoScope: Hashable, Sendable {
    case all
    case unfiled
    case album(String)

    var albumID: String? {
        if case let .album(id) = self { return id }
        return nil
    }
}

enum NativePhotoSort: String, CaseIterable, Identifiable, Sendable {
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

enum NativePhotoLibraryProjection {
    static func photos(
        _ photos: [NativeLibraryPhoto], scope: NativePhotoScope,
        search: String, sort: NativePhotoSort
    ) throws -> [NativeLibraryPhoto] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return try photos.filter { photo in
            try Task.checkCancellation()
            let matchesScope: Bool
            switch scope {
            case .all: matchesScope = true
            case .unfiled: matchesScope = photo.albumID == nil
            case let .album(id): matchesScope = photo.albumID == id
            }
            return matchesScope && (query.isEmpty || photo.media.name.localizedStandardContains(query))
        }.sorted { left, right in
            try Task.checkCancellation()
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
