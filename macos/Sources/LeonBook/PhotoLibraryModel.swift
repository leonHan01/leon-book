import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let leonBookPhotos = UTType(exportedAs: "com.leon-book.photos", conformingTo: .data)
}

private struct NativePhotoDragPayload: Codable {
    let workspace: String
    let urls: [String]
}

@MainActor
final class NativePhotoLibraryModel: ObservableObject {
    let store: LocalBlogStore
    let workspace: String
    @Published private(set) var albums: [NativePhotoAlbum] = []
    @Published private(set) var photos: [NativeLibraryPhoto] = [] {
        didSet {
            albumCounts = photos.reduce(into: [:]) { $0[$1.albumID, default: 0] += 1 }
            rebuildProjection(clearResults: false)
        }
    }
    @Published private(set) var isBusy = false
    @Published private(set) var isProjecting = false
    @Published private(set) var visiblePhotos: [NativeLibraryPhoto] = []
    @Published var errorMessage: String?
    @Published var scope: NativePhotoScope = .all {
        didSet { if scope != oldValue { rebuildProjection() } }
    }
    @Published var search = "" {
        didSet { if search != oldValue { rebuildProjection() } }
    }
    @Published var sort: NativePhotoSort = .newest {
        didSet { if sort != oldValue { rebuildProjection(clearResults: false) } }
    }
    @Published var selection: Set<String> = []
    private var selectionAnchor: String?
    private var albumCounts: [String?: Int] = [:]
    private var projectionTask: Task<Void, Never>?
    private var hasLoaded = false

    init(store: LocalBlogStore, workspace: String) {
        self.store = store
        self.workspace = workspace
    }

    deinit { projectionTask?.cancel() }

    func photoCount(in albumID: String?) -> Int {
        albumCounts[albumID, default: 0]
    }

