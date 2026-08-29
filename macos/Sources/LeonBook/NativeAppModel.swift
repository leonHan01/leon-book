import AppKit
import Foundation
import LeonBookBackupModule
import LeonBookModuleKit
import LeonBookPublishingModule
import SwiftUI


@MainActor
final class NativeNavigationState: ObservableObject {
    @Published var section: NativeSection

    init(section: NativeSection = .dashboard) {
        self.section = section
    }
}

@MainActor
public final class NativeAppModel: ObservableObject {
    private static weak var backgroundMaintenanceOwner: NativeAppModel?

    let navigationScopeID: String?
    public var commandRegistry: NativeCommandRegistry {
        NativeCommandRegistry(definitions: NativeCommandRegistry.builtIn.definitions.filter {
            firstPartyModuleRuntime.authorization(forCommand: $0.id.rawValue).isAllowed
        })
    }
    public let commandPreferences = NativeCommandPreferences.shared
    @Published var firstPartyModuleRuntime = NativeFirstPartyModules.loadRuntime()
    @Published var latestFirstPartyModuleEvent: FirstPartyModuleEvent?
    let firstPartyModuleEventBus = FirstPartyModuleEventBus()
    let navigation = NativeNavigationState()
    var section: NativeSection {
        get { navigation.section }
        set {
            if newValue != .reader, navigation.section != newValue {
                articleNavigationGeneration += 1
            }
            navigation.section = newValue
        }
    }
    @Published var articles: [NativeArticleSummary] = []
    @Published private(set) var activity: [NativeActivityDay] = []
    @Published var moments: [NativeMoment] = []
    @Published private(set) var totalMomentCount = 0
    @Published var filteredMomentCount = 0
    @Published var questions: [NativeQuestion] = []
    @Published var totalQuestionCount = 0
    @Published var questionTagFacets: [NativeQuestionTagFacet] = []
    @Published var selectedQuestion: NativeQuestion?
    @Published var questionAnswers: [NativeQuestionAnswer] = []
    @Published var isLoadingQuestionAnswers = false
    @Published var questionAnswerDraft = NativeQuestionAnswerDraft()
    @Published var editingQuestionAnswerID: String?
    @Published private(set) var trashItems: [NativeTrashItem] = []
    @Published var selectedArticle: NativeArticle?
    @Published var selectedArticleRelations = NativeArticleRelations.empty
    @Published var articleComments: [NativeArticleComment] = []
    @Published var pendingArticleCommentSelection: NativeArticleCommentSelection?
    @Published var articleCommentSelectionRevision = UUID()
    @Published var isSavingArticleComment = false
    @Published var articleTabs: [NativeArticleTab] = []
    @Published var activeArticleTabID: UUID?
    @Published var recentArticleSlugs: [String] = []
    @Published var articleGraph = NativeArticleGraph.empty
    @Published var articleRevisions: [NativeArticleRevision] = []
    @Published var articleSourceConflict: NativeArticleSourceConflict?
    @Published var selectedSlug: String?
    let editorSession = NativeEditorSessionState()
    var editor: NativeEditorDraft {
        get { editorSession.draft }
        set { editorSession.draft = newValue }
    }
    var editorBodySelection: NSRange {
        get { editorSession.bodySelection }
        set { editorSession.bodySelection = newValue }
    }
    var editorAutosaveStatus: String {
        get { editorSession.autosaveStatus }
        set { editorSession.autosaveStatus = newValue }
    }
    var isEditorAutosaving: Bool {
        get { editorSession.isAutosaving }
        set { editorSession.isAutosaving = newValue }
    }
    @Published var momentDraft = NativeMomentDraft()
    @Published private(set) var editingMomentID: String?
    @Published private(set) var selectedArticleTags: Set<String> = []
    @Published var selectedArticleFolderPath: String?
    @Published var selectedMomentTags: Set<String> = []
    @Published var momentDateFilter: NativeMomentDateFilter = .all
    @Published var showsOnlyFavoriteMoments = false
    @Published var isLoading = true
    @Published private(set) var isPublishingMoment = false
    @Published var isPublishingQuestion = false
    @Published var isPublishingQuestionAnswer = false
    @Published private(set) var isLoadingMoreMoments = false
    @Published var hasMoreMoments = false
    @Published var isSaving = false
    @Published var isRenamingArticleProperty = false
    @Published var articlePropertyStatus = ""
    @Published private(set) var isUploadingMedia = false
    @Published var storageReady = false
    @Published private(set) var needsWorkDirectorySelection = false
    @Published private(set) var users: [NativeUser] = []
    @Published private(set) var currentUser = NativeUser.leon
    @Published private(set) var isSwitchingWorkspace = false
    @Published private(set) var dataDirectoryPath = LocalBlogStore.defaultRootURL.path
    @Published private(set) var dataRootDirectoryPath = LocalBlogStore.defaultRootURL.path
    @Published var selectedMarkdownWorkspaceMode = NativeMarkdownWorkspaceMode.copyImport
    @Published var activeMarkdownWorkspaceMode = NativeMarkdownWorkspaceMode.copyImport
    @Published var markdownSourceDirectoryPath = LocalBlogStore.defaultRootURL
        .appendingPathComponent("articles", isDirectory: true).path
    @Published var backupDirectoryPath = LocalBlogStore.savedBackupDirectoryURL?.path ?? ""
    @Published var lastBackupPath = ""
    @Published var backupStatus = "尚未生成备份"
    @Published var isBackingUp = false
    @Published var backupPolicy = LocalBlogStore.savedBackupPolicy
    @Published var backupSnapshots: [NativeBackupSnapshot] = []
    @Published var backupStorageEstimate: NativeBackupStorageEstimate?
    @Published var isValidatingBackup = false
    @Published var isRestoringBackup = false
    @Published var backupValidationStatus = "尚未校验快照"
    @Published var isScanningObsidianVault = false
    @Published var isImportingObsidianVault = false
    @Published var obsidianImportPreview: NativeObsidianImportPreview?
    @Published var obsidianImportStatus = "尚未选择 Vault"
    @Published var errorMessage: String?
    @Published var searchText = ""
    @Published var momentSearchText = ""
    @Published var questionSearchText = ""
    @Published var selectedQuestionTag: String?
    @Published var searchPresentation: NativeSearchPresentation?
    @Published var globalSearchResults: [NativeGlobalSearchResult] = []
    @Published var isSearchingGlobally = false
    @Published var globalSearchText = ""
    @Published var isSearchingArticles = false
    @Published var articleSearchMatchSlugs: Set<String> = []
    @Published var articleSearchResolvedText = ""
    @Published var smartCollections: [NativeSmartCollection] = []
    @Published var selectedSmartCollectionID: String?
    @Published var selectedSmartCollectionViewID: String?
    @Published var smartCollectionArticles: [NativeArticleSummary] = []
    @Published var bookmarks: [NativeBookmark] = []
    @Published var pendingArticleScrollAnchor: String?
    @Published var articleScrollRevision = UUID()

