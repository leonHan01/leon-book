import AppKit
import SwiftUI

/// Report size changes locally. Unlike a GeometryReader preference, scrolling
/// the parent does not rebuild geometry/preferences through the entire feed.
struct NativeMediaSize: NSViewRepresentable {
    let onChange: (CGSize) -> Void

    func makeNSView(context: Context) -> NativeMediaSizeView {
        let view = NativeMediaSizeView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: NativeMediaSizeView, context: Context) {
        view.onChange = onChange
        view.scheduleCheck()
    }

    static func dismantleNSView(_ view: NativeMediaSizeView, coordinator: ()) {
        view.onChange = nil
    }
}

final class NativeMediaSizeView: NSView {
    var onChange: ((CGSize) -> Void)?
    private var lastSize: CGSize?
    private var scheduled = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleCheck()
    }

    func scheduleCheck() {
        guard !scheduled, bounds.size != lastSize else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            let size = self.bounds.size
            guard size.width > 0, size.height > 0, size != self.lastSize else { return }
            self.lastSize = size
            self.onChange?(size)
        }
    }
}
