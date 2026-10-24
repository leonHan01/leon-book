import AppKit
import Foundation
@testable import LeonBook

private struct PhotoTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func photoExpect(_ condition: Bool, _ message: String) throws {
    if !condition { throw PhotoTestFailure(description: message) }
}

final class PhotoLibraryTests {
    private func fixture() throws -> (root: URL, image: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leon-photo-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("风景.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let data = bitmap.representation(using: .png, properties: [:])!
        try data.write(to: image)
        return (root, image)
    }

    func testAlbumsPersistMoveAtomicallyAndKeepPhotos() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let workspace = fixture.root.appendingPathComponent("workspace")
        let store = LocalBlogStore(rootURL: workspace)
        let first = try await store.createPhotoAlbum(name: " 旅行 ")
        let second = try await store.createPhotoAlbum(name: "精选")
        try await store.importLibraryPhotos([fixture.image], toAlbum: first.id)
        let imported = try await store.photoLibrarySnapshot()
        try photoExpect(imported.photos.count == 1, "import must expose one image")
        let photo = imported.photos[0]
        try photoExpect(photo.media.name == "风景.png" && photo.albumID == first.id, "import must retain display name and membership")
        let url = await store.mediaURL(for: photo.id)!
        let bytes = try Data(contentsOf: url)
        try await store.movePhotos([photo.media], toAlbum: second.id)
        try photoExpect(try Data(contentsOf: url) == bytes, "organizing photos must preserve the file and URL")
        try await store.renamePhotoAlbum(id: second.id, name: "Favorite")
        do {
            _ = try await store.createPhotoAlbum(name: " favorite ")
            throw PhotoTestFailure(description: "duplicate names must be rejected")
        } catch NativeStoreError.fileSystem { }
        for invalidName in [" ", "bad\nname", String(repeating: "a", count: 81)] {
            do {
                _ = try await store.createPhotoAlbum(name: invalidName)
                throw PhotoTestFailure(description: "invalid album name was accepted")
            } catch NativeStoreError.fileSystem { }
        }
        let missing = NativeMedia(kind: "image", name: "missing.png", size: 0, url: "/media/inbox/missing.png")
        do {
            try await store.movePhotos([photo.media, missing], toAlbum: first.id)
            throw PhotoTestFailure(description: "missing photos must abort a batch")
        } catch NativeStoreError.fileSystem { }
        let unchanged = try await store.photoLibrarySnapshot()
        try photoExpect(unchanged.photos.first?.albumID == second.id, "failed batch must roll back earlier memberships")
        do {
            try await store.movePhotos([photo.media], toAlbum: "missing-album")
            throw PhotoTestFailure(description: "unknown album must not accept photos")
        } catch NativeStoreError.fileSystem { }
        try await store.deletePhotoAlbum(id: second.id)
        try await store.discardUnreferencedMedia([photo.media])
        try photoExpect(FileManager.default.fileExists(atPath: url.path), "deleting album and cleaning attachments must keep library photos")
        await store.closeForRestore()

        let reopened = LocalBlogStore(rootURL: workspace)
        let snapshot = try await reopened.photoLibrarySnapshot()
        try photoExpect(snapshot.albums == [first], "album changes must survive reopening")
        try photoExpect(snapshot.photos.count == 1 && snapshot.photos[0].albumID == nil, "deleted album photos must become unfiled after reopening")
        try photoExpect(FileManager.default.fileExists(atPath: fixture.image.path), "import must preserve original file")
        await reopened.closeForRestore()

        let other = LocalBlogStore(rootURL: fixture.root.appendingPathComponent("other"))
        let isolated = try await other.photoLibrarySnapshot()
        try photoExpect(isolated.albums.isEmpty && isolated.photos.isEmpty, "workspaces must keep separate libraries")
        await other.closeForRestore()
    }

    func testExistingAttachmentsStayLinkedAndImportRollsBack() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = LocalBlogStore(rootURL: fixture.root.appendingPathComponent("workspace"))
        let upload = try await store.uploadMedia(fileURL: fixture.image, kind: "image")
        let media = NativeMedia(kind: "image", name: upload.name, size: upload.size, url: upload.url)
        let initial = try await store.photoLibrarySnapshot()
        try photoExpect(initial.photos.count == 1 && initial.photos[0].albumID == nil, "existing attachments must be available without import")
        let album = try await store.createPhotoAlbum(name: "附件")
        try await store.movePhotos([media], toAlbum: album.id)
        let article = try await store.saveArticle(NativeSaveArticle(
            banner: nil, body: "![风景](\(media.url))", category: "", excerpt: "", media: [media],
            slug: "photos-test", status: .draft, tags: [], title: "图片引用", expectedUpdatedAt: nil
        ))
        try photoExpect(article.media.first?.url == media.url && article.body.contains(media.url), "saving an inbox attachment in an album must keep its stable URL")
        try await store.deleteArticle(slug: article.slug, expectedUpdatedAt: article.updatedAt)
        try await store.emptyTrash()
        let afterPurge = try await store.photoLibrarySnapshot()
        try photoExpect(afterPurge.photos.first?.id == media.url, "permanently deleting an article must retain album photos")

