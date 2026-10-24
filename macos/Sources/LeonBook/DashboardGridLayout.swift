import SwiftUI

/// Both layout and pointer gestures use the same grid, including its gutters.
struct NativeDashboardGridMetrics {
    static let columns = 12
    static let spacing: CGFloat = 24
    static let rowHeight: CGFloat = 24
    static let columnRange = 3...12
    static let heightRange = 6...80
    static let minimumCardWidth: CGFloat = 240

    let width: CGFloat

    init(width: CGFloat) { self.width = width.isFinite ? max(1, width) : 1_080 }

    var columnStride: CGFloat { (width + Self.spacing) / CGFloat(Self.columns) }
    var minimumColumns: Int {
        if width < Self.minimumCardWidth * 2 + Self.spacing { return Self.columns }
        return min(Self.columns, max(Self.columnRange.lowerBound,
            Int(ceil((Self.minimumCardWidth + Self.spacing) / columnStride))))
    }

    func columns(for preferred: Int) -> Int { min(Self.columns, max(minimumColumns, preferred)) }
    func cardWidth(columns: Int) -> CGFloat { CGFloat(self.columns(for: columns)) * columnStride - Self.spacing }
    func cardHeight(natural: CGFloat, rows: Int?) -> CGFloat {
        if let rows { return CGFloat(min(Self.heightRange.upperBound, max(Self.heightRange.lowerBound, rows))) * Self.rowHeight }
        let natural = natural.isFinite ? natural : 0
        return max(CGFloat(Self.heightRange.lowerBound) * Self.rowHeight, ceil(natural / Self.rowHeight) * Self.rowHeight)
    }

    struct Item {
        let columns: Int
        let height: CGFloat
    }

    func frames(for items: [Item]) -> [CGRect] {
        var column = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        return items.map { item in
            let span = columns(for: item.columns)
            if column + span > Self.columns {
                column = 0
                y += rowHeight + Self.spacing
                rowHeight = 0
            }
            let frame = CGRect(x: CGFloat(column) * columnStride, y: y,
                               width: cardWidth(columns: span), height: item.height)
            column += span
            rowHeight = max(rowHeight, item.height)
            return frame
        }
    }
}

enum NativeDashboardResizeAxis {
    case width, height, both
    var changesWidth: Bool { self != .height }
    var changesHeight: Bool { self != .width }
}

struct NativeDashboardResizeSession {
    let original: NativeDashboardModule
    let axis: NativeDashboardResizeAxis
    let size: CGSize
    let metrics: NativeDashboardGridMetrics

    func module(at translation: CGSize) -> NativeDashboardModule {
        var module = original
        if axis.changesWidth, metrics.minimumColumns < NativeDashboardGridMetrics.columns,
           translation.width.isFinite {
            let start = metrics.columns(for: original.preferredColumnSpan)
            let delta = (translation.width / metrics.columnStride).rounded()
            let snapped = min(CGFloat(NativeDashboardGridMetrics.columns), max(CGFloat(metrics.minimumColumns), CGFloat(start) + delta))
            if Int(snapped) != start { module.setColumnSpan(Int(snapped)) }
        }
        if axis.changesHeight, translation.height.isFinite {
            let unit = NativeDashboardGridMetrics.rowHeight
            let range = NativeDashboardGridMetrics.heightRange
            let start = (size.height / unit).rounded()
            let snapped = min(CGFloat(range.upperBound), max(CGFloat(range.lowerBound), start + (translation.height / unit).rounded()))
            if snapped != start { module.heightRows = Int(snapped) }
        }
        return module
    }
}

struct NativeDashboardColumnSpanKey: LayoutValueKey { static let defaultValue = 12 }
struct NativeDashboardHeightRowsKey: LayoutValueKey { static let defaultValue: Int? = nil }

/// A single Layout keeps each module's identity when it wraps into another row.
/// Nested row ForEach views would recreate players and interrupt resize gestures.
struct NativeDashboardGridLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 1_080
        let frames = frames(width: width, subviews: subviews)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let metrics = NativeDashboardGridMetrics(width: width)
        return metrics.frames(for: subviews.map { subview in
            let columns = subview[NativeDashboardColumnSpanKey.self]
            let rows = subview[NativeDashboardHeightRowsKey.self]
            let natural = rows == nil ? subview.sizeThatFits(
                ProposedViewSize(width: metrics.cardWidth(columns: columns), height: nil)).height : 0
            return .init(columns: columns, height: metrics.cardHeight(natural: natural, rows: rows))
        })
    }
}

struct NativeDashboardGridGuides: View {
    @Environment(\.nativeAppPalette) private var appPalette

    var body: some View {
        Canvas { context, size in
            let metrics = NativeDashboardGridMetrics(width: size.width)
            var path = Path()
            for column in 0..<NativeDashboardGridMetrics.columns {
                for x in [CGFloat(column) * metrics.columnStride,
                          CGFloat(column + 1) * metrics.columnStride - NativeDashboardGridMetrics.spacing] {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
            }
            for y in stride(from: CGFloat(0), through: size.height, by: NativeDashboardGridMetrics.rowHeight) {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(appPalette.accent.opacity(0.18)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
