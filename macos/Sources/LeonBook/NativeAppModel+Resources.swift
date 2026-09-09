import AppKit
import Foundation

extension NativeAppModel {
    var workspaceResourceIndex: NativeWorkspaceResourceIndex {
        if let cachedWorkspaceResourceIndex { return cachedWorkspaceResourceIndex }
        let index = NativeWorkspaceResourceIndex(roots: workspaceResources)
        cachedWorkspaceResourceIndex = index
        return index
    }

    var workspaceResourceItems: [NativeWorkspaceResourceNode] {
        workspaceResourceIndex.items
    }

    var workspaceFolderPaths: [String] {
        workspaceResourceIndex.folderPaths
    }

    func workspaceResource(id: String) -> NativeWorkspaceResourceNode? {
        workspaceResourceIndex.resource(id: id)
    }

    func workspaceResources(ids: Set<String>) -> [NativeWorkspaceResourceNode] {
        guard !ids.isEmpty else { return [] }
        return workspaceResourceIndex.resources(ids: ids)
    }

    func workspaceResourceID(articleSlug: String) -> String? {
        workspaceResourceIndex.resourceID(articleSlug: articleSlug)
    }

    func workspaceResourceAncestorIDs(resourceID: String) -> [String] {
        workspaceResourceIndex.ancestorIDs(resourceID: resourceID)
    }

