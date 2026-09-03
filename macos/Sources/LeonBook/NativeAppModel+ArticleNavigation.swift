import AppKit
import Foundation

extension NativeAppModel {
    func openArticleLink(_ slug: String) {
        let opensNewTab = NSEvent.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.command)
        openArticleLink(slug, disposition: opensNewTab ? .newTab : .currentTab)
    }

    func openArticleLink(_ destination: NativeArticleLinkDestination) {
        if destination.target.isEmpty, let heading = destination.heading {
            scrollToLinkedHeading(heading)
            return
        }
        let resolvedSlug = destination.resolvedSlug
            ?? resolveArticleLink(destination.target)?.slug
        guard let resolvedSlug else {
            createArticle(from: destination)
            return
        }
        guard let summary = articleSummary(for: resolvedSlug) else {
            errorMessage = "关联的文章已不存在。"
            return
        }
        let opensNewTab = NSEvent.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.command)
        Task {
            do {
                guard try await displayArticle(
                    summary,
                    disposition: opensNewTab ? .newTab : .currentTab,
                    recordsPageView: true
                ) else { return }
                if let heading = destination.heading { scrollToLinkedHeading(heading) }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func openArticleLinkInNewTab(_ slug: String) {
        openArticleLink(slug, disposition: .newTab)
    }

    func openArticleLink(_ slug: String, disposition: NativeArticleOpenDisposition) {
        guard let summary = articleSummary(for: slug) else {
            errorMessage = "关联的文章已不存在。"
            return
        }
        Task {
            do {
                try await displayArticle(
                    summary,
                    disposition: disposition,
                    recordsPageView: true
                )
            }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func scrollToLinkedHeading(_ rawHeading: String) {
        guard let article = selectedArticle else { return }
        let normalized = rawHeading.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("^") {
            let requestedID = String(normalized.dropFirst())
            guard let block = NativeArticleEmbed.blockReferences(in: article.body).first(where: {
                $0.id.caseInsensitiveCompare(requestedID) == .orderedSame
            }) else {
                errorMessage = "已打开文章，但没有找到块“^\(requestedID)”。"
                return
            }
            pendingArticleScrollAnchor = block.scrollAnchorID
            articleScrollRevision = UUID()
            return
        }
        let requested = rawHeading.split(separator: "#", omittingEmptySubsequences: true)
            .last.map(String.init) ?? rawHeading
        guard let heading = MarkdownOutline.items(in: article.body).first(where: {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(requested.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }) else {
            errorMessage = "已打开文章，但没有找到标题“\(rawHeading)”。"
            return
        }
        pendingArticleScrollAnchor = heading.id
        articleScrollRevision = UUID()
    }

    private func createArticle(from destination: NativeArticleLinkDestination) {
        let decodedTarget = destination.target.removingPercentEncoding ?? destination.target
        let extensionName = URL(fileURLWithPath: decodedTarget).pathExtension
        guard extensionName.isEmpty || extensionName.caseInsensitiveCompare("md") == .orderedSame else {
            errorMessage = "“\(destination.target)”不是文章链接，无法创建。"
            return
        }
        let targetWithoutExtension = extensionName.isEmpty
            ? decodedTarget
            : String(decodedTarget.dropLast(extensionName.count + 1))
        let title = URL(fileURLWithPath: targetWithoutExtension).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            errorMessage = "双链目标为空，无法创建文章。"
            return
        }

        let previousRecoveryID = editor.recoveryID
        newArticle()
        guard editor.recoveryID != previousRecoveryID else { return }
        editor.title = title
        if targetWithoutExtension.caseInsensitiveCompare(title) != .orderedSame {
            editor.properties["aliases"] = .list([targetWithoutExtension])
        }
        if let rawHeading = destination.heading {
            let heading = rawHeading.split(separator: "#", omittingEmptySubsequences: true)
                .last.map(String.init) ?? rawHeading
            if !heading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                editor.body = "## \(heading)\n\n"
            }
        }
        editorAutosaveStatus = "已从未创建双链预填，等待保存…"
        scheduleEditorAutosave()
        errorMessage = nil
    }

    func activateArticleTab(_ id: UUID) {
        Task {
            do {
                _ = try await activateArticleTabAndWait(id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    func activateArticleTabAndWait(_ id: UUID) async throws -> Bool {
        guard id != activeArticleTabID,
              let tab = articleTabs.first(where: { $0.id == id }),
              let summary = articleSummary(for: tab.slug),
              try await displayArticle(
                  summary,
                  disposition: .refreshActiveTab,
                  recordsPageView: false,
                  persistsNavigation: false
              ) else { return false }
        activeArticleTabID = id
        persistArticleNavigationState()
        return true
    }

    public func navigateArticleBack() {
        navigateActiveArticleTab(forward: false)
    }

    public func navigateArticleForward() {
        navigateActiveArticleTab(forward: true)
    }

    private func navigateActiveArticleTab(forward: Bool) {
        guard let activeArticleTabID,
              let index = articleTabs.firstIndex(where: { $0.id == activeArticleTabID }) else { return }
        var updatedTab = articleTabs[index]
        guard let targetSlug = forward ? updatedTab.goForward() : updatedTab.goBack(),
              let summary = articleSummary(for: targetSlug) else { return }

        Task {
            do {
                guard try await displayArticle(
                    summary,
                    disposition: .refreshActiveTab,
                    recordsPageView: false,
                    persistsNavigation: false
                ) else { return }
                guard self.activeArticleTabID == activeArticleTabID,
                      selectedSlug == targetSlug,
                      let currentIndex = articleTabs.firstIndex(where: { $0.id == activeArticleTabID }) else { return }
                articleTabs[currentIndex] = updatedTab
                persistArticleNavigationState()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func toggleActiveArticleTabPin() {
        guard let activeArticleTabID,
              let index = articleTabs.firstIndex(where: { $0.id == activeArticleTabID }) else { return }
        articleTabs[index].isPinned.toggle()
        reorderArticleTabs()
        persistArticleNavigationState()
    }

    func toggleArticleTabPin(_ id: UUID) {
        guard let index = articleTabs.firstIndex(where: { $0.id == id }) else { return }
        articleTabs[index].isPinned.toggle()
        reorderArticleTabs()
        persistArticleNavigationState()
    }

    public func closeActiveArticleTab() {
        guard let activeArticleTabID else { return }
        closeArticleTab(activeArticleTabID)
    }

    func closeArticleTab(_ id: UUID) {
        guard let index = articleTabs.firstIndex(where: { $0.id == id }) else { return }
        articleNavigationGeneration += 1
        let wasActive = id == activeArticleTabID
        articleTabs.remove(at: index)

        guard wasActive else {
            persistArticleNavigationState()
            return
        }

        selectedSlug = nil
        selectedArticle = nil
        selectedArticleRelations = .empty
        articleComments = []
        pendingArticleCommentSelection = nil
        activeArticleTabID = nil
        guard !articleTabs.isEmpty else {
            section = .articles
            persistArticleNavigationState()
            return
        }
        let nextIndex = min(index, articleTabs.count - 1)
        let nextID = articleTabs[nextIndex].id
        persistArticleNavigationState()
        activateArticleTab(nextID)
    }

    func updateArticleTabs(for slug: String, disposition: NativeArticleOpenDisposition) {
        switch disposition {
        case .refreshActiveTab:
            return
        case .newTab:
            let tab = NativeArticleTab(slug: slug)
            articleTabs.append(tab)
            activeArticleTabID = tab.id
        case .currentTab:
            guard let activeArticleTabID,
                  let index = articleTabs.firstIndex(where: { $0.id == activeArticleTabID }) else {
                let tab = NativeArticleTab(slug: slug)
                articleTabs.append(tab)
                self.activeArticleTabID = tab.id
                return
            }
            if articleTabs[index].isPinned, articleTabs[index].slug != slug {
                let tab = NativeArticleTab(slug: slug)
                articleTabs.append(tab)
                self.activeArticleTabID = tab.id
            } else {
                articleTabs[index].navigate(to: slug)
            }
        }
    }

    private func reorderArticleTabs() {
        let pinned = articleTabs.filter(\.isPinned)
        let unpinned = articleTabs.filter { !$0.isPinned }
        articleTabs = pinned + unpinned
    }

    func restoreWorkspaceTabs(_ savedTabs: [NativeArticleTab], activeTabID: UUID?) {
        let validSlugs = Set(articles.map(\.slug))
        var seen = Set<UUID>()
        articleTabs = savedTabs.compactMap { tab in
            guard validSlugs.contains(tab.slug), seen.insert(tab.id).inserted else { return nil }
            return NativeArticleTab(
                id: tab.id,
                slug: tab.slug,
                isPinned: tab.isPinned,
                backStack: tab.backStack.filter(validSlugs.contains),
                forwardStack: tab.forwardStack.filter(validSlugs.contains)
            )
        }
        reorderArticleTabs()
        self.activeArticleTabID = activeTabID.flatMap { savedID in
            articleTabs.contains(where: { $0.id == savedID }) ? savedID : nil
        } ?? articleTabs.first?.id
        persistArticleNavigationState()

        guard let activeArticleTab,
              let summary = articleSummary(for: activeArticleTab.slug) else { return }
        Task {
            do {
                _ = try await displayArticle(
                    summary,
                    disposition: .refreshActiveTab,
                    recordsPageView: false
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func recordRecentArticle(_ slug: String) {
        recentArticleSlugs.removeAll(where: { $0 == slug })
        recentArticleSlugs.insert(slug, at: 0)
        recentArticleSlugs = Array(recentArticleSlugs.prefix(20))
    }

    private var articleNavigationDefaultsKey: String {
        if let navigationScopeID {
            return "leon-book.article-navigation.\(currentUser.id).window.\(navigationScopeID)"
        }
        return "leon-book.article-navigation.\(currentUser.id)"
    }

    func persistArticleNavigationState() {
        let snapshot = NativeArticleNavigationSnapshot(
            tabs: articleTabs,
            activeTabID: activeArticleTabID,
            recentSlugs: recentArticleSlugs
        )
        let defaultsKey = articleNavigationDefaultsKey
        if articleNavigationPersistenceDefaultsKey == defaultsKey {
            articleNavigationPersistenceTask?.cancel()
        }
        articleNavigationPersistenceDefaultsKey = defaultsKey
        articleNavigationPersistenceTask = Task {
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                UserDefaults.standard.set(data, forKey: defaultsKey)
            }.value
        }
    }

    func restoreArticleNavigationState() async {
        guard let data = UserDefaults.standard.data(forKey: articleNavigationDefaultsKey),
              let snapshot = try? JSONDecoder().decode(NativeArticleNavigationSnapshot.self, from: data) else {
            return
        }
        let validSlugs = Set(articles.map(\.slug))
        var seenTabIDs = Set<UUID>()
        articleTabs = snapshot.tabs.compactMap { tab in
            guard validSlugs.contains(tab.slug), seenTabIDs.insert(tab.id).inserted else { return nil }
            return NativeArticleTab(
                id: tab.id,
                slug: tab.slug,
                isPinned: tab.isPinned,
                backStack: tab.backStack.filter(validSlugs.contains),
                forwardStack: tab.forwardStack.filter(validSlugs.contains)
            )
        }
        reorderArticleTabs()
        var seenRecentSlugs = Set<String>()
        recentArticleSlugs = Array(snapshot.recentSlugs.filter {
            validSlugs.contains($0) && seenRecentSlugs.insert($0).inserted
        }.prefix(20))
        activeArticleTabID = snapshot.activeTabID.flatMap { savedID in
            articleTabs.contains(where: { $0.id == savedID }) ? savedID : nil
        } ?? articleTabs.first?.id

        guard let activeArticleTab,
              let summary = articleSummary(for: activeArticleTab.slug) else {
            persistArticleNavigationState()
            return
        }
        do {
            try await displayArticle(
                summary,
                disposition: .refreshActiveTab,
                recordsPageView: false
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

