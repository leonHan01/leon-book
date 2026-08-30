import AppKit
import Foundation
import LeonBookCaptureModule
import LeonBookModuleKit

extension NativeAppModel {
    func chooseObsidianVault() {
        guard authorizeFirstPartyModule(
                CaptureFirstPartyModule.id,
                permission: .fileRead,
                action: "扫描 Markdown 文件夹"
              ),
              storageReady,
              !isScanningObsidianVault,
              !isImportingObsidianVault,
              !isSwitchingWorkspace,
              !isSaving,
              !isBackingUp else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 Markdown 文件夹或 Obsidian Vault"
        panel.message = selectedMarkdownWorkspaceMode.detail
        panel.prompt = "扫描此文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let vaultURL = panel.url else { return }

        let generation = workspaceGeneration
        isScanningObsidianVault = true
        recordFirstPartyModuleEvent(
            moduleID: CaptureFirstPartyModule.id,
            name: "capture.scan-requested",
            payload: ["path": vaultURL.path]
        )
        obsidianImportStatus = "正在扫描 \(vaultURL.lastPathComponent)…"
        obsidianImportPreview = nil
        obsidianScanTask?.cancel()
        obsidianScanTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isScanningObsidianVault = false
                self.obsidianScanTask = nil
            }
            do {
                let existingSlugs = self.selectedMarkdownWorkspaceMode == .copyImport
                    ? try await self.store.existingManagedMarkdownSlugs()
                    : []
                let scanner = Task.detached(priority: .userInitiated) {
                    try NativeObsidianVaultImporter.scan(
                        vaultURL: vaultURL,
                        existingSlugs: existingSlugs,
                        shouldCancel: { Task.isCancelled }
                    )
                }
                let preview = try await withTaskCancellationHandler {
                    try await scanner.value
                } onCancel: {
                    scanner.cancel()
                }
                guard !Task.isCancelled,
                      generation == self.workspaceGeneration,
                      self.isCaptureModuleEnabled else { return }
                self.obsidianImportPreview = preview
                self.obsidianImportStatus = preview.notes.isEmpty
                    ? "没有找到 Markdown 文件"
                    : "扫描完成，等待确认"
                self.errorMessage = nil
                self.recordFirstPartyModuleEvent(
                    moduleID: CaptureFirstPartyModule.id,
                    name: "capture.scanned",
                    payload: ["noteCount": String(preview.notes.count)]
                )
            } catch {
                guard !Task.isCancelled,
                      generation == self.workspaceGeneration,
                      self.isCaptureModuleEnabled else { return }
                self.obsidianImportStatus = "扫描失败"
                self.errorMessage = "Obsidian Vault 扫描失败：\(error.localizedDescription)"
                self.recordFirstPartyModuleEvent(
                    moduleID: CaptureFirstPartyModule.id,
                    name: "capture.failed",
                    payload: ["reason": error.localizedDescription]
                )
            }
        }
    }

    func cancelObsidianImport() {
        guard !isImportingObsidianVault else { return }
        obsidianImportPreview = nil
        obsidianImportStatus = "已取消"
    }

    func confirmObsidianImport() {
        guard authorizeFirstPartyModule(
                CaptureFirstPartyModule.id,
                permission: .contentWrite,
                action: "导入 Markdown 内容"
              ),
              let preview = obsidianImportPreview,
              (selectedMarkdownWorkspaceMode != .copyImport || preview.importableCount > 0),
              !isImportingObsidianVault,
              !isBackingUp else { return }
        let mode = selectedMarkdownWorkspaceMode
        let alert = NSAlert()
        switch mode {
        case .copyImport:
            alert.messageText = "复制导入 \(preview.importableCount) 篇笔记？"
            alert.informativeText = "Markdown 与附件会复制到 LeonBook 工作区；原目录不会被修改，\(preview.conflictCount) 篇冲突文章会被跳过。"
            alert.addButton(withTitle: "确认复制")
        case .readOnlyMount:
            alert.messageText = "以只读方式挂载此文件夹？"
            alert.informativeText = "LeonBook 会直接读取并持续监听原目录，但所有文章保存、移动、删除和批量属性修改都会被阻止。"
            alert.addButton(withTitle: "只读挂载")
        case .directEdit:
            alert.messageText = "直接编辑此文件夹？"
            alert.informativeText = "此目录将成为 Markdown 权威数据源。LeonBook 的保存、移动和删除会直接写回原文件。"
            alert.addButton(withTitle: "允许直接编辑")
        }
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let generation = workspaceGeneration
        isImportingObsidianVault = true
        obsidianImportStatus = mode == .copyImport ? "正在复制文章与附件…" : "正在挂载并建立索引…"
        Task {
            defer { isImportingObsidianVault = false }
            do {
                guard generation == workspaceGeneration else { return }
                if mode == .copyImport {
                    if activeMarkdownWorkspaceMode != .copyImport {
                        stopMarkdownSourceMonitor()
                        workspaceGeneration += 1
                        _ = try await store.configureMarkdownWorkspaceSource(mode: .copyImport)
                        activeMarkdownWorkspaceMode = .copyImport
                        markdownSourceDirectoryPath = try await store.markdownSourceDirectoryURL().path
                    }
                    let result = try await store.importObsidianVault(preview)
                    try await reload()
                    obsidianImportStatus = "已复制 \(result.importedCount) 篇、\(result.attachmentCount) 个附件；跳过 \(result.skippedCount) 篇"
                    if !result.warnings.isEmpty {
                        errorMessage = "导入完成，但有 \(result.warnings.count) 条提示：\(result.warnings.prefix(3).joined(separator: "；"))"
                    } else {
                        errorMessage = nil
                    }
                } else {
                    stopMarkdownSourceMonitor()
                    workspaceGeneration += 1
                    let sync = try await store.configureMarkdownWorkspaceSource(
                        mode: mode,
                        directoryURL: preview.vaultURL
                    )
                    activeMarkdownWorkspaceMode = mode
                    markdownSourceDirectoryPath = try await store.markdownSourceDirectoryURL().path
                    try await reload()
                    obsidianImportStatus = mode == .readOnlyMount
                        ? "已只读挂载并监听 \(markdownSourceDirectoryPath)"
                        : "已直接挂载并监听 \(markdownSourceDirectoryPath)"
                    errorMessage = sync.warnings.isEmpty ? nil : sync.warnings.joined(separator: "\n")
                }
                try await refreshPortableSidecarStatus()
                portableSidecarRevision = UUID()
                startMarkdownSourceMonitor()
                obsidianImportPreview = nil
                scheduleBackup()
                recordFirstPartyModuleEvent(
                    moduleID: CaptureFirstPartyModule.id,
                    name: "capture.imported",
                    payload: ["mode": mode.rawValue, "path": preview.vaultURL.path]
                )
            } catch {
                if let state = try? await store.markdownWorkspaceSourceState(),
                   let url = try? await store.markdownSourceDirectoryURL() {
                    activeMarkdownWorkspaceMode = state.mode
                    selectedMarkdownWorkspaceMode = state.mode
                    markdownSourceDirectoryPath = url.path
                    startMarkdownSourceMonitor()
                }
                obsidianImportStatus = mode == .copyImport ? "复制失败" : "挂载失败"
                errorMessage = "Markdown 工作区操作失败：\(error.localizedDescription)"
                recordFirstPartyModuleEvent(
                    moduleID: CaptureFirstPartyModule.id,
                    name: "capture.failed",
                    payload: ["reason": error.localizedDescription]
                )
            }
        }
    }

}
