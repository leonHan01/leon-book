import AppKit
import Foundation
import SwiftUI

@MainActor
final class NativeAppModel: ObservableObject {
    @Published var section: NativeSection = .dashboard
    @Published private(set) var articles: [NativeArticleSummary] = []
    @Published private(set) var activity: [NativeActivityDay] = []
    @Published private(set) var moments: [NativeMoment] = []
    @Published private(set) var trashItems: [NativeTrashItem] = []
    @Published private(set) var selectedArticle: NativeArticle?
    @Published var selectedSlug: String?
    @Published var editor = NativeEditorDraft()
    @Published var momentDraft = NativeMomentDraft()
    @Published private(set) var editingMomentID: String?
    @Published private(set) var isLoading = true
    @Published private(set) var isPublishingMoment = false
    @Published private(set) var isSaving = false
    @Published private(set) var storageReady = false
    @Published private(set) var users: [NativeUser] = []
    @Published private(set) var currentUser = NativeUser.leon
    @Published private(set) var isSwitchingWorkspace = false
    @Published private(set) var dataDirectoryPath = LocalBlogStore.defaultRootURL.path
    @Published var errorMessage: String?
    @Published var searchText = ""

    private let userWorkspaces: UserWorkspaceStore
    private(set) var store: LocalBlogStore
    private var trashCleanupTask: Task<Void, Never>?

    init() {
        let rootURL = LocalBlogStore.defaultRootURL
        userWorkspaces = UserWorkspaceStore(rootURL: rootURL)
        store = LocalBlogStore(rootURL: rootURL)
        Task { await start() }
    }

    deinit {
        trashCleanupTask?.cancel()
    }

    var publishedArticles: [NativeArticleSummary] {
        articles.filter { $0.status == .published }
    }

    var draftArticles: [NativeArticleSummary] {
        articles.filter { $0.status == .draft }
    }