    func promptToCreateWorkspaceFolder(parentPath: String) {
        guard !isMarkdownSourceReadOnly else {
            errorMessage = NativeStoreError.readOnlyArticleSource.localizedDescription
            return
        }
        let field = NSTextField()
        field.placeholderString = "文件夹名称"
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        let alert = NSAlert()
        alert.messageText = parentPath.isEmpty ? "新建文件夹" : "在“\(parentPath)”中新建文件夹"
        alert.addButton(withTitle: "新建")
        alert.addButton(withTitle: "取消")
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard !name.contains("/"), !name.contains("\\") else {
            errorMessage = "文件夹名称不能包含路径分隔符。"
            return
        }
        let destination = joinedWorkspacePath(parentPath, name)

        Task {
            do {
                try await store.createWorkspaceFolder(relativePath: destination)
                workspaceResources = try await store.listWorkspaceResources()
                scheduleBackup()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func promptToRenameWorkspaceResource(_ resource: NativeWorkspaceResourceNode) {
        guard resource.canMutateSource, let sourcePath = resource.sourceRelativePath else { return }
        guard !isMarkdownSourceReadOnly else {
            errorMessage = NativeStoreError.readOnlyArticleSource.localizedDescription
            return
        }
        let field = NSTextField(string: resource.name)
        field.placeholderString = resource.kind == .folder ? "文件夹名称" : "文件名"
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        let alert = NSAlert()
        alert.messageText = resource.kind == .folder ? "重命名文件夹" : "重命名文件"
        alert.informativeText = resource.kind == .article
            ? "只修改 Markdown 文件名；文章标题与稳定 slug 保持不变，路径双链会自动更新。"
            : "输入新名称，不需要填写完整路径。"
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var nextName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nextName.isEmpty else { return }
        guard !nextName.contains("/"), !nextName.contains("\\") else {
            errorMessage = "名称不能包含路径分隔符；如需移动，请使用“移动…”。"
            return
        }
        if resource.kind == .article,
           URL(fileURLWithPath: nextName).pathExtension.caseInsensitiveCompare("md") != .orderedSame {
            nextName += ".md"
        }
        let parentPath = sourcePath.split(separator: "/").dropLast().joined(separator: "/")
        let destination = joinedWorkspacePath(parentPath, nextName)
        performWorkspaceResourceMoves([
            NativeWorkspaceResourceMove(
                sourceRelativePath: sourcePath,
                destinationRelativePath: destination
            ),
        ])
    }

    func promptToMoveWorkspaceResources(_ resources: [NativeWorkspaceResourceNode]) {
        let eligible = topLevelMutableWorkspaceResources(resources)
        guard !eligible.isEmpty else {
            errorMessage = "所选项目没有可移动的 Markdown 源文件。应用管理的媒体会继续跟随所属文章。"
            return
        }
        guard !isMarkdownSourceReadOnly else {
            errorMessage = NativeStoreError.readOnlyArticleSource.localizedDescription
            return
        }

        let excludedFolders = eligible.compactMap {
            $0.kind == .folder ? $0.sourceRelativePath : nil
        }
        let candidates = [""] + workspaceFolderPaths.filter { candidate in
            !excludedFolders.contains(where: {
                candidate == $0 || candidate.hasPrefix($0 + "/")
            })
        }
        guard !candidates.isEmpty else { return }
        let popup = NSPopUpButton()
        popup.addItems(withTitles: candidates.map { $0.isEmpty ? "资料库根目录" : $0 })
        popup.frame = NSRect(x: 0, y: 0, width: 380, height: 26)
        let alert = NSAlert()
        alert.messageText = eligible.count == 1 ? "移动“\(eligible[0].name)”" : "移动 \(eligible.count) 个项目"
        alert.informativeText = "选择目标文件夹；文件名、文章 slug、评论和版本历史保持不变。"
        alert.addButton(withTitle: "移动")
        alert.addButton(withTitle: "取消")
        alert.accessoryView = popup
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        moveWorkspaceResources(eligible, toFolder: candidates[popup.indexOfSelectedItem])
    }

    func moveWorkspaceResources(
        _ resources: [NativeWorkspaceResourceNode],
        toFolder folderPath: String
    ) {
        let eligible = topLevelMutableWorkspaceResources(resources)
        let moves = eligible.compactMap { resource -> NativeWorkspaceResourceMove? in
            guard let sourcePath = resource.sourceRelativePath else { return nil }
            let filename = sourcePath.split(separator: "/").last.map(String.init) ?? resource.name
            return NativeWorkspaceResourceMove(
                sourceRelativePath: sourcePath,
                destinationRelativePath: joinedWorkspacePath(folderPath, filename)
            )
        }
        performWorkspaceResourceMoves(moves)
    }

    func promptToTrashWorkspaceResources(_ resources: [NativeWorkspaceResourceNode]) {
        let eligible = topLevelMutableWorkspaceResources(resources)
        guard !eligible.isEmpty else { return }
        guard !isMarkdownSourceReadOnly else {
            errorMessage = NativeStoreError.readOnlyArticleSource.localizedDescription
            return
        }
        let articleCount = eligible.reduce(0) { $0 + $1.articleCount }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = eligible.count == 1
            ? "将“\(eligible[0].name)”移到废纸篓？"
            : "将 \(eligible.count) 个项目移到废纸篓？"
        alert.informativeText = articleCount > 0
            ? "其中包含 \(articleCount) 篇文章。文章会同时进入 LeonBook 回收站；普通附件和文件夹可从 macOS 废纸篓恢复。"
            : "普通附件和文件夹可从 macOS 废纸篓恢复。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task {
            do {
                _ = try await store.trashWorkspaceSourceItems(
                    relativePaths: eligible.compactMap(\.sourceRelativePath)
                )
                try await reload()
                reconcileArticleNavigationAfterWorkspaceMutation()
                scheduleBackup()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
                workspaceResources = (try? await store.listWorkspaceResources()) ?? workspaceResources
            }
        }
    }

    func openWorkspaceAttachment(_ resource: NativeWorkspaceResourceNode) {
        guard resource.kind == .attachment, !resource.absolutePath.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: resource.absolutePath))
    }

