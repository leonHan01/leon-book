import AppKit
import Foundation
import SwiftUI

struct NativeMomentTimelineGroup: Identifiable {
    let id: String
    let label: String
    var moments: [NativeMoment]
}

struct NativeMomentTagFilter: Identifiable, Hashable {
    let tag: String
    let count: Int

    var id: String {
        tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

@MainActor
public final class NativeAppModel: ObservableObject {
    @Published var section: NativeSection = .dashboard
    @Published private(set) var articles: [NativeArticleSummary] = []
    @Published private(set) var activity: [NativeActivityDay] = []
    @Published private(set) var moments: [NativeMoment] = []
    @Published private(set) var totalMomentCount = 0
    @Published private(set) var filteredMomentCount = 0
    @Published private(set) var trashItems: [NativeTrashItem] = []
    @Published private(set) var selectedArticle: NativeArticle?
    @Published var selectedSlug: String?
    @Published var editor = NativeEditorDraft()
    @Published var momentDraft = NativeMomentDraft()
    @Published private(set) var editingMomentID: String?
    @Published private(set) var selectedMomentTags: Set<String> = []
    @Published private(set) var momentDateFilter: NativeMomentDateFilter = .all
    @Published private(set) var showsOnlyFavoriteMoments = false
    @Published private(set) var isLoading = true
    @Published private(set) var isPublishingMoment = false
    @Published private(set) var isLoadingMoreMoments = false
    @Published private(set) var hasMoreMoments = false
    @Published private(set) var isSaving = false
    @Published private(set) var isUploadingMedia = false
    @Published private(set) var storageReady = false
    @Published private(set) var needsWorkDirectorySelection = false
    @Published private(set) var users: [NativeUser] = []
    @Published private(set) var currentUser = NativeUser.leon
    @Published private(set) var isSwitchingWorkspace = false
    @Published private(set) var dataDirectoryPath = LocalBlogStore.defaultRootURL.path
    @Published private(set) var dataRootDirectoryPath = LocalBlogStore.defaultRootURL.path
    @Published private(set) var backupDirectoryPath = LocalBlogStore.savedBackupDirectoryURL?.path ?? ""
    @Published private(set) var lastBackupPath = ""
    @Published private(set) var backupStatus = "尚未生成备份"
    @Published private(set) var isBackingUp = false
    @Published var errorMessage: String?
    @Published var searchText = ""
    @Published var momentSearchText = ""

    private var userWorkspaces: UserWorkspaceStore
    private(set) var store: LocalBlogStore
    private var trashCleanupTask: Task<Void, Never>?
    private var uploadCount = 0
    private var workspaceGeneration = 0
    private var pendingEditorMediaCleanup: [NativeMedia] = []
    private var editorOriginalArticle: NativeArticle?
    private var backupTask: Task<Void, Never>?
    private var momentFacetRecords: [NativeMomentFacetRecord] = []
    private var nextMomentCursor: NativeMomentCursor?
    private var momentFeedGeneration = 0
    private var momentSearchTask: Task<Void, Never>?
    private let momentPageSize = 40

    public init() {
        let rootURL = LocalBlogStore.defaultRootURL
        userWorkspaces = UserWorkspaceStore(rootURL: rootURL)
        store = LocalBlogStore(rootURL: rootURL)
        Task { await start() }
    }

    deinit {
        trashCleanupTask?.cancel()
        backupTask?.cancel()
        momentSearchTask?.cancel()
    }

    private func momentTagIdentifier(_ tag: String) -> String {
        tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
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

    var availableMomentTagFilters: [NativeMomentTagFilter] {
        var filters: [String: NativeMomentTagFilter] = [:]

        for record in momentFacetRecords {
            var countedTags = Set<String>()
            for tag in record.tags {
                let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                let identifier = momentTagIdentifier(normalized)
                guard !normalized.isEmpty, countedTags.insert(identifier).inserted else { continue }

                if let existing = filters[identifier] {
                    filters[identifier] = NativeMomentTagFilter(tag: existing.tag, count: existing.count + 1)
                } else {
                    filters[identifier] = NativeMomentTagFilter(tag: normalized, count: 1)
                }
            }
        }

        return filters.values.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.tag.localizedCaseInsensitiveCompare($1.tag) == .orderedAscending
        }
    }

    var availableMomentTags: [String] {
        availableMomentTagFilters.map(\.tag)
    }

    var filteredMoments: [NativeMoment] {
        moments
    }

    var isFilteringMoments: Bool {
        !selectedMomentTags.isEmpty
            || momentDateFilter != .all
            || showsOnlyFavoriteMoments
            || !momentSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var availableMomentMonths: [NativeMomentMonth] {
        var months = Set<NativeMomentMonth>()
        for record in momentFacetRecords {
            guard let date = NativeTimestamp.date(from: record.createdAt) else { continue }
            let components = Calendar.current.dateComponents([.year, .month], from: date)
            guard let year = components.year, let month = components.month else { continue }
            months.insert(NativeMomentMonth(year: year, month: month))
        }
        return months.sorted {
            $0.year == $1.year ? $0.month > $1.month : $0.year > $1.year
        }
    }

    var availableMomentYears: [Int] {
        Set(availableMomentMonths.map(\.year)).sorted(by: >)
    }

    var momentTimeline: [NativeMomentTimelineGroup] {
        let calendar = Calendar.current
        var groups: [NativeMomentTimelineGroup] = []

        for moment in filteredMoments {
            guard let date = NativeTimestamp.date(from: moment.createdAt) else {
                groups.append(NativeMomentTimelineGroup(
                    id: "unknown-\(moment.id)",
                    label: moment.createdAt.isEmpty ? "未知日期" : moment.createdAt,
                    moments: [moment]
                ))
                continue
            }

            let day = calendar.startOfDay(for: date)
            let id = NativeTimestamp.string(from: day)
            if let lastIndex = groups.indices.last, groups[lastIndex].id == id {
                groups[lastIndex].moments.append(moment)
            } else {
                groups.append(NativeMomentTimelineGroup(
                    id: id,
                    label: timelineDateLabel(for: day, calendar: calendar),
                    moments: [moment]
                ))
            }
        }
        return groups
    }

    func start() async {
        isLoading = true
        defer { isLoading = false }
        guard let rootURL = workDirectoryForStartup() else {
            storageReady = false
            needsWorkDirectorySelection = true
            errorMessage = "未选择工作目录，应用不会创建空数据库。"
            return
        }
        do {
            try await connect(to: rootURL)
            startTrashCleanupLoop()
            scheduleBackup()
        } catch {
            storageReady = false
            errorMessage = error.localizedDescription
        }
    }

    func chooseWorkDirectory() {
        guard !isLoading, !isSwitchingWorkspace, !isSaving, !isPublishingMoment, !isUploadingMedia, !isBackingUp,
              let rootURL = presentWorkDirectoryPicker() else { return }
        LocalBlogStore.rememberWorkDirectory(rootURL)
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                try await connect(to: rootURL)
                startTrashCleanupLoop()
                scheduleBackup()
                errorMessage = nil
            } catch {
                storageReady = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func connect(to rootURL: URL) async throws {
        userWorkspaces = UserWorkspaceStore(rootURL: rootURL)
        store = LocalBlogStore(rootURL: rootURL)
        dataRootDirectoryPath = rootURL.standardizedFileURL.path
        let workspace = try await userWorkspaces.prepare()
        try await loadWorkspace(workspace)
        needsWorkDirectorySelection = false
        storageReady = true
    }

    func chooseBackupDirectory() {
        guard !isBackingUp else { return }
        let panel = NSOpenPanel()
        panel.title = "选择备份目录"
        panel.message = "应用会在此目录中创建带时间戳的完整快照。请优先选择另一块磁盘或启用 FileVault 的磁盘。"
        panel.prompt = "使用此目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = backupDirectoryPath.isEmpty
            ? URL(fileURLWithPath: "/Volumes", isDirectory: true)
            : URL(fileURLWithPath: backupDirectoryPath, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try LocalBackupManager.validateDestination(
                source: URL(fileURLWithPath: dataRootDirectoryPath, isDirectory: true),
                destination: url
            )
            LocalBlogStore.rememberBackupDirectory(url)
            backupDirectoryPath = url.standardizedFileURL.path
            backupStatus = "正在创建首次备份…"
            backupNow()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearBackupDirectory() {
        guard !isBackingUp else { return }
        backupTask?.cancel()
        LocalBlogStore.clearBackupDirectory()
        backupDirectoryPath = ""
        lastBackupPath = ""
        backupStatus = "未设置备份目录"
    }

    func openBackupDirectory() {
        guard !backupDirectoryPath.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: backupDirectoryPath)
    }

    func backupNow() {
        backupTask?.cancel()
        backupTask = Task { [weak self] in
            await self?.performBackup()
        }
    }

    private func scheduleBackup() {
        guard !backupDirectoryPath.isEmpty else { return }
        backupTask?.cancel()
        backupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.performBackup()
        }
    }

    private func performBackup() async {
        guard storageReady, !backupDirectoryPath.isEmpty else { return }
        guard !isBackingUp else { return }
        guard !isLoading, !isSwitchingWorkspace, !isSaving, !isPublishingMoment, !isUploadingMedia else {
            backupStatus = "等待当前操作完成后备份…"
            scheduleBackup()
            return
        }

        let sourceURL = URL(fileURLWithPath: dataRootDirectoryPath, isDirectory: true)
        let destinationURL = URL(fileURLWithPath: backupDirectoryPath, isDirectory: true)
        isBackingUp = true
        backupStatus = "正在创建备份…"
        defer { isBackingUp = false }

        do {
            try await store.prepareForBackup()
            try await userWorkspaces.prepareForBackup()
            let snapshotPath = try await Task.detached(priority: .utility) {
                try LocalBackupManager.createSnapshot(source: sourceURL, destination: destinationURL).path
            }.value
            lastBackupPath = snapshotPath
            backupStatus = "备份完成：\(URL(fileURLWithPath: snapshotPath).lastPathComponent)"
            errorMessage = nil
        } catch {
            backupStatus = "备份失败"
            errorMessage = "自动备份失败：\(error.localizedDescription)"
        }
    }

    private func workDirectoryForStartup() -> URL? {
        guard LocalBlogStore.needsWorkDirectorySelection else {
            return LocalBlogStore.defaultRootURL
        }
        guard let selected = presentWorkDirectoryPicker() else { return nil }
        LocalBlogStore.rememberWorkDirectory(selected)
        return selected
    }

    private func presentWorkDirectoryPicker() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择工作目录"
        panel.message = "默认工作目录 /Volumes/T7Shield/myblog 不可用，请选择一个用于保存博客数据的文件夹。"
        panel.prompt = "使用此目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        let volumesURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        if FileManager.default.fileExists(atPath: volumesURL.path) {
            panel.directoryURL = volumesURL
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.standardizedFileURL
    }

    func selectUser(_ user: NativeUser) {
        guard user.id != currentUser.id, !isSwitchingWorkspace, !isSaving, !isPublishingMoment, !isUploadingMedia, !isBackingUp else { return }
        guard confirmDiscardUnsavedWork(includingMomentDraft: true) else { return }
        Task {
            isSwitchingWorkspace = true
            isLoading = true
            defer {
                isSwitchingWorkspace = false
                isLoading = false
            }
            do {
                let workspace = try await userWorkspaces.selectUser(id: user.id)
                await discardCurrentMomentDraft()
                await discardCurrentEditorDraft()
                try await loadWorkspace(workspace)
                scheduleBackup()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func createUser(named name: String) async -> Bool {
        guard !isSwitchingWorkspace, !isSaving, !isPublishingMoment, !isUploadingMedia, !isBackingUp else { return false }
        guard confirmDiscardUnsavedWork(includingMomentDraft: true) else { return false }
        isSwitchingWorkspace = true
        isLoading = true
        defer {
            isSwitchingWorkspace = false
            isLoading = false
        }
        do {
            let workspace = try await userWorkspaces.createUser(named: name)
            await discardCurrentMomentDraft()
            await discardCurrentEditorDraft()
            try await loadWorkspace(workspace)
            scheduleBackup()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func reload() async throws {
        articles = try await store.listArticles()
        try await reloadMomentFeed()
        trashItems = try await store.listTrash()
        try await refreshActivity()
        if let selectedSlug, let selected = articles.first(where: { $0.slug == selectedSlug }) {
            try await select(selected)
        }
    }

    private func loadWorkspace(_ workspace: NativeWorkspaceState) async throws {
        let nextStore = LocalBlogStore(rootURL: workspace.workspaceURL)
        try await nextStore.prepare()
        workspaceGeneration += 1
        store = nextStore
        users = workspace.users
        currentUser = workspace.activeUser
        dataDirectoryPath = workspace.workspaceURL.path
        articles = []
        moments = []
        totalMomentCount = 0
        filteredMomentCount = 0
        momentFacetRecords = []
        nextMomentCursor = nil
        hasMoreMoments = false
        trashItems = []
        activity = []
        selectedArticle = nil
        selectedSlug = nil
        editor = NativeEditorDraft()
        pendingEditorMediaCleanup = []
        editorOriginalArticle = nil
        momentDraft = NativeMomentDraft()
        editingMomentID = nil
        searchText = ""
        momentSearchText = ""
        selectedMomentTags = []
        momentDateFilter = .all
        showsOnlyFavoriteMoments = false
        section = .dashboard
        try await reload()
    }

    private var currentMomentFilter: NativeMomentFilter {
        NativeMomentFilter(
            searchText: momentSearchText,
            tags: Array(selectedMomentTags),
            dateFilter: momentDateFilter,
            favoritesOnly: showsOnlyFavoriteMoments
        )
    }

    private func reloadMomentFeed() async throws {
        momentFeedGeneration += 1
        let generation = momentFeedGeneration
        isLoadingMoreMoments = true
        defer { isLoadingMoreMoments = false }

        let filter = currentMomentFilter
        let facets = try await store.listMomentFacetRecords()
        let total = facets.count
        let filteredTotal = try await store.countMoments(matching: filter)
        let page = try await store.listMomentPage(matching: filter, limit: momentPageSize)
        guard generation == momentFeedGeneration else { return }

        momentFacetRecords = facets
        totalMomentCount = total
        filteredMomentCount = filteredTotal
        moments = page.moments
        nextMomentCursor = page.nextCursor
        hasMoreMoments = page.nextCursor != nil
    }

    func loadMoreMoments() {
        guard hasMoreMoments, !isLoadingMoreMoments, let cursor = nextMomentCursor else { return }
        let generation = momentFeedGeneration
        let filter = currentMomentFilter
        isLoadingMoreMoments = true

        Task {
            defer { isLoadingMoreMoments = false }
            do {
                let page = try await store.listMomentPage(
                    matching: filter,
                    before: cursor,
                    limit: momentPageSize
                )
                guard generation == momentFeedGeneration, filter == currentMomentFilter else { return }
                moments.append(contentsOf: page.moments)
                nextMomentCursor = page.nextCursor
                hasMoreMoments = page.nextCursor != nil
            } catch {
                guard generation == momentFeedGeneration else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func refreshMomentFeed(after delay: TimeInterval = 0) {
        momentSearchTask?.cancel()
        momentSearchTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }
            do {
                try await self.reloadMomentFeed()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
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

    public func newArticle() {
        guard !isSaving, !isUploadingMedia, !isBackingUp else { return }
        guard confirmDiscardUnsavedWork() else { return }
        discardUnreferencedMedia(editorDraftMedia() + pendingEditorMediaCleanup)
        selectedSlug = nil
        selectedArticle = nil
        editor = NativeEditorDraft()
        pendingEditorMediaCleanup = []
        editorOriginalArticle = nil
        section = .editor
        errorMessage = nil
    }

    func editSelected() {
        guard let article = selectedArticle else { return }
        guard !isSaving, !isUploadingMedia, !isBackingUp else { return }
        if isEditorDirty {
            guard confirmDiscardUnsavedWork() else { return }
            discardUnreferencedMedia(editorDraftMedia() + pendingEditorMediaCleanup)
        }
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
        pendingEditorMediaCleanup = []
        editorOriginalArticle = article
        section = .editor
    }

    func saveEditor(as status: NativeArticleStatus) async {
        guard !isBackingUp else {
            errorMessage = "备份进行中，请稍后再保存。"
            return
        }
        let title = editor.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = editor.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !body.isEmpty else {
            errorMessage = NativeStoreError.invalidArticle.localizedDescription
            return
        }

        isSaving = true
        defer { isSaving = false }
        let slug: String
        do {
            slug = editor.slug.isEmpty ? try await store.allocateSlug(from: title) : editor.slug
        } catch {
            errorMessage = error.localizedDescription
            return
        }
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
            let cleanupCandidates = pendingEditorMediaCleanup
            pendingEditorMediaCleanup = []
            editor.slug = saved.slug
            editor.status = saved.status
            editor.updatedAt = saved.updatedAt
            selectedSlug = saved.slug
            selectedArticle = saved
            editorOriginalArticle = saved
            discardUnreferencedMedia(cleanupCandidates)
            try await reload()
            scheduleBackup()
            section = .reader
            errorMessage = nil
        } catch {
            if !slug.isEmpty, let latest = try? await store.getArticle(slug: slug) {
                editor.slug = latest.slug
                editor.updatedAt = latest.updatedAt
                selectedArticle = latest
                editorOriginalArticle = latest
            }
            errorMessage = error.localizedDescription
        }
    }

    func deleteSelected() async {
        guard !isBackingUp else { return }
        guard let article = selectedArticle else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "将这篇文章移入回收站？"
        alert.informativeText = "文章和关联的本地媒体会保留 30 天，可在回收站中恢复，之后自动永久删除。"
        alert.addButton(withTitle: "移入回收站")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try await store.deleteArticle(slug: article.slug, expectedUpdatedAt: article.updatedAt)
            selectedArticle = nil
            selectedSlug = nil
            section = .articles
            try await reload()
            scheduleBackup()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreTrash(_ item: NativeTrashItem) {
        guard !isBackingUp else { return }
        Task {
            do {
                try await store.restoreTrash(item)
                try await reload()
                scheduleBackup()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func permanentlyDeleteTrash(_ item: NativeTrashItem) {
        guard !isBackingUp else { return }
        Task {
            do {
                try await store.permanentlyDeleteTrash(item)
                try await reload()
                scheduleBackup()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func emptyTrash() {
        guard !isBackingUp else { return }
        Task {
            do {
                try await store.emptyTrash()
                try await reload()
                scheduleBackup()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func chooseAndUpload(kind: String, forArticle slug: String? = nil, banner: Bool = false) {
        guard !isBackingUp else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = kind == "video" ? [.movie] : [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let generation = beginUpload()
            defer { endUpload() }
            do {
                let uploaded = try await store.uploadMedia(fileURL: url, kind: kind, slug: slug)
                guard generation == workspaceGeneration else { return }
                if banner {
                    replaceEditorBanner(
                        NativeBanner(
                            alt: url.deletingPathExtension().lastPathComponent,
                            name: uploaded.name,
                            size: uploaded.size,
                            url: uploaded.url
                        )
                    )
                } else {
                    editor.media.append(NativeMedia(kind: uploaded.kind, name: uploaded.name, size: uploaded.size, url: uploaded.url))
                }
                try await refreshActivity()
                scheduleBackup()
            } catch {
                guard generation == workspaceGeneration else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func chooseMomentImages() {
        guard !isBackingUp else { return }
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
            let generation = beginUpload()
            defer { endUpload() }
            do {
                var uploadedImages: [NativeMedia] = []
                for fileURL in selectedURLs {
                    let uploaded = try await store.uploadMedia(fileURL: fileURL, kind: "image", slug: "moments")
                    uploadedImages.append(NativeMedia(kind: uploaded.kind, name: uploaded.name, size: uploaded.size, url: uploaded.url))
                }
                guard generation == workspaceGeneration else { return }
                momentDraft.images.append(contentsOf: uploadedImages)
                try await refreshActivity()
                scheduleBackup()
                errorMessage = nil
            } catch {
                guard generation == workspaceGeneration else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func removeMomentImage(_ image: NativeMedia) {
        momentDraft.images.removeAll { $0.id == image.id }
        discardUnreferencedMedia([image])
    }

    func removeEditorMedia(_ media: NativeMedia) {
        editor.media.removeAll { $0.id == media.id }
        queueEditorMediaCleanup(media)
    }

    func beginEditingMoment(_ moment: NativeMoment) {
        guard !isPublishingMoment else { return }
        if isMomentDraftDirty {
            guard confirmDiscardMomentDraft() else { return }
            discardUnreferencedMedia(momentDraft.images)
        }
        editingMomentID = moment.id
        momentDraft = editableMomentDraft(from: moment)
        errorMessage = nil
    }

    func toggleMomentTagFilter(_ tag: String) {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        if let selectedTag = selectedMomentTags.first(where: {
            $0.caseInsensitiveCompare(normalized) == .orderedSame
        }) {
            selectedMomentTags.remove(selectedTag)
        } else {
            selectedMomentTags.insert(normalized)
        }
        refreshMomentFeed()
    }

    func isMomentTagSelected(_ tag: String) -> Bool {
        selectedMomentTags.contains {
            $0.caseInsensitiveCompare(tag) == .orderedSame
        }
    }

    func selectMomentDateFilter(_ filter: NativeMomentDateFilter) {
        guard momentDateFilter != filter else { return }
        momentDateFilter = filter
        refreshMomentFeed()
    }

    func toggleFavoriteMomentFilter() {
        showsOnlyFavoriteMoments.toggle()
        refreshMomentFeed()
    }

    func toggleMomentFavorite(_ moment: NativeMoment) {
        guard !isBackingUp else { return }
        Task {
            do {
                let updated = try await store.setMomentFavorite(id: moment.id, isFavorite: !moment.isFavorite)
                if let index = moments.firstIndex(where: { $0.id == updated.id }) {
                    moments[index] = updated
                }
                try await reloadMomentFeed()
                scheduleBackup()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func clearMomentFilters() {
        momentSearchText = ""
        selectedMomentTags = []
        momentDateFilter = .all
        showsOnlyFavoriteMoments = false
        refreshMomentFeed()
    }

    func cancelMomentEditing() {
        guard !isPublishingMoment else { return }
        let discardedMedia = momentDraft.images
        editingMomentID = nil
        momentDraft = NativeMomentDraft()
        discardUnreferencedMedia(discardedMedia)
        errorMessage = nil
    }

    func deleteMoment(_ moment: NativeMoment) {
        guard !isBackingUp else { return }
        if editingMomentID == moment.id {
            cancelMomentEditing()
        }
        Task {
            do {
                try await store.deleteMoment(id: moment.id)
                try await reloadMomentFeed()
                trashItems = try await store.listTrash()
                scheduleBackup()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func uploadMomentPastedImages(_ images: [NSImage]) {
        guard !isBackingUp else { return }
        let remaining = max(0, 9 - momentDraft.images.count)
        guard remaining > 0 else {
            errorMessage = "每条微博最多添加 9 张图片。"
            return
        }

        let imagesToUpload = Array(images.prefix(remaining))
        guard !imagesToUpload.isEmpty else { return }

        Task {
            let generation = beginUpload()
            defer { endUpload() }
            do {
                var uploadedImages: [NativeMedia] = []
                for image in imagesToUpload {
                    guard let imageData = image.pngData else {
                        throw NativeStoreError.fileSystem("无法读取拖入或粘贴的图片。")
                    }
                    let temporaryURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("moment-image-\(UUID().uuidString.lowercased()).png")
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
                guard generation == workspaceGeneration else { return }
                momentDraft.images.append(contentsOf: uploadedImages)
                try await refreshActivity()
                scheduleBackup()
                errorMessage = nil
            } catch {
                guard generation == workspaceGeneration else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func publishMoment() {
        guard !isBackingUp else {
            errorMessage = "备份进行中，请稍后再发布。"
            return
        }
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
                try await reloadMomentFeed()
                try await refreshActivity()
                scheduleBackup()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func uploadPastedImage(_ image: NSImage, placeholder: String) {
        guard !isBackingUp else { return }
        guard let imageData = image.pngData else {
            replacePastedImage(placeholder, with: "[图片粘贴失败]")
            errorMessage = "无法读取剪贴板中的图片。"
            return
        }

        let filename = "pasted-image-\(UUID().uuidString.lowercased()).png"
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        Task {
            let generation = beginUpload()
            defer { endUpload() }
            do {
                try imageData.write(to: temporaryURL, options: .atomic)
                defer { try? FileManager.default.removeItem(at: temporaryURL) }

                let uploaded = try await store.uploadMedia(fileURL: temporaryURL, kind: "image", slug: editor.slug)
                guard generation == workspaceGeneration else { return }
                editor.media.append(NativeMedia(kind: uploaded.kind, name: uploaded.name, size: uploaded.size, url: uploaded.url))
                replacePastedImage(placeholder, with: "![粘贴的图片](\(uploaded.url))")
                try await refreshActivity()
                scheduleBackup()
            } catch {
                guard generation == workspaceGeneration else { return }
                replacePastedImage(placeholder, with: "[图片粘贴失败]")
                errorMessage = error.localizedDescription
            }
        }
    }

    func openMedia(_ media: NativeMedia) {
        Task {
            guard let url = await store.mediaURL(for: media.url) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    private func beginUpload() -> Int {
        uploadCount += 1
        isUploadingMedia = true
        return workspaceGeneration
    }

    private func endUpload() {
        uploadCount = max(0, uploadCount - 1)
        isUploadingMedia = uploadCount > 0
    }

    private var isEditorDirty: Bool {
        if editor.isNew {
            return !editor.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !editor.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || editor.banner != nil
                || !editor.media.isEmpty
        }
        guard let original = editorOriginalArticle else { return false }
        return editor.title != original.title
            || editor.body != original.body
            || editor.excerpt != original.excerpt
            || editor.category != original.category
            || editor.tags != original.tags.joined(separator: ", ")
            || editor.banner != original.banner
            || editor.media != original.media
            || editor.status != original.status
    }

    private var isMomentDraftDirty: Bool {
        !momentDraft.isEmpty || editingMomentID != nil
    }

    private func confirmDiscardUnsavedWork(includingMomentDraft: Bool = false) -> Bool {
        let willDiscardMomentDraft = includingMomentDraft && isMomentDraftDirty
        guard isEditorDirty || willDiscardMomentDraft else { return true }
        let alert = NSAlert()
        alert.messageText = "放弃未保存的修改？"
        alert.informativeText = isEditorDirty && willDiscardMomentDraft
            ? "当前文章和微博草稿都有未保存的内容或附件。"
            : willDiscardMomentDraft
                ? "当前微博草稿还有未发布的内容或图片。"
                : "当前文章还有未保存的标题、正文或附件。"
        alert.addButton(withTitle: "放弃")
        alert.addButton(withTitle: "继续编辑")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmDiscardMomentDraft() -> Bool {
        guard isMomentDraftDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "放弃未发布的微博？"
        alert.informativeText = "当前微博草稿中的文字和图片将被放弃。"
        alert.addButton(withTitle: "放弃并编辑")
        alert.addButton(withTitle: "继续编辑")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func editorDraftMedia() -> [NativeMedia] {
        let banner = editor.banner.map {
            NativeMedia(kind: "image", name: $0.name, size: $0.size, url: $0.url)
        }
        return editor.media + (banner.map { [$0] } ?? [])
    }

    private func replaceEditorBanner(_ banner: NativeBanner) {
        if let previous = editor.banner, previous.url != banner.url {
            queueEditorMediaCleanup(
                NativeMedia(kind: "image", name: previous.name, size: previous.size, url: previous.url)
            )
        }
        editor.banner = banner
    }

    private func queueEditorMediaCleanup(_ media: NativeMedia) {
        guard !pendingEditorMediaCleanup.contains(where: { $0.id == media.id }) else { return }
        pendingEditorMediaCleanup.append(media)
        if editor.isNew {
            discardUnreferencedMedia([media])
        }
    }

    private func discardUnreferencedMedia(_ media: [NativeMedia]) {
        guard !media.isEmpty else { return }
        let sourceStore = store
        Task {
            try? await sourceStore.discardUnreferencedMedia(media)
        }
    }

    private func timelineDateLabel(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        return date.formatted(date: .long, time: .omitted)
    }

    private func editableMomentDraft(from moment: NativeMoment) -> NativeMomentDraft {
        let content = moment.displayContent
        let tagsText = moment.tags.map { "#\($0)" }.joined(separator: " ")
        guard !tagsText.isEmpty else {
            return NativeMomentDraft(text: content.text, textRuns: content.runs, images: moment.images)
        }

        let separator = content.text.isEmpty ? "" : " "
        return NativeMomentDraft(
            text: content.text + separator + tagsText,
            textRuns: content.runs + [
                NativeMomentTextRun(text: separator + tagsText, bold: false, color: nil),
            ],
            images: moment.images
        )
    }

    private func discardCurrentMomentDraft() async {
        let discardedMedia = momentDraft.images
        editingMomentID = nil
        momentDraft = NativeMomentDraft()
        guard !discardedMedia.isEmpty else { return }
        let sourceStore = store
        try? await sourceStore.discardUnreferencedMedia(discardedMedia)
    }

    private func discardCurrentEditorDraft() async {
        let discardedMedia = editorDraftMedia() + pendingEditorMediaCleanup
        pendingEditorMediaCleanup = []
        guard !discardedMedia.isEmpty else { return }
        let sourceStore = store
        try? await sourceStore.discardUnreferencedMedia(discardedMedia)
    }

    private func replacePastedImage(_ placeholder: String, with replacement: String) {
        guard editor.body.contains(placeholder) else { return }
        editor.body = editor.body.replacingOccurrences(of: placeholder, with: replacement)
    }

    private func activityWindowStart(now: Date = Date()) -> Date {
        let calendar = Calendar.current
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
