import AppKit
import Foundation

enum NativeMediaUploadKind: String {
    case image
    case video
    case audio
    case file
}

enum NativeMediaUploadDestination: Equatable {
    case inbox
    case article(slug: String)
    case moments
    case questionAnswers

    var directoryName: String? {
        switch self {
        case .inbox:
            return nil
        case let .article(slug):
            return slug
        case .moments:
            return "moments"
        case .questionAnswers:
            return "question-answers"
        }
    }
}

/// Owns media conversion, temporary-file lifetime, batch upload, and partial
/// failure cleanup. Feature models only decide where successful media belongs.
enum NativeMediaUpload {
    static func files(
        _ fileURLs: [URL],
        kind: NativeMediaUploadKind,
        destination: NativeMediaUploadDestination,
        store: LocalBlogStore
    ) async throws -> [NativeMedia] {
        var uploadedMedia: [NativeMedia] = []
        do {
            for fileURL in fileURLs {
                let uploaded = try await store.uploadMedia(
                    fileURL: fileURL,
                    kind: kind.rawValue,
                    slug: destination.directoryName
                )
                uploadedMedia.append(uploaded.media)
            }
            return uploadedMedia
        } catch {
            try? await store.discardUnreferencedMedia(uploadedMedia)
            throw error
        }
    }

    static func images(
        _ images: [NSImage],
        destination: NativeMediaUploadDestination,
        temporaryNamePrefix: String,
        invalidImageMessage: String = "无法读取拖入或粘贴的图片。",
        store: LocalBlogStore
    ) async throws -> [NativeMedia] {
        var temporaryURLs: [URL] = []
        defer {
            for url in temporaryURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }

        for image in images {
            guard let imageData = image.pngData else {
                throw NativeStoreError.fileSystem(invalidImageMessage)
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(temporaryNamePrefix)-\(UUID().uuidString.lowercased()).png")
            temporaryURLs.append(url)
            try imageData.write(to: url, options: .atomic)
        }

        return try await files(
            temporaryURLs,
            kind: .image,
            destination: destination,
            store: store
        )
    }
}

private extension NativeUploadedMedia {
    var media: NativeMedia {
        NativeMedia(kind: kind, name: name, size: size, url: url)
    }
}

extension NSImage {
    var pngData: Data? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
