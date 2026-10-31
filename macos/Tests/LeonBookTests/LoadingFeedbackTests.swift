import AppKit
import SwiftUI
import WebKit
@testable import LeonBook

private struct LoadingFeedbackFailure: Error { let message: String }

private extension LocalBlogStore {
    func holdLoadingFeedbackQueue(entered: @Sendable () -> Void, release: DispatchSemaphore) -> Bool {
        entered()
        return release.wait(timeout: .now() + 10) == .success
    }
}

@MainActor
final class LoadingFeedbackTests {
    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw LoadingFeedbackFailure(message: message) }
    }

    func testOverlappingOperationsAndWorkspaceReset() throws {
        var operations = NativeLoadingOperations()
        let first = operations.begin(.history)
        let second = operations.begin(.history)
        operations.end(first)
        try require(operations.contains(.history), "older completion hid a pending request")
        let opening = operations.begin(.article)
        try require(operations.current == .article, "latest action must have visible feedback")
        operations.end(opening)
        try require(operations.current == .history, "pending operation lost after the foreground request completed")
        operations.reset()
        let newWorkspace = operations.begin(.questions)
        operations.end(second)
        try require(operations.current == .questions, "old workspace completion changed new workspace feedback")
        operations.end(newWorkspace)
        try require(operations.current == nil, "completed operations kept animating")
    }

    func testRealLoadsExposePendingStateAndClearAfterCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loading-model-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false, store: LocalBlogStore(rootURL: root))
        model.storageReady = true
        model.isLoading = false
        try await model.store.prepare()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        var blocker: Task<Bool, Never>!
        await withCheckedContinuation { continuation in
            blocker = Task {
                await model.store.holdLoadingFeedbackQueue(entered: { continuation.resume() }, release: release)
            }
        }
        let dashboard = Task { await model.reloadDashboard() }
        let questions = Task { try await model.reloadQuestionList() }
        model.refreshArticleHistory()
        for _ in 0..<100 {
            if model.loadingOperations.contains(.dashboard) && model.loadingOperations.contains(.questions) { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try require(model.loadingOperations.contains(.dashboard), "homepage reload has no pending feedback")
        try require(model.loadingOperations.contains(.questions), "question query has no pending feedback")
        try require(model.loadingOperations.contains(.history), "history sheet would show a false empty state")
        questions.cancel()
        model.workspaceGeneration += 1
        try require(model.loadingOperations.current == nil, "workspace change retained old loading state")
        let next = model.loadingOperations.begin(.article)
        release.signal()
        try require(await blocker.value, "store test queue timed out")
        await dashboard.value
        _ = try? await questions.value
        // The queued history load also completes after the store is released.
        for _ in 0..<10 { await Task.yield() }
        try require(model.loadingOperations.current == .article, "obsolete load completion dismissed current feedback")
        model.loadingOperations.end(next)
        try require(model.loadingFeedbackTitle == nil, "idle model kept a loading indicator")
    }

    func testWebFeedbackIgnoresObsoleteCompletionAndStopsOnFailure() throws {
        _ = NSApplication.shared
        let view = NativeLoadingWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 500), configuration: WKWebViewConfiguration())
        view.waitsForContent = true
        let old = view.beginContentLoading()
        let current = view.beginContentLoading()
        view.finishContentLoading(old)
        try require(view.loadingRequestID == current, "stale WebKit completion hid the new document's loader")
        view.showLoadingFailure("Test failure")
        let indicators = descendants(view).compactMap { $0 as? NSProgressIndicator }
        try require(!indicators.isEmpty && indicators.allSatisfy(\.isHidden), "failure left an endless spinner")
        let retried = view.beginContentLoading()
        view.finishContentLoading(current)
        try require(view.loadingRequestID == retried, "old completion dismissed retry feedback")
        view.finishContentLoading(retried)
        try require(view.loadingRequestID == nil, "successful load kept its spinner")
        view.beginContentLoading()
        view.cancelLoadingFeedback()
        try require(!descendants(view).contains { $0.identifier?.rawValue == "web-loading-status" }, "closed view retained feedback")
    }

    func testRefreshFeedbackPreservesContentAndSkipsFastOperations() async throws {
        _ = NSApplication.shared
        var mounts = 0
        func content(_ title: String?) -> some View {
            LoadingContentProbe { mounts += 1 }.nativeLoadingFeedback(title)
        }
        let host = NSHostingView(rootView: content(nil))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        func hasSpinner() -> Bool { descendants(host).contains { $0 is NSProgressIndicator } }
        host.rootView = content("Loading")
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 40_000_000)
        host.rootView = content(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 160_000_000)
        host.layoutSubtreeIfNeeded()
        try require(!hasSpinner(), "a completed fast operation revealed delayed feedback")
        host.rootView = content("Loading")
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        host.layoutSubtreeIfNeeded()
        try require(hasSpinner(), "long refresh had no visible progress indicator")
        try require(mounts == 1, "refresh feedback remounted useful page content")
        host.rootView = content(nil)
        host.layoutSubtreeIfNeeded()
        try require(!hasSpinner(), "finished operation kept its progress indicator")
    }

    func testRichEditorFeedbackTracksDocumentReadiness() async throws {
        _ = NSApplication.shared
        func editor(_ id: String) -> RichArticleEditor {
            RichArticleEditor(html: .constant("<article data-leon-format=\"html-v1\"><p>\(id)</p></article>"), documentID: id)
        }
        let host = NSHostingView(rootView: editor("first-document"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        guard let view = descendants(host).compactMap({ $0 as? NativeLoadingWebView }).first else {
            throw LoadingFeedbackFailure(message: "real rich editor did not install native loading feedback")
        }
        try require(view.loadingRequestID != nil, "initial blank editor had no feedback")
        if let path = ProcessInfo.processInfo.environment["LEON_LOADING_PREVIEW"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        func waitForDocument(_ id: String) async throws {
            for _ in 0..<250 {
                if view.loadingRequestID == nil,
                   (try? await view.evaluateJavaScript("document.getElementById('document')?.innerText.includes('\(id)')")) as? Bool == true { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            throw LoadingFeedbackFailure(message: "document readiness failed: \(id)")
        }
        try await waitForDocument("first-document")
        host.rootView = editor("second-document")
        host.layoutSubtreeIfNeeded()
        try require(view.loadingRequestID != nil, "document switch had no pending feedback")
        try await waitForDocument("second-document")
        let html = try await view.evaluateJavaScript("document.getElementById('document').innerText") as? String
        try require(html?.contains("first-document") == false, "new document showed stale content")
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

private struct LoadingContentProbe: NSViewRepresentable {
    let onMount: () -> Void
    func makeNSView(context: Context) -> NSTextField {
        onMount()
        return NSTextField(labelWithString: "Existing content")
    }
    func updateNSView(_ view: NSTextField, context: Context) { }
}