    var userWorkspaces: UserWorkspaceStore
    private(set) var store: LocalBlogStore
    var trashCleanupTask: Task<Void, Never>?
    private var uploadCount = 0
    var workspaceGeneration = 0
    private var pendingEditorMediaCleanup: [NativeMedia] = []
    private var editorOriginalArticle: NativeArticle?
    var backupTask: Task<Void, Never>?
    var editorAutosaveTask: Task<Void, Never>?
    private var momentFacetRecords: [NativeMomentFacetRecord] = []
    var nextMomentCursor: NativeMomentCursor?
    private var momentFeedGeneration = 0
    private var momentSearchTask: Task<Void, Never>?
    var questionSearchTask: Task<Void, Never>?
    var editingQuestionAnswerUpdatedAt: String?
    var globalSearchTask: Task<Void, Never>?
    var globalSearchGeneration = 0
    var articleListSearchTask: Task<Void, Never>?
    var knowledgeGraphTask: Task<Void, Never>?
    var obsidianScanTask: Task<Void, Never>?
    private var markdownSourceEventMonitor: MarkdownSourceEventMonitor?
    private var markdownSourceSyncTask: Task<Void, Never>?
    private var markdownSourceVerificationTask: Task<Void, Never>?
    private var pendingMarkdownSourceChanges = NativeMarkdownSourceChangeSet()
    var articleListSearchGeneration = 0
    var articleNavigationGeneration = 0
    private var automationObserver: NSObjectProtocol?
    var automationRetryTask: Task<Void, Never>?
    private let momentPageSize = 40

