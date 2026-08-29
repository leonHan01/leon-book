import SwiftUI

struct ArticleGraphView: View {
    @ObservedObject var model: NativeAppModel
    @ObservedObject var pageState: NativeArticleGraphPageState

    private var projection: NativeArticleGraphProjection {
        NativeArticleGraphProjector.project(
            model.articleGraph,
            query: NativeArticleGraphQuery(
                searchText: pageState.searchText,
                status: pageState.statusFilter,
                includesOrphans: pageState.includesOrphans,
                nodeLimit: pageState.nodeLimit
            )
        )
    }

    private var graph: NativeArticleGraph { projection.graph }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("文章关系图", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.title2.weight(.semibold))
                        Text("箭头从引用文章指向被引用文章；筛选和节点裁剪在绘制前完成。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(graphSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button {
                        model.bookmarkGraph()
                    } label: {
                        Label(
                            model.isBookmarked(.graph) ? "取消收藏" : "收藏图谱",
                            systemImage: model.isBookmarked(.graph) ? "bookmark.fill" : "bookmark"
                        )
                    }
                }

                HStack(spacing: 12) {
                    TextField("筛选标题、slug、标签或别名", text: $pageState.searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 210, idealWidth: 280, maxWidth: 360)

                    Picker("状态", selection: $pageState.statusFilter) {
                        ForEach(NativeArticleGraphStatusFilter.allCases) { status in
                            Text(status.title).tag(status)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()

                    Toggle("显示孤立节点", isOn: $pageState.includesOrphans)
                        .toggleStyle(.checkbox)
                        .fixedSize()

                    Picker("节点上限", selection: $pageState.nodeLimit) {
                        Text("50 节点").tag(50)
                        Text("100 节点").tag(100)
                        Text("200 节点").tag(200)
                        Text("500 节点").tag(500)
                    }
                    .pickerStyle(.menu)
                    .fixedSize()

                    Spacer(minLength: 8)

                    Button(action: pageState.zoomOut) {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .disabled(pageState.zoom <= 0.5)
                    Slider(value: $pageState.zoom, in: 0.5...1.8, step: 0.1)
                        .frame(width: 110)
                    Text("\(Int((pageState.zoom * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                    Button(action: pageState.zoomIn) {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .disabled(pageState.zoom >= 1.8)
                    Button("重置", action: pageState.resetView)
                        .buttonStyle(.borderless)
                }
                .controlSize(.small)
            }
            .padding(22)

            Divider()

            if model.articleGraph.nodes.isEmpty {
                EmptyState(
                    title: "还没有文章可显示",
                    message: "创建文章并使用 [[文章标题]] 建立引用后，关系图会自动更新。",
                    actionTitle: "新文章"
                ) {
                    model.newArticle()
                }
            } else if graph.nodes.isEmpty {
                EmptyState(
                    title: "没有匹配的图谱节点",
                    message: "请放宽关键词或状态筛选，或重新显示孤立节点。",
                    actionTitle: "重置筛选",
                    action: pageState.resetView
                )
            } else {
                ScrollView([.horizontal, .vertical]) {
                    let canvasSize = ArticleGraphLayout.canvasSize(for: graph.nodes.count)
                    ArticleGraphCanvas(graph: graph, onOpenArticle: model.openArticleLink)
                        .frame(
                            width: canvasSize.width,
                            height: canvasSize.height
                        )
                        .scaleEffect(pageState.zoom, anchor: .topLeading)
                        .frame(
                            width: canvasSize.width * pageState.zoom,
                            height: canvasSize.height * pageState.zoom,
                            alignment: .topLeading
                        )
                        .padding(36)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }

    private var graphSummary: String {
        var value = "\(graph.nodes.count) / \(projection.matchingNodeCount) 篇 · \(graph.edges.count) 条引用"
        if projection.isClipped { value += " · 已裁剪 \(projection.clippedNodeCount) 篇" }
        return value
    }
}

private struct ArticleGraphCanvas: View {
    let graph: NativeArticleGraph
    let onOpenArticle: (String) -> Void

    var body: some View {
        GeometryReader { proxy in
            let positions = ArticleGraphLayout.positions(for: graph.nodes, in: proxy.size)

            ZStack {
                Canvas { context, _ in
                    for edge in graph.edges {
                        guard let source = positions[edge.sourceSlug],
                              let target = positions[edge.targetSlug] else {
                            continue
                        }
                        draw(edge: edge, from: source, to: target, in: &context)
                    }
                }

                ForEach(graph.nodes) { article in
                    if let position = positions[article.slug] {
                        ArticleGraphNode(article: article) {
                            onOpenArticle(article.slug)
                        }
                        .position(position)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("文章关系图，共 \(graph.nodes.count) 个文章节点和 \(graph.edges.count) 条引用连线")
        }
    }

    private func draw(edge: NativeArticleGraphEdge, from source: CGPoint, to target: CGPoint, in context: inout GraphicsContext) {
        let lineColor = Color.secondary.opacity(0.56)
        guard edge.sourceSlug != edge.targetSlug else {
            let loopCenter = CGPoint(
                x: source.x + ArticleGraphLayout.nodeSize.width * 0.33,
                y: source.y - ArticleGraphLayout.nodeSize.height * 0.42
            )
            let loopRect = CGRect(x: loopCenter.x - 17, y: loopCenter.y - 17, width: 34, height: 34)
            context.stroke(Path(ellipseIn: loopRect), with: .color(lineColor), lineWidth: 1.3)
            return
        }

        let delta = CGPoint(x: target.x - source.x, y: target.y - source.y)
        let distance = max(1, hypot(delta.x, delta.y))
        let direction = CGPoint(x: delta.x / distance, y: delta.y / distance)
        let nodeOffset = max(
            abs(direction.x) * ArticleGraphLayout.nodeSize.width / 2,
            abs(direction.y) * ArticleGraphLayout.nodeSize.height / 2
        ) + 6
        let start = CGPoint(x: source.x + direction.x * nodeOffset, y: source.y + direction.y * nodeOffset)
        let end = CGPoint(x: target.x - direction.x * nodeOffset, y: target.y - direction.y * nodeOffset)

        var line = Path()
        line.move(to: start)
        line.addLine(to: end)
        context.stroke(line, with: .color(lineColor), lineWidth: 1.3)

        let arrowLength: CGFloat = 8
        let arrowHalfWidth: CGFloat = 4
        let arrowBase = CGPoint(x: end.x - direction.x * arrowLength, y: end.y - direction.y * arrowLength)
        let perpendicular = CGPoint(x: -direction.y, y: direction.x)
        var arrow = Path()
        arrow.move(to: end)
        arrow.addLine(to: CGPoint(
            x: arrowBase.x + perpendicular.x * arrowHalfWidth,
            y: arrowBase.y + perpendicular.y * arrowHalfWidth
        ))
        arrow.addLine(to: CGPoint(
            x: arrowBase.x - perpendicular.x * arrowHalfWidth,
            y: arrowBase.y - perpendicular.y * arrowHalfWidth
        ))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(lineColor))
    }
}

private struct ArticleGraphNode: View {
    let article: NativeArticleSummary
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 4) {
                Text(article.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(article.status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(width: ArticleGraphLayout.nodeSize.width, height: ArticleGraphLayout.nodeSize.height, alignment: .leading)
            .background(nodeBackground, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(article.status == .published ? Color.accentColor.opacity(0.38) : Color.orange.opacity(0.48))
            }
        }
        .buttonStyle(.plain)
        .help("打开文章：\(article.title)")
        .accessibilityLabel("打开文章：\(article.title)，\(article.status.label)")
    }

    private var nodeBackground: Color {
        article.status == .published ? Color.accentColor.opacity(0.12) : Color.orange.opacity(0.12)
    }
}

private enum ArticleGraphLayout {
    static let nodeSize = CGSize(width: 148, height: 66)
    private static let initialRadius: CGFloat = 130
    private static let ringSpacing: CGFloat = 142
    private static let nodeSpacing: CGFloat = 158

    static func canvasSize(for nodeCount: Int) -> CGSize {
        guard nodeCount > 1 else { return CGSize(width: 560, height: 460) }
        let radius = outerRadius(for: nodeCount)
        let side = max(640, radius * 2 + nodeSize.width + 120)
        return CGSize(width: side, height: side)
    }

    static func positions(for nodes: [NativeArticleSummary], in size: CGSize) -> [String: CGPoint] {
        guard nodes.count > 1 else {
            guard let article = nodes.first else { return [:] }
            return [article.slug: CGPoint(x: size.width / 2, y: size.height / 2)]
        }

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var positions: [String: CGPoint] = [:]
        var nodeIndex = 0
        var radius = initialRadius
        var ringIndex = 0

        while nodeIndex < nodes.count {
            let capacity = ringCapacity(at: radius)
            let count = min(capacity, nodes.count - nodeIndex)
            let phase = -Double.pi / 2 + (ringIndex.isMultiple(of: 2) ? 0 : Double.pi / Double(count))

            for offset in 0..<count {
                let angle = phase + Double(offset) * 2 * Double.pi / Double(count)
                let article = nodes[nodeIndex + offset]
                positions[article.slug] = CGPoint(
                    x: center.x + radius * CGFloat(cos(angle)),
                    y: center.y + radius * CGFloat(sin(angle))
                )
            }

            nodeIndex += count
            radius += ringSpacing
            ringIndex += 1
        }

        return positions
    }

    private static func outerRadius(for nodeCount: Int) -> CGFloat {
        var remaining = nodeCount
        var radius = initialRadius
        while remaining > 0 {
            let capacity = ringCapacity(at: radius)
            remaining -= capacity
            if remaining <= 0 { return radius }
            radius += ringSpacing
        }
        return radius
    }

    private static func ringCapacity(at radius: CGFloat) -> Int {
        max(6, Int((2 * Double.pi * Double(radius)) / Double(nodeSpacing)))
    }
}
