import AppKit
import SwiftUI

/// Observe the native clip view without publishing a scroll offset into SwiftUI.
/// Only crossing the prefetch boundary changes a media cell's state.
struct NativeMediaVisibility: NSViewRepresentable {
    var onSizeChange: ((CGSize) -> Void)? = nil
    var onViewportChange: ((CGRect) -> Void)? = nil
    var onScrollingChange: ((Bool) -> Void)? = nil
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NativeMediaVisibilityView {
        let view = NativeMediaVisibilityView()
        view.onChange = onChange
        view.onSizeChange = onSizeChange
        view.onViewportChange = onViewportChange
        view.onScrollingChange = onScrollingChange
        return view
    }

    func updateNSView(_ view: NativeMediaVisibilityView, context: Context) {
        view.onChange = onChange
        view.onSizeChange = onSizeChange
        view.onViewportChange = onViewportChange
        view.onScrollingChange = onScrollingChange
        view.scheduleCheck()
    }

    static func dismantleNSView(_ view: NativeMediaVisibilityView, coordinator: ()) {
        view.onScrollingChange = nil
        view.stopObserving()
        view.onChange = nil
        view.onSizeChange = nil
        view.onViewportChange = nil
    }
}

final class NativeMediaVisibilityView: NSView {
    var onChange: ((Bool) -> Void)?
    var onSizeChange: ((CGSize) -> Void)?
    var onViewportChange: ((CGRect) -> Void)?
    var onScrollingChange: ((Bool) -> Void)?
    private var lastSize: CGSize?
    private(set) var scrollObserver: NativeMediaScrollObserver?
    private var checkScheduled = false
    private var lastVisibility: Bool?
    private var lastScrolling = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopObserving() }
        scheduleCheck()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleCheck()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        scheduleCheck()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleCheck()
    }

    func scheduleCheck() {
        guard !checkScheduled else { return }
        checkScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.checkScheduled = false
            self.checkVisibility(forceViewport: true)
        }
    }

    fileprivate func checkVisibility(forceViewport: Bool = false) {
        guard window != nil, onChange != nil || onSizeChange != nil || onViewportChange != nil else {
            stopObserving()
            if lastVisibility != false {
                lastVisibility = false
                onChange?(false)
            }
            return
        }
        let sizeChanged = bounds.size != lastSize
        if bounds.width > 0, bounds.height > 0, sizeChanged {
            lastSize = bounds.size
            onSizeChange?(bounds.size)
        }
        let scroll = enclosingScrollView
        if scrollObserver?.scrollView !== scroll {
            stopObserving()
            if let scroll {
                scrollObserver = NativeMediaScrollObserver.shared(for: scroll)
                scrollObserver?.add(self)
            }
        }
        let visible: Bool
        if window == nil || bounds.isEmpty {
            visible = false
            updateScrolling(false)
        } else if let scroll, let document = scroll.documentView {
            let prefetchRect = scroll.documentVisibleRect.insetBy(dx: 0, dy: -240)
            let frame = convert(bounds, to: document)
            visible = frame.intersects(prefetchRect)
            updateScrolling(visible && scrollObserver?.isScrolling == true)
            // Initialize offscreen spacers and respond to content/width changes,
            // but a wheel event only updates intersecting or departing columns.
            if forceViewport || sizeChanged || visible || lastVisibility != false {
                onViewportChange?(CGRect(x: 0,
                    y: document.isFlipped ? prefetchRect.minY - frame.minY : frame.maxY - prefetchRect.maxY,
                    width: bounds.width, height: prefetchRect.height))
            }
        } else {
            visible = true
            updateScrolling(false)
            onViewportChange?(bounds)
        }
        guard lastVisibility != visible else { return }
        lastVisibility = visible
        onChange?(visible)
    }

    func stopObserving() {
        scrollObserver?.remove(self)
        scrollObserver = nil
        guard lastScrolling else { return }
        lastScrolling = false
        // Detachment can occur during a SwiftUI update. Publish after that pass,
        // unless a reattachment has already resumed scrolling.
        let callback = onScrollingChange
        DispatchQueue.main.async { [weak self] in
            guard self?.lastScrolling != true else { return }
            callback?(false)
        }
    }

    private func updateScrolling(_ scrolling: Bool) {
        guard scrolling != lastScrolling else { return }
        lastScrolling = scrolling
        onScrollingChange?(scrolling)
    }
}

/// All date columns and media cells in a feed share one native subscription and
/// one settling timer. Weak members let offscreen SwiftUI cells disappear freely.
@MainActor
final class NativeMediaScrollObserver {
    private static let observers = NSMapTable<NSScrollView, NativeMediaScrollObserver>.weakToWeakObjects()
    private(set) weak var scrollView: NSScrollView?
    private let members = NSHashTable<NativeMediaVisibilityView>.weakObjects()
    private var boundsObserver: NSObjectProtocol?
    private var checkScheduled = false
    private var settleTask: Task<Void, Never>?
    private var lastScrollY: CGFloat
    private var lastMovement = 0.0
    private(set) var isScrolling = false

    static func shared(for scroll: NSScrollView) -> NativeMediaScrollObserver {
        if let observer = observers.object(forKey: scroll) { return observer }
        let observer = NativeMediaScrollObserver(scroll: scroll)
        observers.setObject(observer, forKey: scroll)
        return observer
    }

    private init(scroll: NSScrollView) {
        scrollView = scroll
        lastScrollY = scroll.contentView.bounds.origin.y
        scroll.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleCheck() }
        }
    }

    fileprivate func add(_ view: NativeMediaVisibilityView) { members.add(view) }
    fileprivate func remove(_ view: NativeMediaVisibilityView) { members.remove(view) }

    private func scheduleCheck() {
        guard !checkScheduled else { return }
        checkScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.checkScheduled = false
            self.checkMembers()
        }
    }

    private func checkMembers() {
        guard let scrollView else { return }
        let scrollY = scrollView.contentView.bounds.origin.y
        if scrollY != lastScrollY {
            lastScrollY = scrollY
            lastMovement = ProcessInfo.processInfo.systemUptime
            isScrolling = true
            scheduleSettle()
        }
        for view in members.allObjects { view.checkVisibility() }
    }

    private func scheduleSettle() {
        guard settleTask == nil else { return }
        settleTask = Task { [weak self] in
            var remaining = 0.1
            while true {
                do { try await Task.sleep(nanoseconds: UInt64(max(0, remaining) * 1_000_000_000)) }
                catch { return }
                guard let self, !Task.isCancelled else { return }
                remaining = 0.1 - (ProcessInfo.processInfo.systemUptime - self.lastMovement)
                if remaining <= 0 {
                    self.settleTask = nil
                    self.isScrolling = false
                    self.scheduleCheck()
                    return
                }
            }
        }
    }

    deinit {
        settleTask?.cancel()
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }
}
