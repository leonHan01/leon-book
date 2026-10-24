import AppKit
import SwiftUI

struct NativeDashboardDragSnapshot {
    let image: NSImage
    let size: CGSize
}

/// Capture the already-rendered card only when a drag starts. In particular,
/// the preview must not instantiate another video player or article reader.
@MainActor
final class NativeDashboardDragPreviewRegistry: ObservableObject {
    private final class Anchor {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    private var anchors: [UUID: Anchor] = [:]
    @Published private var activeSnapshot: (moduleID: UUID, snapshot: NativeDashboardDragSnapshot)?

    func prepare(for moduleID: UUID) {
        activeSnapshot = capture(moduleID).map { (moduleID, $0) }
    }

    func clear() { activeSnapshot = nil }

    func register(_ view: NSView, for moduleID: UUID) {
        anchors[moduleID] = Anchor(view)
    }

    func unregister(_ view: NSView, for moduleID: UUID) {
        if anchors[moduleID]?.view === view { anchors.removeValue(forKey: moduleID) }
    }

    func snapshot(for moduleID: UUID) -> NativeDashboardDragSnapshot? {
        activeSnapshot?.moduleID == moduleID ? activeSnapshot?.snapshot : nil
    }

    private func capture(_ moduleID: UUID) -> NativeDashboardDragSnapshot? {
        guard let anchor = anchors[moduleID]?.view, let contentView = anchor.window?.contentView,
              anchor.bounds.width > 1, anchor.bounds.height > 1 else { return nil }
        var rect = anchor.convert(anchor.bounds, to: contentView)
        // A long article should not create an enormous bitmap or cover the
        // destination. Keep the card's heading and the first part of its body.
        let height = min(rect.height, 320)
        if !contentView.isFlipped { rect.origin.y = rect.maxY - height }
        rect.size.height = height
        rect = rect.intersection(contentView.bounds)
        guard !rect.isEmpty, let bitmap = contentView.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        contentView.cacheDisplay(in: rect, to: bitmap)
        let image = NSImage(size: rect.size)
        image.addRepresentation(bitmap)
        let scale = min(1, 480 / rect.width)
        return NativeDashboardDragSnapshot(image: image, size: CGSize(width: rect.width * scale, height: rect.height * scale))
    }
}

struct NativeDashboardDragPreviewAnchor: NSViewRepresentable {
    let moduleID: UUID
    let registry: NativeDashboardDragPreviewRegistry

    final class View: NSView {
        var moduleID: UUID?
        weak var registry: NativeDashboardDragPreviewRegistry?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> View { View() }

    func updateNSView(_ view: View, context: Context) {
        if let previousID = view.moduleID, previousID != moduleID {
            view.registry?.unregister(view, for: previousID)
        }
        view.moduleID = moduleID
        view.registry = registry
        registry.register(view, for: moduleID)
    }

    static func dismantleNSView(_ view: View, coordinator: ()) {
        if let id = view.moduleID { view.registry?.unregister(view, for: id) }
    }
}

struct NativeDashboardModuleDragPreview: View {
    @Environment(\.nativeAppPalette) private var appPalette

    let module: NativeDashboardModule
    @ObservedObject var previews: NativeDashboardDragPreviewRegistry

    var body: some View {
        Group {
            if let snapshot = previews.snapshot(for: module.id) {
                Image(nsImage: snapshot.image).resizable()
                    .frame(width: snapshot.size.width, height: snapshot.size.height)
            } else {
                // Still provide a visible card if the source has just left the
                // window while SwiftUI is requesting its drag image.
                VStack(alignment: .leading, spacing: 18) {
                    Label(module.displayTitle, nativeIcon: module.kind.symbol).font(.headline)
                    RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.16)).frame(height: 8)
                    RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.1)).frame(width: 160, height: 8)
                }
                .padding(20).frame(width: 320, alignment: .leading)
                .background(appPalette.surface)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(appPalette.accent.opacity(0.5))
        }
        .opacity(0.76)
        .shadow(color: .black.opacity(0.22), radius: 12, x: 0, y: 7)
        .padding(16)
        .allowsHitTesting(false)
    }
}