        let invalid = fixture.root.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: invalid)
        do {
            try await store.importLibraryPhotos([fixture.image, invalid], toAlbum: album.id)
            throw PhotoTestFailure(description: "invalid import must fail")
        } catch NativeStoreError.fileSystem { }
        let sourceDirectory = fixture.root.appendingPathComponent("gone")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let firstSource = sourceDirectory.appendingPathComponent("first.png")
        let secondSource = sourceDirectory.appendingPathComponent("second.png")
        try FileManager.default.copyItem(at: fixture.image, to: firstSource)
        try FileManager.default.copyItem(at: fixture.image, to: secondSource)
        // A deleted target album must reject a batch before copying any files.
        try await store.deletePhotoAlbum(id: album.id)
        do {
            try await store.importLibraryPhotos([firstSource, secondSource], toAlbum: album.id)
            throw PhotoTestFailure(description: "stale drop target must fail")
        } catch NativeStoreError.fileSystem { }
        let afterFailure = try await store.photoLibrarySnapshot()
        try photoExpect(afterFailure.photos.count == 1, "failed imports must leave no extra files or memberships")
        // Relative traversal and external references cannot enter an album.
        for badURL in ["/media/../outside.png", fixture.image.absoluteString, "https://example.com/photo.png"] {
            do {
                try await store.movePhotos([NativeMedia(kind: "image", name: "bad", size: 0, url: badURL)], toAlbum: nil)
                throw PhotoTestFailure(description: "non-library path must be rejected")
            } catch NativeStoreError.fileSystem { }
        }
        await store.closeForRestore()
    }

    func testPhotoFilteringAndStableSort() throws {
        let photos = [
            NativeLibraryPhoto(media: NativeMedia(kind: "image", name: "Beach 10.png", size: 0, url: "c"), modifiedAt: Date(timeIntervalSince1970: 3), albumID: "trip"),
            NativeLibraryPhoto(media: NativeMedia(kind: "image", name: "Beach 2.png", size: 0, url: "a"), modifiedAt: Date(timeIntervalSince1970: 1), albumID: nil),
            NativeLibraryPhoto(media: NativeMedia(kind: "image", name: "山.png", size: 0, url: "b"), modifiedAt: Date(timeIntervalSince1970: 3), albumID: "trip"),
        ]
        let sorted = NativePhotoLibraryProjection.photos(photos, scope: .all, search: "", sort: .newest)
        try photoExpect(sorted.map(\.id) == ["b", "c", "a"], "equal timestamps need deterministic ordering")
        let search = NativePhotoLibraryProjection.photos(photos, scope: .all, search: " beach ", sort: .name)
        try photoExpect(search.map(\.id) == ["a", "c"], "search must trim whitespace, ignore case, and naturally sort names")
        let album = NativePhotoLibraryProjection.photos(photos, scope: .album("trip"), search: "", sort: .oldest)
        try photoExpect(album.map(\.id) == ["b", "c"], "album filters must exclude other scopes")
        let unfiled = NativePhotoLibraryProjection.photos(photos, scope: .unfiled, search: "", sort: .newest)
        try photoExpect(unfiled.map(\.id) == ["a"], "unfiled must exclude album photos")
    }

    @MainActor
    func testMultiPhotoDropsAndWorkspaceIsolation() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = LocalBlogStore(rootURL: fixture.root.appendingPathComponent("workspace"))
        let album = try await store.createPhotoAlbum(name: "拖拽")
        try await store.importLibraryPhotos([fixture.image, fixture.image], toAlbum: nil)
        let model = NativePhotoLibraryModel(store: store, workspace: fixture.root.appendingPathComponent("workspace").path)
        await model.load()
        model.selection = Set(model.photos.map(\.id))
        let provider = model.dragProvider(for: model.photos[0])
        var changes = 0
        await model.receiveDrop([provider], to: album.id) { changes += 1 }
        try photoExpect(model.errorMessage == nil && changes == 1, "internal drop should complete successfully")
        try photoExpect(model.photos.count == 2 && model.photos.allSatisfy { $0.albumID == album.id }, "dragging a selection must move every selected photo")
        try photoExpect(model.selection.isEmpty, "moving a selection should clear hidden selections")
        await model.receiveDrop([provider], to: nil) { changes += 1 }
        try photoExpect(model.photos.allSatisfy { $0.albumID == nil }, "dropping on Unfiled must remove album membership")

        let other = LocalBlogStore(rootURL: fixture.root.appendingPathComponent("other"))
        let otherModel = NativePhotoLibraryModel(store: other, workspace: fixture.root.appendingPathComponent("other").path)
        await otherModel.load()
        await otherModel.receiveDrop([provider], to: nil) { changes += 1 }
        try photoExpect(otherModel.errorMessage != nil && changes == 2, "cross-workspace drags must not mutate either library")
        let otherPhotos = try await other.photoLibrarySnapshot()
        try photoExpect(otherPhotos.photos.isEmpty, "cross-workspace drop must not import hidden references")

        let fileProvider = NSItemProvider(contentsOf: fixture.image)!
        await model.receiveDrop([fileProvider], to: album.id) { changes += 1 }
        try photoExpect(model.errorMessage == nil && changes == 3, "Finder file URL drops must import the image")
        try photoExpect(model.photos.count == 3 && model.photos.filter { $0.albumID == album.id }.count == 1,
                        "external drop must import directly into the target album")
        await store.closeForRestore()
        await other.closeForRestore()
    }
}
