import AppKit
import Foundation
import SwiftUI
@testable import LeonBook

private struct DashboardTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func dashboardExpect(_ condition: Bool, _ message: String) throws {
    if !condition { throw DashboardTestFailure(description: message) }
}

final class DashboardTests {
    func testGridSnappingWrappingAndLegacyDimensions() throws {
        let metrics = NativeDashboardGridMetrics(width: 1_080)
        let frames = metrics.frames(for: [
            .init(columns: 3, height: metrics.cardHeight(natural: 133, rows: nil)),
            .init(columns: 5, height: metrics.cardHeight(natural: 225, rows: nil)),
            .init(columns: 4, height: metrics.cardHeight(natural: 190, rows: nil)),
            .init(columns: 6, height: metrics.cardHeight(natural: 0, rows: 8)),
            .init(columns: 6, height: metrics.cardHeight(natural: 0, rows: 10)),
        ])
        try dashboardExpect(frames[2].maxX == 1_080 && frames[4].maxX == 1_080,
                            "different column combinations must share the same right edge, including gutters")
        try dashboardExpect(frames[3].minY == 264 && frames[3].minY == frames[4].minY,
                            "new rows must clear the tallest preceding card and align at the same grid line")
        for (index, frame) in frames.enumerated() {
            try dashboardExpect(frame.minY.truncatingRemainder(dividingBy: 24) == 0 && frame.maxY.truncatingRemainder(dividingBy: 24) == 0,
                                "all top and bottom edges must align to the vertical grid")
            for other in frames.dropFirst(index + 1) {
                try dashboardExpect(!frame.intersects(other), "resized cards must never overlap")
            }
        }
        let original = NativeDashboardModule(kind: .text, width: .half, text: "Keep content", columnSpan: 6, heightRows: 10)
        let session = NativeDashboardResizeSession(original: original, axis: .both,
            size: CGSize(width: 528, height: 240), metrics: metrics)
        try dashboardExpect(session.module(at: CGSize(width: 45, height: 11)) == original,
                            "movement below half a grid unit must not jitter the dimensions")
        let larger = session.module(at: CGSize(width: 47, height: 13))
        try dashboardExpect(larger.columnSpan == 7 && larger.heightRows == 11 && larger.text == original.text,
                            "crossing each half-unit threshold must snap dimensions independently, preserving content")
        let smaller = session.module(at: CGSize(width: -47, height: -13))
        try dashboardExpect(smaller.columnSpan == 5 && smaller.heightRows == 9, "both resize directions must snap symmetrically")
        let minimum = session.module(at: CGSize(width: -10_000, height: -10_000))
        let maximum = session.module(at: CGSize(width: 10_000, height: 10_000))
        try dashboardExpect(minimum.columnSpan == 3 && minimum.heightRows == 6 && maximum.columnSpan == 12 && maximum.heightRows == 80,
                            "resizing must clamp to usable dimensions and remain inside the grid")
        let horizontal = NativeDashboardResizeSession(original: original, axis: .width, size: session.size, metrics: metrics)
        let vertical = NativeDashboardResizeSession(original: original, axis: .height, size: session.size, metrics: metrics)
        try dashboardExpect(horizontal.module(at: CGSize(width: 92, height: 240)).heightRows == 10,
                            "the right edge must not change height")
        try dashboardExpect(vertical.module(at: CGSize(width: 920, height: 24)).columnSpan == 6,
                            "the bottom edge must not change width")
        let compact = NativeDashboardGridMetrics(width: 360)
        let compactFrames = compact.frames(for: [.init(columns: 3, height: 144), .init(columns: 9, height: 240)])
        try dashboardExpect(compactFrames.allSatisfy { $0.width == 360 && $0.minX == 0 } && compactFrames[1].minY == 168,
                            "small windows must stack cards without changing saved column spans")
        let compactResize = NativeDashboardResizeSession(original: original, axis: .both,
            size: CGSize(width: 360, height: 240), metrics: compact).module(at: CGSize(width: 100, height: 24))
        try dashboardExpect(compactResize.columnSpan == 6 && compactResize.heightRows == 11,
                            "height changes in a narrow window must preserve desktop widths")

        // JSON written before grid resizing has neither optional dimension.
        let legacy = NativeDashboardModule(kind: .text, width: .half, text: "Old layout")
        let legacyData = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(NativeDashboardModule.self, from: legacyData)
        try dashboardExpect(!String(decoding: legacyData, as: UTF8.self).contains("columnSpan") && decoded.preferredColumnSpan == 6 && decoded.heightRows == nil,
                            "existing homepage documents must retain half width and content-driven height")
    }

