import AppKit
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
        render(superseded)
        guard window.firstResponder !== editor else {
            throw WorkspaceNavigationFailure(description: "typing could still reach the hidden outgoing editor")
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