    var filteredArticles: [NativeArticleSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return articles }
        return articles.filter {
            $0.title.lowercased().contains(query)
                || $0.category.lowercased().contains(query)
                || $0.tags.joined(separator: " ").lowercased().contains(query)
        }
    }

    func start() async {
        isLoading = true
        do {
            let workspace = try await userWorkspaces.prepare()
            try await loadWorkspace(workspace)
            storageReady = true
            startTrashCleanupLoop()
        } catch {
            storageReady = false
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func selectUser(_ user: NativeUser) {
        guard user.id != currentUser.id, !isSwitchingWorkspace, !isSaving, !isPublishingMoment else { return }
        Task {
            isSwitchingWorkspace = true
            isLoading = true
            defer {
                isSwitchingWorkspace = false
                isLoading = false
            }
            do {
                let workspace = try await userWorkspaces.selectUser(id: user.id)
                try await loadWorkspace(workspace)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func createUser(named name: String) async -> Bool {
        guard !isSwitchingWorkspace, !isSaving, !isPublishingMoment else { return false }
        isSwitchingWorkspace = true
        isLoading = true
        defer {
            isSwitchingWorkspace = false
            isLoading = false
        }
        do {
            let workspace = try await userWorkspaces.createUser(named: name)
            try await loadWorkspace(workspace)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func reload() async throws {
        articles = try await store.listArticles()
        moments = try await store.listMoments()
        trashItems = try await store.listTrash()
        try await refreshActivity()
        if let selectedSlug, let selected = articles.first(where: { $0.slug == selectedSlug }) {
            try await select(selected)
        }
    }

    private func loadWorkspace(_ workspace: NativeWorkspaceState) async throws {
        let nextStore = LocalBlogStore(rootURL: workspace.workspaceURL)
        try await nextStore.prepare()
        store = nextStore
        users = workspace.users
        currentUser = workspace.activeUser
        dataDirectoryPath = workspace.workspaceURL.path
        articles = []
        moments = []
        trashItems = []
        activity = []
        selectedArticle = nil
        selectedSlug = nil
        editor = NativeEditorDraft()
        momentDraft = NativeMomentDraft()
        editingMomentID = nil
        searchText = ""
        section = .dashboard
        try await reload()
    }

    private func refreshActivity() async throws {
        activity = try await store.listActivity(since: activityWindowStart())
    }

    func select(_ summary: NativeArticleSummary) async throws {
        selectedSlug = summary.slug
        selectedArticle = try await store.getArticle(slug: summary.slug)
        section = .reader
        errorMessage = nil
    }

    func selectSlug(_ slug: String?) {
        guard let slug, let summary = articles.first(where: { $0.slug == slug }) else { return }
        Task {
            do { try await select(summary) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func newArticle() {
        selectedSlug = nil
        selectedArticle = nil
        editor = NativeEditorDraft()
        section = .editor
        errorMessage = nil
    }

    func editSelected() {
        guard let article = selectedArticle else { return }
        editor = NativeEditorDraft(
            slug: article.slug,
            title: article.title,
            category: article.category,
            excerpt: article.excerpt,
            tags: article.tags.joined(separator: ", "),
            body: article.body,
            banner: article.banner,
            media: article.media,
            status: article.status,
            updatedAt: article.updatedAt
        )
        section = .editor
    }

    func saveEditor(as status: NativeArticleStatus) async {
        let title = editor.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = editor.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !body.isEmpty else {
            errorMessage = NativeStoreError.invalidArticle.localizedDescription
            return
        }

        isSaving = true
        defer { isSaving = false }
        let slug = editor.slug.isEmpty ? slugify(title) : editor.slug
        let tags = editor.tags.split(whereSeparator: { ",，\n".contains($0) }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "") }.filter { !$0.isEmpty }
        let payload = NativeSaveArticle(
            banner: editor.banner,
            body: editor.body,
            category: editor.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Notes" : editor.category.trimmingCharacters(in: .whitespacesAndNewlines),
            excerpt: editor.excerpt,
            media: editor.media,
            slug: slug,
            status: status,
            tags: Array(Array(Set(tags)).prefix(12)),
            title: title,
            expectedUpdatedAt: editor.updatedAt
        )

        do {
            let saved = try await store.saveArticle(payload)
            editor.slug = saved.slug
            editor.status = saved.status
            editor.updatedAt = saved.updatedAt
            selectedSlug = saved.slug
            selectedArticle = saved
            try await reload()
            section = .reader
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSelected() async {
        guard let article = selectedArticle else { return }
        do {
            try await store.deleteArticle(slug: article.slug, expectedUpdatedAt: article.updatedAt)
            selectedArticle = nil
            selectedSlug = nil
            section = .articles
            try await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreTrash(_ item: NativeTrashItem) {
        Task {
            do {
                try await store.restoreTrash(item)
                try await reload()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func permanentlyDeleteTrash(_ item: NativeTrashItem) {
        Task {
            do {
                try await store.permanentlyDeleteTrash(item)
                try await reload()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func emptyTrash() {
        Task {
            do {
                try await store.emptyTrash()
                try await reload()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func chooseAndUpload(kind: String, forArticle slug: String? = nil, banner: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = kind == "video" ? [.movie] : [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let uploaded = try await store.uploadMedia(fileURL: url, kind: kind, slug: slug)
                if banner {
                    editor.banner = NativeBanner(alt: url.deletingPathExtension().lastPathComponent, name: uploaded.name, size: uploaded.size, url: uploaded.url)
                } else {
                    editor.media.append(NativeMedia(kind: uploaded.kind, name: uploaded.name, size: uploaded.size, url: uploaded.url))
                }
                try await refreshActivity()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func chooseMomentImages() {
        let remaining = max(0, 9 - momentDraft.images.count)
        guard remaining > 0 else {
            errorMessage = "每条微博最多添加 9 张图片。"
            return
        }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        let selectedURLs = Array(panel.urls.prefix(remaining))
        guard !selectedURLs.isEmpty else { return }

        Task {
            do {
                var uploadedImages: [NativeMedia] = []
                for fileURL in selectedURLs {
                    let uploaded = try await store.uploadMedia(fileURL: fileURL, kind: "image", slug: "moments")
                    uploadedImages.append(NativeMedia(kind: uploaded.kind, name: uploaded.name, size: uploaded.size, url: uploaded.url))
                }
                momentDraft.images.append(contentsOf: uploadedImages)
                try await refreshActivity()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func removeMomentImage(_ image: NativeMedia) {
        momentDraft.images.removeAll { $0.id == image.id }
    }

    func beginEditingMoment(_ moment: NativeMoment) {
        guard !isPublishingMoment else { return }
        editingMomentID = moment.id
        momentDraft = NativeMomentDraft(
            text: moment.text,
            textRuns: moment.textRuns,
            images: moment.images
        )
        errorMessage = nil
    }

    func cancelMomentEditing() {
        guard !isPublishingMoment else { return }
        editingMomentID = nil
        momentDraft = NativeMomentDraft()
        errorMessage = nil
    }

    func deleteMoment(_ moment: NativeMoment) {
        if editingMomentID == moment.id {
            cancelMomentEditing()
        }
        Task {
            do {
                try await store.deleteMoment(id: moment.id)
                moments.removeAll { $0.id == moment.id }
                trashItems = try await store.listTrash()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func uploadMomentPastedImages(_ images: [NSImage]) {
        let remaining = max(0, 9 - momentDraft.images.count)
        guard remaining > 0 else {
            errorMessage = "每条微博最多添加 9 张图片。"
            return
        }

        let imagesToUpload = Array(images.prefix(remaining))
        guard !imagesToUpload.isEmpty else { return }

        Task {
            do {
                var uploadedImages: [NativeMedia] = []
                for image in imagesToUpload {
                    guard let imageData = image.pngData else {
                        throw NativeStoreError.fileSystem("无法读取拖入或粘贴的图片。")
                    }
                    let temporaryURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("moment-image-(UUID().uuidString.lowercased()).png")
                    try imageData.write(to: temporaryURL, options: .atomic)
                    defer { try? FileManager.default.removeItem(at: temporaryURL) }

                    let uploaded = try await store.uploadMedia(
                        fileURL: temporaryURL,
                        kind: "image",
                        slug: "moments"
                    )
                    uploadedImages.append(
                        NativeMedia(kind: uploaded.kind, name: uploaded.name, size: uploaded.size, url: uploaded.url)
                    )
                }
                momentDraft.images.append(contentsOf: uploadedImages)
                try await refreshActivity()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func publishMoment() {
        guard !momentDraft.isEmpty else {
            errorMessage = NativeStoreError.invalidMoment.localizedDescription
            return
        }
        guard !isPublishingMoment else { return }
        isPublishingMoment = true

        Task {
            defer { isPublishingMoment = false }
            do {
                let saved: NativeMoment
                if let editingMomentID {
                    saved = try await store.updateMoment(
                        id: editingMomentID,
                        text: momentDraft.text,
                        textRuns: momentDraft.textRuns,
                        images: momentDraft.images
                    )
                    if let index = moments.firstIndex(where: { $0.id == saved.id }) {
                        moments[index] = saved
                    }
                    self.editingMomentID = nil
                } else {
                    saved = try await store.saveMoment(
                        text: momentDraft.text,
                        textRuns: momentDraft.textRuns,
                        images: momentDraft.images
                    )
                    moments.insert(saved, at: 0)
                }
                momentDraft = NativeMomentDraft()
                try await refreshActivity()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func uploadPastedImage(_ image: NSImage, placeholder: String) {
        guard let imageData = image.pngData else {
            replacePastedImage(placeholder, with: "[图片粘贴失败]")
            errorMessage = "无法读取剪贴板中的图片。"
            return
        }

        let filename = "pasted-image-\(UUID().uuidString.lowercased()).png"
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        Task {
            do {
                try imageData.write(to: temporaryURL, options: .atomic)
                defer { try? FileManager.default.removeItem(at: temporaryURL) }

                let uploaded = try await store.uploadMedia(fileURL: temporaryURL, kind: "image", slug: editor.slug)
                editor.media.append(NativeMedia(kind: uploaded.kind, name: uploaded.name, size: uploaded.size, url: uploaded.url))
                replacePastedImage(placeholder, with: "![粘贴的图片](\(uploaded.url))")
                try await refreshActivity()
            } catch {
                replacePastedImage(placeholder, with: "[图片粘贴失败]")
                errorMessage = error.localizedDescription
            }
        }
    }

    func openMedia(_ media: NativeMedia) {
        Task {
            let url = await store.mediaURL(for: media.url)
            NSWorkspace.shared.open(url)
        }
    }

    private func slugify(_ title: String) -> String {
        let value = title.folding(options: .diacriticInsensitive, locale: .current).lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let slug = String(value).split(separator: "-").joined(separator: "-")
        return slug.isEmpty ? "draft-\(Int(Date().timeIntervalSince1970))" : String(slug.prefix(80))
    }

    private func replacePastedImage(_ placeholder: String, with replacement: String) {
        guard editor.body.contains(placeholder) else { return }
        editor.body = editor.body.replacingOccurrences(of: placeholder, with: replacement)
    }

    private func activityWindowStart(now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -364, to: today) ?? today
    }

    private func startTrashCleanupLoop() {
        guard trashCleanupTask == nil else { return }
        trashCleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                try? await self.refreshTrash()
            }
        }
    }

    private func refreshTrash() async throws {
        trashItems = try await store.listTrash()
    }
}

private extension NSImage {
    var pngData: Data? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
