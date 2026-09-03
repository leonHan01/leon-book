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

    private var highlightedPath: NativeArticleGraphPath? {
        guard let sourceSlug = pageState.pathStartSlug,
              let destinationSlug = pageState.pathDestinationSlug else {
            return nil
        }
        return NativeArticleGraphPathFinder.shortestPath(
            in: graph,
            from: sourceSlug,
            to: destinationSlug
        )
    }

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
                    graphSummary
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button {
                        model.bookmarkGraph()
                    } label: {
                        Label(
                            LocalizedStringKey(model.isBookmarked(.graph) ? "取消收藏" : "收藏图谱"),
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
                            Text(LocalizedStringKey(status.title)).tag(status)
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

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Label("最短路径", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.callout.weight(.medium))

                        TextField("起始节点（标题、slug 或别名）", text: pathStartText)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 180, idealWidth: 230, maxWidth: 280)

                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)

                        TextField("目的节点（标题、slug 或别名）", text: pathDestinationText)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 180, idealWidth: 230, maxWidth: 280)

                        Button("查找路径", action: findShortestPath)
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                pageState.pathStartText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || pageState.pathDestinationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            )
                            .keyboardShortcut(.return, modifiers: [])

                        if pageState.pathFeedback != nil {
                            Button("清除", action: clearPathSearch)
                                .buttonStyle(.borderless)
                        }

                        Spacer(minLength: 8)
                    }
                    .controlSize(.small)

                    if let feedback = pageState.pathFeedback {
                        Text(feedback)
                            .font(.caption)
                            .foregroundStyle(highlightedPath == nil ? Color.orange : Color.secondary)
                            .lineLimit(2)
                            .accessibilityLabel(feedback)
                    } else {
                        Text("在当前可见图谱中沿箭头方向查找，支持唯一的部分匹配。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
                    ArticleGraphCanvas(
                        graph: graph,
                        manualPositions: $pageState.nodePositions,
                        highlightedPath: highlightedPath,
                        onOpenArticle: model.openArticleLink
                    )
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
        .onChange(of: graph) { _ in
            pageState.clearPathResult()
        }
    }

    private var graphSummary: Text {
        var value = Text("\(graph.nodes.count) / \(projection.matchingNodeCount) 篇 · \(graph.edges.count) 条引用")
        if projection.isClipped {
            value = value + Text(" · 已裁剪 \(projection.clippedNodeCount) 篇")
        }
        return value
    }

    private var pathStartText: Binding<String> {
        Binding(
            get: { pageState.pathStartText },
            set: {
                pageState.pathStartText = $0
                pageState.clearPathResult()
            }
        )
    }

    private var pathDestinationText: Binding<String> {
        Binding(
            get: { pageState.pathDestinationText },
            set: {
                pageState.pathDestinationText = $0
                pageState.clearPathResult()
            }
        )
    }

    private func findShortestPath() {
        let sourceMatches = matchingArticles(for: pageState.pathStartText)
        guard let source = uniqueArticle(
            from: sourceMatches,
            role: "起始",
            query: pageState.pathStartText
        ) else { return }

        let destinationMatches = matchingArticles(for: pageState.pathDestinationText)
        guard let destination = uniqueArticle(
            from: destinationMatches,
            role: "目的",
            query: pageState.pathDestinationText
        ) else { return }

        guard let path = NativeArticleGraphPathFinder.shortestPath(
            in: graph,
            from: source.slug,
            to: destination.slug
        ) else {
            pageState.showPathError("当前可见图谱中不存在从“\(source.title)”到“\(destination.title)”的有向路径。")
            return
        }

        let route = compactPathDescription(path.nodes.map(\.title))
        pageState.showPath(
            from: source.slug,
            to: destination.slug,
            feedback: "最短路径：\(route) · \(path.hopCount) 跳"
        )
    }

    private func matchingArticles(for query: String) -> [NativeArticleSummary] {
        let normalizedQuery = normalizedNodeQuery(query)
        guard !normalizedQuery.isEmpty else { return [] }

        if let slugMatch = graph.nodes.first(where: {
            normalizedNodeQuery($0.slug) == normalizedQuery
        }) {
            return [slugMatch]
        }

        let exactNameMatches = graph.nodes.filter { article in
            normalizedNodeQuery(article.title) == normalizedQuery
                || article.aliases.contains { normalizedNodeQuery($0) == normalizedQuery }
        }
        if !exactNameMatches.isEmpty { return exactNameMatches }

        return graph.nodes.filter { article in
            ([article.title, article.slug] + article.aliases)
                .map(normalizedNodeQuery)
                .contains { $0.contains(normalizedQuery) }
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func uniqueArticle(
        from matches: [NativeArticleSummary],
        role: String,
        query: String
    ) -> NativeArticleSummary? {
        guard !matches.isEmpty else {
            pageState.showPathError("当前可见图谱中找不到\(role)节点“\(query.trimmingCharacters(in: .whitespacesAndNewlines))”。")
            return nil
        }
        guard matches.count == 1 else {
            let examples = matches.prefix(3).map { "\($0.title)（\($0.slug)）" }.joined(separator: "、")
            pageState.showPathError("\(role)节点匹配到多个结果：\(examples)。请改用准确的 slug。")
            return nil
        }
        return matches[0]
    }

    private func normalizedNodeQuery(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased(with: .current)
    }

    private func compactPathDescription(_ titles: [String]) -> String {
        guard titles.count > 7 else { return titles.joined(separator: " → ") }
        return (Array(titles.prefix(4)) + ["…"] + Array(titles.suffix(2))).joined(separator: " → ")
    }

    private func clearPathSearch() {
        pageState.pathStartText = ""
        pageState.pathDestinationText = ""
        pageState.clearPathResult()
    }
}

private struct ArticleGraphCanvas: View {
    let graph: NativeArticleGraph
    @Binding var manualPositions: [String: CGPoint]
    let highlightedPath: NativeArticleGraphPath?
    let onOpenArticle: (String) -> Void
    @State private var dragOrigins: [String: CGPoint] = [:]
    @State private var suppressOpenSlugs: Set<String> = []

    private static let coordinateSpaceName = "article-graph-canvas"

    var body: some View {
        GeometryReader { proxy in
            let positions = ArticleGraphLayout.resolvedPositions(
                for: graph.nodes,
                in: proxy.size,
                manualPositions: manualPositions
            )
            let highlightedEdges = Set(highlightedPath?.edges ?? [])
            let highlightedNodeSlugs = Set(highlightedPath?.nodes.map(\.slug) ?? [])
            let hasHighlightedPath = highlightedPath != nil

            ZStack {
                Canvas { context, _ in
                    for edge in graph.edges where !highlightedEdges.contains(edge) {
                        guard let source = positions[edge.sourceSlug],
                              let target = positions[edge.targetSlug] else {
                            continue
                        }
                        draw(
                            edge: edge,
                            from: source,
                            to: target,
                            style: hasHighlightedPath ? .dimmed : .standard,
                            in: &context
                        )
                    }
                    for edge in graph.edges where highlightedEdges.contains(edge) {
                        guard let source = positions[edge.sourceSlug],
                              let target = positions[edge.targetSlug] else {
                            continue
                        }
                        draw(edge: edge, from: source, to: target, style: .highlighted, in: &context)
                    }
                }

                ForEach(graph.nodes) { article in
                    if let position = positions[article.slug] {
                        ArticleGraphNode(
                            article: article,
                            pathRole: pathRole(for: article.slug),
                            isDimmed: hasHighlightedPath && !highlightedNodeSlugs.contains(article.slug)
                        ) {
                            guard !suppressOpenSlugs.contains(article.slug) else { return }
                            onOpenArticle(article.slug)
                        }
                        .position(position)
                        .highPriorityGesture(
                            nodeDragGesture(
                                slug: article.slug,
                                position: position,
                                canvasSize: proxy.size
                            )
                        )
                    }
                }
            }
            .coordinateSpace(name: Self.coordinateSpaceName)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("文章关系图，共 \(graph.nodes.count) 个文章节点和 \(graph.edges.count) 条引用连线")
        }
    }

    private func nodeDragGesture(
        slug: String,
        position: CGPoint,
        canvasSize: CGSize
    ) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { value in
                let origin = dragOrigins[slug] ?? position
                if dragOrigins[slug] == nil {
                    dragOrigins[slug] = origin
                    suppressOpenSlugs.insert(slug)
                }
                manualPositions[slug] = ArticleGraphLayout.clampedPosition(
                    CGPoint(
                        x: origin.x + value.translation.width,
                        y: origin.y + value.translation.height
                    ),
                    in: canvasSize
                )
            }
            .onEnded { _ in
                dragOrigins.removeValue(forKey: slug)
                DispatchQueue.main.async {
                    suppressOpenSlugs.remove(slug)
                }
            }
    }

    private func draw(
        edge: NativeArticleGraphEdge,
        from source: CGPoint,
        to target: CGPoint,
        style: ArticleGraphEdgeStyle,
        in context: inout GraphicsContext
    ) {
        let lineColor: Color
        let lineWidth: CGFloat
        switch style {
        case .standard:
            lineColor = Color.secondary.opacity(0.56)
            lineWidth = 1.3
        case .dimmed:
            lineColor = Color.secondary.opacity(0.16)
            lineWidth = 1
        case .highlighted:
            lineColor = Color.accentColor.opacity(0.95)
            lineWidth = 3
        }
        guard edge.sourceSlug != edge.targetSlug else {
            let loopCenter = CGPoint(
                x: source.x + ArticleGraphLayout.nodeSize.width * 0.33,
                y: source.y - ArticleGraphLayout.nodeSize.height * 0.42
            )
            let loopRect = CGRect(x: loopCenter.x - 17, y: loopCenter.y - 17, width: 34, height: 34)
            context.stroke(Path(ellipseIn: loopRect), with: .color(lineColor), lineWidth: lineWidth)
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
        context.stroke(line, with: .color(lineColor), lineWidth: lineWidth)

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

    private func pathRole(for slug: String) -> ArticleGraphPathNodeRole? {
        guard let path = highlightedPath,
              let first = path.nodes.first?.slug,
              let last = path.nodes.last?.slug,
              path.nodes.contains(where: { $0.slug == slug }) else {
            return nil
        }
        if slug == first && slug == last { return .startAndDestination }
        if slug == first { return .start }
        if slug == last { return .destination }
        return .waypoint
    }
}

private enum ArticleGraphEdgeStyle {
    case standard
    case dimmed
    case highlighted
}

private enum ArticleGraphPathNodeRole {
    case start
    case waypoint
    case destination
    case startAndDestination

    var label: String {
        switch self {
        case .start: return "起点"
        case .waypoint: return "路径节点"
        case .destination: return "终点"
        case .startAndDestination: return "起点与终点"
        }
    }

    var color: Color {
        switch self {
        case .start: return .green
        case .waypoint: return .accentColor
        case .destination: return .pink
        case .startAndDestination: return .purple
        }
    }
}

private struct ArticleGraphNode: View {
    let article: NativeArticleSummary
    let pathRole: ArticleGraphPathNodeRole?
    let isDimmed: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 4) {
                Text(article.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(LocalizedStringKey(pathRole?.label ?? article.status.label))
                    .font(.caption)
                    .foregroundStyle(pathRole?.color ?? Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(width: ArticleGraphLayout.nodeSize.width, height: ArticleGraphLayout.nodeSize.height, alignment: .leading)
            .background(nodeBackground, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(nodeBorder, lineWidth: pathRole == nil ? 1 : 2.5)
            }
        }
        .buttonStyle(.plain)
        .opacity(isDimmed ? 0.42 : 1)
        .help("拖动调整位置；单击打开：\(article.title)")
        .accessibilityLabel("打开文章：\(article.title)，\(NativeLocalization.string(article.status.label, language: NativeLocalization.currentLanguage))")
    }

    private var nodeBackground: Color {
        if let pathRole { return pathRole.color.opacity(0.18) }
        return article.status == .published ? Color.accentColor.opacity(0.12) : Color.orange.opacity(0.12)
    }

    private var nodeBorder: Color {
        if let pathRole { return pathRole.color.opacity(0.9) }
        return article.status == .published ? Color.accentColor.opacity(0.38) : Color.orange.opacity(0.48)
    }
}

enum ArticleGraphLayout {
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

    static func resolvedPositions(
        for nodes: [NativeArticleSummary],
        in size: CGSize,
        manualPositions: [String: CGPoint]
    ) -> [String: CGPoint] {
        var resolved = positions(for: nodes, in: size)
        for article in nodes {
            guard let manualPosition = manualPositions[article.slug] else { continue }
            resolved[article.slug] = clampedPosition(manualPosition, in: size)
        }
        return resolved
    }

    static func clampedPosition(_ position: CGPoint, in size: CGSize) -> CGPoint {
        let halfWidth = nodeSize.width / 2
        let halfHeight = nodeSize.height / 2
        return CGPoint(
            x: min(max(position.x, halfWidth), max(halfWidth, size.width - halfWidth)),
            y: min(max(position.y, halfHeight), max(halfHeight, size.height - halfHeight))
        )
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
