import AppKit
import SwiftUI
@testable import LeonBook

private struct MomentViewportFailure: Error, CustomStringConvertible {
    let description: String
}

private final class MomentViewportDocument: NSView {
    override var isFlipped: Bool { true }
}

final class MomentViewportPerformanceTests {
    @MainActor
    func testHistoricalColumnsShareScrollingAndSkipOffscreenCallbacks() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let document = MomentViewportDocument(frame: NSRect(x: 0, y: 0, width: 400, height: 60_000))
        scroll.documentView = document
        window.contentView = scroll
        var viewportCalls = Array(repeating: 0, count: 100)
        var scrollingChanges = Array(repeating: [Bool](), count: 100)
        var visibilityChanges = Array(repeating: [Bool](), count: 100)
        let columns = (0..<100).map { _ in MomentColumnViewport() }
        let probes = (0..<100).map { index in
            let view = NativeMediaVisibilityView(frame: NSRect(x: 0, y: CGFloat(index * 600), width: 400, height: 600))
            view.onViewportChange = { rect in
                viewportCalls[index] += 1
                columns[index].update(ids: ["day-\(index)"], viewport: rect) { [600] }
            }
            view.onScrollingChange = { value in
                scrollingChanges[index].append(value)
                columns[index].setScrolling(value)
            }
            view.onChange = { visibilityChanges[index].append($0) }
            document.addSubview(view)
            return view
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        let observers = Set(probes.compactMap { $0.scrollObserver.map(ObjectIdentifier.init) })
        guard observers.count == 1, probes.allSatisfy({ $0.scrollObserver != nil }),
              columns.allSatisfy({ $0.layout.totalHeight == 600 }) else {
            throw MomentViewportFailure(description: "historical columns must share one observer and initialize every spacer")
        }
        viewportCalls = Array(repeating: 0, count: 100)
        scrollingChanges = Array(repeating: [], count: 100)
        for y in 1...12 {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(y)))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(nanoseconds: 4_000_000)
        }
        guard viewportCalls[0] > 0, viewportCalls.dropFirst().allSatisfy({ $0 == 0 }),
              scrollingChanges[0] == [true], scrollingChanges.dropFirst().allSatisfy(\.isEmpty) else {
            throw MomentViewportFailure(description: "scrolling within one day performed work on offscreen historical columns")
        }
        try await Task.sleep(nanoseconds: 130_000_000)
        guard scrollingChanges[0] == [true, false], !columns[0].isScrolling else {
            throw MomentViewportFailure(description: "shared scrolling state did not settle exactly once")
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 48_000))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(nanoseconds: 20_000_000)
        guard columns[0].layout.range.isEmpty, !columns[80].layout.range.isEmpty,
              visibilityChanges[0].last == false, visibilityChanges[80].last == true,
              columns[80].isScrolling, viewportCalls[30] == 0 else {
            throw MomentViewportFailure(description: "long scroll must release the departing day, mount the destination, and skip intermediate days")
        }
        columns[30].recordHeight(700, for: "day-30")
        probes[30].setFrameSize(NSSize(width: 320, height: 600))
        try await Task.sleep(nanoseconds: 20_000_000)
        guard columns[30].layout.width == 320, columns[30].layout.totalHeight == 600 else {
            throw MomentViewportFailure(description: "offscreen width changes must invalidate measured heights")
        }
        weak var observer = probes[0].scrollObserver
        for probe in probes {
            probe.stopObserving()
            probe.removeFromSuperview()
        }
        try await Task.sleep(nanoseconds: 140_000_000)
        guard observer == nil else {
            throw MomentViewportFailure(description: "removing the feed must release its shared observer and settling task")
        }
    }

    @MainActor
    func testActualMultiDateFeedUsesOneObserverAndRetainsHistoryHeight() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leon-moment-dates-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false, store: LocalBlogStore(rootURL: root))
        model.isLoading = false
        model.storageReady = true
        let formatter = ISO8601DateFormatter()
        let firstDate = formatter.date(from: "2026-10-30T12:00:00Z")!
        model.moments = (0..<96).map { index in
            let timestamp = formatter.string(from: firstDate.addingTimeInterval(-Double(index / 2) * 86_400))
            return NativeMoment(createdAt: timestamp, id: "day-post-\(index)", images: [],
                                text: "Historical day \(index / 2), post \(index)", textRuns: [], updatedAt: timestamp)
        }
        model.totalMomentCount = model.moments.count
        let suite = "MomentDates.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("doubleColumnWaterfall", forKey: "momentFeedLayout")
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: MomentFeedView(model: model, pageState: NativeMomentFeedPageState()).defaultAppStorage(defaults))
        host.sizingOptions = []
        window.contentView = host
        func settle() async throws {
            for _ in 0..<20 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        try await settle()
        let nativeViews = descendants(host)
        guard model.momentTimeline.count == 48,
              let scroll = nativeViews.compactMap({ $0 as? NSScrollView }).first(where: \.hasVerticalScroller),
              let document = scroll.documentView else {
            throw MomentViewportFailure(description: "multi-date feed fixture failed to mount")
        }
        let columns = nativeViews.compactMap { $0 as? NativeMediaVisibilityView }.filter { $0.onViewportChange != nil }
        guard columns.count == 96,
              Set(columns.compactMap { $0.scrollObserver.map(ObjectIdentifier.init) }).count == 1,
              document.bounds.height > 5_000 else {
            throw MomentViewportFailure(description: "48 real timeline dates must share one observer without dropping historical spacers")
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - scroll.contentSize.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        guard document.bounds.height > 5_000,
              columns.allSatisfy({ $0.scrollObserver === columns[0].scrollObserver }),
              columns[0].scrollObserver?.isScrolling == false else {
            throw MomentViewportFailure(description: "historical navigation lost height, duplicated observers, or failed to settle")
        }
    }
}