    @MainActor
    func testNativeResizeHandlesSnapReflowAndCancel() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false, store: LocalBlogStore(rootURL: root))
        model.storageReady = true
        model.isLoading = false
        await model.reloadDashboard()
        let first = NativeDashboardModule(kind: .text, title: "今天的灵感", width: .half,
            text: "## 留一点时间给自己\n\n读完一本书，记录一个想法。\n\n> 慢慢来，比较快。", columnSpan: 6, heightRows: 10)
        let second = NativeDashboardModule(kind: .text, title: "阅读清单", width: .half,
            text: "### 这周想读\n\n- 一篇长文章\n- 一本新书\n- 昨天的笔记", columnSpan: 6, heightRows: 10)
        let original = NativeDashboardDocument(title: "我的创作空间", subtitle: "拖动边缘，让每一块内容都有合适的空间。", modules: [
            first, second, NativeDashboardModule(kind: .quickNote, title: "开始写作", heightRows: 8)
        ])
        model.dashboardEditing.draft = original
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 1_050),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        defer { window.close() }
        let view = NSHostingView(rootView: DashboardView(model: model)
            .environment(\.colorScheme, .light).environment(\.locale, Locale(identifier: "zh-Hans")))
        window.contentView = view
        view.setFrameSize(NSSize(width: 1_100, height: 1_050))
        func settle() async throws {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 80_000_000)
            view.layoutSubtreeIfNeeded()
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func handle(_ id: UUID, axis: NativeDashboardResizeAxis = .both) throws -> NativeDashboardResizeHandleView {
            guard let handle = descendants(view).compactMap({ $0 as? NativeDashboardResizeHandleView })
                .first(where: { $0.moduleID == id && $0.axis == axis }) else {
                throw DashboardTestFailure(description: "the displayed card must expose its native resize handle")
            }
            return handle
        }
        func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func start(_ handle: NativeDashboardResizeHandleView) -> CGPoint {
            let point = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
            handle.mouseDown(with: event(.leftMouseDown, at: point))
            return point
        }
        let metrics = NativeDashboardGridMetrics(width: 1_012)
        try await settle()
        let corner = try handle(first.id)
        let hitPoint = corner.convert(CGPoint(x: corner.bounds.midX, y: corner.bounds.midY), to: view.superview)
        try dashboardExpect(view.hitTest(hitPoint) === corner,
                            "the visible corner must receive mouse hits instead of decorative overlays or sorting gestures")
        let origin = start(corner)
        let destination = CGPoint(x: origin.x + metrics.columnStride * 2, y: origin.y - 48)
        corner.mouseDragged(with: event(.leftMouseDragged, at: destination))
        try await settle()
        try dashboardExpect(model.dashboardEditing.draft?.modules[0].columnSpan == 8 && model.dashboardEditing.draft?.modules[0].heightRows == 12,
                            "actual native mouse callbacks must resize the visible module on both axes")
        try dashboardExpect(try handle(first.id) === corner, "grid wrapping must retain native handle identity during the gesture")
        let anchors = descendants(view).compactMap { $0 as? NativeDashboardDragPreviewAnchor.View }
        let firstAnchor = anchors.first { $0.moduleID == first.id }!
        let secondAnchor = anchors.first { $0.moduleID == second.id }!
        try dashboardExpect(abs(firstAnchor.bounds.width - metrics.cardWidth(columns: 8)) < 1 && abs(firstAnchor.bounds.height - 288) < 1,
                            "the displayed card must actually honor its persisted width and height")
        try dashboardExpect(!firstAnchor.convert(firstAnchor.bounds, to: view).intersects(secondAnchor.convert(secondAnchor.bounds, to: view)),
                            "neighbours must reflow without overlap during resizing")
        if let path = ProcessInfo.processInfo.environment["LEON_DASHBOARD_RESIZE_PREVIEW_PATH"],
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        }
        corner.mouseUp(with: event(.leftMouseUp, at: destination))
        try await settle()
        try dashboardExpect(model.dashboardEditing.draft?.modules[0].columnSpan == 8 && model.dashboard == .standard,
                            "mouse release must retain the resized draft without writing the saved homepage")

        // A module starting in the second column moves to a new row mid-drag.
        // Subsequent events must still use the original window coordinates.
        model.dashboardEditing.draft = original
        try await settle()
        let moving = try handle(second.id)
        let movingOrigin = start(moving)
        let movingEnd = CGPoint(x: movingOrigin.x + metrics.columnStride, y: movingOrigin.y - 24)
        moving.mouseDragged(with: event(.leftMouseDragged, at: movingEnd))
        try await settle()
        try dashboardExpect(try handle(second.id) === moving, "a module wrapping to a new row must not lose mouse capture")
        moving.mouseUp(with: event(.leftMouseUp, at: movingEnd))
        try dashboardExpect(model.dashboardEditing.draft?.modules[1].columnSpan == 7 && model.dashboardEditing.draft?.modules[1].heightRows == 11,
                            "moving the handle's frame must not feed back into the pointer delta")

        try await settle()
        let beforeCancel = model.dashboardEditing.draft
        let bottom = try handle(first.id, axis: .height)
        let bottomOrigin = start(bottom)
        bottom.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: bottomOrigin.x + 500, y: bottomOrigin.y - 72)))
        try dashboardExpect(model.dashboardEditing.draft?.modules[0].columnSpan == 6 && model.dashboardEditing.draft?.modules[0].heightRows == 13,
                            "the native bottom handle must change only height")
        bottom.cancelOperation(nil)
        bottom.mouseUp(with: event(.leftMouseUp, at: bottomOrigin))
        try dashboardExpect(model.dashboardEditing.draft == beforeCancel, "Esc must restore the pre-gesture dimensions and ignore a later mouse-up")

        let pending = try handle(first.id)
        let pendingOrigin = start(pending)
        model.dashboardEditing.draft = nil
        try await settle()
        pending.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: pendingOrigin.x + 300, y: pendingOrigin.y - 200)))
        try dashboardExpect(model.dashboardEditing.draft == nil, "finishing a gesture after Cancel must never recreate an abandoned draft")
        try dashboardExpect(descendants(view).compactMap { $0 as? NativeDashboardResizeHandleView }.isEmpty,
                            "saved viewing mode must not expose edit handles")
        await model.store.closeForRestore()
    }

    @MainActor
    func testDraggingModuleDownwardReordersDraft() throws {
        let editing = NativeDashboardEditingState()
        let first = NativeDashboardModule(kind: .text, title: "First")
        let second = NativeDashboardModule(kind: .text, title: "Second")
        var document = NativeDashboardDocument.standard
        document.modules = [first, second]
        editing.draft = document
        // Same entry point as the homepage's drop callback: drag the first
        // module down onto its neighbour and release.
        editing.dropModule(first.id, onto: second.id)
        try dashboardExpect(editing.draft?.modules.map(\.id) == [second.id, first.id],
                            "dropping the first module onto the next one must move it downward, not leave it unchanged")
    }

    @MainActor
    func testNativeModuleDropsReorderAndPreserveEditingBoundaries() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false, store: LocalBlogStore(rootURL: root))
        model.storageReady = true
        model.isDashboardLoaded = true
        model.isLoading = false
        let first = NativeDashboardModule(kind: .text, title: "First", width: .half, text: "Keep my content")
        let second = NativeDashboardModule(kind: .text, title: "Second", width: .half)
        let third = NativeDashboardModule(kind: .text, title: "Third")
        var document = NativeDashboardDocument.standard
        document.modules = [first, second, third]
        model.dashboard = document
        model.dashboardEditing.draft = document
        var activeDrag: NativeDashboardModuleDrag?
        var dropTargetID: UUID?
        func delegate(for target: UUID) -> NativeDashboardModuleDropDelegate {
            NativeDashboardModuleDropDelegate(model: model, targetID: target,
                activeDrag: Binding(get: { activeDrag }, set: { activeDrag = $0 }),
                dropTargetID: Binding(get: { dropTargetID }, set: { dropTargetID = $0 }))
        }
        func waitForDelivery() async throws {
            let deadline = Date().addingTimeInterval(2)
            while activeDrag != nil, Date() < deadline {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            try dashboardExpect(activeDrag == nil, "native provider delivery must complete and release the drag")
        }
        func drop(_ source: UUID, onto target: UUID) async throws {
            let drag = NativeDashboardModuleDrag(moduleID: source)
            activeDrag = drag
            dropTargetID = target
            try dashboardExpect(delegate(for: target).performDrop(provider: drag.itemProvider()), "native module drop must be accepted")
            try await waitForDelivery()
            try dashboardExpect(dropTargetID == nil, "release must clear the highlighted drop target")
        }
        try await drop(first.id, onto: second.id)
        try dashboardExpect(model.dashboardEditing.draft?.modules == [second, first, third], "adjacent downward drops must change order and preserve all content")
        try await drop(first.id, onto: third.id)
        try dashboardExpect(model.dashboardEditing.draft?.modules == [second, third, first], "dropping on the last module must reach the final position")
        try await drop(first.id, onto: second.id)
        try dashboardExpect(model.dashboardEditing.draft?.modules == [first, second, third], "upward drops must reach the first position")
        try dashboardExpect(model.dashboardEditing.draft?.rows(compact: false).map(\.count) == [2, 1], "half-width cards must still pair in their new reading order")
        try await drop(first.id, onto: first.id)
        try dashboardExpect(model.dashboardEditing.draft == document, "dropping on the source must be harmless")

        let drag = NativeDashboardModuleDrag(moduleID: first.id)
        activeDrag = drag
        try dashboardExpect(!delegate(for: UUID()).performDrop(provider: drag.itemProvider()), "removed drop targets must reject the drop")
        try dashboardExpect(!delegate(for: second.id).performDrop(provider: NSItemProvider(object: "External text" as NSString)), "external text must not reorder modules")
        let otherGesture = NativeDashboardModuleDrag(moduleID: first.id)
        try dashboardExpect(delegate(for: second.id).performDrop(provider: otherGesture.itemProvider()), "matching types may load before session validation")
        try await waitForDelivery()
        try dashboardExpect(model.dashboardEditing.draft == document, "a different gesture or window must not reuse a stale drag identity")

        activeDrag = drag
        try dashboardExpect(delegate(for: second.id).performDrop(provider: drag.itemProvider()), "drop must start before saving")
        model.isSavingDashboard = true
        try await waitForDelivery()
        try dashboardExpect(model.dashboardEditing.draft == document, "an asynchronous drop must not change a draft being saved")
        model.isSavingDashboard = false
        activeDrag = drag
        try dashboardExpect(delegate(for: second.id).performDrop(provider: drag.itemProvider()), "drop must start before cancelling")
        model.dashboardEditing.draft = nil
        try await waitForDelivery()
        try dashboardExpect(model.dashboardEditing.draft == nil, "an asynchronous drop must not restore a cancelled draft")
        activeDrag = drag
        try dashboardExpect(!delegate(for: second.id).performDrop(provider: drag.itemProvider()), "viewing mode must not accept module drops")
        try dashboardExpect(model.dashboard == document, "dragging must never mutate the saved homepage")
    }

    func testRegistryRecoversEmptyHomepageScaffoldingWithoutMovingFiles() async throws {
        if let path = ProcessInfo.processInfo.environment["LEON_DASHBOARD_RECOVERY_FIXTURE_PATH"] {
            let fixture = URL(fileURLWithPath: path)
            let database = fixture.appendingPathComponent("workspaces/leon/leon-book.sqlite")
            let originalDatabase = try Data(contentsOf: database)
            let replay = UserWorkspaceStore(rootURL: fixture)
            let state = try await replay.prepare()
            try dashboardExpect(state.workspaceURL == fixture.appendingPathComponent("workspaces/leon", isDirectory: true),
                                "the copied affected registry must reconnect to its original workspace")
            try dashboardExpect(try Data(contentsOf: database) == originalDatabase,
                                "recovery must not rewrite the existing user's content database")
            print("Copied workspace recovery: connected to leon; \(state.users.count) users; content database unchanged")
            await replay.closeForRestore()
        }
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = UserWorkspaceStore(rootURL: root)
        let existing = try await registry.prepare()
        let content = LocalBlogStore(rootURL: existing.workspaceURL)
        _ = try await content.saveArticle(NativeSaveArticle(
            banner: nil, body: "原有正文", category: "", excerpt: "", media: [],
            slug: "original", status: .published, tags: [], title: "原有文章", expectedUpdatedAt: nil
        ))
        await content.closeForRestore()
        await registry.closeForRestore()
        // Recreate files already produced by the affected app, including the
        // empty article schema inside the existing user registry database.
        let accidental = LocalBlogStore(rootURL: root)
        _ = try await accidental.loadDashboard()
        await accidental.closeForRestore()
        let before = try Data(contentsOf: root.appendingPathComponent("moments/index.json"))
        let reopened = try await registry.prepare()
        try dashboardExpect(reopened.workspaceURL == existing.workspaceURL && reopened.users == existing.users,
                            "empty startup artifacts must not block the existing user workspace")
        try dashboardExpect(try Data(contentsOf: root.appendingPathComponent("moments/index.json")) == before,
                            "recovery must leave root artifacts in place without deleting or merging files")
        let restored = LocalBlogStore(rootURL: reopened.workspaceURL)
        try dashboardExpect(try await restored.getArticle(slug: "original").body == "原有正文",
                            "recovery must read the original user's content")
        await restored.closeForRestore()
        await registry.closeForRestore()

        let unexpected = root.appendingPathComponent("media/do-not-ignore.txt")
        try Data("important".utf8).write(to: unexpected)
        do {
            _ = try await registry.prepare()
            throw DashboardTestFailure(description: "recovery must refuse to ignore actual files")
        } catch is NativeStoreError { }
        try FileManager.default.removeItem(at: unexpected)
        let rootContent = LocalBlogStore(rootURL: root)
        _ = try await rootContent.saveArticle(NativeSaveArticle(
            banner: nil, body: "根目录真实数据", category: "", excerpt: "", media: [],
            slug: "keep-me", status: .draft, tags: [], title: "根目录文章", expectedUpdatedAt: nil
        ))
        await rootContent.closeForRestore()
        do {
            _ = try await registry.prepare()
            throw DashboardTestFailure(description: "recovery must refuse a root database containing real content")
        } catch is NativeStoreError { }
        await registry.closeForRestore()
    }

    @MainActor
    func testHomepageWaitsForWorkspaceConnectionBeforeLoading() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = UserWorkspaceStore(rootURL: root)
        let existing = try await registry.prepare()
        let content = LocalBlogStore(rootURL: existing.workspaceURL)
        try await content.prepareForInteractiveUse()
        await content.closeForRestore()
        await registry.closeForRestore()

        // SwiftUI mounts the homepage while connect(to:) is still resolving the
        // active user. At this point model.store points at the registry root.
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false,
                                   store: LocalBlogStore(rootURL: root))
        defer {
            model.stopMarkdownSourceMonitor()
            model.workspaceAncillaryLoadTask?.cancel()
            model.compatibilityExportTask?.cancel()
        }
        await model.reloadDashboard()
        let reopened = try await registry.prepare()
        try dashboardExpect(reopened.workspaceURL == existing.workspaceURL,
                            "early homepage loading must not break an existing user's workspace")
        try dashboardExpect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("articles").path),
                            "the user registry must not acquire article workspace directories")
        try dashboardExpect(!model.isDashboardLoaded, "home content must wait for the user's connected store")
        try await model.connect(to: root)
        await model.reloadDashboard()
        let connectedRoot = await model.store.rootURL
        try dashboardExpect(model.storageReady && model.isDashboardLoaded && connectedRoot == existing.workspaceURL,
                            "after connection the homepage must load from the selected user's content store")
        model.workspaceAncillaryLoadTask?.cancel()
        model.compatibilityExportTask?.cancel()
        model.stopMarkdownSourceMonitor()
        await model.store.closeForRestore()
        await model.userWorkspaces.closeForRestore()
        await registry.closeForRestore()
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leon-dashboard-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testLayoutPersistenceIsolationAndConflicts() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        let first = LocalBlogStore(rootURL: workspace)
        var layout = try await first.loadDashboard()
        try dashboardExpect(layout.modules.map(\.kind) == [.quickNote, .statistics, .recentArticles, .activity], "existing home content must be the default")
        layout.title = "我的创作角落"
        layout.subtitle = "今天也留下一点记录"
        layout.modules = NativeDashboardModuleKind.allCases.map { NativeDashboardModule(kind: $0) }
        layout.modules[0].text = "## 灵感\n\n- 写作\n- 阅读"
        layout.modules[0].width = .half
        layout.modules[1].width = .half
        layout.modules[0].setColumnSpan(4)
        layout.modules[0].heightRows = 12
        layout.modules[1].setColumnSpan(8)
        layout.modules[1].heightRows = 12
        layout.modules[4].articleSlug = "pinned-article"
        layout.modules[5].showsCompletedTodos = true
        let second = LocalBlogStore(rootURL: workspace)
        let stale = try await second.loadDashboard()
        let saved = try await first.saveDashboard(layout)
        do {
            _ = try await second.saveDashboard(stale)
            throw DashboardTestFailure(description: "a stale second window must not overwrite the dashboard")
        } catch NativeDashboardError.conflict { }
        try dashboardExpect(try await second.loadDashboard() == saved, "every module's contents and layout must round-trip")
        try dashboardExpect(saved.rows(compact: false).first?.count == 2, "adjacent half-width cards must share a row")
        try dashboardExpect(saved.rows(compact: true).allSatisfy { $0.count == 1 }, "narrow windows must stack all modules")

        var reordered = saved
        let last = reordered.modules.last!.id, target = reordered.modules[0].id
        reordered.move(last, onto: target)
        reordered.move(last, by: 1)
        let reorderedSaved = try await first.saveDashboard(reordered)
        await first.closeForRestore()
        await second.closeForRestore()
        let reopened = LocalBlogStore(rootURL: workspace)
        try dashboardExpect(try await reopened.loadDashboard() == reorderedSaved, "custom order and contents must survive reopening")
        let other = LocalBlogStore(rootURL: root.appendingPathComponent("other-user"))
        try dashboardExpect(try await other.loadDashboard() == .standard, "users must have independent dashboards")
        var empty = reorderedSaved
        empty.modules = []
        _ = try await reopened.saveDashboard(empty)
        try dashboardExpect(try await reopened.loadDashboard().modules.isEmpty, "an intentionally empty home must stay empty")
        await reopened.closeForRestore()
        await other.closeForRestore()
    }

    func testInvalidConfigurationsPreserveSavedContent() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root)
        let saved = try await store.saveDashboard(.standard)
        var duplicate = saved
        duplicate.modules.append(duplicate.modules[0])
        do {
            _ = try await store.saveDashboard(duplicate)
            throw DashboardTestFailure(description: "duplicate module identities must be rejected")
        } catch NativeDashboardError.invalidDocument { }
        try dashboardExpect(try await store.loadDashboard() == saved, "invalid edits must preserve the saved home")
        for (columns, rows) in [(2, 10), (13, 10), (6, 5), (6, 81)] {
            var invalidSize = saved
            invalidSize.modules[0].columnSpan = columns
            invalidSize.modules[0].heightRows = rows
            do {
                _ = try await store.saveDashboard(invalidSize)
                throw DashboardTestFailure(description: "invalid grid dimensions must not reach persistent storage")
            } catch NativeDashboardError.invalidDocument { }
            try dashboardExpect(try await store.loadDashboard() == saved, "rejected dimensions must preserve the saved home")
        }
        for raw in ["{invalid", "{\"version\":2,\"revision\":1,\"title\":\"Future\",\"subtitle\":\"\",\"modules\":[]}"] {
            try await store.setDashboardRawForTest(raw)
            do {
                _ = try await store.saveDashboard(.standard)
                throw DashboardTestFailure(description: "unreadable or newer documents must not be replaced by defaults")
            } catch is NativeDashboardError { }
            try dashboardExpect(try await store.dashboardRawForTest() == raw, "failed loads must leave original data untouched")
        }
        await store.closeForRestore()
    }

    func testMediaImportsSurviveSourceRemovalAndCleanup() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBlogStore(rootURL: root.appendingPathComponent("workspace"))
        let image = root.appendingPathComponent("图片.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: image)
        let audio = root.appendingPathComponent("音乐.mp3"), video = root.appendingPathComponent("片段.mp4")
        try FileManager.default.copyItem(at: Bundle.module.url(forResource: "article-audio-silence", withExtension: "mp3", subdirectory: "Fixtures")!, to: audio)
        try FileManager.default.copyItem(at: Bundle.module.url(forResource: "media-library-sample", withExtension: "mp4", subdirectory: "Fixtures")!, to: video)
        var modules: [NativeDashboardModule] = []
        for (url, kind) in [(image, NativeDashboardModuleKind.image), (audio, .audio), (video, .video)] {
            let media = try await store.importDashboardMedia(url, kind: kind)
            try dashboardExpect(media.name == url.lastPathComponent && media.kind == kind.rawValue && media.size > 0, "media imports must preserve original names and types")
            modules.append(NativeDashboardModule(kind: kind, media: media))
            try FileManager.default.removeItem(at: url)
        }
        let saved = try await store.saveDashboard(NativeDashboardDocument(modules: modules))
        try await store.discardUnreferencedMedia(modules.compactMap(\.media))
        for module in modules {
            let local = await store.mediaURL(for: module.media!.url)!
            try dashboardExpect(FileManager.default.fileExists(atPath: local.path), "imported media must survive source deletion and attachment cleanup")
        }
        let invalid = root.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: invalid)
        do {
            _ = try await store.importDashboardMedia(invalid, kind: .image)
            throw DashboardTestFailure(description: "corrupt image imports must fail")
        } catch is NativeStoreError { }
        let badVideo = root.appendingPathComponent("broken.mp4")
        try Data("not a video".utf8).write(to: badVideo)
        do {
            _ = try await store.importDashboardMedia(badVideo, kind: .video)
            throw DashboardTestFailure(description: "corrupt video imports must fail")
        } catch let error as DashboardTestFailure { throw error }
        catch { }
        try dashboardExpect(try await store.loadDashboard() == saved, "failed imports must not alter the saved layout")
        let reservedSlug = try await store.allocateSlug(from: "dashboard")
        try dashboardExpect(reservedSlug != "dashboard", "article deletion must never own the homepage media directory")
        try await store.prepareForBackup()
        let snapshot = try LocalBackupManager.createSnapshot(source: root.appendingPathComponent("workspace"), destination: root.appendingPathComponent("backups"))
        let backup = LocalBlogStore(rootURL: snapshot)
        try dashboardExpect(try await backup.loadDashboard() == saved, "complete workspace backups must contain the dashboard")
        for module in modules {
            let local = await backup.mediaURL(for: module.media!.url)!
            try dashboardExpect(FileManager.default.fileExists(atPath: local.path), "backups must contain homepage media")
        }
        await backup.closeForRestore()
        await store.closeForRestore()
    }

    @MainActor
    func testEditingSessionAndSavedView() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false, store: LocalBlogStore(rootURL: root))
        let suite = "DashboardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            model.backupTask?.cancel()
            model.compatibilityExportTask?.cancel()
            defaults.removePersistentDomain(forName: suite)
        }
        model.firstPartyModuleRuntime = NativeFirstPartyModules.loadRuntime(defaults: defaults)
        model.storageReady = true
        model.isLoading = false
        model.backupDirectoryPath = ""
        await model.reloadDashboard()
        try dashboardExpect(model.canEditDashboard, "loaded dashboards must be editable")
        model.dashboardEditing.draft = model.dashboard
        model.dashboardEditing.draft?.title = "我的创作空间"
        model.dashboardEditing.draft?.subtitle = "灵感、阅读和日常，放在同一个地方。"
        model.dashboardEditing.draft?.modules = [
            NativeDashboardModule(kind: .text, title: "今天的灵感", width: .half, text: "## 留一点时间给自己\n\n读完一本书，记录一个想法。\n\n> 慢慢来，比较快。"),
            NativeDashboardModule(kind: .todos, title: "今天要做的事", width: .half),
            NativeDashboardModule(kind: .quickNote, title: "开始写作"),
            NativeDashboardModule(kind: .statistics),
            NativeDashboardModule(kind: .activity),
        ]
        model.section = .articles
        model.section = .dashboard
        try dashboardExpect(model.dashboardEditing.draft?.title == "我的创作空间", "navigating away must preserve unfinished layout edits")
        try dashboardExpect(model.dashboard.title.isEmpty, "editing must not mutate the saved dashboard before save")
        let success = await model.saveDashboard(model.dashboardEditing.draft!)
        try dashboardExpect(success && model.dashboard.title == "我的创作空间", "Save must persist the edited dashboard")
        model.dashboardEditing.draft = nil
        model.isBackingUp = true
        try dashboardExpect(!model.canEditDashboard, "backup must prevent conflicting writes")
        model.isBackingUp = false
        if let path = ProcessInfo.processInfo.environment["LEON_DASHBOARD_PREVIEW_PATH"] {
            _ = await model.saveTodoDraft(.init(title: "整理今天的阅读笔记"))
            _ = await model.saveTodoDraft(.init(title: "给新文章加一张封面图"))
            try await snapshot(model, path: path)
            model.dashboardEditing.draft = model.dashboard
            let base = URL(fileURLWithPath: path).deletingPathExtension().path
            try await snapshot(model, path: base + "-editing.png", width: 760)
            model.dashboardEditing.draft = nil
        }
        await model.store.closeForRestore()
    }

    @MainActor
    private func snapshot(_ model: NativeAppModel, path: String, width: CGFloat = 1_100) async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1_050), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let previews = NativeDashboardDragPreviewRegistry()
        let view = NSHostingView(rootView: DashboardView(model: model, dragPreviews: previews)
            .environment(\.colorScheme, .light).environment(\.locale, Locale(identifier: "zh-Hans")))
        window.contentView = view
        view.setFrameSize(NSSize(width: width, height: 1_050))
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 600_000_000)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw DashboardTestFailure(description: "could not render the dashboard")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        if let module = model.dashboardEditing.draft?.modules.first {
            // Optional visual QA uses the actual laid-out card, just as the
            // drag source does when requesting its on-demand preview.
            previews.prepare(for: module.id)
            guard let snapshot = previews.snapshot(for: module.id) else {
                throw DashboardTestFailure(description: "could not capture the module's drag preview")
            }
            let size = CGSize(width: snapshot.size.width + 32, height: snapshot.size.height + 32)
            let ghostWindow = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [], backing: .buffered, defer: false)
            ghostWindow.isReleasedWhenClosed = false
            ghostWindow.appearance = NSAppearance(named: .aqua)
            ghostWindow.isOpaque = false
            ghostWindow.backgroundColor = .clear
            defer { ghostWindow.close(); previews.clear() }
            let ghost = NSHostingView(rootView: NativeDashboardModuleDragPreview(module: module, previews: previews)
                .environment(\.colorScheme, .light))
            ghostWindow.contentView = ghost
            ghost.setFrameSize(size)
            ghost.layoutSubtreeIfNeeded()
            guard let rendered = ghost.bitmapImageRepForCachingDisplay(in: ghost.bounds) else {
                throw DashboardTestFailure(description: "could not render the translucent drag preview")
            }
            ghost.cacheDisplay(in: ghost.bounds, to: rendered)
            let ghostPath = URL(fileURLWithPath: path).deletingPathExtension().path + "-ghost.png"
            try rendered.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ghostPath))
        }
    }
}

private extension LocalBlogStore {
    func setDashboardRawForTest(_ raw: String) throws {
        try db().execute("UPDATE metadata SET value = ? WHERE key = 'dashboard_v1'", values: [.text(raw)])
    }
    func dashboardRawForTest() throws -> String? {
        try db().text("SELECT value FROM metadata WHERE key = 'dashboard_v1'")
    }
}
