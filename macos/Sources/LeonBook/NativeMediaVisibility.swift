import AppKit
import SwiftUI

/// Observe the native clip view without publishing a scroll offset into SwiftUI.
/// Only crossing the prefetch boundary changes a media cell's state.
struct NativeMediaVisibility: NSViewRepresentable {
    var onSizeChange: ((CGSize) -> Void)? = nil
    var onViewportChange: ((CGRect) -> Void)? = nil
    var onScrollChange: (() -> Void)? = nil
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NativeMediaVisibilityView {
        let view = NativeMediaVisibilityView()
        view.onChange = onChange
        view.onSizeChange = onSizeChange
        view.onViewportChange = onViewportChange
        view.onScrollChange = onScrollChange
        return view
    }

    func updateNSView(_ view: NativeMediaVisibilityView, context: Context) {
        view.onChange = onChange
        view.onSizeChange = onSizeChange
        view.onViewportChange = onViewportChange
        view.onScrollChange = onScrollChange
        view.scheduleCheck()
    }

    static func dismantleNSView(_ view: NativeMediaVisibilityView, coordinator: ()) {
        view.stopObserving()
        view.onChange = nil
        view.onSizeChange = nil
        view.onViewportChange = nil
        view.onScrollChange = nil
    }
}

final class NativeMediaVisibilityView: NSView {
    var onChange: ((Bool) -> Void)?
    var onSizeChange: ((CGSize) -> Void)?
    var onViewportChange: ((CGRect) -> Void)?
    var onScrollChange: (() -> Void)?
    private var lastScrollY: CGFloat?
    private var lastSize: CGSize?
    private weak var observedScrollView: NSScrollView?
    private var boundsObserver: NSObjectProtocol?
    private var checkScheduled = false
    private var lastVisibility: Bool?

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
            self.checkVisibility()
        }
    }

    private func checkVisibility() {
        guard window != nil, onChange != nil || onSizeChange != nil || onViewportChange != nil else {
            stopObserving()
            if lastVisibility != false {
                lastVisibility = false
                onChange?(false)
            }
            return
        }
        if bounds.width > 0, bounds.height > 0, bounds.size != lastSize {
            lastSize = bounds.size
            onSizeChange?(bounds.size)
        }
        let scroll = enclosingScrollView
        if observedScrollView !== scroll {
            stopObserving()
            observedScrollView = scroll
            if let clip = scroll?.contentView {
                clip.postsBoundsChangedNotifications = true
                boundsObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleCheck() }
                }
            }
        }
        let visible: Bool
        if window == nil || bounds.isEmpty {
            visible = false
        } else if let scroll, let document = scroll.documentView {
            let scrollY = scroll.contentView.bounds.origin.y
            if let lastScrollY, lastScrollY != scrollY { onScrollChange?() }
            lastScrollY = scrollY
            let prefetchRect = scroll.documentVisibleRect.insetBy(dx: 0, dy: -240)
            let frame = convert(bounds, to: document)
            visible = frame.intersects(prefetchRect)
            onViewportChange?(CGRect(x: 0,
                y: document.isFlipped ? prefetchRect.minY - frame.minY : frame.maxY - prefetchRect.maxY,
                width: bounds.width, height: prefetchRect.height))
        } else {
            visible = true
            onViewportChange?(bounds)
        }
        guard lastVisibility != visible else { return }
        lastVisibility = visible
        onChange?(visible)
    }

    func stopObserving() {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        boundsObserver = nil
        observedScrollView = nil
        lastScrollY = nil
    }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }
}
