import AppKit
import Foundation
import LeonBookSearchModule

extension NativeAppModel {
    public func presentGlobalSearch() {
        guard storageReady,
              authorizeFirstPartyModule(
                SearchFirstPartyModule.id,
                permission: .contentRead,
                action: "搜索"
              ) else { return }
        searchPresentation = .globalSearch
        updateGlobalSearch(globalSearchText, articlesOnly: false, debounce: false)
    }

    public func handleAutomationURL(_ url: URL) {
        do {
            receiveAutomationCommand(try NativeAutomationURL.command(from: url))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func consumeAutomationInbox() {
        guard canPerformAutomationRoutes else {
            scheduleAutomationRetryIfNeeded()
            return
        }
        for command in NativeAutomationInbox.drain() { executeCommand(command) }
    }

    private func receiveAutomationCommand(_ command: NativeCommandInvocation) {
        guard canPerformAutomationRoutes else {
            NativeAutomationInbox.enqueue(command)
            scheduleAutomationRetryIfNeeded()
            return
        }
        executeCommand(command)
    }

    private var canPerformAutomationRoutes: Bool {
        storageReady
            && !isSwitchingWorkspace
            && !isRestoringBackup
            && !isSaving
            && !isSavingArticleComment
            && !isPublishingMoment
            && !isUploadingMedia
            && !isBackingUp
            && !isScanningObsidianVault
            && !isImportingObsidianVault
    }

    private func scheduleAutomationRetryIfNeeded() {
        guard storageReady, automationRetryTask == nil else { return }
        automationRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            automationRetryTask = nil
            consumeAutomationInbox()
        }
    }

    public func presentQuickSwitcher() {
        guard storageReady,
              authorizeFirstPartyModule(
                SearchFirstPartyModule.id,
                permission: .contentRead,
                action: "快速打开"
              ) else { return }
        globalSearchText = ""
        searchPresentation = .quickOpen
        updateGlobalSearch("", articlesOnly: true, debounce: false)
    }

    public func presentCommandPalette() {
        searchPresentation = .commandPalette
    }

    func updateGlobalSearch(
        _ query: String,
        articlesOnly: Bool,
        debounce: Bool = true
    ) {
        guard isSearchModuleEnabled else {
            globalSearchResults = []
            isSearchingGlobally = false
            return
        }
        globalSearchText = query
        globalSearchTask?.cancel()
        globalSearchGeneration += 1
        let generation = globalSearchGeneration
        let workspace = workspaceGeneration
        let activeStore = store
        isSearchingGlobally = true

        globalSearchTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: 160_000_000)
            }
            guard !Task.isCancelled, let self else { return }
            do {
                let types: Set<NativeSearchDocumentType> = articlesOnly ? [.article] : []
                let results = try await activeStore.search(query, restrictingTo: types)
                guard !Task.isCancelled,
                      generation == self.globalSearchGeneration,
                      workspace == self.workspaceGeneration else { return }
                self.globalSearchResults = results
                self.isSearchingGlobally = false
                self.recordFirstPartyModuleEvent(
                    moduleID: SearchFirstPartyModule.id,
                    name: "search.completed",
                    payload: ["resultCount": String(results.count)]
                )
            } catch {
                guard !Task.isCancelled,
                      generation == self.globalSearchGeneration,
                      workspace == self.workspaceGeneration else { return }
                self.globalSearchResults = []
                self.isSearchingGlobally = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func updateArticleListSearch(_ query: String, debounce: Bool = true) {
        articleListSearchTask?.cancel()
        articleListSearchGeneration += 1
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSearchModuleEnabled else {
            articleSearchMatchSlugs = []
            articleSearchResolvedText = ""
            isSearchingArticles = false
            return
        }
        guard !trimmed.isEmpty else {
            articleSearchMatchSlugs = []
            articleSearchResolvedText = ""
            isSearchingArticles = false
            return
        }

        let generation = articleListSearchGeneration
        let workspace = workspaceGeneration
        let activeStore = store
        isSearchingArticles = true
        articleListSearchTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: 160_000_000)
            }
            guard !Task.isCancelled, let self else { return }
            do {
                let results = try await activeStore.search(
                    trimmed,
                    restrictingTo: [.article],
                    limit: 200
                )
                guard !Task.isCancelled,
                      generation == self.articleListSearchGeneration,
                      workspace == self.workspaceGeneration else { return }
                self.articleSearchMatchSlugs = Set(results.map(\.documentID))
                self.articleSearchResolvedText = trimmed
                self.isSearchingArticles = false
            } catch {
                guard !Task.isCancelled,
                      generation == self.articleListSearchGeneration,
                      workspace == self.workspaceGeneration else { return }
                self.articleSearchMatchSlugs = []
                self.articleSearchResolvedText = trimmed
                self.isSearchingArticles = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func openSearchResult(_ result: NativeGlobalSearchResult) {
        searchPresentation = nil
        globalSearchTask?.cancel()
        switch result.documentType {
        case .article:
            openArticleLink(result.documentID)
        case .moment:
            openMomentSearchResult(result.documentID)
        }
    }

    public func canExecuteCommand(_ command: NativeCommandID) -> Bool {
        firstPartyModuleAllowsCommand(command)
            && commandRegistry.definition(for: command)?.isAvailable(in: commandContext) == true
    }

    public func executeCommand(_ command: NativeCommandID) {
        executeCommand(NativeCommandInvocation(id: command))
    }

    public func executeCommand(_ invocation: NativeCommandInvocation) {
        let command = invocation.id
        guard firstPartyModuleAllowsCommand(command) else {
            if let module = firstPartyModuleRuntime.catalog.module(owningCommand: command.rawValue) {
                errorMessage = "“\(module.name)”模块已停用，无法执行该命令。"
                recordFirstPartyModuleEvent(
                    moduleID: module.id,
                    name: "module.authorization-denied",
                    payload: ["command": command.rawValue]
                )
            }
            return
        }
        guard let definition = commandRegistry.definition(for: command) else {
            errorMessage = "找不到命令“\(command.rawValue)”。"
            return
        }
        guard definition.isAvailable(in: commandContext) else { return }

        searchPresentation = nil
        commandPreferences.recordUse(command)

        if executeFirstPartyModuleCommand(invocation) { return }

        if command == .commandPalette {
            presentCommandPalette()
        } else if command == .newArticle {
            performNewArticleCommand(invocation)
        } else if command == .saveDraft {
            Task { await saveEditor(as: .draft) }
        } else if command == .dashboard {
            section = .dashboard
        } else if command == .articles {
            showAllArticles()
        } else if command == .moments {
            section = .moments
        } else if command == .today {
            performTodayCommand()
        } else if command == .trash {
            section = .trash
        } else if command == .settings {
            section = .settings
        } else if command == .articleBack {
            navigateArticleBack()
        } else if command == .articleForward {
            navigateArticleForward()
        } else if command == .toggleArticleTabPin {
            toggleActiveArticleTabPin()
        } else if command == .closeArticleTab {
            closeActiveArticleTab()
        } else if command == .openArticle {
            performOpenArticleCommand(invocation)
        } else if command == .reload {
            Task {
                do { try await reload() }
                catch { errorMessage = error.localizedDescription }
            }
        } else if let insertion = definition.textInsertion {
            performEditorInsertion(insertion, invocation: invocation)
        }
    }

    private func performNewArticleCommand(_ invocation: NativeCommandInvocation) {
        let previousRecoveryID = editor.recoveryID
        newArticle()
        guard editor.recoveryID != previousRecoveryID else { return }

        let title = invocation.arguments["title"]
        let content = invocation.arguments["content"]
        let sourceURL = invocation.arguments["sourceURL"]
        if let title { editor.title = title }
        var bodyParts: [String] = []
        if let content { bodyParts.append(content) }
        if let sourceURL { bodyParts.append("来源：\(sourceURL)") }
        if !bodyParts.isEmpty { editor.body = bodyParts.joined(separator: "\n\n") }
        if title != nil || !bodyParts.isEmpty {
            editorAutosaveStatus = "已从自动化入口预填，等待保存…"
            scheduleEditorAutosave()
        }
    }

    private func performOpenArticleCommand(_ invocation: NativeCommandInvocation) {
        guard let slug = invocation.arguments["slug"], !slug.isEmpty else {
            errorMessage = "打开文章命令缺少 slug。"
            return
        }
        guard let article = articles.first(where: {
            $0.slug.caseInsensitiveCompare(slug) == .orderedSame
        }) else {
            errorMessage = "找不到 slug 为“\(slug)”的文章。"
            return
        }
        openArticleLink(article.slug, disposition: .currentTab)
    }

    private func performTodayCommand() {
        momentSearchText = ""
        selectedMomentTags = []
        momentDateFilter = .today
        showsOnlyFavoriteMoments = false
        section = .moments
        Task {
            do {
                try await reloadMomentFeed()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performEditorInsertion(
        _ insertion: NativeCommandTextInsertion,
        invocation: NativeCommandInvocation
    ) {
        let source = editor.body as NSString
        let requestedLocation = invocation.arguments["selectionLocation"].flatMap(Int.init)
        let requestedLength = invocation.arguments["selectionLength"].flatMap(Int.init)
        let location = min(max(0, requestedLocation ?? editorBodySelection.location), source.length)
        let length = min(
            max(0, requestedLength ?? editorBodySelection.length),
            max(0, source.length - location)
        )
        let replacementRange = NSRange(location: location, length: length)
        editor.body = source.replacingCharacters(in: replacementRange, with: insertion.text)
        editorBodySelection = NSRange(
            location: replacementRange.location + insertion.cursorOffset,
            length: 0
        )
    }

    private func openMomentSearchResult(_ id: String) {
        let workspace = workspaceGeneration
        let activeStore = store
        Task {
            do {
                let moment = try await activeStore.getMoment(id: id)
                guard workspace == workspaceGeneration else { return }
                selectedMomentTags = []
                momentDateFilter = .all
                showsOnlyFavoriteMoments = false

                let text = moment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    momentSearchText = text
                    try await reloadMomentFeed()
                } else if let tag = moment.tags.first {
                    momentSearchText = ""
                    selectedMomentTags = [tag]
                    try await reloadMomentFeed()
                } else {
                    momentSearchText = ""
                    moments = [moment]
                    filteredMomentCount = 1
                    nextMomentCursor = nil
                    hasMoreMoments = false
                }
                section = .moments
                errorMessage = nil
            } catch {
                guard workspace == workspaceGeneration else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

}
