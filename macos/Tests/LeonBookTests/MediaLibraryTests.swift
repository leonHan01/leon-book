import AVFoundation
import AppKit
@testable import LeonBook

private struct MediaLibraryTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func mediaExpect(_ condition: Bool, _ message: String) throws {
    if !condition { throw MediaLibraryTestFailure(description: message) }
}

final class MediaLibraryTests {
    func testMediaGroupsMigrateExistingLibrary() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let workspace = fixture.root.appendingPathComponent("workspace")
        let directory = workspace.appendingPathComponent("media/media-library")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.audio, to: directory.appendingPathComponent("old.mp3"))
        let oldDatabase = try SQLiteDatabase(url: workspace.appendingPathComponent("leon-book.sqlite"))
        try oldDatabase.execute("""
        CREATE TABLE media_library_items(url TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, kind TEXT NOT NULL,
                                         introduction TEXT NOT NULL DEFAULT '');
        INSERT INTO media_library_items VALUES('/media/media-library/old.mp3', '旧录音.mp3', 'audio', '原有介绍');
        """)
        oldDatabase.close()
        let store = LocalBlogStore(rootURL: workspace)
        _ = try await store.mediaLibraryItems()
        let database = try SQLiteDatabase(url: workspace.appendingPathComponent("leon-book.sqlite"))
        defer { database.close() }
        try mediaExpect(
            try database.integer("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'media_library_groups'") == 1,
            "media library must persist its own editable groups independently of article directories"
        )
        let migrated = try await store.mediaLibrarySnapshot()
        try mediaExpect(migrated.groups.isEmpty && migrated.items.count == 1 && migrated.items[0].groupID == nil,
                        "existing media must migrate to the default group")
        try mediaExpect(migrated.items[0].introduction == "原有介绍" && migrated.items[0].media.name == "旧录音.mp3",
                        "group migration must preserve existing names and introductions")
        let group = try await store.createMediaGroup(name: "收藏")
        try await store.moveLibraryMedia([migrated.items[0].media], toGroup: group.id)
        try await store.deleteMediaGroup(id: group.id)
        let returned = try await store.mediaLibrarySnapshot()
        try mediaExpect(returned.groups.isEmpty && returned.items == migrated.items,
                        "migrated databases must also return media to default when a group is deleted")
        await store.closeForRestore()
    }

    func testMediaGroupsKeepArticleAttachmentsAndPersistIndependently() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let workspace = fixture.root.appendingPathComponent("workspace")
        let store = LocalBlogStore(rootURL: workspace)
        try await store.createWorkspaceFolder(relativePath: "文章专用目录")
        let upload = try await store.uploadMedia(fileURL: fixture.audio, kind: "audio", slug: "article-audio")
        let media = NativeMedia(kind: "audio", name: upload.name, size: upload.size, url: upload.url)
        let article = try await store.saveArticle(NativeSaveArticle(
            banner: nil, body: "<audio controls src=\"\(media.url)\"></audio>", category: "文章分类", excerpt: "", media: [media],
            slug: "article-audio", status: .draft, tags: [], title: "文章中的影音", expectedUpdatedAt: nil
        ))
        let initial = try await store.mediaLibrarySnapshot()
        try mediaExpect(initial.groups.isEmpty && initial.items.count == 1 && initial.items[0].groupID == nil,
                        "article folders and categories must never become media groups; attachments start in default")
        let articleDirectories = try await store.listWorkspaceResources()
        let first = try await store.createMediaGroup(name: " 录音 ")
        let second = try await store.createMediaGroup(name: "旅行")
        let file = await store.mediaURL(for: media.url)!
        let bytes = try Data(contentsOf: file)
        try await store.saveMediaIntroduction("文章音频的介绍", for: media)
        try await store.moveLibraryMedia([media], toGroup: first.id)
        try await store.saveMediaIntroduction("编辑后的介绍", for: media)
        try await store.renameMediaGroup(id: first.id, name: "音乐与录音")
        let organized = try await store.mediaLibrarySnapshot()
        try mediaExpect(organized.items[0].groupID == first.id && organized.items[0].introduction == "编辑后的介绍",
                        "group assignment and introduction editing must preserve each other")
        try mediaExpect(try Data(contentsOf: file) == bytes, "organizing an article attachment must preserve its path and bytes")
        let unchangedArticle = try await store.getArticle(slug: article.slug)
        try mediaExpect(unchangedArticle.media == article.media && unchangedArticle.body == article.body,
                        "organizing media must not rewrite article content or attachment URLs")
        let unchangedDirectories = try await store.listWorkspaceResources()
        try mediaExpect(unchangedDirectories == articleDirectories, "media group edits must not affect article directories")
        await store.closeForRestore()

        let reopened = LocalBlogStore(rootURL: workspace)
        let restored = try await reopened.mediaLibrarySnapshot()
        try mediaExpect(restored.items == organized.items && restored.groups.contains(NativeMediaGroup(id: first.id, name: "音乐与录音")),
                        "group names, memberships, and introductions must survive reopening")
        try await reopened.moveLibraryMedia([media], toGroup: nil)
        let ungrouped = try await reopened.mediaLibrarySnapshot()
        try mediaExpect(ungrouped.items[0].groupID == nil, "moving to default must clear membership")
        try await reopened.moveLibraryMedia([media], toGroup: second.id)
        try await reopened.deleteMediaGroup(id: second.id)
        try await reopened.discardUnreferencedMedia([media])
        let afterDelete = try await reopened.mediaLibrarySnapshot()
        try mediaExpect(afterDelete.items[0].groupID == nil && afterDelete.items[0].introduction == "编辑后的介绍",
                        "deleting a group must return its media to default while retaining introductions")
        try mediaExpect(FileManager.default.fileExists(atPath: file.path), "group deletion must never remove the media file")
        await reopened.closeForRestore()

        let other = LocalBlogStore(rootURL: fixture.root.appendingPathComponent("other"))
        let isolated = try await other.mediaLibrarySnapshot()
        try mediaExpect(isolated.groups.isEmpty && isolated.items.isEmpty, "media groups must remain isolated between workspaces")
        await other.closeForRestore()
    }

    func testMediaGroupsRejectInvalidChangesAtomically() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = LocalBlogStore(rootURL: fixture.root.appendingPathComponent("workspace"))
        let first = try await store.createMediaGroup(name: "Favorite")
        let second = try await store.createMediaGroup(name: "旅行")
        try await store.importLibraryMedia([fixture.audio], toGroup: first.id)
        let initial = try await store.mediaLibrarySnapshot()
        try mediaExpect(initial.items.count == 1 && initial.items[0].groupID == first.id,
                        "imports must belong to the selected group")
        for name in [" ", "bad\nname", String(repeating: "a", count: 81), " favorite ", "默认分组", "all media"] {
            do {
                _ = try await store.createMediaGroup(name: name)
                throw MediaLibraryTestFailure(description: "invalid or duplicate group name was accepted")
            } catch NativeStoreError.fileSystem { }
        }
        do {
            try await store.renameMediaGroup(id: second.id, name: "FAVORITE")
            throw MediaLibraryTestFailure(description: "renaming must not duplicate another group")
        } catch NativeStoreError.fileSystem { }
        let missing = NativeMedia(kind: "audio", name: "missing.mp3", size: 1, url: "/media/inbox/missing.mp3")
        do {
            try await store.moveLibraryMedia([initial.items[0].media, missing], toGroup: second.id)
            throw MediaLibraryTestFailure(description: "missing files must abort a group move")
        } catch NativeStoreError.fileSystem { }
        do {
            try await store.moveLibraryMedia([initial.items[0].media], toGroup: "missing-group")
            throw MediaLibraryTestFailure(description: "stale group targets must reject moves")
        } catch NativeStoreError.fileSystem { }
        for url in ["/media/../outside.mp3", fixture.audio.absoluteString, "https://example.com/audio.mp3"] {
            do {
                try await store.moveLibraryMedia([NativeMedia(kind: "audio", name: "bad.mp3", size: 1, url: url)], toGroup: second.id)
                throw MediaLibraryTestFailure(description: "external media must not be grouped")
            } catch NativeStoreError.fileSystem { }
        }
        try await store.deleteMediaGroup(id: second.id)
        do {
            try await store.importLibraryMedia([fixture.audio], toGroup: second.id)
            throw MediaLibraryTestFailure(description: "deleted groups must reject imports before copying files")
        } catch NativeStoreError.fileSystem { }
        let unchanged = try await store.mediaLibrarySnapshot()
        try mediaExpect(unchanged.items == initial.items && unchanged.groups == [first],
                        "failed changes must leave no partial memberships, extra groups, or imported files")
        await store.closeForRestore()
    }

    @MainActor
    func testMediaGroupsShareSelectionRefreshAndResetForWorkspace() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = LocalBlogStore(rootURL: fixture.root.appendingPathComponent("workspace"))
        let app = NativeAppModel(navigationScopeID: "media-group-tests", startsAutomatically: false, store: store)
        let library = app.mediaLibrary
        app.section = .mediaLibrary
        try mediaExpect(app.mediaLibrary === library, "sidebar and content must share a single media library model")
        var changes = 0
        await library.saveGroup(name: "录音") { changes += 1 }
        let group = library.groups[0]
        try mediaExpect(library.scope == .group(group.id) && library.title == "录音", "creating a group must select it and update the content title")
        await library.importURLs([fixture.audio]) { changes += 1 }
        try mediaExpect(library.items.count == 1 && library.visibleItems.count == 1 && library.items[0].groupID == group.id,
                        "imports must immediately appear in the current sidebar group")
        let item = library.items[0]
        try await library.saveIntroduction("可搜索的音乐介绍", for: item) { changes += 1 }
        try mediaExpect(library.items[0].groupID == group.id, "editing introductions must keep the selected group")
        library.search = "音乐介绍"
        library.filter = .video
        try mediaExpect(library.visibleItems.isEmpty, "media type filtering must apply within the selected group")
        library.filter = .audio
        try mediaExpect(library.visibleItems.count == 1, "group scope and introduction search must compose")
        library.scope = .defaultGroup
        try mediaExpect(library.visibleItems.isEmpty, "default must exclude manually grouped media")
        await library.move([item.media], to: nil) { changes += 1 }
        try mediaExpect(library.visibleItems.count == 1, "moving to default must refresh both sidebar and cards")
        await library.saveGroup(name: "音乐", group: group) { changes += 1 }
        try mediaExpect(library.groups.first?.name == "音乐", "renaming must refresh sidebar labels")
        await library.move([item.media], to: group.id) { changes += 1 }
        library.scope = .group(group.id)
        await library.deleteGroup(group) { changes += 1 }
        try mediaExpect(library.scope == .defaultGroup && library.visibleItems.count == 1 && library.groups.isEmpty,
                        "deleting the selected group must reveal its media in default")
        try mediaExpect(changes == 7 && library.errorMessage == nil && !library.isBusy, "every successful mutation must schedule backup and release busy state")
        await library.saveGroup(name: " ") { changes += 1 }
        try mediaExpect(changes == 7 && library.errorMessage != nil && !library.isBusy, "invalid edits must report an error and skip backup")
        app.section = .articles
        app.section = .mediaLibrary
        try mediaExpect(app.mediaLibrary === library && library.scope == .defaultGroup, "navigating away and back must preserve the selected media group")
        let other = LocalBlogStore(rootURL: fixture.root.appendingPathComponent("other"))
        app.store = other
        await app.mediaLibrary.load()
        try mediaExpect(app.mediaLibrary !== library && app.mediaLibrary.groups.isEmpty && app.mediaLibrary.items.isEmpty && app.mediaLibrary.scope == .all,
                        "switching workspace must replace shared media state, including its filters and selection")
        await store.closeForRestore()
        await other.closeForRestore()
    }

    private func fixture() throws -> (root: URL, audio: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leon-media-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent("录音 & 一.MP3")
        let source = Bundle.module.url(forResource: "article-audio-silence", withExtension: "mp3", subdirectory: "Fixtures")!
        try FileManager.default.copyItem(at: source, to: audio)
        return (root, audio)
    }

    func testImportsPersistNamesAndSurviveAttachmentCleanup() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let video = fixture.root.appendingPathComponent("旅行.mp4")
        let videoSource = Bundle.module.url(forResource: "media-library-sample", withExtension: "mp4", subdirectory: "Fixtures")!
        try FileManager.default.copyItem(at: videoSource, to: video)
        let workspace = fixture.root.appendingPathComponent("workspace")
        let store = LocalBlogStore(rootURL: workspace)
        try await store.importLibraryMedia([fixture.audio, video])
        let items = try await store.mediaLibraryItems()
        try mediaExpect(items.count == 2, "video and MP3 must both appear after import")
        try mediaExpect(Set(items.map(\.media.name)) == [fixture.audio.lastPathComponent, video.lastPathComponent], "original names must survive UUID storage")
        try mediaExpect(Set(items.map(\.media.kind)) == ["audio", "video"], "the library must distinguish video and audio")
        try await store.discardUnreferencedMedia(items.map(\.media))
        for item in items {
            let url = await store.mediaURL(for: item.id)!
            try mediaExpect(FileManager.default.fileExists(atPath: url.path), "attachment cleanup must preserve library ownership")
            try mediaExpect(item.media.size > 0, "cards must expose real file sizes")
        }
        let article = try await store.saveArticle(NativeSaveArticle(
            banner: nil, body: "<p>影音引用</p>", category: "", excerpt: "", media: items.map(\.media),
            slug: "media-reference", status: .draft, tags: [], title: "影音引用", expectedUpdatedAt: nil
        ))
        try await store.deleteArticle(slug: article.slug, expectedUpdatedAt: article.updatedAt)
        try await store.emptyTrash()
        await store.closeForRestore()
        let reopened = LocalBlogStore(rootURL: workspace)
        let restored = try await reopened.mediaLibraryItems()
        try mediaExpect(Set(restored) == Set(items), "names, kinds, and original files must survive reopen and article deletion")
        await reopened.closeForRestore()
        let other = LocalBlogStore(rootURL: fixture.root.appendingPathComponent("other"))
        let isolated = try await other.mediaLibraryItems()
        try mediaExpect(isolated.isEmpty, "users must have separate media libraries")
        await other.closeForRestore()
        try mediaExpect(FileManager.default.fileExists(atPath: fixture.audio.path), "import must preserve the original audio")
    }

    func testRejectsInvalidBatchesAndScansExistingAttachments() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = LocalBlogStore(rootURL: fixture.root.appendingPathComponent("workspace"))
        let uploaded = try await store.uploadMedia(fileURL: fixture.audio, kind: "audio", slug: "moments")
        let audio = NativeMedia(kind: "audio", name: uploaded.name, size: uploaded.size, url: uploaded.url)
        _ = try await store.saveMoment(text: "音频", textRuns: [], images: [audio])
        let initial = try await store.mediaLibraryItems()
        try mediaExpect(initial.count == 1 && initial[0].media.name == fixture.audio.lastPathComponent, "existing attachments must be listed with their display names")
        let broken = fixture.root.appendingPathComponent("broken.mp4")
        try Data("not a video".utf8).write(to: broken)
        let unsupported = fixture.root.appendingPathComponent("note.txt")
        try Data("text".utf8).write(to: unsupported)
        let disguised = fixture.root.appendingPathComponent("audio.mp4")
        try FileManager.default.copyItem(at: fixture.audio, to: disguised)
        for invalid in [broken, unsupported, disguised, fixture.root.appendingPathComponent("missing.mp3"), URL(string: "https://example.com/test.mp3")!] {
            do {
                try await store.importLibraryMedia([fixture.audio, invalid])
                throw MediaLibraryTestFailure(description: "invalid batch was accepted: \(invalid)")
            } catch is MediaLibraryTestFailure { throw MediaLibraryTestFailure(description: "invalid batch was accepted") }
            catch { }
            let unchanged = try await store.mediaLibraryItems()
            try mediaExpect(unchanged == initial, "failed batches must not leave partial imports")
        }
        let directory = fixture.root.appendingPathComponent("workspace/media/moments")
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("external.mp3"), withDestinationURL: fixture.audio)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("workspace/media/external"), withDestinationURL: fixture.root)
        let safe = try await store.mediaLibraryItems()
        try mediaExpect(safe == initial, "scanning must not follow external symlinks")
        await store.closeForRestore()
    }

    func testFilteringAndNaturalStableSort() throws {
        let items = [
            NativeLibraryMedia(media: NativeMedia(kind: "video", name: "Trip 10.mp4", size: 3, url: "c"), modifiedAt: Date(timeIntervalSince1970: 3), introduction: "Forest walk 森林漫步"),
            NativeLibraryMedia(media: NativeMedia(kind: "audio", name: "Trip 2.mp3", size: 2, url: "a"), modifiedAt: Date(timeIntervalSince1970: 1)),
            NativeLibraryMedia(media: NativeMedia(kind: "video", name: "山.mov", size: 1, url: "b"), modifiedAt: Date(timeIntervalSince1970: 3)),
        ]
        let searched = NativeMediaLibraryProjection.items(items, filter: .all, search: " trip ", sort: .name)
        try mediaExpect(searched.map(\.id) == ["a", "c"], "search must trim whitespace, ignore case, and use natural name ordering")
        let videos = NativeMediaLibraryProjection.items(items, filter: .video, search: "", sort: .newest)
        try mediaExpect(videos.map(\.id) == ["b", "c"], "equal dates must use a stable tie break")
        let audio = NativeMediaLibraryProjection.items(items, filter: .audio, search: "", sort: .oldest)
        try mediaExpect(audio.map(\.id) == ["a"], "audio filter must exclude videos")
        let introduced = NativeMediaLibraryProjection.items(items, filter: .all, search: " forest ", sort: .name)
        try mediaExpect(introduced.map(\.id) == ["c"], "search must match introduction text")
        let filtered = NativeMediaLibraryProjection.items(items, filter: .audio, search: "森林", sort: .name)
        try mediaExpect(filtered.isEmpty, "introduction search must still honor media type")
    }

    func testIntroductionMigrationPersistenceAndClearing() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let workspace = fixture.root.appendingPathComponent("workspace")
        let directory = workspace.appendingPathComponent("media/media-library")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceVideo = Bundle.module.url(forResource: "media-library-sample", withExtension: "mp4", subdirectory: "Fixtures")!
        try FileManager.default.copyItem(at: fixture.audio, to: directory.appendingPathComponent("old.mp3"))
        try FileManager.default.copyItem(at: sourceVideo, to: directory.appendingPathComponent("old.mp4"))
        let oldDatabase = try SQLiteDatabase(url: workspace.appendingPathComponent("leon-book.sqlite"))
        try oldDatabase.execute("""
        CREATE TABLE media_library_items(url TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, kind TEXT NOT NULL);
        INSERT INTO media_library_items VALUES('/media/media-library/old.mp3', '录音.mp3', 'audio');
        INSERT INTO media_library_items VALUES('/media/media-library/old.mp4', '旅行.mp4', 'video');
        """)
        oldDatabase.close()

        let store = LocalBlogStore(rootURL: workspace)
        let migrated = try await store.mediaLibraryItems()
        try mediaExpect(migrated.count == 2 && migrated.allSatisfy { $0.introduction.isEmpty }, "existing libraries must migrate to empty introductions without losing files")
        let audio = migrated.first { $0.media.isAudio }!
        let video = migrated.first { $0.media.isVideo }!
        let audioText = "第一段：音乐与录音 🎵\n第二段：'引号' & 说明"
        let videoText = "一次旅行的视频介绍。"
        try await store.saveMediaIntroduction("  \(audioText)\n", for: audio.media)
        try await store.saveMediaIntroduction(videoText, for: video.media)
        await store.closeForRestore()

        let reopened = LocalBlogStore(rootURL: workspace)
        let restored = try await reopened.mediaLibraryItems()
        try mediaExpect(restored.first { $0.id == audio.id }?.introduction == audioText, "multiline Unicode introductions must survive reopening")
        try mediaExpect(restored.first { $0.id == video.id }?.introduction == videoText, "each video must retain its own introduction")
        try await reopened.saveMediaIntroduction(" \n ", for: audio.media)
        let cleared = try await reopened.mediaLibraryItems()
        try mediaExpect(cleared.first { $0.id == audio.id }?.introduction == "", "users must be able to clear an introduction")
        try mediaExpect(cleared.first { $0.id == video.id }?.introduction == videoText, "clearing audio must preserve other descriptions")
        try mediaExpect(try Data(contentsOf: directory.appendingPathComponent("old.mp3")) == Data(contentsOf: fixture.audio), "editing introductions must preserve media bytes")
        await reopened.closeForRestore()
    }

    @MainActor
    func testIntroductionEditingRefreshesCardsAndKeepsAttachmentIdentity() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = LocalBlogStore(rootURL: fixture.root.appendingPathComponent("workspace"))
        let upload = try await store.uploadMedia(fileURL: fixture.audio, kind: "audio")
        let library = NativeMediaLibraryModel(store: store)
        await library.load()
        let item = library.items[0]
        var changes = 0
        try await library.saveIntroduction("录音的详细介绍", for: item) { changes += 1 }
        try mediaExpect(changes == 1 && library.items[0].introduction == "录音的详细介绍" && !library.isBusy, "saving must update cards immediately and schedule backup")
        library.search = "详细介绍"
        try mediaExpect(library.visibleItems.count == 1, "the updated introduction must be searchable immediately")
        let article = try await store.saveArticle(NativeSaveArticle(
            banner: nil, body: "<p>附件介绍</p>", category: "", excerpt: "", media: [item.media],
            slug: "introduced-audio", status: .draft, tags: [], title: "附件介绍", expectedUpdatedAt: nil
        ))
        try mediaExpect(article.media[0].url == upload.url, "annotated inbox media must keep its URL when attached to an article")
        await library.load()
        try mediaExpect(library.items[0].introduction == "录音的详细介绍", "refreshing attachments must keep introductions")
        let invalid = NativeLibraryMedia(media: NativeMedia(kind: "audio", name: "outside.mp3", size: 1, url: fixture.audio.absoluteString), modifiedAt: .distantPast)
        do {
            try await library.saveIntroduction("outside", for: invalid) { changes += 1 }
            throw MediaLibraryTestFailure(description: "external media must not accept introductions")
        } catch NativeStoreError.fileSystem { }
        try mediaExpect(changes == 1 && !library.isBusy && library.items[0].introduction == "录音的详细介绍", "failed saves must preserve introductions, release busy state, and skip backup")
        await store.closeForRestore()
    }

    @MainActor
    func testAudioPlaybackLifecycleAndLibraryRefresh() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = LocalBlogStore(rootURL: fixture.root.appendingPathComponent("workspace"))
        let library = NativeMediaLibraryModel(store: store)
        var changes = 0
        await library.importURLs([fixture.audio]) { changes += 1 }
        try mediaExpect(changes == 1 && library.items.count == 1 && !library.isBusy, "successful import must refresh cards and notify backup")
        let playback = NativeInlineVideoPlayerModel(mediaID: library.items[0].id, isAudio: true)
        await playback.resolve(using: store)
        try mediaExpect(playback.phase == .poster && playback.poster == nil && playback.player == nil, "audio resolution must skip video decoding and player allocation")
        await playback.play()
        for _ in 0..<200 {
            if playback.phase == .ready { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try mediaExpect(playback.phase == .ready && playback.player != nil, "MP3 must prepare the native player")
        let player = playback.player!
        playback.release()
        try mediaExpect(playback.player == nil && player.currentItem == nil && player.rate == 0, "closing playback must pause and detach the native player")
        await library.importURLs([fixture.root.appendingPathComponent("missing.mp3")]) { changes += 1 }
        try mediaExpect(changes == 1 && library.items.count == 1 && library.errorMessage != nil && !library.isBusy, "failed imports must retain the list and expose an error without scheduling backup")
        await store.closeForRestore()
    }

    @MainActor
    func testVideoPosterPlaybackAndRelease() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let video = Bundle.module.url(forResource: "media-library-sample", withExtension: "mp4", subdirectory: "Fixtures")!
        let store = LocalBlogStore(rootURL: fixture.root.appendingPathComponent("workspace"))
        try await store.importLibraryMedia([video])
        let item = try await store.mediaLibraryItems()[0]
        let playback = NativeInlineVideoPlayerModel(mediaID: item.id)
        await playback.resolve(using: store)
        try mediaExpect(playback.phase == .poster && playback.poster != nil && playback.player == nil, "video must show a decoded poster before creating a player")
        await playback.play()
        for _ in 0..<200 {
            if playback.phase == .ready { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try mediaExpect(playback.phase == .ready && playback.duration > 0, "MP4 must become playable with a valid duration")
        let player = playback.player!
        playback.release()
        try mediaExpect(playback.player == nil && player.currentItem == nil && player.rate == 0, "closing video must release decoding resources")
        await store.closeForRestore()
    }
}
