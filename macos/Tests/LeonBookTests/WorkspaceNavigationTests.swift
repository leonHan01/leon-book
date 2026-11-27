import AppKit
import AVKit
import Combine
import SwiftUI
import WebKit
@testable import LeonBook

private struct WorkspaceNavigationFailure: Error, CustomStringConvertible {
    let description: String
}

final class WorkspaceNavigationTests {
    @MainActor
    func testMainNavigationPresentsLoadingBeforeWebKitAndSkipsSupersededPages() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leon-navigation-first-frame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false, store: LocalBlogStore(rootURL: root))
        model.storageReady = true
        model.isLoading = false
        model.section = .articles
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: ContentView(model: model))
        window.contentViewController = host
        defer { window.close() }
        func webView(in view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap { webView(in: $0) }.first
        }
        host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        host.view.layoutSubtreeIfNeeded()
        let started = ProcessInfo.processInfo.systemUptime
        model.section = .canvas
        host.view.layoutSubtreeIfNeeded()
        print("MAIN_NAVIGATION_FIRST_FRAME syncMS=\((ProcessInfo.processInfo.systemUptime - started) * 1_000) webKit=\(webView(in: host.view) != nil)")
        guard model.section == .canvas, webView(in: host.view) == nil else {
            throw WorkspaceNavigationFailure(description: "canvas WebKit construction blocked the navigation's first loading frame")
        }
        if let output = ProcessInfo.processInfo.environment["LEON_NAVIGATION_LOADING_PREVIEW"],
           let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) {
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
        }
        // A second click arrives before the first destination has been mounted.
        model.showAllArticles()
        host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        host.view.layoutSubtreeIfNeeded()
        guard model.section == .articles, webView(in: host.view) == nil else {
            throw WorkspaceNavigationFailure(description: "a superseded canvas request mounted after returning to articles")
        }
        model.section = .canvas
        host.view.layoutSubtreeIfNeeded()
        for _ in 0..<100 {
            if webView(in: host.view) != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
            host.view.layoutSubtreeIfNeeded()
        }
        guard webView(in: host.view) != nil else {
            throw WorkspaceNavigationFailure(description: "the current destination never mounted after its loading frame")
        }
        model.section = .qAndA
        host.view.layoutSubtreeIfNeeded()
        for _ in 0..<100 {
            if webView(in: host.view) == nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
            host.view.layoutSubtreeIfNeeded()
        }
        guard webView(in: host.view) == nil else {
            throw WorkspaceNavigationFailure(description: "inactive canvas views were retained after navigation")
        }
    }

    @MainActor
    func testDeferredNavigationOnlyMountsLatestRequestAndResetsForWorkspace() async throws {
        _ = NSApplication.shared
        let barrier = NavigationLoadingFrameBarrier()
        var mounts: [NativeNavigationPageRequest] = []
        func page(_ request: NativeNavigationPageRequest, visible: Bool = true) -> some View {
            Group {
                if visible {
                    NativeDeferredNavigationContent(request: request, waitForLoadingFrame: {
                        await barrier.wait(for: request)
                    }) { mounted in
                        NavigationMountProbe(request: mounted) { mounts.append($0) }.id(mounted)
                    }
                }
            }
        }
        let first = NativeNavigationPageRequest(section: .articles, revision: 1, workspaceGeneration: 0)
        let superseded = NativeNavigationPageRequest(section: .canvas, revision: 2, workspaceGeneration: 0)
        let returned = NativeNavigationPageRequest(section: .articles, revision: 3, workspaceGeneration: 0)
        let switched = NativeNavigationPageRequest(section: .articles, revision: 3, workspaceGeneration: 1)
        let disappeared = NativeNavigationPageRequest(section: .photos, revision: 4, workspaceGeneration: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: page(first))
        window.contentView = host
        defer { window.close(); barrier.releaseAll() }
        func until(_ condition: () -> Bool) async throws {
            for _ in 0..<200 {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            throw WorkspaceNavigationFailure(description: "deferred navigation did not reach its expected state")
        }
        func render(_ request: NativeNavigationPageRequest, visible: Bool = true) {
            host.rootView = page(request, visible: visible)
            host.layoutSubtreeIfNeeded()
        }
        try await until { barrier.isWaiting(for: first) }
        guard mounts.isEmpty else { throw WorkspaceNavigationFailure(description: "content mounted before its loading frame") }
        barrier.release(first)
        try await until { mounts == [first] }
        func textEditor(in view: NSView) -> NSTextView? {
            if let editor = view as? NSTextView { return editor }
            return view.subviews.lazy.compactMap { textEditor(in: $0) }.first
        }
        guard let editor = textEditor(in: host), window.makeFirstResponder(editor) else {
            throw WorkspaceNavigationFailure(description: "the outgoing editor could not receive test focus")
        }
        let otherWindow = NSWindow(contentRect: window.frame, styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        defer { otherWindow.close() }
        let otherEditor = NSTextView()
        otherWindow.contentView = otherEditor
        guard otherWindow.makeFirstResponder(otherEditor) else {
            throw WorkspaceNavigationFailure(description: "the second window could not receive test focus")
        }
        render(superseded)
        guard window.firstResponder !== editor else {
            throw WorkspaceNavigationFailure(description: "typing could still reach the hidden outgoing editor")
        }
        guard otherWindow.firstResponder === otherEditor else {
            throw WorkspaceNavigationFailure(description: "navigation cleared an unrelated window's editor focus")
        }
        try await until { barrier.isWaiting(for: superseded) }
        guard mounts == [first] else { throw WorkspaceNavigationFailure(description: "the outgoing snapshot followed the requested destination") }
        render(returned)
        try await until { barrier.isWaiting(for: returned) }
        // Deliberately resume the cancelled task after the new task has started.
        barrier.release(superseded)
        try await Task.sleep(nanoseconds: 5_000_000)
        host.layoutSubtreeIfNeeded()
        guard mounts == [first] else { throw WorkspaceNavigationFailure(description: "a cancelled task constructed its hidden destination") }
        barrier.release(returned)
        try await until { mounts == [first, returned] }
        render(switched)
        try await until { barrier.isWaiting(for: switched) }
        guard mounts == [first, returned] else { throw WorkspaceNavigationFailure(description: "workspace content was reused before the new loading frame") }
        barrier.release(switched)
        try await until { mounts == [first, returned, switched] }
        render(disappeared)
        try await until { barrier.isWaiting(for: disappeared) }
        render(disappeared, visible: false)
        barrier.release(disappeared)
        try await Task.sleep(nanoseconds: 5_000_000)
        host.layoutSubtreeIfNeeded()
        guard mounts == [first, returned, switched] else {
            throw WorkspaceNavigationFailure(description: "a destination mounted after its window content disappeared")
        }
    }

    @MainActor
    func testMainNavigationAvoidsSplitControllerRebuilds() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leon-navigation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false, store: LocalBlogStore(rootURL: root))
        model.storageReady = true
        model.isLoading = false
        model.isDashboardLoaded = true
        model.section = .articles
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "navigation-test")
        let host = NSHostingController(rootView: ContentView(model: model))
        window.contentViewController = host
        defer { window.close() }

        func splitView(in view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            return view.subviews.lazy.compactMap { splitView(in: $0) }.first
        }
        func settle() async throws {
            for _ in 0..<3 {
                host.view.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        try await settle()
        var splitContainerCount = splitView(in: host.view) == nil ? 0 : 1
        // Exercise the same destination changes as the navigation rail. Keep
        // media empty so decoding, network, and data size cannot hide shell work.
        let rounds = Int(ProcessInfo.processInfo.environment["LEON_BOOK_NAVIGATION_ROUNDS"] ?? "1") ?? 1
        for _ in 0..<max(1, rounds) {
            for section in [NativeSection.moments, .articles, .photos, .mediaLibrary, .qAndA, .articles] {
                let started = ProcessInfo.processInfo.systemUptime
                if section == .articles { model.showAllArticles() }
                else { model.section = section }
                host.view.layoutSubtreeIfNeeded()
                let synchronousMS = (ProcessInfo.processInfo.systemUptime - started) * 1_000
                try await settle()
                if splitView(in: host.view) != nil { splitContainerCount += 1 }
                print("MAIN_NAVIGATION section=\(section) syncMS=\(String(format: "%.3f", synchronousMS))")
            }
        }
        guard splitContainerCount == 0 else {
            throw WorkspaceNavigationFailure(description: "main navigation mounted \(splitContainerCount) expensive AppKit split containers")
        }
    }

    @MainActor
    func testLightweightTabsMountImmediatelyAndRetainStateAcrossSwitches() async throws {
        _ = NSApplication.shared
        var mounts: [NativeNavigationPageRequest] = []
        func page(_ request: NativeNavigationPageRequest) -> some View {
            NativeDeferredNavigationContent(request: request) { mounted in
                NavigationMountProbe(request: mounted) { mounts.append($0) }.id(mounted)
            }
        }
        let first = NativeNavigationPageRequest(section: .articles, revision: 1, workspaceGeneration: 0)
        let second = NativeNavigationPageRequest(section: .qAndA, revision: 2, workspaceGeneration: 0)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: page(first))
        window.contentView = host
        defer { window.close() }

        host.layoutSubtreeIfNeeded()
        guard mounts == [first] else {
            throw WorkspaceNavigationFailure(description: "lightweight destination did not mount immediately without waiting: \(mounts)")
        }
        host.rootView = page(second)
        host.layoutSubtreeIfNeeded()
        guard mounts == [first, second] else {
            throw WorkspaceNavigationFailure(description: "switching to another lightweight destination did not mount immediately: \(mounts)")
        }

        // Verify ContentView retains visited lightweight views within the same workspaceGeneration.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leon-lightweight-retain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false, store: LocalBlogStore(rootURL: root))
        model.storageReady = true
        model.isLoading = false
        model.isDashboardLoaded = true
        model.section = .qAndA
        let appWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                                 styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        appWindow.isReleasedWhenClosed = false
        let appHost = NSHostingController(rootView: ContentView(model: model))
        appWindow.contentViewController = appHost
        defer { appWindow.close() }

        func textInputs(in view: NSView) -> [NSView] {
            var result: [NSView] = []
            if view is NSTextView || view is NSTextField { result.append(view) }
            for subview in view.subviews { result.append(contentsOf: textInputs(in: subview)) }
            return result
        }
        appHost.view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        appHost.view.layoutSubtreeIfNeeded()
        let qAndAInputsBefore = textInputs(in: appHost.view).map(ObjectIdentifier.init)
        guard !qAndAInputsBefore.isEmpty else {
            throw WorkspaceNavigationFailure(description: "expected Q&A view to mount immediately")
        }

        model.section = .todos
        appHost.view.layoutSubtreeIfNeeded()
        model.section = .qAndA
        appHost.view.layoutSubtreeIfNeeded()
        let qAndAInputsAfter = textInputs(in: appHost.view).map(ObjectIdentifier.init)
        guard !Set(qAndAInputsBefore).isDisjoint(with: Set(qAndAInputsAfter)) else {
            throw WorkspaceNavigationFailure(description: "lightweight Q&A view was destroyed and rebuilt across tab switches")
        }
    }

    @MainActor
    func testIsolatedSubStoresDoNotBroadcastAppModelChanges() async throws {
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false)
        var modelBroadcasts = 0
        var questionBroadcasts = 0
        var todoBroadcasts = 0
        var momentComposerBroadcasts = 0

        let c1 = model.objectWillChange.sink { _ in modelBroadcasts += 1 }
        let c2 = model.questionSessionStore.objectWillChange.sink { _ in questionBroadcasts += 1 }
        let c3 = model.todoSessionStore.objectWillChange.sink { _ in todoBroadcasts += 1 }
        let c4 = model.momentComposer.objectWillChange.sink { _ in momentComposerBroadcasts += 1 }
        defer { withExtendedLifetime((c1, c2, c3, c4)) {} }

        model.questionAnswerDraft.body = "draft answer"
        model.questionSearchText = "swift"
        model.todoSession.quickTitle = "ship optimization"
        model.todoSession.filter = .completed
        model.momentDraft.text = "hello moment"
        model.editingMomentID = "moment-1"

        guard modelBroadcasts == 0 else {
            throw WorkspaceNavigationFailure(description: "editing isolated sub-stores unexpectedly triggered \(modelBroadcasts) NativeAppModel broadcasts")
        }
        guard questionBroadcasts >= 2, todoBroadcasts >= 2, momentComposerBroadcasts >= 2 else {
            throw WorkspaceNavigationFailure(description: "isolated sub-stores did not publish their own updates: q=\(questionBroadcasts), todo=\(todoBroadcasts), moment=\(momentComposerBroadcasts)")
        }

        // Verify O(1) bookmark lookup stays synced with bookmarks array.
        let target = NativeBookmarkTarget.article(slug: "demo")
        guard !model.isBookmarked(target) else {
            throw WorkspaceNavigationFailure(description: "unexpected initial bookmark match")
        }
        model.bookmarks = [NativeBookmark(title: "Demo", target: target)]
        guard model.isBookmarked(target) else {
            throw WorkspaceNavigationFailure(description: "bookmarkedTargets set did not sync on bookmarks update")
        }
    }

    @MainActor
    func testAncillaryDomainsLoadLazilyOnTabSwitch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leon-lazy-ancillary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Seed a workspace with one moment, one question, and one trashed moment.
        let userStore = UserWorkspaceStore(rootURL: root)
        let workspace = try await userStore.prepare()
        let seedStore = LocalBlogStore(rootURL: workspace.workspaceURL)
        _ = try await seedStore.saveMoment(text: "seed moment", textRuns: [], images: [])
        let toTrash = try await seedStore.saveMoment(text: "trashed moment", textRuns: [], images: [])
        try await seedStore.deleteMoment(id: toTrash.id)
        _ = try await seedStore.saveQuestion(title: "Lazy question", body: "details", tags: ["Perf"])
        await seedStore.closeForRestore()
        await userStore.closeForRestore()

        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false)
        try await model.connect(to: root)
        await model.workspaceAncillaryLoadTask?.value

        guard model.loadedAncillaryDomains.contains(.dashboard),
              model.loadedAncillaryDomains.contains(.activity),
              model.totalMomentCount == 1 else {
            throw WorkspaceNavigationFailure(description: "startup should load dashboard, activity, and lightweight moment count")
        }
        guard !model.loadedAncillaryDomains.contains(.moments),
              !model.loadedAncillaryDomains.contains(.questions),
              !model.loadedAncillaryDomains.contains(.trash) else {
            throw WorkspaceNavigationFailure(description: "unvisited ancillary domains should not eagerly load on startup: \(model.loadedAncillaryDomains)")
        }

        model.section = .qAndA
        await model.ancillaryDomainTasks[.questions]?.value
        guard model.loadedAncillaryDomains.contains(.questions), model.questions.count == 1 else {
            throw WorkspaceNavigationFailure(description: "switching to Q&A did not lazily load questions")
        }
        guard !model.loadedAncillaryDomains.contains(.moments) else {
            throw WorkspaceNavigationFailure(description: "visiting Q&A should not load moments")
        }

        model.section = .moments
        await model.ancillaryDomainTasks[.moments]?.value
        guard model.loadedAncillaryDomains.contains(.moments), model.moments.count == 1 else {
            throw WorkspaceNavigationFailure(description: "switching to moments did not lazily load moment feed")
        }

        model.section = .trash
        await model.ancillaryDomainTasks[.trash]?.value
        guard model.loadedAncillaryDomains.contains(.trash), model.trashItems.count == 1 else {
            throw WorkspaceNavigationFailure(description: "switching to trash did not lazily load trash items")
        }
    }

    @MainActor
    func testFirstDashboardTodoModuleLoadsExistingTodos() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leon-dashboard-todos-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false)
        try await model.connect(to: root)
        await model.workspaceAncillaryLoadTask?.value
        let todo = try await model.store.saveTodo(.init(title: "Existing dashboard task"))
        guard model.isTodoModuleEnabled, !model.todoSession.hasLoaded else {
            throw WorkspaceNavigationFailure(description: "the fixture must start with an enabled but unloaded Todo module")
        }

        var dashboard = model.dashboard
        dashboard.modules.append(NativeDashboardModule(kind: .todos))
        guard await model.saveDashboard(dashboard) else {
            throw WorkspaceNavigationFailure(description: "the new dashboard module could not be saved")
        }
        await model.ancillaryDomainTasks[.todos]?.value
        guard model.section == .dashboard, model.todoSession.items.map(\.id) == [todo.id] else {
            throw WorkspaceNavigationFailure(description: "the first dashboard Todo module never loaded existing tasks")
        }
    }

    @MainActor
    func testDashboardAudioIsReleasedWhenLeavingDashboard() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leon-dashboard-audio-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false)
        try await model.connect(to: root)
        await model.workspaceAncillaryLoadTask?.value
        guard let audio = Bundle.module.url(forResource: "article-audio-silence", withExtension: "mp3", subdirectory: "Fixtures") else {
            throw WorkspaceNavigationFailure(description: "missing dashboard audio fixture")
        }
        let media = try await model.store.importDashboardMedia(audio, kind: .audio)
        let document = NativeDashboardDocument(modules: [NativeDashboardModule(kind: .audio, media: media)])
        guard await model.saveDashboard(document) else {
            throw WorkspaceNavigationFailure(description: "the audio dashboard could not be saved")
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: ContentView(model: model))
        window.contentViewController = host
        defer { window.close() }
        func playerView(in view: NSView) -> AVPlayerView? {
            if let view = view as? AVPlayerView { return view }
            return view.subviews.lazy.compactMap { playerView(in: $0) }.first
        }
        for _ in 0..<100 {
            host.view.layoutSubtreeIfNeeded()
            if playerView(in: host.view)?.player != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let view = playerView(in: host.view), let player = view.player else {
            throw WorkspaceNavigationFailure(description: "the dashboard audio player never mounted")
        }
        player.isMuted = true
        player.play()
        model.section = .trash
        for _ in 0..<50 {
            host.view.layoutSubtreeIfNeeded()
            if view.player == nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard view.player == nil, player.rate == 0, playerView(in: host.view) == nil else {
            throw WorkspaceNavigationFailure(description: "dashboard audio stayed mounted after leaving the page")
        }
    }

    @MainActor
    func testFirstMomentSearchKeepsOlderImageResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leon-moment-search-navigation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false)
        try await model.connect(to: root)
        await model.workspaceAncillaryLoadTask?.value
        let media = NativeMedia(kind: "image", name: "sample.png", size: 1, url: "sample.png")
        let target = try await model.store.saveMoment(text: "", textRuns: [], images: [media])
        for index in 1...41 {
            _ = try await model.store.saveMoment(text: "Newer moment \(index)", textRuns: [], images: [])
        }

        model.updateGlobalSearch("type:moment", articlesOnly: false, debounce: false)
        await model.globalSearchTask?.value
        guard let result = model.globalSearchResults.first(where: { $0.documentID == target.id }) else {
            throw WorkspaceNavigationFailure(description: "the image-only moment was missing from global search")
        }
        model.openSearchResult(result)
        for _ in 0..<100 {
            if model.section == .moments { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await model.ancillaryDomainTasks[.moments]?.value
        guard model.section == .moments, model.moments.map(\.id) == [target.id], !model.hasMoreMoments,
              model.loadedAncillaryDomains.contains(.moments), model.totalMomentCount == 42 else {
            throw WorkspaceNavigationFailure(description: "the first feed load replaced the selected image-only result")
        }
    }

    @MainActor
    func testTrashRestoreDoesNotPublishAfterWorkspaceChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leon-trash-workspace-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldStore = LocalBlogStore(rootURL: root.appendingPathComponent("old"))
        let newStore = LocalBlogStore(rootURL: root.appendingPathComponent("new"))
        let restoring = try await oldStore.saveMoment(text: "Restore this moment", textRuns: [], images: [])
        try await oldStore.deleteMoment(id: restoring.id)
        let newMoment = try await newStore.saveMoment(text: "Other workspace trash", textRuns: [], images: [])
        try await newStore.deleteMoment(id: newMoment.id)
        let oldTrash = try await oldStore.listTrash()
        guard let item = oldTrash.first else {
            throw WorkspaceNavigationFailure(description: "missing the item to restore")
        }
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false, store: oldStore)
        model.loadedAncillaryDomains.insert(.moments)
        var switched = false
        model.projectionRebuildWillBuild = { [weak model] kind in
            guard kind == .momentFacets, let model else { return }
            model.workspaceGeneration += 1
            model.momentFeedGeneration += 1
            model.store = newStore
            model.moments = []
            model.trashItems = []
            model.totalMomentCount = 0
            switched = true
        }
        guard let operation = model.restoreTrash(item) else {
            throw WorkspaceNavigationFailure(description: "the restore operation did not start")
        }
        await operation.value
        let restored = try await oldStore.getMoment(id: restoring.id)
        guard switched, restored.id == restoring.id,
              model.trashItems.isEmpty, !model.loadedAncillaryDomains.contains(.trash),
              model.totalMomentCount == 0, model.availableMomentMonths.isEmpty else {
            throw WorkspaceNavigationFailure(description: "an old restore published data after switching workspaces")
        }
    }

    @MainActor
    func testMentionConversionDoesNotReplaceNewArticleRelations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leon-relations-navigation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        func save(_ slug: String, title: String, body: String) async throws -> NativeArticle {
            try await store.saveArticle(NativeSaveArticle(
                banner: nil, body: body, category: "Notes", excerpt: "", media: [],
                slug: slug, status: .draft, tags: [], title: title, expectedUpdatedAt: nil
            ))
        }
        let target = try await save("target", title: "Unique Target", body: "Target content")
        let source = try await save("source", title: "Source", body: "Unique Target mentioned here")
        let next = try await save("next", title: "Next article", body: "Next article content")
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false, store: store)
        await model.replaceArticleSummaries([target.summary, source.summary, next.summary])
        model.selectedArticle = target
        model.selectedSlug = target.slug
        let navigation = model.$articleGraph.dropFirst().prefix(1).sink { _ in
            Task { @MainActor in
                model.articleNavigationGeneration += 1
                model.selectedArticle = next
                model.selectedSlug = next.slug
                model.selectedArticleRelations = .empty
            }
        }
        defer { navigation.cancel() }

        model.convertUnlinkedMention(.init(article: source.summary, count: 1, snippet: source.body))
        for _ in 0..<100 {
            if !model.isSaving && model.selectedSlug == next.slug { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let converted = try await store.getArticle(slug: source.slug)
        guard !model.isSaving, converted.body.contains("[[target"),
              model.selectedSlug == next.slug, model.selectedArticleRelations == .empty else {
            throw WorkspaceNavigationFailure(description: "mention conversion wrote stale relations into the next article")
        }
    }
}

@MainActor
private final class NavigationLoadingFrameBarrier {
    private var pending: [NativeNavigationPageRequest: CheckedContinuation<Void, Never>] = [:]

    func wait(for request: NativeNavigationPageRequest) async {
        await withCheckedContinuation { pending[request] = $0 }
    }

    func isWaiting(for request: NativeNavigationPageRequest) -> Bool { pending[request] != nil }
    func release(_ request: NativeNavigationPageRequest) { pending.removeValue(forKey: request)?.resume() }
    func releaseAll() {
        let continuations = Array(pending.values)
        pending.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private struct NavigationMountProbe: NSViewRepresentable {
    let request: NativeNavigationPageRequest
    let onMount: (NativeNavigationPageRequest) -> Void

    func makeNSView(context: Context) -> NSView { onMount(request); return NSTextView() }
    func updateNSView(_ view: NSView, context: Context) {}
}
