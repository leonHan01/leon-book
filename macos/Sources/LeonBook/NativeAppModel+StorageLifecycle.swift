import Foundation

@MainActor
enum NativeWorkspaceWindows {
    private static let models = NSHashTable<NativeAppModel>.weakObjects()

    static func register(_ model: NativeAppModel) { models.add(model) }

    static func matching(_ root: URL) -> [NativeAppModel] {
        let path = root.standardizedFileURL.resolvingSymlinksInPath().path
        return models.allObjects.filter {
            URL(fileURLWithPath: $0.dataRootDirectoryPath)
                .standardizedFileURL.resolvingSymlinksInPath().path == path
        }
    }

    static func reloadTodos(in root: URL, excluding initiator: NativeAppModel) {
        for model in models.allObjects where model !== initiator && model.store.rootURL.standardizedFileURL == root.standardizedFileURL && model.storageReady && !model.isRestoringBackup {
            Task { [weak model] in
                do { try await model?.reloadTodos() }
                catch { model?.errorMessage = error.localizedDescription }
            }
        }
    }

    static func reloadDashboards(in root: URL, excluding initiator: NativeAppModel) {
        for model in models.allObjects where model !== initiator && model.store.rootURL.standardizedFileURL == root.standardizedFileURL && model.storageReady && !model.isRestoringBackup {
            Task { [weak model] in await model?.reloadDashboard() }
        }
    }

    static func reloadAfterAutomation(in workspace: URL, dataRoot: URL) {
        for model in matching(dataRoot) where model.store.rootURL.standardizedFileURL.resolvingSymlinksInPath() == workspace.standardizedFileURL.resolvingSymlinksInPath() && model.storageReady && !model.isRestoringBackup {
            Task { [weak model] in
                guard let model else { return }
                do {
                    // reload() preserves dirty editor buffers and refreshes saved views.
                    try await model.reload()
                    model.scheduleBackup()
                } catch { model.errorMessage = error.localizedDescription }
            }
        }
    }

    static func automationCommand(_ request: AutomationRequest, root: URL) throws -> AutomationValue {
        let p = AutomationParameters(values: request.params ?? [:])
        let windowID: String? = try p.optional("windowID")
        let candidates = matching(root).filter {
            $0.storageReady && !$0.isRestoringBackup && $0.navigationScopeID != "settings"
                && (request.userID == nil || $0.currentUser.id == request.userID)
                && (windowID == nil || $0.navigationScopeID == windowID)
        }
        guard !candidates.isEmpty else { throw AutomationFailure("app_unavailable", "No matching app window is ready. Open the app or use a content operation.") }
        if request.method == "app.commands" {
            return .array(candidates.map { model in
                .object([
                    "windowID": model.navigationScopeID.map(AutomationValue.string) ?? .null,
                    "userID": .string(model.currentUser.id),
                    "commands": .array(model.commandRegistry.definitions.map {
                        .object(["id": .string($0.id.rawValue), "title": .string($0.title), "description": .string($0.detail), "available": .bool(model.canExecuteCommand($0.id))])
                    }),
                ])
            })
        }
        guard candidates.count == 1 else { throw AutomationFailure("ambiguous_window", "Multiple windows match; supply windowID from app.commands.") }
        let model = candidates[0], command = NativeCommandID(rawValue: try p.required("command"))
        guard model.commandRegistry.definition(for: command) != nil else { throw AutomationFailure("method_not_found", "Unknown or disabled app command") }
        guard model.canExecuteCommand(command) else { throw AutomationFailure("busy", "Command is unavailable in this window's current state") }
        model.executeCommand(.init(id: command, arguments: try p.optional("arguments") ?? [:]))
        return .object(["accepted": .bool(true), "command": .string(command.rawValue)])
    }

    static func pauseForRestore(in root: URL, initiatedBy initiator: NativeAppModel) throws -> [NativeAppModel] {
        let affected = matching(root)
        guard affected.allSatisfy({ model in
            !model.isSaving && !model.isEditorAutosaving && !model.isSavingArticleComment
                && !model.isSavingMomentComment
                && !model.isPublishingMoment && !model.isPublishingQuestion
                && !model.isPublishingQuestionAnswer && !model.isUploadingMedia
                && !model.isSavingTodo && !model.isSavingDashboard
                && !model.isImportingObsidianVault && !model.isSwitchingWorkspace
                && !model.isBackingUp && !model.isLoading
                && (model === initiator || !model.isRestoringBackup)
        }) else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("其他窗口仍在处理资料库操作，请完成后再恢复。"))
        }
        for model in affected { model.pauseForWorkspaceRestore() }
        return affected
    }
}

extension NativeAppModel {
    func pauseForWorkspaceRestore() {
        isRestoringBackup = true
        isBackingUp = true
        isLoading = true
        storageReady = false
        workspaceGeneration += 1
        todoLoadGeneration += 1
        todoSession = NativeTodoSession()
        articleNavigationGeneration += 1
        stopMarkdownSourceMonitor()
        editorAutosaveTask?.cancel()
        editorRecoveryTask?.cancel()
        trashCleanupTask?.cancel()
        trashCleanupTask = nil
        articleAncillaryLoadTask?.cancel()
        articlePostSaveTask?.cancel()
        articleNavigationPersistenceTask?.cancel()
        compatibilityExportTask?.cancel()
        workspaceAncillaryLoadTask?.cancel()
        articleListSearchTask?.cancel()
        globalSearchTask?.cancel()
        momentSearchTask?.cancel()
        questionSearchTask?.cancel()
        knowledgeGraphTask?.cancel()
        obsidianScanTask?.cancel()
        backupOverviewTask?.cancel()
        automationRetryTask?.cancel()
    }

    func preserveEditorBeforeRestore() async throws {
        guard hasUnsavedEditorChanges else { return }
        _ = try await store.saveArticleAutosave(
            draftKey: editor.recoveryID,
            articleSlug: editor.slug.isEmpty ? nil : editor.slug,
            snapshot: currentArticleHistorySnapshot
        )
    }

    func refreshMarkdownWorkspaceConfiguration() async {
        guard storageReady, !isRestoringBackup else { return }
        do {
            let state = try await store.markdownWorkspaceSourceState()
            let directory = try await store.markdownSourceDirectoryURL()
            let changed = activeMarkdownWorkspaceMode != state.mode || markdownSourceDirectoryPath != directory.path
            guard changed else { return }
            activeMarkdownWorkspaceMode = state.mode
            selectedMarkdownWorkspaceMode = state.mode
            markdownSourceDirectoryPath = directory.path
            startMarkdownSourceMonitor()
            try await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