    private func rebuildProjection(clearResults: Bool = true) {
        projectionTask?.cancel()
        if clearResults || photos.isEmpty { visiblePhotos = [] }
        isProjecting = !photos.isEmpty
        guard isProjecting else {
            projectionTask = nil
            return
        }
        let worker = Task.detached(priority: .userInitiated) { [photos, scope, search, sort] in
            try? NativePhotoLibraryProjection.photos(photos, scope: scope, search: search, sort: sort)
        }
        projectionTask = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self else { return }
            self.visiblePhotos = result ?? []
            self.isProjecting = false
            self.projectionTask = nil
        }
    }

    var title: String {
        switch scope {
        case .all: return NativeLocalization.string("全部图片", language: NativeLocalization.currentLanguage)
        case .unfiled: return NativeLocalization.string("未分类", language: NativeLocalization.currentLanguage)
        case let .album(id): return albums.first { $0.id == id }?.name ?? "相册"
        }
    }

    func load() async {
        await perform { try await self.reload() }
    }

    private func reload(reuseFiles: Bool = false) async throws {
        let snapshot = try await store.photoLibrarySnapshot(reusing: reuseFiles && hasLoaded ? photos : nil)
        try Task.checkCancellation()
        if albums != snapshot.albums { albums = snapshot.albums }
        if let id = scope.albumID, !albums.contains(where: { $0.id == id }) { scope = .all }
        if photos != snapshot.photos {
            photos = snapshot.photos
            if !selection.isEmpty { selection.formIntersection(Set(photos.map(\.id))) }
        }
        hasLoaded = true
    }

    func show(_ scope: NativePhotoScope) {
        self.scope = scope
        selection = []
        selectionAnchor = nil
    }

    func select(_ photo: NativeLibraryPhoto, in visible: [NativeLibraryPhoto]) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift), let anchor = selectionAnchor,
           let start = visible.firstIndex(where: { $0.id == anchor }),
           let end = visible.firstIndex(where: { $0.id == photo.id }) {
            selection.formUnion(visible[min(start, end)...max(start, end)].map(\.id))
        } else if modifiers.contains(.command) {
            if selection.contains(photo.id) { selection.remove(photo.id) } else { selection.insert(photo.id) }
            selectionAnchor = photo.id
        } else {
            selection = [photo.id]
            selectionAnchor = photo.id
        }
    }

    func contextualPhotos(_ photo: NativeLibraryPhoto) -> [NativeMedia] {
        let ids = selection.contains(photo.id) ? selection : [photo.id]
        return photos.filter { ids.contains($0.id) }.map(\.media)
    }

    func dragProvider(for photo: NativeLibraryPhoto) -> NSItemProvider {
        let payload = NativePhotoDragPayload(workspace: workspace, urls: contextualPhotos(photo).map(\.url))
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        let provider = NSItemProvider()
        provider.suggestedName = photo.media.name
        provider.registerDataRepresentation(forTypeIdentifier: UTType.leonBookPhotos.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    func acceptDrop(_ providers: [NSItemProvider], to albumID: String?, onChange: @escaping () -> Void) -> Bool {
        guard !isBusy else { return false }
        guard providers.contains(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.leonBookPhotos.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else { return false }
        Task { await receiveDrop(providers, to: albumID, onChange: onChange) }
        return true
    }

    func receiveDrop(_ providers: [NSItemProvider], to albumID: String?, onChange: () -> Void) async {
        let internalProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.leonBookPhotos.identifier) }
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !internalProviders.isEmpty || !fileProviders.isEmpty else { return }
        await perform {
            if !internalProviders.isEmpty {
                var ids = Set<String>()
                for provider in internalProviders {
                    let data = try await self.loadData(provider, type: .leonBookPhotos)
                    let payload = try JSONDecoder().decode(NativePhotoDragPayload.self, from: data)
                    guard payload.workspace == self.workspace else {
                        throw NativeStoreError.fileSystem(NativeLocalization.text("请在图片所属的工作区内整理相册。"))
                    }
                    ids.formUnion(payload.urls)
                }
                let media = self.photos.filter { ids.contains($0.id) }.map(\.media)
                guard media.count == ids.count else { throw NativeStoreError.notFound }
                try await self.store.movePhotos(media, toAlbum: albumID)
            } else {
                var urls: [URL] = []
                for provider in fileProviders {
                    let data = try await self.loadData(provider, type: .fileURL)
                    guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                        throw NativeStoreError.fileSystem(NativeLocalization.text("无法读取拖入的文件。"))
                    }
                    if !urls.contains(url) { urls.append(url) }
                }
                try await self.store.importLibraryPhotos(urls, toAlbum: albumID)
            }
            onChange()
            self.selection = []
            try await self.reload(reuseFiles: !internalProviders.isEmpty)
        }
    }

    func importPhotos(onChange: @escaping () -> Void) {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = NativeLocalization.text("选择要导入相册的图片")
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls, albumID = scope.albumID
        Task {
            await perform {
                try await self.store.importLibraryPhotos(urls, toAlbum: albumID)
                onChange()
                try await self.reload()
            }
        }
    }

    func editAlbum(_ album: NativePhotoAlbum? = nil, onChange: @escaping () -> Void) {
        guard !isBusy else { return }
        let field = NSTextField(string: album?.name ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        field.placeholderString = NativeLocalization.text("相册名称")
        let alert = NSAlert()
        alert.messageText = album == nil ? NativeLocalization.text("新建相册") : NativeLocalization.text("重命名相册")
        alert.accessoryView = field
        alert.addButton(withTitle: NativeLocalization.text("保存"))
        alert.addButton(withTitle: NativeLocalization.text("取消"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue
        Task {
            await perform {
                if let album { try await self.store.renamePhotoAlbum(id: album.id, name: name) }
                else {
                    let created = try await self.store.createPhotoAlbum(name: name)
                    self.show(.album(created.id))
                }
                onChange()
                try await self.reload(reuseFiles: true)
            }
        }
    }

    func deleteAlbum(_ album: NativePhotoAlbum, onChange: @escaping () -> Void) {
        guard !isBusy else { return }
        let alert = NSAlert()
        alert.messageText = NativeLocalization.text("删除相册“\(album.name)”？")
        alert.informativeText = NativeLocalization.text("相册内的图片会回到“未分类”，图片文件和文章引用会保留。")
        alert.addButton(withTitle: NativeLocalization.text("删除相册"))
        alert.addButton(withTitle: NativeLocalization.text("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            await perform {
                try await self.store.deletePhotoAlbum(id: album.id)
                onChange()
                try await self.reload(reuseFiles: true)
            }
        }
    }

    func move(_ media: [NativeMedia], to albumID: String?, onChange: @escaping () -> Void) {
        Task {
            await perform {
                try await self.store.movePhotos(media, toAlbum: albumID)
                onChange()
                self.selection = []
                let ids = Set(self.photos.map(\.id))
                try await self.reload(reuseFiles: media.allSatisfy { ids.contains($0.url) })
            }
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do { try await operation() }
        catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }

    private func loadData(_ provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? NativeStoreError.fileSystem(NativeLocalization.text("无法读取拖拽内容。"))) }
            }
        }
    }
}
