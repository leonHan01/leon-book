import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class NativeMediaLibraryModel: ObservableObject {
    let store: LocalBlogStore
    let workspace: String
    @Published private(set) var groups: [NativeMediaGroup] = []
    @Published private(set) var items: [NativeLibraryMedia] = []
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published var filter: NativeMediaLibraryFilter = .all
    @Published var search = ""
    @Published var sort: NativeMediaLibrarySort = .newest
    @Published var scope: NativeMediaLibraryScope = .all

    init(store: LocalBlogStore) {
        self.store = store
        workspace = store.rootURL.path
    }

    var visibleItems: [NativeLibraryMedia] {
        NativeMediaLibraryProjection.items(items, scope: scope, filter: filter, search: search, sort: sort)
    }

    var title: String {
        switch scope {
        case .all: return localized("影音库")
        case .defaultGroup: return localized("默认分组")
        case let .group(id): return groups.first { $0.id == id }?.name ?? localized("影音库")
        }
    }

    func load() async {
        await perform { try await self.reload() }
    }

    func importFiles(onChange: @escaping () -> Void) {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["mp4", "mov", "m4v", "mp3", "m4a", "aac", "wav", "aif", "aiff", "caf"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = NativeLocalization.string(NativeLocalization.text("选择要导入影音库的视频或音频"), language: NativeLocalization.currentLanguage)
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await importURLs(urls, onChange: onChange) }
    }

    func importURLs(_ urls: [URL], onChange: () -> Void) async {
        guard !urls.isEmpty else { return }
        let groupID = scope.groupID
        await perform {
            try await self.store.importLibraryMedia(urls, toGroup: groupID)
            onChange()
            try await self.reload()
        }
    }

    func acceptDrop(_ providers: [NSItemProvider], onChange: @escaping () -> Void) -> Bool {
        guard !isBusy else { return false }
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        let groupID = scope.groupID
        Task {
            await perform {
                var urls: [URL] = []
                for provider in files {
                    let data: Data = try await withCheckedThrowingContinuation { continuation in
                        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                            if let error { continuation.resume(throwing: error) }
                            else if let data { continuation.resume(returning: data) }
                            else { continuation.resume(throwing: NativeStoreError.fileSystem(NativeLocalization.text("无法读取拖入的文件。"))) }
                        }
                    }
                    guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                        throw NativeStoreError.fileSystem(NativeLocalization.text("无法读取拖入的文件。"))
                    }
                    if !urls.contains(url) { urls.append(url) }
                }
                try await self.store.importLibraryMedia(urls, toGroup: groupID)
                onChange()
                try await self.reload()
            }
        }
        return true
    }

    func editGroup(_ group: NativeMediaGroup? = nil, onChange: @escaping () -> Void) {
        guard !isBusy else { return }
        let field = NSTextField(string: group?.name ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        field.placeholderString = localized(NativeLocalization.text("分组名称"))
        let alert = NSAlert()
        alert.messageText = localized(group == nil ? NativeLocalization.text("新建影音分组") : NativeLocalization.text("重命名影音分组"))
        alert.accessoryView = field
        alert.addButton(withTitle: localized("保存"))
        alert.addButton(withTitle: localized("取消"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue
        Task { await saveGroup(name: name, group: group, onChange: onChange) }
    }

    func saveGroup(name: String, group: NativeMediaGroup? = nil, onChange: () -> Void) async {
        await perform {
            if let group {
                try await self.store.renameMediaGroup(id: group.id, name: name)
            } else {
                let created = try await self.store.createMediaGroup(name: name)
                self.scope = .group(created.id)
            }
            onChange()
            try await self.reload()
        }
    }

    func confirmDeleteGroup(_ group: NativeMediaGroup, onChange: @escaping () -> Void) {
        guard !isBusy else { return }
        let alert = NSAlert()
        alert.messageText = localized(NativeLocalization.text("删除影音分组"))
        alert.informativeText = group.name + "\n\n" + localized(NativeLocalization.text("分组内的影音会移入默认分组，文件和文章引用会保留。"))
        alert.addButton(withTitle: localized("删除分组"))
        alert.addButton(withTitle: localized("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await deleteGroup(group, onChange: onChange) }
    }

    func deleteGroup(_ group: NativeMediaGroup, onChange: () -> Void) async {
        await perform {
            try await self.store.deleteMediaGroup(id: group.id)
            onChange()
            try await self.reload()
        }
    }

    func move(_ media: [NativeMedia], to groupID: String?, onChange: () -> Void) async {
        await perform {
            try await self.store.moveLibraryMedia(media, toGroup: groupID)
            onChange()
            try await self.reload()
        }
    }

    func reveal(_ media: NativeMedia) {
        Task {
            if let url = await store.mediaURL(for: media.url) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    func saveIntroduction(_ introduction: String, for item: NativeLibraryMedia, onChange: () -> Void) async throws {
        guard !isBusy else { throw NativeStoreError.fileSystem(NativeLocalization.text("影音库正在处理其他操作，请稍后重试。")) }
        isBusy = true
        defer { isBusy = false }
        let saved = try await store.saveMediaIntroduction(introduction, for: item.media)
        items = items.map {
            $0.id == item.id ? NativeLibraryMedia(media: $0.media, modifiedAt: $0.modifiedAt,
                                                 introduction: saved, groupID: $0.groupID) : $0
        }
        onChange()
    }

    private func reload() async throws {
        let snapshot = try await store.mediaLibrarySnapshot()
        try Task.checkCancellation()
        groups = snapshot.groups
        items = snapshot.items
        if let id = scope.groupID, !groups.contains(where: { $0.id == id }) { scope = .defaultGroup }
    }

    private func localized(_ text: String) -> String {
        NativeLocalization.string(text, language: NativeLocalization.currentLanguage)
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
