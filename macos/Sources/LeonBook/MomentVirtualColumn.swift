import SwiftUI

private struct MomentMediaScrollingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var momentMediaIsScrolling: Bool {
        get { self[MomentMediaScrollingKey.self] }
        set { self[MomentMediaScrollingKey.self] = newValue }
    }
}

/// One spacer and viewport observer per column, not one per historical post.
/// Only the visible slice participates in SwiftUI layout and media loading.
struct MomentVirtualColumn<Content: View>: View {
    let moments: [NativeMoment]
    @ViewBuilder let content: (NativeMoment, CGFloat) -> Content
    @StateObject private var viewport = MomentColumnViewport()

    var body: some View {
        let ids = moments.map(\.id)
        let layout = viewport.layout
        let visible = moments[min(layout.range.lowerBound, moments.count)..<min(layout.range.upperBound, moments.count)]
        Color.clear
            .frame(height: layout.totalHeight)
            .overlay(alignment: .topLeading) {
                VStack(spacing: MomentColumnViewport.spacing) {
                    ForEach(visible) { moment in
                        content(moment, layout.width)
                            .environment(\.momentMediaIsScrolling, viewport.isScrolling)
                            .fixedSize(horizontal: false, vertical: true)
                            .background(NativeMediaSize { size in viewport.recordHeight(size.height, for: moment.id) })
                    }
                }
                .padding(.top, layout.topOffset)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(NativeMediaVisibility(onViewportChange: { rect in
                viewport.update(ids: ids, viewport: rect) {
                    moments.map { Self.estimatedHeight($0, width: rect.width) }
                }
            }, onScrollChange: { viewport.beginScrolling() }) { _ in })
    }

    private static func estimatedHeight(_ moment: NativeMoment, width: CGFloat) -> CGFloat {
        let contentWidth = max(1, min(width, 860) - 36)
        let imageCount = moment.imageAttachments.count
        let imageHeight = MomentMediaSizing.imageHeight(count: imageCount, width: contentWidth) + (imageCount > 0 ? 15 : 0)
        let videoHeight = MomentMediaSizing.videoHeight(count: moment.videoAttachments.count, width: contentWidth)
        let textLines = ceil(CGFloat(moment.text.count) / max(1, contentWidth / 14))
        return 110 + textLines * 21 + imageHeight + videoHeight
            + (moment.tags.isEmpty ? 0 : 42) + CGFloat(moment.audioAttachments.count) * 100
    }
}

@MainActor
final class MomentColumnViewport: ObservableObject {
    static let spacing: CGFloat = 16

    struct Layout: Equatable {
        var range = 0..<0
        var topOffset: CGFloat = 0
        // A nonzero initial canvas lets the native observer report its width.
        var totalHeight: CGFloat = 1
        var width: CGFloat = 0
    }

    @Published private(set) var layout = Layout()
    @Published private(set) var isScrolling = false
    private var settleTask: Task<Void, Never>?
    private var ids: [String] = []
    private var estimates: [CGFloat] = []
    private var measured: [String: CGFloat] = [:]
    private var offsets: [CGFloat] = [0]
    private var viewport = CGRect.zero
    private var measuredWidth: CGFloat = 0

    func beginScrolling() {
        if !isScrolling { isScrolling = true }
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.isScrolling = false
        }
    }

    deinit { settleTask?.cancel() }

    func update(ids: [String], viewport: CGRect, estimates: () -> [CGFloat]) {
        guard viewport.width > 0 else { return }
        let widthChanged = abs(viewport.width - measuredWidth) > 0.5
        if widthChanged || ids != self.ids {
            if widthChanged {
                measured.removeAll()
                measuredWidth = viewport.width
            }
            else { measured = measured.filter { ids.contains($0.key) } }
            self.ids = ids
            self.estimates = estimates()
            rebuildOffsets()
        }
        self.viewport = viewport
        publishLayout()
    }

    func recordHeight(_ height: CGFloat, for id: String) {
        guard height > 0, ids.contains(id), abs(height - (measured[id] ?? 0)) > 0.5 else { return }
        measured[id] = height
        rebuildOffsets()
        publishLayout()
    }

    private func rebuildOffsets() {
        offsets = [0]
        for (index, id) in ids.enumerated() {
            offsets.append(offsets.last! + (measured[id] ?? estimates[index]) + Self.spacing)
        }
    }

    private func publishLayout() {
        let total = max(1, (offsets.last ?? 0) - Self.spacing)
        let range: Range<Int>
        if viewport.maxY <= 0 || viewport.minY >= total || ids.isEmpty {
            range = 0..<0
        } else {
            let first = max(0, upperBound(viewport.minY) - 1)
            let end = min(ids.count, upperBound(viewport.maxY))
            range = min(first, end)..<end
        }
        let next = Layout(range: range, topOffset: offsets[range.lowerBound], totalHeight: total, width: viewport.width)
        if next != layout { layout = next }
    }

    private func upperBound(_ y: CGFloat) -> Int {
        var lower = 0, upper = offsets.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if offsets[middle] <= y { lower = middle + 1 }
            else { upper = middle }
        }
        return lower
    }
}

enum MomentMediaSizing {
    static func imageHeight(count: Int, width: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let columns = count == 1 ? 1 : count == 2 ? 2 : 3
        let tile = min(count == 1 ? 320 : count == 2 ? 176 : 128,
                       max(1, (width - CGFloat(columns - 1) * 6) / CGFloat(columns)))
        let rows = CGFloat((count + columns - 1) / columns)
        return rows * tile * (count == 1 ? 0.75 : 1) + max(0, rows - 1) * 6
    }

    static func videoHeight(count: Int, width: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * (min(width, 840) * 9 / 16 + 22) + CGFloat(count - 1) * 10
    }
}
