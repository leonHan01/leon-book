import AppKit
import SwiftUI

struct NativeDashboardResizeHandles: View {
    @Environment(\.nativeAppPalette) private var appPalette

    let moduleID: UUID
    let canResizeWidth: Bool
    let onBegin: (NativeDashboardResizeAxis, CGSize) -> Bool
    let onChange: (CGSize) -> Void
    let onEnd: (Bool) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if canResizeWidth {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        handle(.width, size: geometry.size)
                            .frame(width: 12).padding(.vertical, 28)
                            .overlay { Capsule().fill(appPalette.accent.opacity(0.45)).frame(width: 3, height: 28).allowsHitTesting(false) }
                    }
                }
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    handle(.height, size: geometry.size)
                        .frame(height: 12).padding(.horizontal, 28)
                        .overlay { Capsule().fill(appPalette.accent.opacity(0.45)).frame(width: 28, height: 3).allowsHitTesting(false) }
                }
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        handle(canResizeWidth ? .both : .height, size: geometry.size)
                            .frame(width: 28, height: 28)
                            .background(appPalette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                            .overlay {
                                NativeIcon.image(canResizeWidth ? "arrow.up.left.and.arrow.down.right" : "arrow.up.and.down", size: 12).foregroundStyle(appPalette.accent)
                                    .allowsHitTesting(false)
                            }
                            .padding(4)
                    }
                }
            }
        }
    }

    private func handle(_ axis: NativeDashboardResizeAxis, size: CGSize) -> some View {
        let help: LocalizedStringKey = axis == .width ? "拖动调整宽度，按列吸附" : axis == .height ? "拖动调整高度，每格 24 点" : "拖动调整宽高，自动对齐网格；Esc 撤销本次调整"
        let label: LocalizedStringKey = axis == .width ? "调整模块宽度" : axis == .height ? "调整模块高度" : "调整模块宽高"
        return NativeDashboardResizeHandle(moduleID: moduleID, axis: axis, onBegin: { onBegin(axis, size) }, onChange: onChange, onEnd: onEnd)
            .help(Text(help))
            .accessibilityLabel(Text(label))
    }
}

/// Track window coordinates so resizing remains stable even when a wider card
/// wraps onto the next row. Native mouse capture also works outside the handle.
struct NativeDashboardResizeHandle: NSViewRepresentable {
    let moduleID: UUID
    let axis: NativeDashboardResizeAxis
    let onBegin: () -> Bool
    let onChange: (CGSize) -> Void
    let onEnd: (Bool) -> Void

    func makeNSView(context: Context) -> NativeDashboardResizeHandleView { NativeDashboardResizeHandleView() }

    func updateNSView(_ view: NativeDashboardResizeHandleView, context: Context) {
        view.axis = axis
        view.moduleID = moduleID
        view.identifier = NSUserInterfaceItemIdentifier("dashboard-resize-\(moduleID)-\(axis)")
        view.onBegin = onBegin
        view.onChange = onChange
        view.onEnd = onEnd
        view.window?.invalidateCursorRects(for: view)
    }

    static func dismantleNSView(_ view: NativeDashboardResizeHandleView, coordinator: ()) {
        view.stopTracking(notify: false)
    }
}

final class NativeDashboardResizeHandleView: NSView {
    var moduleID: UUID?
    var axis: NativeDashboardResizeAxis = .both
    var onBegin: (() -> Bool)?
    var onChange: ((CGSize) -> Void)?
    var onEnd: ((Bool) -> Void)?
    private var startLocation: NSPoint?
    private weak var previousResponder: NSResponder?

    private static let diagonalCursor: NSCursor = {
        let image = NativeIcon.nsImage("arrow.up.left.and.arrow.down.right", size: 20)
        return NSCursor(image: image, hotSpot: NSPoint(x: 10, y: 10))
    }()

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        let cursor: NSCursor = axis == .width ? .resizeLeftRight : axis == .height ? .resizeUpDown : Self.diagonalCursor
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        guard startLocation == nil, onBegin?() == true else { return }
        startLocation = event.locationInWindow
        previousResponder = window?.firstResponder
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) { update(with: event) }

    override func mouseUp(with event: NSEvent) {
        guard startLocation != nil else { return }
        update(with: event)
        stopTracking(notify: true, cancelled: false)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) }
        else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { stopTracking(notify: true, cancelled: true) }

    func stopTracking(notify: Bool, cancelled: Bool = true) {
        guard startLocation != nil else { return }
        startLocation = nil
        if window?.firstResponder === self { window?.makeFirstResponder(previousResponder) }
        previousResponder = nil
        if notify { onEnd?(cancelled) }
    }

    private func update(with event: NSEvent) {
        guard let startLocation else { return }
        onChange?(CGSize(width: event.locationInWindow.x - startLocation.x,
                         height: startLocation.y - event.locationInWindow.y))
    }
}
