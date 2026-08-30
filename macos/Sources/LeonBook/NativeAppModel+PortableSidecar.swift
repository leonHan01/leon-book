import Foundation

extension NativeAppModel {
    func refreshPortableSidecarStatus() async throws {
        let status = try await store.portableSidecarStatus()
        applyPortableSidecarStatus(status)
    }

    func setPortableSidecarEnabled(_ enabled: Bool) {
        guard !isSynchronizingPortableSidecar else { return }
        isSynchronizingPortableSidecar = true
        Task {
            defer { isSynchronizingPortableSidecar = false }
            do {
                let result = try await store.setPortableSidecarEnabled(enabled)
                try await refreshPortableStateAfterImport(result)
                portableSidecarRevision = UUID()
                errorMessage = nil
            } catch {
                try? await refreshPortableSidecarStatus()
                errorMessage = ".leonbook 设置失败：\(error.localizedDescription)"
            }
        }
    }

    func synchronizePortableSidecarNow() {
        guard isPortableSidecarEnabled, !isSynchronizingPortableSidecar else { return }
        isSynchronizingPortableSidecar = true
        portableSidecarStatus = isPortableSidecarWritable ? "正在合并并写入…" : "正在重新导入…"
        Task {
            defer { isSynchronizingPortableSidecar = false }
            do {
                let result = try await store.synchronizePortableSidecar()
                try await refreshPortableStateAfterImport(result)
                portableSidecarRevision = UUID()
                errorMessage = nil
            } catch {
                try? await refreshPortableSidecarStatus()
                errorMessage = ".leonbook 同步失败：\(error.localizedDescription)"
            }
        }
    }

    func importPortableSidecarAfterExternalChange() async throws {
        let result = try await store.importPortableSidecarIfEnabled()
        try await refreshPortableStateAfterImport(result)
        if isPortableSidecarEnabled { portableSidecarRevision = UUID() }
    }

    private func refreshPortableStateAfterImport(
        _ result: NativePortableSidecarImportResult
    ) async throws {
        bookmarks = try await store.listBookmarks()
        if let selectedSlug {
            articleComments = try await store.listArticleComments(articleSlug: selectedSlug)
        }
        if !editor.recoveryID.isEmpty {
            articleRevisions = try await store.listArticleRevisions(
                articleSlug: editor.slug.isEmpty ? nil : editor.slug,
                draftKey: editor.recoveryID
            )
        }
        let status = try await store.portableSidecarStatus()
        applyPortableSidecarStatus(status, importResult: result)
    }

    func applyPortableSidecarStatus(
        _ status: NativePortableSidecarStatus,
        importResult: NativePortableSidecarImportResult? = nil
    ) {
        isPortableSidecarEnabled = status.isEnabled
        isPortableSidecarWritable = status.isWritable
        portableSidecarDirectoryPath = status.directoryPath
        if let error = status.lastError {
            portableSidecarStatus = "需要处理：\(error)"
        } else if !status.isEnabled {
            portableSidecarStatus = "未启用"
        } else if let result = importResult, result.didChange {
            let count = result.importedCommentCount + result.importedRevisionCount
                + result.importedBookmarkCount + result.deletedCommentCount
                + result.deletedBookmarkCount
            portableSidecarStatus = status.isWritable
                ? "已合并 \(count) 项并写入 sidecar"
                : "已从只读 sidecar 导入 \(count) 项"
        } else if !status.hasSidecar {
            portableSidecarStatus = status.isWritable
                ? "已启用，等待创建 sidecar"
                : "已启用，但只读目录中尚无 sidecar"
        } else {
            portableSidecarStatus = status.isWritable ? "已同步" : "只读导入模式"
        }
    }
}