    func revealWorkspaceResourceInFinder(_ resource: NativeWorkspaceResourceNode) {
        guard !resource.absolutePath.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: resource.absolutePath)])
    }

    private func performWorkspaceResourceMoves(_ moves: [NativeWorkspaceResourceMove]) {
        guard !moves.isEmpty else { return }
        let retargetedFolderPath = retargetedSelectedFolderPath(after: moves)
        let retargetedDraftFolderPath = retargetedWorkspaceFolderPath(
            pendingNewArticleFolderPath,
            after: moves
        )
        Task {
            do {
                _ = try await store.moveWorkspaceSourceItems(moves)
                try await reload()
                selectedArticleFolderPath = retargetedFolderPath
                pendingNewArticleFolderPath = retargetedDraftFolderPath
                reconcileArticleNavigationAfterWorkspaceMutation()
                scheduleBackup()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
                workspaceResources = (try? await store.listWorkspaceResources()) ?? workspaceResources
            }
        }
    }

    private func reconcileArticleNavigationAfterWorkspaceMutation() {
        let liveSlugs = Set(articles.map(\.slug))
        if let selectedArticleFolderPath,
           !workspaceFolderPaths.contains(selectedArticleFolderPath) {
            self.selectedArticleFolderPath = nil
        }
        if let pendingNewArticleFolderPath,
           !workspaceFolderPaths.contains(pendingNewArticleFolderPath) {
            self.pendingNewArticleFolderPath = nil
            if editor.isNew { editorAutosaveStatus = "目标文件夹已移除，将在资料库根目录保存" }
        }
        articleTabs.removeAll(where: { !liveSlugs.contains($0.slug) })
        recentArticleSlugs.removeAll(where: { !liveSlugs.contains($0) })
        if let selectedSlug, !liveSlugs.contains(selectedSlug) {
            self.selectedSlug = nil
            selectedArticle = nil
            selectedArticleRelations = .empty
            articleComments = []
            pendingArticleCommentSelection = nil
            activeArticleTabID = articleTabs.first?.id
            if section == .reader { section = .articles }
        }
        persistArticleNavigationState()
    }

    private func retargetedSelectedFolderPath(
        after moves: [NativeWorkspaceResourceMove]
    ) -> String? {
        retargetedWorkspaceFolderPath(selectedArticleFolderPath, after: moves)
    }

    private func retargetedWorkspaceFolderPath(
        _ folderPath: String?,
        after moves: [NativeWorkspaceResourceMove]
    ) -> String? {
        guard let folderPath else { return nil }
        for move in moves.sorted(by: {
            $0.sourceRelativePath.count > $1.sourceRelativePath.count
        }) {
            let source = move.sourceRelativePath
            guard folderPath == source || folderPath.hasPrefix(source + "/") else { continue }
            let suffix = String(folderPath.dropFirst(source.count))
            return move.destinationRelativePath + suffix
        }
        return folderPath
    }

    private func topLevelMutableWorkspaceResources(
        _ resources: [NativeWorkspaceResourceNode]
    ) -> [NativeWorkspaceResourceNode] {
        let mutable: [String: NativeWorkspaceResourceNode] = Dictionary(
            uniqueKeysWithValues: resources.compactMap { resource -> (String, NativeWorkspaceResourceNode)? in
            guard resource.canMutateSource, let path = resource.sourceRelativePath else { return nil }
            return (path, resource)
            }
        )
        let paths = mutable.keys.sorted {
            let leftDepth = $0.split(separator: "/").count
            let rightDepth = $1.split(separator: "/").count
            if leftDepth != rightDepth { return leftDepth < rightDepth }
            return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        var selected: [NativeWorkspaceResourceNode] = []
        for path in paths where !selected.contains(where: {
            guard let parent = $0.sourceRelativePath else { return false }
            return path.hasPrefix(parent + "/")
        }) {
            if let resource = mutable[path] { selected.append(resource) }
        }
        return selected
    }

    private func joinedWorkspacePath(_ folder: String, _ name: String) -> String {
        let folder = folder.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return folder.isEmpty ? name : "\(folder)/\(name)"
    }
}
