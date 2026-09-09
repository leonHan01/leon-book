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

    static func pauseForRestore(in root: URL, initiatedBy initiator: NativeAppModel) throws -> [NativeAppModel] {
        let affected = matching(root)
        guard affected.allSatisfy({ model in
            !model.isSaving && !model.isEditorAutosaving && !model.isSavingArticleComment
                && !model.isPublishingMoment && !model.isPublishingQuestion
                && !model.isPublishingQuestionAnswer && !model.isUploadingMedia
                && !model.isImportingObsidianVault && !model.isSwitchingWorkspace
                && !model.isBackingUp && !model.isLoading
                && (model === initiator || !model.isRestoringBackup)
        }) else {
            throw NativeStoreError.fileSystem("其他窗口仍在处理资料库操作，请完成后再恢复。")
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
        articleNavigationGeneration += 1
        stopMarkdownSourceMonitor()
        editorAutosaveTask?.cancel()
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
