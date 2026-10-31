import AppKit
import Foundation
import LeonBookCaptureModule
import LeonBookModuleKit

extension NativeAppModel {
    func useNativeArticleLibrary() {
        Task {
            do {
                stopMarkdownSourceMonitor()
                workspaceGeneration += 1
                _ = try await store.configureMarkdownWorkspaceSource(mode: .copyImport)
                await refreshMarkdownWorkspaceConfiguration()
                try await reload()
                startMarkdownSourceMonitor()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func chooseObsidianVault() {
        guard authorizeFirstPartyModule(
                CaptureFirstPartyModule.id,
                permission: .fileRead,
                action: NativeLocalization.text("扫描 Markdown 文件夹")
              ),
              storageReady,
              !isScanningObsidianVault,
              !isImportingObsidianVault,
              !isSwitchingWorkspace,
              !isSaving,
              !isBackingUp else { return }
        let panel = NSOpenPanel()
        panel.title = NativeLocalization.text("选择 Markdown 文件夹或 Obsidian Vault")
        panel.message = selectedMarkdownWorkspaceMode.detail
        panel.prompt = NativeLocalization.text("扫描此文件夹")
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
        obsidianImportStatus = NativeLocalization.text("正在扫描 \(vaultURL.lastPathComponent)…")
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
                    ? NativeLocalization.text("没有找到 Markdown 文件")
                    : NativeLocalization.text("扫描完成，等待确认")
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
                self.obsidianImportStatus = NativeLocalization.text("扫描失败")
                self.errorMessage = NativeLocalization.text("Obsidian Vault 扫描失败：\(error.localizedDescription)")
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
        obsidianImportStatus = NativeLocalization.text("已取消")
    }

    func confirmObsidianImport() {
        guard authorizeFirstPartyModule(
                CaptureFirstPartyModule.id,
                permission: .contentWrite,
                action: NativeLocalization.text("导入 Markdown 内容")
              ),
              let preview = obsidianImportPreview,
              (selectedMarkdownWorkspaceMode != .copyImport || preview.importableCount > 0),
              !isImportingObsidianVault,
              !isBackingUp else { return }
        let mode = selectedMarkdownWorkspaceMode
        let alert = NSAlert()
        switch mode {
        case .copyImport:
            alert.messageText = NativeLocalization.text("复制导入 \(preview.importableCount) 篇笔记？")
            alert.informativeText = NativeLocalization.text("Markdown 与附件会复制到 LeonBook 工作区；原目录不会被修改，\(preview.conflictCount) 篇冲突文章会被跳过。")
            alert.addButton(withTitle: NativeLocalization.text("确认复制"))
        case .readOnlyMount:
            alert.messageText = NativeLocalization.text("以只读方式挂载此文件夹？")
            alert.informativeText = NativeLocalization.text("LeonBook 会直接读取并持续监听原目录，但所有文章保存、移动、删除和批量属性修改都会被阻止。")
            alert.addButton(withTitle: NativeLocalization.text("只读挂载"))
        case .directEdit:
            alert.messageText = NativeLocalization.text("直接编辑此文件夹？")
            alert.informativeText = NativeLocalization.text("此目录将成为 Markdown 权威数据源。LeonBook 的保存、移动和删除会直接写回原文件。")
            alert.addButton(withTitle: NativeLocalization.text("允许直接编辑"))
        }
        alert.addButton(withTitle: NativeLocalization.text("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let generation = workspaceGeneration
        isImportingObsidianVault = true
        obsidianImportStatus = mode == .copyImport ? NativeLocalization.text("正在复制文章与附件…") : NativeLocalization.text("正在挂载并建立索引…")
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
                    obsidianImportStatus = NativeLocalization.text("已复制 \(result.importedCount) 篇、\(result.attachmentCount) 个附件；跳过 \(result.skippedCount) 篇")
                    if !result.warnings.isEmpty {
                        errorMessage = NativeLocalization.text("导入完成，但有 \(result.warnings.count) 条提示：\(result.warnings.prefix(3).joined(separator: "；"))")
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
                        ? NativeLocalization.text("已只读挂载并监听 \(markdownSourceDirectoryPath)")
                        : NativeLocalization.text("已直接挂载并监听 \(markdownSourceDirectoryPath)")
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
                obsidianImportStatus = mode == .copyImport ? NativeLocalization.text("复制失败") : NativeLocalization.text("挂载失败")
                errorMessage = NativeLocalization.text("Markdown 工作区操作失败：\(error.localizedDescription)")
                recordFirstPartyModuleEvent(
                    moduleID: CaptureFirstPartyModule.id,
                    name: "capture.failed",
                    payload: ["reason": error.localizedDescription]
                )
            }
        }
    }

}

extension NativeAppModel {
    /// Import a Finder-dropped HTML file into the selected article directory.
    func importHTMLArticle(from url: URL, into folder: String) {
        guard !isMarkdownSourceReadOnly else {
            errorMessage = NativeStoreError.readOnlyArticleSource.localizedDescription
            return
        }
        guard url.isFileURL, ["html", "htm"].contains(url.pathExtension.lowercased()) else {
            errorMessage = NativeLocalization.text("请拖入 HTML 文件。")
            return
        }
        let loadingID = loadingOperations.begin(.resources)
        Task {
            defer { loadingOperations.end(loadingID) }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            var uploaded: [NativeMedia] = []
            var saved = false
            do {
                let destination = try NativeArticleDirectoryPolicy.validatedFolderPath(folder)
                let parsed = try await Task.detached(priority: .userInitiated) {
                    let html = try String(contentsOf: url, encoding: .utf8)
                    return try NativeHTMLArticleImporter.parse(html, fileURL: url)
                }.value
                let slug = try await store.allocateSlug(from: parsed.title)
                var body = parsed.body
                let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("leonbook-html-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
                for (index, image) in parsed.images.enumerated() {
                    let imageURL = temporaryDirectory.appendingPathComponent("image-\(index).\(image.fileExtension)")
                    try image.data.write(to: imageURL, options: .atomic)
                    let item = try await store.uploadMedia(fileURL: imageURL, kind: "image", slug: slug)
                    let media = NativeMedia(kind: item.kind, name: item.name, size: item.size, url: item.url)
                    uploaded.append(media)
                    body = body.replacingOccurrences(of: image.token, with: item.url)
                }
                _ = try await store.saveArticle(NativeSaveArticle(
                    banner: nil, body: body, category: "Notes", excerpt: "", media: uploaded,
                    slug: slug, status: .draft, tags: [], title: parsed.title, expectedUpdatedAt: nil,
                    sourceRelativePath: "\(destination)/\(slug).html"
                ))
                saved = true
                try await reload()
                scheduleBackup()
                errorMessage = nil
            } catch {
                if !saved { try? await store.discardUnreferencedMedia(uploaded) }
                errorMessage = NativeLocalization.text("HTML 导入失败：\(error.localizedDescription)")
            }
        }
    }
}