    public init(navigationScopeID: String? = nil) {
        self.navigationScopeID = navigationScopeID
        let rootURL = LocalBlogStore.defaultRootURL
        userWorkspaces = UserWorkspaceStore(rootURL: rootURL)
        store = LocalBlogStore(rootURL: rootURL)
        automationObserver = NotificationCenter.default.addObserver(
            forName: NativeAutomationInbox.didEnqueueNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.consumeAutomationInbox() }
        }
        Task { await start() }
    }

    deinit {
        trashCleanupTask?.cancel()
        backupTask?.cancel()
        editorAutosaveTask?.cancel()
        momentSearchTask?.cancel()
        questionSearchTask?.cancel()
        globalSearchTask?.cancel()
        articleListSearchTask?.cancel()
        knowledgeGraphTask?.cancel()
        obsidianScanTask?.cancel()
        markdownSourceEventMonitor?.stop()
        markdownSourceSyncTask?.cancel()
        markdownSourceVerificationTask?.cancel()
        automationRetryTask?.cancel()
        if let automationObserver {
            NotificationCenter.default.removeObserver(automationObserver)
        }
    }

    private func tagIdentifier(_ tag: String) -> String {
        tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    var publishedArticles: [NativeArticleSummary] {
        articles.filter { $0.status == .published }
    }

    var draftArticles: [NativeArticleSummary] {
        articles.filter { $0.status == .draft }
    }

    var filteredArticles: [NativeArticleSummary] {
        let query = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let resolvedQuery = articleSearchResolvedText
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return articleListBase.filter { article in
            let searchableSummary = [article.title, article.category, article.excerpt, article.tags.joined(separator: " ")]
                .joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let matchesSearch = query.isEmpty || (resolvedQuery == query
                ? articleSearchMatchSlugs.contains(article.slug)
                : searchableSummary.contains(query))
            let matchesTags = selectedArticleTags.isEmpty || article.tags.contains { tag in
                selectedArticleTags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
            }
            let matchesFolder = selectedArticleFolderPath.map { folder in
                article.sourceFolderPath == folder || article.sourceFolderPath.hasPrefix(folder + "/")
            } ?? true
            return matchesSearch && matchesTags && matchesFolder
        }
    }

    var availableArticleFolderFilters: [NativeArticleFolderFilter] {
        var counts: [String: Int] = [:]
        for article in articles where !article.sourceFolderPath.isEmpty {
            let components = article.sourceFolderPath.split(separator: "/").map(String.init)
            for length in 1...components.count {
                counts[components.prefix(length).joined(separator: "/"), default: 0] += 1
            }
        }
        return counts.map { NativeArticleFolderFilter(path: $0.key, count: $0.value) }
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    var availableArticleTagFilters: [NativeArticleTagFilter] {
        var filters: [String: NativeArticleTagFilter] = [:]

        for article in articleListBase {
            var countedTags = Set<String>()
            for tag in article.tags {
                let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                let identifier = tagIdentifier(normalized)
                guard !normalized.isEmpty, countedTags.insert(identifier).inserted else { continue }

                if let existing = filters[identifier] {
                    filters[identifier] = NativeArticleTagFilter(tag: existing.tag, count: existing.count + 1)
                } else {
                    filters[identifier] = NativeArticleTagFilter(tag: normalized, count: 1)
                }
            }
        }

        return filters.values.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.tag.localizedCaseInsensitiveCompare($1.tag) == .orderedAscending
        }
    }

    var availableArticleTags: [String] {
        availableArticleTagFilters.map(\.tag)
    }

    var selectedSmartCollectionDefinition: NativeSmartCollection? {
        guard let selectedSmartCollectionID else { return nil }
        return smartCollections.first(where: { $0.id == selectedSmartCollectionID })
    }

    var selectedSmartCollection: NativeSmartCollection? {
        selectedSmartCollectionDefinition?.materialized(viewID: selectedSmartCollectionViewID)
    }

    var articleListTitle: String {
        if let collection = selectedSmartCollection,
           let view = collection.selectedView,
           collection.views.count > 1 {
            return "\(collection.name) · \(view.name)"
        }
        return selectedSmartCollection?.name ?? selectedArticleFolderPath ?? "全部文章"
    }

    private var articleListBase: [NativeArticleSummary] {
        selectedSmartCollection == nil ? articles : smartCollectionArticles
    }

    var activeArticleTab: NativeArticleTab? {
        guard let activeArticleTabID else { return nil }
        return articleTabs.first(where: { $0.id == activeArticleTabID })
    }

    public var canNavigateArticleBack: Bool {
        activeArticleTab?.canGoBack == true
    }

    public var canNavigateArticleForward: Bool {
        activeArticleTab?.canGoForward == true
    }

    public var isActiveArticleTabPinned: Bool {
        activeArticleTab?.isPinned == true
    }

    public var hasActiveArticleTab: Bool {
        activeArticleTab != nil
    }

    public var commandContext: NativeCommandContext {
        NativeCommandContext(
            storageReady: storageReady,
            isBusy: isLoading
                || isSwitchingWorkspace
                || isRestoringBackup
                || isSaving
                || isSavingArticleComment
                || isPublishingMoment
                || isPublishingQuestion
                || isPublishingQuestionAnswer
                || isUploadingMedia
                || isBackingUp
                || isScanningObsidianVault
                || isImportingObsidianVault,
            isArticleEditor: section == .editor,
            hasActiveArticleTab: hasActiveArticleTab,
            canNavigateArticleBack: canNavigateArticleBack,
            canNavigateArticleForward: canNavigateArticleForward
        )
    }

    var recentArticles: [NativeArticleSummary] {
        let summaries = Dictionary(uniqueKeysWithValues: articles.map { ($0.slug, $0) })
        return recentArticleSlugs.compactMap { summaries[$0] }
    }

    var currentArticleHistorySnapshot: NativeArticleRevisionSnapshot {
        if section != .editor, let selectedArticle {
            return NativeArticleRevisionSnapshot(article: selectedArticle)
        }
        return editorRevisionSnapshot
    }

    var currentArticleHistoryTitle: String {
        let title = currentArticleHistorySnapshot.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "未命名文章" : title
    }

    var isFilteringArticles: Bool {
        !selectedArticleTags.isEmpty
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var availableMomentTagFilters: [NativeMomentTagFilter] {
        var filters: [String: NativeMomentTagFilter] = [:]

        for record in momentFacetRecords {
            var countedTags = Set<String>()
            for tag in record.tags {
                let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                let identifier = tagIdentifier(normalized)
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
            consumeAutomationInbox()
            startTrashCleanupLoop()
            await refreshBackupOverview()
            scheduleBackup()
        } catch {
            storageReady = false
            errorMessage = error.localizedDescription
        }
    }

    func chooseWorkDirectory() {
        guard !isLoading, !isSwitchingWorkspace, !isSaving, !isPublishingMoment,
              !isPublishingQuestion, !isPublishingQuestionAnswer, !isUploadingMedia, !isBackingUp,
              !isScanningObsidianVault, !isImportingObsidianVault,
              let rootURL = presentWorkDirectoryPicker() else { return }
        LocalBlogStore.rememberWorkDirectory(rootURL)
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                try await connect(to: rootURL)
                consumeAutomationInbox()
                startTrashCleanupLoop()
                await refreshBackupOverview()
                scheduleBackup()
                errorMessage = nil
            } catch {
                storageReady = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func connect(to rootURL: URL) async throws {
        userWorkspaces = UserWorkspaceStore(rootURL: rootURL)
        store = LocalBlogStore(rootURL: rootURL)
        dataRootDirectoryPath = rootURL.standardizedFileURL.path
        let workspace = try await userWorkspaces.prepare()
        try await loadWorkspace(workspace)
        needsWorkDirectorySelection = false
        storageReady = true
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
        guard user.id != currentUser.id, !isSwitchingWorkspace, !isSaving, !isPublishingMoment,
              !isPublishingQuestion, !isPublishingQuestionAnswer, !isUploadingMedia,
              !isBackingUp, !isScanningObsidianVault, !isImportingObsidianVault else { return }
        guard confirmDiscardUnsavedWork(includingMomentDraft: true) else { return }
        Task {
            isSwitchingWorkspace = true
            isLoading = true
            defer {
                isSwitchingWorkspace = false
                isLoading = false
                consumeAutomationInbox()
            }
            do {
                let workspace = try await userWorkspaces.selectUser(id: user.id)
                await discardCurrentMomentDraft()
                await discardCurrentQuestionAnswerDraft()
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
        guard !isSwitchingWorkspace, !isSaving, !isPublishingMoment,
              !isPublishingQuestion, !isPublishingQuestionAnswer, !isUploadingMedia, !isBackingUp,
              !isScanningObsidianVault, !isImportingObsidianVault else { return false }
        guard confirmDiscardUnsavedWork(includingMomentDraft: true) else { return false }
        isSwitchingWorkspace = true
        isLoading = true
        defer {
            isSwitchingWorkspace = false
            isLoading = false
            consumeAutomationInbox()
        }
        do {
            let workspace = try await userWorkspaces.createUser(named: name)
            await discardCurrentMomentDraft()
            await discardCurrentQuestionAnswerDraft()
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
        let syncResult = try await store.refreshMarkdownSources()
        try await reloadIndexedState()
        if !syncResult.warnings.isEmpty {
            errorMessage = syncResult.warnings.joined(separator: "\n")
        }
    }

    private func reloadIndexedState() async throws {
        articles = try await store.listArticles()
        smartCollections = try await store.listSmartCollections()
        bookmarks = try await store.listBookmarks()
        if let selectedSmartCollectionID,
           !smartCollections.contains(where: { $0.id == selectedSmartCollectionID }) {
            self.selectedSmartCollectionID = nil
            selectedSmartCollectionViewID = nil
        } else if let definition = selectedSmartCollectionDefinition,
                  !definition.views.contains(where: { $0.id == selectedSmartCollectionViewID }) {
            selectedSmartCollectionViewID = definition.views.first?.id
        }
        try await refreshSelectedSmartCollection()
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updateArticleListSearch(searchText, debounce: false)
        }
        try await reloadKnowledgeGraph()
        try await reloadMomentFeed(refreshesFacets: true)
        try await reloadQuestionList()
        trashItems = try await store.listTrash()
        try await refreshActivity()
        if !isEditorDirty,
           let selectedSlug,
           let selected = articles.first(where: { $0.slug == selectedSlug }) {
            try await displayArticle(
                selected,
                disposition: .refreshActiveTab,
                recordsPageView: false
            )
        }
    }

    private func reloadAfterMarkdownSourceChanges(_ result: NativeMarkdownSyncResult) async throws {
        let plan = NativeMarkdownRefreshPlan(
            result: result,
            selectedArticleSlug: selectedSlug
        )
        guard plan.reloadsArticleList else { return }

        articles = try await store.listArticles()
        if plan.reloadsSelectedSmartCollection {
            try await refreshSelectedSmartCollection()
        }
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updateArticleListSearch(searchText, debounce: false)
        }
        if plan.reloadsKnowledgeGraph {
            try await reloadKnowledgeGraph()
        }
        if plan.reloadsTrash {
            trashItems = try await store.listTrash()
        }

        guard plan.reloadsSelectedArticle, !isEditorDirty, let selectedSlug else { return }
        guard let selected = articles.first(where: { $0.slug == selectedSlug }) else {
            articleTabs.removeAll(where: { $0.slug == selectedSlug })
            recentArticleSlugs.removeAll(where: { $0 == selectedSlug })
            self.selectedSlug = nil
            selectedArticle = nil
            selectedArticleRelations = .empty
            articleComments = []
            pendingArticleCommentSelection = nil
            activeArticleTabID = articleTabs.first?.id
            if section == .reader { section = .articles }
            persistArticleNavigationState()
            return
        }

        let previousSection = section
        try await displayArticle(
            selected,
            disposition: .refreshActiveTab,
            recordsPageView: false
        )
        if previousSection != .reader {
            section = previousSection
        }
    }

    var isMarkdownSourceReadOnly: Bool { activeMarkdownWorkspaceMode.isReadOnly }

    func startMarkdownSourceMonitor() {
        stopMarkdownSourceMonitor()
        let generation = workspaceGeneration
        let articlesURL = URL(fileURLWithPath: markdownSourceDirectoryPath, isDirectory: true)
        let monitor = MarkdownSourceEventMonitor(rootURL: articlesURL)
        markdownSourceEventMonitor = monitor
        do {
            try monitor.start { [weak self] changes in
                Task { @MainActor [weak self] in
                    self?.enqueueMarkdownSourceChanges(changes, generation: generation)
                }
            }
        } catch {
            markdownSourceEventMonitor = nil
            errorMessage = "Markdown 事件监听启动失败，将使用低频校验：\(error.localizedDescription)"
        }
        markdownSourceVerificationTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self,
                      generation == self.workspaceGeneration else { return }
                self.enqueueMarkdownSourceChanges(
                    NativeMarkdownSourceChangeSet(requiresFullScan: true),
                    generation: generation
                )
            }
        }
    }

    func stopMarkdownSourceMonitor() {
        markdownSourceEventMonitor?.stop()
        markdownSourceEventMonitor = nil
        markdownSourceSyncTask?.cancel()
        markdownSourceSyncTask = nil
        markdownSourceVerificationTask?.cancel()
        markdownSourceVerificationTask = nil
        pendingMarkdownSourceChanges = NativeMarkdownSourceChangeSet()
    }

    private func enqueueMarkdownSourceChanges(
        _ changes: NativeMarkdownSourceChangeSet,
        generation: Int
    ) {
        guard generation == workspaceGeneration else { return }
        pendingMarkdownSourceChanges.merge(changes)
        guard markdownSourceSyncTask == nil else { return }
        markdownSourceSyncTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 700_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.processPendingMarkdownSourceChanges(generation: generation)
        }
    }

    private func processPendingMarkdownSourceChanges(generation: Int) async {
        defer {
            markdownSourceSyncTask = nil
            if generation == workspaceGeneration, !pendingMarkdownSourceChanges.isEmpty {
                enqueueMarkdownSourceChanges(
                    NativeMarkdownSourceChangeSet(),
                    generation: generation
                )
            }
        }
        guard generation == workspaceGeneration else { return }
        let changes = pendingMarkdownSourceChanges
        pendingMarkdownSourceChanges = NativeMarkdownSourceChangeSet()
        guard !changes.isEmpty else { return }
        do {
            let result: NativeMarkdownSyncResult
            if changes.requiresFullScan {
                result = try await store.refreshMarkdownSources()
            } else {
                result = try await store.refreshMarkdownSources(
                    changedRelativePaths: changes.relativePaths,
                    changedDirectoryPrefixes: changes.directoryPrefixes
                )
            }
            guard generation == workspaceGeneration else { return }
            if result.didChange { try await reloadAfterMarkdownSourceChanges(result) }
            if !result.warnings.isEmpty {
                errorMessage = result.warnings.joined(separator: "\n")
            }
        } catch {
            guard generation == workspaceGeneration else { return }
            errorMessage = "Markdown 自动同步失败：\(error.localizedDescription)"
        }
    }

    private func loadWorkspace(_ workspace: NativeWorkspaceState) async throws {
        let nextStore = LocalBlogStore(rootURL: workspace.workspaceURL)
        try await nextStore.prepare()
        let sourceState = try await nextStore.markdownWorkspaceSourceState()
        let sourceURL = try await nextStore.markdownSourceDirectoryURL()
        stopMarkdownSourceMonitor()
        articleListSearchTask?.cancel()
        globalSearchTask?.cancel()
        questionSearchTask?.cancel()
        workspaceGeneration += 1
        store = nextStore
        users = workspace.users
        currentUser = workspace.activeUser
        dataDirectoryPath = workspace.workspaceURL.path
        activeMarkdownWorkspaceMode = sourceState.mode
        selectedMarkdownWorkspaceMode = sourceState.mode
        markdownSourceDirectoryPath = sourceURL.path
        articles = []
        moments = []
        totalMomentCount = 0
        filteredMomentCount = 0
        questions = []
        totalQuestionCount = 0
        questionTagFacets = []
        selectedQuestion = nil
        questionAnswers = []
        isLoadingQuestionAnswers = false
        questionAnswerDraft = NativeQuestionAnswerDraft()
        editingQuestionAnswerID = nil
        editingQuestionAnswerUpdatedAt = nil
        momentFacetRecords = []
        nextMomentCursor = nil
        hasMoreMoments = false
        trashItems = []
        activity = []
        selectedArticle = nil
        selectedArticleRelations = .empty
        articleComments = []
        pendingArticleCommentSelection = nil
        articleTabs = []
        activeArticleTabID = nil
        recentArticleSlugs = []
        articleGraph = .empty
        articleRevisions = []
        articleSourceConflict = nil
        selectedSlug = nil
        editor = NativeEditorDraft()
        editorAutosaveStatus = "尚未自动保存"
        pendingEditorMediaCleanup = []
        editorOriginalArticle = nil
        momentDraft = NativeMomentDraft()
        editingMomentID = nil
        searchText = ""
        momentSearchText = ""
        questionSearchText = ""
        selectedQuestionTag = nil
        globalSearchText = ""
        globalSearchResults = []
        searchPresentation = nil
        articleSearchMatchSlugs = []
        articleSearchResolvedText = ""
        smartCollections = []
        selectedSmartCollectionID = nil
        selectedSmartCollectionViewID = nil
        smartCollectionArticles = []
        bookmarks = []
        pendingArticleScrollAnchor = nil
        isSearchingArticles = false
        isSearchingGlobally = false
        obsidianImportPreview = nil
        obsidianImportStatus = "尚未选择 Vault"
        isScanningObsidianVault = false
        isImportingObsidianVault = false
        selectedArticleTags = []
        selectedArticleFolderPath = nil
        selectedMomentTags = []
        momentDateFilter = .all
        showsOnlyFavoriteMoments = false
        section = .dashboard
        try await reload()
        await restoreArticleNavigationState()
        try await restoreLatestUnsavedArticleDraftIfNeeded()
        startMarkdownSourceMonitor()
    }

    private var currentMomentFilter: NativeMomentFilter {
        NativeMomentFilter(
            searchText: momentSearchText,
            tags: Array(selectedMomentTags),
            dateFilter: momentDateFilter,
            favoritesOnly: showsOnlyFavoriteMoments
        )
    }

    func reloadMomentFeed(refreshesFacets: Bool = false) async throws {
        momentFeedGeneration += 1
        let generation = momentFeedGeneration
        isLoadingMoreMoments = true
        defer { isLoadingMoreMoments = false }

        let filter = currentMomentFilter
        let facets = refreshesFacets ? try await store.listMomentFacetRecords() : nil
        let filteredTotal = try await store.countMoments(matching: filter)
        let page = try await store.listMomentPage(matching: filter, limit: momentPageSize)
        guard generation == momentFeedGeneration else { return }

        if let facets {
            momentFacetRecords = facets
            totalMomentCount = facets.count
        }
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


    func refreshActivity() async throws {
        activity = try await store.listActivity(since: activityWindowStart())
    }

    public func newArticle() {
        guard !isSaving, !isUploadingMedia, !isBackingUp else { return }
        let discardsDirtyEditor = isEditorDirty
        guard confirmDiscardUnsavedWork() else { return }
        articleNavigationGeneration += 1
        editorAutosaveTask?.cancel()
        if discardsDirtyEditor {
            discardArticleAutosaves(
                draftKey: editor.recoveryID,
                newerThan: editorOriginalArticle?.updatedAt
            )
        }
        discardUnreferencedMedia(editorDraftMedia() + pendingEditorMediaCleanup)
        selectedSlug = nil
        selectedArticle = nil
        selectedArticleRelations = .empty
        articleComments = []
        pendingArticleCommentSelection = nil
        editor = NativeEditorDraft()
        editorBodySelection = NSRange(location: 0, length: 0)
        articleRevisions = []
        editorAutosaveStatus = "尚未自动保存"
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
            discardArticleAutosaves(
                draftKey: editor.recoveryID,
                newerThan: editorOriginalArticle?.updatedAt
            )
            discardUnreferencedMedia(editorDraftMedia() + pendingEditorMediaCleanup)
        }
        editor = NativeEditorDraft(
            recoveryID: article.slug,
            slug: article.slug,
            title: article.title,
            category: article.category,
            excerpt: article.excerpt,
            tags: articleTagText(article.tags),
            body: article.body,
            banner: article.banner,
            media: article.media,
            properties: article.properties,
            status: article.status,
            updatedAt: article.updatedAt
        )
        editorBodySelection = NSRange(location: 0, length: 0)
        pendingEditorMediaCleanup = []
        editorOriginalArticle = article
        editorAutosaveStatus = "已载入正式版本"
        section = .editor
        restoreLatestAutosaveIfNeeded(for: article)
        refreshArticleHistory()
    }

    func acceptArticleRefactor(_ article: NativeArticle) {
        editor.body = article.body
        editor.updatedAt = article.updatedAt
        editorOriginalArticle = article
        selectedArticle = article
        selectedSlug = article.slug
        editorAutosaveTask?.cancel()
        editorAutosaveStatus = isEditorDirty ? "正文已重构，其他修改尚未保存" : "正文重构已保存"
        refreshArticleHistory()
    }

    var hasUnsavedEditorChanges: Bool { isEditorDirty }

    func scheduleEditorAutosave() {
        editorAutosaveTask?.cancel()
        guard storageReady, isEditorDirty, hasRecoverableEditorContent else {
            if !isEditorDirty {
                editorAutosaveStatus = editor.updatedAt == nil ? "尚未自动保存" : "已保存"
            }
            return
        }

        let recoveryID = editor.recoveryID
        let generation = workspaceGeneration
        editorAutosaveStatus = "等待自动保存…"
        editorAutosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self,
                  self.workspaceGeneration == generation,
                  self.editor.recoveryID == recoveryID else { return }
            await self.performEditorAutosave()
        }
    }

    func refreshArticleHistory() {
        let recoveryID = editor.recoveryID
        let slug = editor.slug.isEmpty ? selectedArticle?.slug : editor.slug
        let generation = workspaceGeneration
        Task {
            do {
                let revisions = try await store.listArticleRevisions(
                    articleSlug: slug,
                    draftKey: recoveryID
                )
                let currentSlug = editor.slug.isEmpty ? selectedArticle?.slug : editor.slug
                guard generation == workspaceGeneration,
                      editor.recoveryID == recoveryID,
                      currentSlug == slug else { return }
                articleRevisions = revisions
            } catch {
                guard generation == workspaceGeneration else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func restoreArticleRevision(_ revision: NativeArticleRevision) -> Bool {
        let alert = NSAlert()
        alert.messageText = "恢复这个版本？"
        alert.informativeText = "当前编辑内容会被替换，但仍会先保留为自动保存版本。恢复后请确认内容并正式保存。"
        alert.addButton(withTitle: "恢复到编辑器")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let slug = editor.slug.isEmpty ? selectedArticle?.slug ?? "" : editor.slug
        let recoveryID = slug.isEmpty ? editor.recoveryID : slug
        let expectedUpdatedAt = editor.updatedAt ?? selectedArticle?.updatedAt
        if let selectedArticle, selectedArticle.slug == slug {
            editorOriginalArticle = selectedArticle
        }
        editor = editorDraft(
            from: revision.snapshot,
            recoveryID: recoveryID,
            slug: slug,
            expectedUpdatedAt: expectedUpdatedAt
        )
        editorAutosaveStatus = "已恢复版本，等待自动保存…"
        section = .editor
        scheduleEditorAutosave()
        return true
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
        if status == .published {
            guard authorizeFirstPartyModule(
                PublishingFirstPartyModule.id,
                permission: .contentPublish,
                action: "发布文章"
            ) else { return }
            recordFirstPartyModuleEvent(
                moduleID: PublishingFirstPartyModule.id,
                name: "publishing.requested",
                payload: ["kind": "article"]
            )
            do {
                try FirstPartyPublicationPolicy.validate(.init(
                    kind: .article,
                    title: title,
                    body: body,
                    attachmentCount: editor.media.count
                ))
            } catch {
                errorMessage = error.localizedDescription
                return
            }
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
        let recoveryID = editor.recoveryID
        let tags = NativeArticleTag.parse(editor.tags)
        let payload = NativeSaveArticle(
            banner: editor.banner,
            body: editor.body,
            category: editor.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Notes" : editor.category.trimmingCharacters(in: .whitespacesAndNewlines),
            excerpt: editor.excerpt,
            media: editor.media,
            slug: slug,
            status: status,
            tags: tags,
            title: title,
            expectedUpdatedAt: editor.updatedAt,
            properties: editor.properties
        )

        do {
            let saved = try await store.saveArticle(payload)
            try await store.attachArticleRevisions(draftKey: recoveryID, toArticleSlug: saved.slug)
            let cleanupCandidates = pendingEditorMediaCleanup
            pendingEditorMediaCleanup = []
            editor.slug = saved.slug
            editor.status = saved.status
            editor.updatedAt = saved.updatedAt
            editor.properties = saved.properties
            updateArticleTabs(for: saved.slug, disposition: .currentTab)
            recordRecentArticle(saved.slug)
            selectedSlug = saved.slug
            selectedArticle = saved
            selectedArticleRelations = .empty
            articleComments = []
            pendingArticleCommentSelection = nil
            editorOriginalArticle = saved
            editorAutosaveTask?.cancel()
            editorAutosaveStatus = "已正式保存"
            discardUnreferencedMedia(cleanupCandidates)
            try await reload()
            articleRevisions = try await store.listArticleRevisions(
                articleSlug: saved.slug,
                draftKey: recoveryID
            )
            scheduleBackup()
            section = .reader
            persistArticleNavigationState()
            errorMessage = nil
            if status == .published {
                recordFirstPartyModuleEvent(
                    moduleID: PublishingFirstPartyModule.id,
                    name: "publishing.completed",
                    payload: ["kind": "article", "id": saved.slug]
                )
            }
        } catch {
            if let storeError = error as? NativeStoreError,
               case .conflict = storeError,
               !slug.isEmpty,
               let latest = try? await store.getArticle(slug: slug) {
                selectedArticle = latest
                articleSourceConflict = NativeArticleSourceConflict(
                    external: latest,
                    local: editorRevisionSnapshot
                )
                errorMessage = "Markdown 在编辑期间发生了外部修改，请比较两个版本后选择处理方式。"
                return
            }
            if !slug.isEmpty, let latest = try? await store.getArticle(slug: slug) {
                selectedArticle = latest
            }
            errorMessage = error.localizedDescription
        }
    }

    func resolveArticleSourceConflictUsingExternal() {
        guard let conflict = articleSourceConflict else { return }
        let article = conflict.external
        editor = NativeEditorDraft(
            recoveryID: article.slug,
            slug: article.slug,
            title: article.title,
            category: article.category,
            excerpt: article.excerpt,
            tags: articleTagText(article.tags),
            body: article.body,
            banner: article.banner,
            media: article.media,
            properties: article.properties,
            status: article.status,
            updatedAt: article.updatedAt
        )
        editorOriginalArticle = article
        selectedArticle = article
        articleSourceConflict = nil
        editorAutosaveStatus = "已载入外部 Markdown 版本"
        errorMessage = nil
        section = .editor
    }

    func resolveArticleSourceConflictByOverwriting() {
        guard let conflict = articleSourceConflict else { return }
        editor.updatedAt = conflict.external.updatedAt
        editorOriginalArticle = conflict.external
        selectedArticle = conflict.external
        articleSourceConflict = nil
        let status = editor.status
        Task { await saveEditor(as: status) }
    }

    func resolveArticleSourceConflictAsCopy() {
        guard articleSourceConflict != nil else { return }
        editor.recoveryID = UUID().uuidString.lowercased()
        editor.slug = ""
        editor.updatedAt = nil
        editor.title = editor.title.trimmingCharacters(in: .whitespacesAndNewlines) + "（冲突副本）"
        editorOriginalArticle = nil
        selectedSlug = nil
        selectedArticle = nil
        articleSourceConflict = nil
        editorAutosaveStatus = "将保存为新文章"
        errorMessage = nil
        section = .editor
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
            articleTabs.removeAll(where: { $0.slug == article.slug })
            recentArticleSlugs.removeAll(where: { $0 == article.slug })
            selectedArticle = nil
            selectedArticleRelations = .empty
            articleComments = []
            pendingArticleCommentSelection = nil
            selectedSlug = nil
            let nextTabID = articleTabs.first?.id
            activeArticleTabID = nil
            try await reload()
            if let nextTabID {
                activateArticleTab(nextTabID)
            } else {
                section = .articles
            }
            persistArticleNavigationState()
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

    func toggleArticleTagFilter(_ tag: String) {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        if let selectedTag = selectedArticleTags.first(where: {
            $0.caseInsensitiveCompare(normalized) == .orderedSame
        }) {
            selectedArticleTags.remove(selectedTag)
        } else {
            selectedArticleTags.insert(normalized)
        }
    }

    func isArticleTagSelected(_ tag: String) -> Bool {
        selectedArticleTags.contains {
            $0.caseInsensitiveCompare(tag) == .orderedSame
        }
    }

    func showArticles(tag: String) {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        selectedSmartCollectionID = nil
        selectedSmartCollectionViewID = nil
        smartCollectionArticles = []
        selectedArticleTags = [normalized]
        section = .articles
    }

    func clearArticleFilters() {
        searchText = ""
        updateArticleListSearch("")
        selectedArticleTags = []
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
                try await reloadMomentFeed(refreshesFacets: true)
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
        guard authorizeFirstPartyModule(
            PublishingFirstPartyModule.id,
            permission: .contentPublish,
            action: "发布动态"
        ) else { return }
        recordFirstPartyModuleEvent(
            moduleID: PublishingFirstPartyModule.id,
            name: "publishing.requested",
            payload: ["kind": "moment"]
        )
        guard !isBackingUp else {
            errorMessage = "备份进行中，请稍后再发布。"
            return
        }
        guard !momentDraft.isEmpty else {
            errorMessage = NativeStoreError.invalidMoment.localizedDescription
            return
        }
        do {
            try FirstPartyPublicationPolicy.validate(.init(
                kind: .moment,
                body: momentDraft.text,
                attachmentCount: momentDraft.images.count
            ))
        } catch {
            errorMessage = error.localizedDescription
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
                try await reloadMomentFeed(refreshesFacets: true)
                try await refreshActivity()
                scheduleBackup()
                errorMessage = nil
                recordFirstPartyModuleEvent(
                    moduleID: PublishingFirstPartyModule.id,
                    name: "publishing.completed",
                    payload: ["kind": "moment", "id": saved.id]
                )
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

    func beginUpload() -> Int {
        uploadCount += 1
        isUploadingMedia = true
        return workspaceGeneration
    }

    func endUpload() {
        uploadCount = max(0, uploadCount - 1)
        isUploadingMedia = uploadCount > 0
    }

    private var hasRecoverableEditorContent: Bool {
        !editor.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !editor.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !editor.excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !editor.tags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || editor.banner != nil
            || !editor.media.isEmpty
    }

    private var editorRevisionSnapshot: NativeArticleRevisionSnapshot {
        NativeArticleRevisionSnapshot(
            banner: editor.banner,
            body: editor.body,
            category: editor.category,
            excerpt: editor.excerpt,
            media: editor.media,
            status: editor.status,
            tags: NativeArticleTag.parse(editor.tags),
            title: editor.title,
            articleUpdatedAt: editor.updatedAt,
            properties: editor.properties
        )
    }

    private func performEditorAutosave() async {
        guard storageReady, isEditorDirty, hasRecoverableEditorContent else { return }
        guard !isLoading, !isSwitchingWorkspace, !isSaving, !isPublishingMoment, !isUploadingMedia else {
            scheduleEditorAutosave()
            return
        }

        let recoveryID = editor.recoveryID
        let slug = editor.slug.isEmpty ? nil : editor.slug
        let snapshot = editorRevisionSnapshot
        let generation = workspaceGeneration
        isEditorAutosaving = true
        defer { isEditorAutosaving = false }

        do {
            let revision = try await store.saveArticleAutosave(
                draftKey: recoveryID,
                articleSlug: slug,
                snapshot: snapshot
            )
            guard generation == workspaceGeneration, editor.recoveryID == recoveryID else { return }
            editorAutosaveStatus = "已自动保存：\(revision.updatedAt.nativeDateLabel)"
            articleRevisions = try await store.listArticleRevisions(
                articleSlug: slug,
                draftKey: recoveryID
            )
            errorMessage = nil
        } catch {
            guard generation == workspaceGeneration else { return }
            editorAutosaveStatus = "自动保存失败"
            errorMessage = "自动保存失败：\(error.localizedDescription)"
        }
    }

    private func restoreLatestAutosaveIfNeeded(for article: NativeArticle) {
        let generation = workspaceGeneration
        Task {
            do {
                guard let revision = try await store.latestArticleAutosave(articleSlug: article.slug),
                      generation == workspaceGeneration,
                      editor.slug == article.slug,
                      revision.snapshot != NativeArticleRevisionSnapshot(article: article),
                      let autosavedAt = NativeTimestamp.date(from: revision.updatedAt),
                      let articleUpdatedAt = NativeTimestamp.date(from: article.updatedAt),
                      autosavedAt > articleUpdatedAt else { return }

                editor = editorDraft(
                    from: revision.snapshot,
                    recoveryID: article.slug,
                    slug: article.slug,
                    expectedUpdatedAt: article.updatedAt
                )
                editorAutosaveStatus = "已恢复自动保存：\(revision.updatedAt.nativeDateLabel)"
                refreshArticleHistory()
            } catch {
                guard generation == workspaceGeneration else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func restoreLatestUnsavedArticleDraftIfNeeded() async throws {
        guard let revision = try await store.latestUnsavedArticleAutosave() else { return }
        editorOriginalArticle = nil
        pendingEditorMediaCleanup = []
        selectedSlug = nil
        selectedArticle = nil
        selectedArticleRelations = .empty
        articleComments = []
        pendingArticleCommentSelection = nil
        editor = editorDraft(
            from: revision.snapshot,
            recoveryID: revision.draftKey,
            slug: "",
            expectedUpdatedAt: nil
        )
        articleRevisions = try await store.listArticleRevisions(
            articleSlug: nil,
            draftKey: revision.draftKey
        )
        editorAutosaveStatus = "已恢复自动保存：\(revision.updatedAt.nativeDateLabel)"
        section = .editor
    }

    private func editorDraft(
        from snapshot: NativeArticleRevisionSnapshot,
        recoveryID: String,
        slug: String,
        expectedUpdatedAt: String?
    ) -> NativeEditorDraft {
        NativeEditorDraft(
            recoveryID: recoveryID,
            slug: slug,
            title: snapshot.title,
            category: snapshot.category,
            excerpt: snapshot.excerpt,
            tags: articleTagText(snapshot.tags),
            body: snapshot.body,
            banner: snapshot.banner,
            media: snapshot.media,
            properties: snapshot.properties,
            status: snapshot.status,
            updatedAt: expectedUpdatedAt
        )
    }

    private func discardArticleAutosaves(draftKey: String, newerThan timestamp: String?) {
        let sourceStore = store
        Task {
            try? await sourceStore.discardArticleAutosaves(draftKey: draftKey, newerThan: timestamp)
        }
    }

    private var isEditorDirty: Bool {
        if editor.isNew {
            return !editor.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !editor.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !editor.excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !editor.tags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || editor.category != "Notes"
                || editor.banner != nil
                || !editor.media.isEmpty
        }
        guard let original = editorOriginalArticle else { return false }
        return editor.title != original.title
            || editor.body != original.body
            || editor.excerpt != original.excerpt
            || editor.category != original.category
            || !articleTagsEqual(NativeArticleTag.parse(editor.tags), original.tags)
            || editor.banner != original.banner
            || editor.media != original.media
            || editor.properties != original.properties
            || editor.status != original.status
    }

    private var isMomentDraftDirty: Bool {
        !momentDraft.isEmpty || editingMomentID != nil
    }

    private func articleTagText(_ tags: [String]) -> String {
        NativeArticleTag.normalized(tags).map { "#\($0)" }.joined(separator: " ")
    }

    private func articleTagsEqual(_ lhs: [String], _ rhs: [String]) -> Bool {
        NativeArticleTag.normalized(lhs).map(tagIdentifier)
            == NativeArticleTag.normalized(rhs).map(tagIdentifier)
    }

    private func confirmDiscardUnsavedWork(includingMomentDraft: Bool = false) -> Bool {
        let willDiscardMomentDraft = includingMomentDraft && isMomentDraftDirty
        let willDiscardQuestionAnswerDraft = includingMomentDraft && !questionAnswerDraft.isEmpty
        guard isEditorDirty || willDiscardMomentDraft || willDiscardQuestionAnswerDraft else { return true }
        let alert = NSAlert()
        alert.messageText = "放弃未保存的修改？"
        let draftCount = [isEditorDirty, willDiscardMomentDraft, willDiscardQuestionAnswerDraft]
            .filter { $0 }.count
        if draftCount > 1 {
            alert.informativeText = "当前有多份草稿包含未保存的内容或图片。"
        } else if willDiscardQuestionAnswerDraft {
            alert.informativeText = "当前回答草稿还有未发布的文字或图片。"
        } else if willDiscardMomentDraft {
            alert.informativeText = "当前微博草稿还有未发布的内容或图片。"
        } else {
            alert.informativeText = "当前文章还有未保存的标题、正文或附件。"
        }
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

    func discardUnreferencedMedia(_ media: [NativeMedia]) {
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

    private func discardCurrentQuestionAnswerDraft() async {
        let discardedMedia = questionAnswerDraft.images
        questionAnswerDraft = NativeQuestionAnswerDraft()
        editingQuestionAnswerID = nil
        editingQuestionAnswerUpdatedAt = nil
        guard !discardedMedia.isEmpty else { return }
        let sourceStore = store
        try? await sourceStore.discardUnreferencedMedia(discardedMedia)
    }

    private func discardCurrentEditorDraft() async {
        let discardsDirtyEditor = isEditorDirty
        let recoveryID = editor.recoveryID
        let discardedMedia = editorDraftMedia() + pendingEditorMediaCleanup
        pendingEditorMediaCleanup = []
        let sourceStore = store
        if discardsDirtyEditor {
            try? await sourceStore.discardArticleAutosaves(
                draftKey: recoveryID,
                newerThan: editorOriginalArticle?.updatedAt
            )
        }
        guard !discardedMedia.isEmpty else { return }
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

    func startTrashCleanupLoop() {
        guard claimBackgroundMaintenanceOwnership(), trashCleanupTask == nil else { return }
        trashCleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                try? await self.store.performMaintenance()
                try? await self.refreshTrash()
            }
        }
    }

    func claimBackgroundMaintenanceOwnership() -> Bool {
        if let owner = Self.backgroundMaintenanceOwner {
            return owner === self
        }
        Self.backgroundMaintenanceOwner = self
        return true
    }

    private func refreshTrash() async throws {
        trashItems = try await store.listTrash()
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
