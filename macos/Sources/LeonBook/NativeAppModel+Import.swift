import AppKit
import Foundation

extension NativeAppModel {
    func chooseObsidianVault() {
        guard storageReady,
              !isScanningObsidianVault,
              !isImportingObsidianVault,
              !isSwitchingWorkspace,
              !isSaving,
              !isBackingUp else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 Obsidian Vault"
        panel.message = "仅扫描并预览 Markdown 与附件；不会修改所选 Vault。SQLite 始终是导入后的主数据源。"
        panel.prompt = "扫描此 Vault"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let vaultURL = panel.url else { return }

        let generation = workspaceGeneration
        isScanningObsidianVault = true
        obsidianImportStatus = "正在扫描 \(vaultURL.lastPathComponent)…"
        obsidianImportPreview = nil
        Task {
            defer { isScanningObsidianVault = false }
            do {
                let existingSlugs = try await store.existingArticleSlugs()
                let preview = try await Task.detached(priority: .userInitiated) {
                    try NativeObsidianVaultImporter.scan(
                        vaultURL: vaultURL,
                        existingSlugs: existingSlugs
                    )
                }.value
                guard generation == workspaceGeneration else { return }
                obsidianImportPreview = preview
                obsidianImportStatus = preview.notes.isEmpty
                    ? "没有找到可导入的 Markdown"
                    : "扫描完成，等待确认"
                errorMessage = nil
            } catch {
                guard generation == workspaceGeneration else { return }
                obsidianImportStatus = "扫描失败"
                errorMessage = "Obsidian Vault 扫描失败：\(error.localizedDescription)"
            }
        }
    }

    func cancelObsidianImport() {
        guard !isImportingObsidianVault else { return }
        obsidianImportPreview = nil
        obsidianImportStatus = "已取消导入"
    }

    func confirmObsidianImport() {
        guard let preview = obsidianImportPreview,
              preview.importableCount > 0,
              !isImportingObsidianVault,
              !isBackingUp else { return }
        let alert = NSAlert()
        alert.messageText = "将 \(preview.importableCount) 篇笔记导入 SQLite？"
        alert.informativeText = "这是单向导入。Obsidian Vault 不会被修改；SQLite 是主数据源，\(preview.conflictCount) 篇冲突文章会被跳过。"
        alert.addButton(withTitle: "确认导入")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let generation = workspaceGeneration
        isImportingObsidianVault = true
        obsidianImportStatus = "正在导入文章与附件…"
        Task {
            defer { isImportingObsidianVault = false }
            do {
                let result = try await store.importObsidianVault(preview)
                guard generation == workspaceGeneration else { return }
                try await reload()
                obsidianImportPreview = nil
                obsidianImportStatus = "已导入 \(result.importedCount) 篇、\(result.attachmentCount) 个附件；跳过 \(result.skippedCount) 篇"
                if !result.warnings.isEmpty {
                    errorMessage = "导入完成，但有 \(result.warnings.count) 条提示：\(result.warnings.prefix(3).joined(separator: "；"))"
                } else {
                    errorMessage = nil
                }
                scheduleBackup()
            } catch {
                guard generation == workspaceGeneration else { return }
                obsidianImportStatus = "导入失败"
                errorMessage = "Obsidian Vault 导入失败：\(error.localizedDescription)"
            }
        }
    }

}
