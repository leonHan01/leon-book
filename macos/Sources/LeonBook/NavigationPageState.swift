import SwiftUI

/// Lightweight state that survives page reconstruction without retaining the
/// corresponding SwiftUI view hierarchy, media views, or WebKit instances.
@MainActor
final class NativeNavigationPageStateCache: ObservableObject {
    let moments = NativeMomentFeedPageState()
    let graph = NativeArticleGraphPageState()
}

@MainActor
final class NativeMomentFeedPageState: ObservableObject {
    @Published private(set) var collapsedTimelineDays: Set<String> = []

    func toggleTimelineDay(_ dayID: String) {
        if collapsedTimelineDays.contains(dayID) {
            collapsedTimelineDays.remove(dayID)
        } else {
            collapsedTimelineDays.insert(dayID)
        }
    }
}

@MainActor
final class NativeArticleGraphPageState: ObservableObject {
    @Published var searchText = ""
    @Published var statusFilter = NativeArticleGraphStatusFilter.all
    @Published var includesOrphans = true
    @Published var nodeLimit = 100
    @Published var zoom: Double = 1
    @Published var nodePositions: [String: CGPoint] = [:]

    func zoomIn() {
        zoom = min(1.8, ((zoom + 0.1) * 10).rounded() / 10)
    }

    func zoomOut() {
        zoom = max(0.5, ((zoom - 0.1) * 10).rounded() / 10)
    }

    func resetView() {
        searchText = ""
        statusFilter = .all
        includesOrphans = true
        nodeLimit = 100
        zoom = 1
        nodePositions = [:]
    }
}
