import AppKit
import Foundation
import LeonBookBackupModule
import LeonBookModuleKit

extension NativeAppModel {
    func scheduleCompatibilityExportVerification(for sourceStore: LocalBlogStore) {
        compatibilityExportTask?.cancel()
        compatibilityExportTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            do {
                try await sourceStore.verifyCompatibilityExports()
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorMessage = "兼容导出校验失败：\(error.localizedDescription)"
            }
        }
    }

    func scheduleBackupOverviewRefresh() {
        backupOverviewTask?.cancel()
        backupOverviewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.refreshBackupOverview()
        }
    }

    func chooseBackupDirectory() {
        guard authorizeFirstPartyModule(
            BackupFirstPartyModule.id,
            permission: .backupWrite,
            action: "设置备份目录"
        ) else { return }
        guard !isBackingUp, !isRestoringBackup else { return }
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
            backupSnapshots = []
            backupStorageEstimate = nil
            backupNow()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearBackupDirectory() {
        guard authorizeFirstPartyModule(
            BackupFirstPartyModule.id,
            permission: .backupWrite,
            action: "清除备份设置"
        ) else { return }
        guard !isBackingUp, !isRestoringBackup else { return }
        backupTask?.cancel()
        LocalBlogStore.clearBackupDirectory()
        backupDirectoryPath = ""
        lastBackupPath = ""
        backupStatus = "未设置备份目录"
        backupSnapshots = []
        backupStorageEstimate = nil
        backupValidationStatus = "尚未校验快照"
    }

    func openBackupDirectory() {
        guard authorizeFirstPartyModule(
            BackupFirstPartyModule.id,
            permission: .backupRead,
            action: "打开备份目录"
        ) else { return }
        guard !backupDirectoryPath.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: backupDirectoryPath)
    }

    func backupNow() {
        guard authorizeFirstPartyModule(
            BackupFirstPartyModule.id,
            permission: .backupWrite,
            action: "创建备份"
        ) else { return }
        guard !isRestoringBackup else { return }
        backupTask?.cancel()
        backupTask = Task { [weak self] in
            _ = await self?.performBackup(manual: true)
        }
    }

    func scheduleBackup() {
        // Compatibility exports are intentionally coalesced with ordinary
        // mutations even when automatic snapshots are not configured.
        scheduleCompatibilityExportVerification(for: store)
        guard authorizeFirstPartyModule(
                BackupFirstPartyModule.id,
                permission: .backupWrite,
                action: "创建自动备份",
                presentsError: false
              ),
              claimBackgroundMaintenanceOwnership(),
              !backupDirectoryPath.isEmpty,
              !isRestoringBackup else { return }
        startTrashCleanupLoop()
        backupTask?.cancel()
        let newestSnapshotDate = backupSnapshots.first(where: \.isManifestReadable)?.createdAt
        let intervalDelay = newestSnapshotDate.map {
            max(0, $0.addingTimeInterval(backupPolicy.automaticInterval).timeIntervalSinceNow)
        } ?? 0
        let delay = max(30, intervalDelay)
        if intervalDelay > 30, !isBackingUp {
            let nextDate = Date().addingTimeInterval(delay)
            backupStatus = "变更已合并，下次自动备份：\(nextDate.formatted(date: .omitted, time: .shortened))"
        }
        backupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            _ = await self?.performBackup(manual: false)
        }
    }

    @discardableResult
    private func performBackup(manual: Bool) async -> Bool {
        guard authorizeFirstPartyModule(
            BackupFirstPartyModule.id,
            permission: .backupWrite,
            action: "创建备份",
            presentsError: manual
        ) else { return false }
        guard storageReady, !backupDirectoryPath.isEmpty else { return false }
        guard !isBackingUp, !isRestoringBackup else { return false }
        guard !isLoading, !isSwitchingWorkspace, !isSaving, !isPublishingMoment, !isUploadingMedia else {
            backupStatus = "等待当前操作完成后备份…"
            scheduleBackup()
            return false
        }

        let sourceURL = URL(fileURLWithPath: dataRootDirectoryPath, isDirectory: true)
        let destinationURL = URL(fileURLWithPath: backupDirectoryPath, isDirectory: true)
        let policy = backupPolicy
        isBackingUp = true
        backupStatus = manual ? "正在创建手动备份…" : "正在创建增量备份…"
        recordFirstPartyModuleEvent(
            moduleID: BackupFirstPartyModule.id,
            name: "backup.requested",
            payload: ["manual": String(manual)]
        )
        defer { isBackingUp = false }

        do {
            try await store.prepareForBackup()
            try await userWorkspaces.prepareForBackup()
            let result = try await Task.detached(priority: .utility) {
                try LocalBackupManager.createManagedSnapshot(
                    source: sourceURL,
                    destination: destinationURL,
                    policy: policy
                )
            }.value
            lastBackupPath = result.snapshot.url.path
            let reused = result.reusedFileCount > 0 ? "，复用 \(result.reusedFileCount) 个文件" : ""
            let cleaned = result.removedSnapshotCount > 0 ? "，清理 \(result.removedSnapshotCount) 个过期快照" : ""
            backupStatus = "备份完成：\(result.snapshot.url.lastPathComponent)\(reused)\(cleaned)"
            await refreshBackupOverview()
            errorMessage = nil
            recordFirstPartyModuleEvent(
                moduleID: BackupFirstPartyModule.id,
                name: "backup.completed",
                payload: ["snapshot": result.snapshot.url.lastPathComponent]
            )
            return true
        } catch {
            backupStatus = "备份失败"
            errorMessage = "\(manual ? "手动" : "自动")备份失败：\(error.localizedDescription)"
            recordFirstPartyModuleEvent(
                moduleID: BackupFirstPartyModule.id,
                name: "backup.failed",
                payload: ["reason": error.localizedDescription]
            )
            return false
        }
    }

    var backupAutomaticIntervalHours: Int {
        max(1, Int(backupPolicy.automaticInterval / (60 * 60)))
    }

    var backupRetentionDays: Int { backupPolicy.retentionDays }
    var backupMaximumSnapshotCount: Int { backupPolicy.maximumSnapshotCount }
    var backupMinimumFreeSpaceGB: Int {
        max(0, Int(backupPolicy.minimumFreeSpaceBytes / (1_024 * 1_024 * 1_024)))
    }

    func updateBackupPolicy(
        automaticIntervalHours: Int? = nil,
        retentionDays: Int? = nil,
        maximumSnapshotCount: Int? = nil,
        minimumFreeSpaceGB: Int? = nil
    ) {
        guard authorizeFirstPartyModule(
            BackupFirstPartyModule.id,
            permission: .backupWrite,
            action: "修改备份策略"
        ) else { return }
        backupPolicy = NativeBackupPolicy(
            automaticInterval: TimeInterval(automaticIntervalHours ?? backupAutomaticIntervalHours) * 60 * 60,
            retentionDays: retentionDays ?? backupRetentionDays,
            maximumSnapshotCount: maximumSnapshotCount ?? backupMaximumSnapshotCount,
            minimumFreeSpaceBytes: Int64(minimumFreeSpaceGB ?? backupMinimumFreeSpaceGB) * 1_024 * 1_024 * 1_024
        )
        LocalBlogStore.rememberBackupPolicy(backupPolicy)
        guard !backupDirectoryPath.isEmpty else { return }
        let destinationURL = URL(fileURLWithPath: backupDirectoryPath, isDirectory: true)
        let policy = backupPolicy
        Task {
            _ = try? await Task.detached(priority: .utility) {
                try LocalBackupManager.enforceRetention(in: destinationURL, policy: policy)
            }.value
            await refreshBackupOverview()
            scheduleBackup()
        }
    }

    func refreshBackupOverviewNow() {
        Task { await refreshBackupOverview() }
    }

    func refreshBackupOverview() async {
        guard authorizeFirstPartyModule(
            BackupFirstPartyModule.id,
            permission: .backupRead,
            action: "读取备份快照",
            presentsError: false
        ) else {
            backupSnapshots = []
            backupStorageEstimate = nil
            return
        }
        guard !backupDirectoryPath.isEmpty else {
            backupSnapshots = []
            backupStorageEstimate = nil
            return
        }
        let sourceURL = URL(fileURLWithPath: dataRootDirectoryPath, isDirectory: true)
        let destinationURL = URL(fileURLWithPath: backupDirectoryPath, isDirectory: true)
        do {
            let overview = try await Task.detached(priority: .utility) {
                try LocalBackupManager.overview(
                    source: sourceURL,
                    destination: destinationURL
                )
            }.value
            backupSnapshots = overview.snapshots
            backupStorageEstimate = overview.estimate
            lastBackupPath = overview.snapshots.first?.url.path ?? ""
        } catch {
            backupValidationStatus = "无法读取快照：\(error.localizedDescription)"
        }
    }

    func showBackupSnapshotInFinder(_ snapshot: NativeBackupSnapshot) {
        NSWorkspace.shared.activateFileViewerSelecting([snapshot.url])
    }

    func validateBackupSnapshot(_ snapshot: NativeBackupSnapshot) {
        guard authorizeFirstPartyModule(
            BackupFirstPartyModule.id,
            permission: .backupRead,
            action: "校验备份快照"
        ) else { return }
        guard !isValidatingBackup, !isRestoringBackup else { return }
        isValidatingBackup = true
        backupValidationStatus = "正在校验 \(snapshot.url.lastPathComponent)…"
        Task {
            defer { isValidatingBackup = false }
            do {
                let result = try await Task.detached(priority: .utility) {
                    try LocalBackupManager.validateSnapshot(at: snapshot.url)
                }.value
                let checksumLabel = result.verifiedChecksums ? "SHA-256 完整校验" : "旧格式结构校验"
                backupValidationStatus = "校验通过：\(result.checkedFileCount) 个文件，\(checksumLabel)"
                errorMessage = nil
            } catch {
                backupValidationStatus = "校验失败"
                errorMessage = error.localizedDescription
            }
        }
    }

    func restoreBackupSnapshot(_ snapshot: NativeBackupSnapshot) {
        guard authorizeFirstPartyModule(
            BackupFirstPartyModule.id,
            permission: .backupWrite,
            action: "恢复备份快照"
        ) else { return }
        guard storageReady,
              !isBackingUp,
              !isRestoringBackup,
              !isSaving,
              !isPublishingMoment,
              !isUploadingMedia else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "恢复整个资料库？"
        alert.informativeText = "将先为当前数据创建一个安全快照，再用 \(snapshot.url.lastPathComponent) 替换所有用户、文章、微博、媒体和设置。恢复前会校验所选快照；新版快照会执行 SHA-256 完整校验。"
        alert.addButton(withTitle: "校验并恢复")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Lock module lifecycle before yielding to the restore task. A restore
        // cannot be cancelled safely after it starts replacing workspace data.
        isRestoringBackup = true
        Task { await performBackupRestore(snapshot) }
    }

    func performBackupRestore(_ snapshot: NativeBackupSnapshot) async {
        let rootURL = URL(fileURLWithPath: dataRootDirectoryPath, isDirectory: true)
        let destinationURL = URL(fileURLWithPath: backupDirectoryPath, isDirectory: true)
        let policy = backupPolicy
        let affected: [NativeAppModel]
        do {
            affected = try NativeWorkspaceWindows.pauseForRestore(in: rootURL, initiatedBy: self)
        } catch {
            isRestoringBackup = false
            errorMessage = error.localizedDescription
            return
        }
        // Restore runs in its own task; cancel all previously scheduled backups.
        for model in affected { model.backupTask?.cancel() }
        var suspension: WorkspaceStorageLifecycle.Suspension?
        var restoreError: Error?
        var didRestore = false
        backupStatus = "恢复前正在创建当前数据的安全快照…"

        do {
            for model in affected { try await model.preserveEditorBeforeRestore() }
            let session = try WorkspaceStorageLifecycle.suspend(in: rootURL)
            suspension = session
            try await session.prepareAndClose()
            let safetySnapshot = try await Task.detached(priority: .utility) {
                try LocalBackupManager.createManagedSnapshot(
                    source: rootURL,
                    destination: destinationURL,
                    policy: policy,
                    enforceRetention: false
                )
            }.value
            lastBackupPath = safetySnapshot.snapshot.url.path
            backupStatus = "正在校验并恢复资料库…"
            try await Task.detached(priority: .userInitiated) {
                try LocalBackupManager.restoreSnapshot(
                    at: snapshot.url,
                    to: rootURL,
                    minimumFreeSpaceBytes: policy.minimumFreeSpaceBytes
                )
            }.value
            didRestore = true
        } catch {
            restoreError = error
        }
        suspension?.finish()

        // Include windows created during the restore. They were prevented from
        // opening a database by the shared storage gate.
        for model in NativeWorkspaceWindows.matching(rootURL) {
            do {
                if !didRestore, affected.contains(where: { $0 === model }) {
                    try await model.store.prepareForInteractiveUse()
                    try await model.reload()
                    model.startMarkdownSourceMonitor()
                    model.storageReady = true
                } else {
                    try await model.connect(to: rootURL, preferredUserID: model.currentUser.id)
                }
                model.errorMessage = restoreError?.localizedDescription
            } catch {
                model.storageReady = false
                model.errorMessage = "无法重新连接资料库：\(error.localizedDescription)"
            }
            model.isBackingUp = false
            model.isRestoringBackup = false
            model.isLoading = false
            model.backupStatus = didRestore
                ? "恢复完成：\(snapshot.url.lastPathComponent)；恢复前数据已保存为安全快照"
                : "恢复失败：\(restoreError?.localizedDescription ?? "未知错误")"
            if didRestore { model.backupValidationStatus = "恢复时已通过快照校验" }
            model.startTrashCleanupLoop()
            model.consumeAutomationInbox()
        }
        await refreshBackupOverview()
        if didRestore {
            recordFirstPartyModuleEvent(
                moduleID: BackupFirstPartyModule.id,
                name: "backup.restored",
                payload: ["snapshot": snapshot.url.lastPathComponent]
            )
        }
    }

}
