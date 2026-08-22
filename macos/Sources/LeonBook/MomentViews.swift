import AppKit
import ImageIO
import SwiftUI

private let momentFeedMaximumWidth: CGFloat = 1_760

struct MomentFeedView: View {
    @ObservedObject var model: NativeAppModel
    @State private var imageBrowser: MomentImageBrowserState?
    @State private var collapsedTimelineDays: Set<String> = []
    @AppStorage("momentFeedLayout") private var momentFeedLayoutRawValue = MomentFeedLayout.singleColumn.rawValue

    private var momentFeedLayout: MomentFeedLayout {
        MomentFeedLayout(rawValue: momentFeedLayoutRawValue) ?? .singleColumn
    }

    private func toggleTimelineDay(_ dayID: String) {
        if collapsedTimelineDays.contains(dayID) {
            collapsedTimelineDays.remove(dayID)
        } else {
            collapsedTimelineDays.insert(dayID)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("微博")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("用图片和一句话记录此刻，内容只保存在本机资料库中。")
                        .foregroundStyle(.secondary)
                }

                MomentComposerSection(model: model)

                HStack(alignment: .firstTextBaseline) {
                    Text("历史微博")
                        .font(.title2.weight(.bold))
                    Text(
                        !model.isFilteringMoments
                            ? "\(model.totalMomentCount) 条"
                            : "已加载 \(model.moments.count) / \(model.filteredMomentCount) 条"
                    )
                        .foregroundStyle(.secondary)
                    Spacer()

                    Menu {
                        ForEach(MomentFeedLayout.allCases) { layout in
                            Button {
                                momentFeedLayoutRawValue = layout.rawValue
                            } label: {
                                if momentFeedLayout == layout {
                                    Label(layout.title, systemImage: "checkmark")
                                } else {
                                    Label(layout.title, systemImage: layout.systemImage)
                                }
                            }
                        }
                    } label: {
                        Label(momentFeedLayout.title, systemImage: momentFeedLayout.systemImage)
                    }
                    .help("切换微博的单列或多列瀑布流布局")
                    .accessibilityLabel("微博布局：\(momentFeedLayout.title)")

                    TextField("搜索正文、标签或日期", text: $model.momentSearchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                        .help("可搜索正文、#标签、2026-08-22 或 2026年8月22日")
                        .onChange(of: model.momentSearchText) { _ in
                            model.refreshMomentFeed(after: 0.25)
                        }

                    Menu {
                        Button {
                            model.selectMomentDateFilter(.all)
                        } label: {
                            if model.momentDateFilter == .all {
                                Label("全部时间", systemImage: "checkmark")
                            } else {
                                Text("全部时间")
                            }
                        }
                        Button {
                            model.selectMomentDateFilter(.today)
                        } label: {
                            if model.momentDateFilter == .today {
                                Label("今天", systemImage: "checkmark")
                            } else {
                                Text("今天")
                            }
                        }
                        Button {
                            model.selectMomentDateFilter(.thisWeek)
                        } label: {
                            if model.momentDateFilter == .thisWeek {
                                Label("本周", systemImage: "checkmark")
                            } else {
                                Text("本周")
                            }
                        }

                        if !model.availableMomentMonths.isEmpty {
                            Divider()
                            Menu("按月份回顾") {
                                ForEach(model.availableMomentMonths) { month in
                                    let filter = NativeMomentDateFilter.month(year: month.year, month: month.month)
                                    Button {
                                        model.selectMomentDateFilter(filter)
                                    } label: {
                                        if model.momentDateFilter == filter {
                                            Label(month.label, systemImage: "checkmark")
                                        } else {
                                            Text(month.label)
                                        }
                                    }
                                }
                            }
                            Menu("按年份回顾") {
                                ForEach(model.availableMomentYears, id: \.self) { year in
                                    let filter = NativeMomentDateFilter.year(year)
                                    Button {
                                        model.selectMomentDateFilter(filter)
                                    } label: {
                                        if model.momentDateFilter == filter {
                                            Label("\(year)年", systemImage: "checkmark")
                                        } else {
                                            Text("\(year)年")
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        Label(model.momentDateFilter.label, systemImage: "calendar")
                    }
                    .help("按今天、本周、月份或年份回顾微博")

                    Button {
                        model.toggleFavoriteMomentFilter()
                    } label: {
                        Label(
                            model.showsOnlyFavoriteMoments ? "已筛选收藏" : "仅看收藏",
                            systemImage: model.showsOnlyFavoriteMoments ? "heart.fill" : "heart"
                        )
                    }
                    .buttonStyle(.bordered)
                    .tint(model.showsOnlyFavoriteMoments ? .pink : .gray)
                    .help("仅显示已收藏的微博")

                    if model.isFilteringMoments {
                        Button("清除筛选") {
                            model.clearMomentFilters()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if !model.availableMomentTagFilters.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Label("标签筛选", systemImage: "tag")
                                .font(.subheadline.weight(.semibold))
                            Text("可多选 · 任一匹配")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if !model.selectedMomentTags.isEmpty {
                                Text("已选 \(model.selectedMomentTags.count) 个")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }

                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 118, maximum: 210), spacing: 8)],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            ForEach(model.availableMomentTagFilters) { tagFilter in
                                let isSelected = model.isMomentTagSelected(tagFilter.tag)
                                Button {
                                    model.toggleMomentTagFilter(tagFilter.tag)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "tag")
                                        Text("#\(tagFilter.tag)")
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                        Text("\(tagFilter.count)")
                                            .font(.caption.monospacedDigit())
                                    }
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        isSelected ? Color.accentColor : Color.accentColor.opacity(0.1),
                                        in: Capsule()
                                    )
                                }
                                .buttonStyle(.plain)
                                .help("筛选标签 #\(tagFilter.tag)：\(tagFilter.count) 条微博")
                                .accessibilityLabel("标签 #\(tagFilter.tag)，\(tagFilter.count) 条微博")
                                .accessibilityValue(isSelected ? "已选中" : "未选中")
                            }
                        }
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    }
                }
            }
            .frame(maxWidth: momentFeedMaximumWidth, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.top, 34)
            .padding(.bottom, 20)

            Divider()

            if model.filteredMoments.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 38))
                        .foregroundStyle(.secondary)
                    Text(model.isFilteringMoments ? "没有符合筛选条件的微博" : "还没有微博")
                        .font(.headline)
                    Text(
                        !model.isFilteringMoments
                            ? "发布第一条图文动态，它会显示在这里。"
                            : "可清空搜索关键词或标签筛选后重试。"
                    )
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 24) {
                        ForEach(Array(model.momentTimeline.enumerated()), id: \.element.id) { index, group in
                            HStack(alignment: .top, spacing: 14) {
                                VStack(spacing: 0) {
                                    ZStack {
                                        Circle()
                                            .fill(Color.accentColor.opacity(0.14))
                                            .frame(width: 30, height: 30)
                                        Circle()
                                            .fill(Color.accentColor)
                                            .frame(width: 10, height: 10)
                                    }
                                    .padding(.top, 5)
                                    if index < model.momentTimeline.count - 1 {
                                        Rectangle()
                                            .fill(
                                                LinearGradient(
                                                    colors: [
                                                        Color.accentColor.opacity(0.48),
                                                        Color.accentColor.opacity(0.06),
                                                    ],
                                                    startPoint: .top,
                                                    endPoint: .bottom
                                                )
                                            )
                                            .frame(width: 2)
                                            .frame(minHeight: collapsedTimelineDays.contains(group.id) ? 52 : 112)
                                            .frame(maxHeight: .infinity)
                                            .padding(.top, 6)
                                    }
                                }
                                .frame(width: 30)

                                VStack(alignment: .leading, spacing: 12) {
                                    Button {
                                        toggleTimelineDay(group.id)
                                    } label: {
                                        HStack(spacing: 12) {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(group.label)
                                                    .font(.title3.weight(.semibold))
                                                HStack(spacing: 6) {
                                                    Label("\(group.moments.count) 条微博", systemImage: "rectangle.3.group")
                                                    Text(
                                                        collapsedTimelineDays.contains(group.id)
                                                            ? "点击展开"
                                                            : "点击折叠"
                                                    )
                                                }
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            }

                                            Spacer(minLength: 8)

                                            Image(systemName: collapsedTimelineDays.contains(group.id) ? "chevron.right" : "chevron.down")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.secondary)
                                                .frame(width: 28, height: 28)
                                                .background(.quaternary.opacity(0.55), in: Circle())
                                        }
                                        .padding(.horizontal, 15)
                                        .padding(.vertical, 11)
                                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 14)
                                                .strokeBorder(Color.primary.opacity(0.08))
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help(collapsedTimelineDays.contains(group.id) ? "展开 \(group.label) 的微博" : "折叠 \(group.label) 的微博")
                                    .accessibilityLabel(collapsedTimelineDays.contains(group.id) ? "展开 \(group.label) 的微博" : "折叠 \(group.label) 的微博")

                                    if collapsedTimelineDays.contains(group.id) {
                                        Label("已折叠 \(group.moments.count) 条微博", systemImage: "rectangle.stack")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 9)
                                            .background(Color.accentColor.opacity(0.08), in: Capsule())
                                    } else {
                                        if momentFeedLayout.columnCount == 1 {
                                            LazyVStack(spacing: 16) {
                                                momentCards(for: group.moments)
                                            }
                                        } else {
                                            MomentMasonryLayout(columns: momentFeedLayout.columnCount, spacing: 16) {
                                                momentCards(for: group.moments)
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        if model.hasMoreMoments {
                            HStack {
                                Spacer()
                                Button {
                                    model.loadMoreMoments()
                                } label: {
                                    if model.isLoadingMoreMoments {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("正在加载…")
                                    } else {
                                        Label("加载更多历史微博", systemImage: "arrow.down.circle")
                                    }
                                }
                                .disabled(model.isLoadingMoreMoments)
                                Spacer()
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    .frame(maxWidth: momentFeedMaximumWidth, alignment: .leading)
                    .padding(.horizontal, 34)
                    .padding(.vertical, 22)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $imageBrowser) { browser in
            MomentImageBrowserView(
                images: browser.images,
                initialIndex: browser.initialIndex,
                store: model.store
            )
        }
    }

    @ViewBuilder
    private func momentCards(for moments: [NativeMoment]) -> some View {
        ForEach(moments) { moment in
            MomentCard(moment: moment, store: model.store) { imageIndex in
                imageBrowser = MomentImageBrowserState(
                    images: moment.images,
                    initialIndex: imageIndex
                )
            } onEdit: {
                model.beginEditingMoment(moment)
            } onToggleFavorite: {
                model.toggleMomentFavorite(moment)
            } onSelectTag: { tag in
                model.toggleMomentTagFilter(tag)
            } onDelete: {
                model.deleteMoment(moment)
            }
        }
    }
}

private enum MomentFeedLayout: String, CaseIterable, Identifiable {
    case singleColumn
    case doubleColumnWaterfall
    case threeColumnWaterfall
    case fourColumnWaterfall

    var id: String { rawValue }

    var columnCount: Int {
        switch self {
        case .singleColumn: return 1
        case .doubleColumnWaterfall: return 2
        case .threeColumnWaterfall: return 3
        case .fourColumnWaterfall: return 4
        }
    }

    var title: String {
        switch self {
        case .singleColumn: return "单列"
        case .doubleColumnWaterfall: return "双列瀑布"
        case .threeColumnWaterfall: return "三列瀑布"
        case .fourColumnWaterfall: return "四列瀑布"
        }
    }

    var systemImage: String {
        switch self {
        case .singleColumn: return "rectangle"
        case .doubleColumnWaterfall: return "rectangle.split.2x1"
        case .threeColumnWaterfall: return "rectangle.split.3x1"
        case .fourColumnWaterfall: return "rectangle.split.2x2"
        }
    }
}

private struct MomentMasonryLayout: Layout {
    let columns: Int
    let spacing: CGFloat

    struct Cache {
        var frames: [CGRect] = []
        var size = CGSize.zero
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        cache = arrangement(width: proposedWidth(from: proposal, subviews: subviews), subviews: subviews)
        return cache.size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        cache = arrangement(width: bounds.width, subviews: subviews)

        for (index, subview) in subviews.enumerated() {
            let frame = cache.frames[index]
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: nil)
            )
        }
    }

    private func proposedWidth(from proposal: ProposedViewSize, subviews: Subviews) -> CGFloat {
        if let width = proposal.width {
            return width
        }

        let minimumColumnWidth: CGFloat = 280
        return minimumColumnWidth * CGFloat(max(columns, 1)) + spacing * CGFloat(max(columns - 1, 0))
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> Cache {
        let columnCount = max(columns, 1)
        let resolvedWidth = max(width, 0)
        let columnWidth = max(
            0,
            (resolvedWidth - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount)
        )
        var columnHeights = Array(repeating: CGFloat.zero, count: columnCount)
        var frames: [CGRect] = []

        for subview in subviews {
            let column = columnHeights.indices.min { columnHeights[$0] < columnHeights[$1] } ?? 0
            let y = columnHeights[column] == 0 ? 0 : columnHeights[column] + spacing
            let size = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            let height = max(size.height, 0)

            frames.append(
                CGRect(
                    x: CGFloat(column) * (columnWidth + spacing),
                    y: y,
                    width: columnWidth,
                    height: height
                )
            )
            columnHeights[column] = y + height
        }

        return Cache(
            frames: frames,
            size: CGSize(width: resolvedWidth, height: columnHeights.max() ?? 0)
        )
    }
}

private struct MomentComposerSection: View {
    @ObservedObject var model: NativeAppModel
    @State private var isExpanded = false

    private var isEditing: Bool { model.editingMomentID != nil }

    var body: some View {
        VStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Label(
                        isEditing ? "编辑微博" : "发布微博",
                        systemImage: isEditing ? "pencil" : "square.and.pencil"
                    )
                    .font(.headline)

                    Spacer()

                    Text(isExpanded ? "收起" : "展开")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(.quaternary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isEditing ? "编辑微博" : "发布微博")
            .accessibilityValue(isExpanded ? "已展开" : "已折叠")

            if isExpanded {
                MomentComposerView(model: model)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear {
            // Do not hide an unsaved draft or an edit session when returning to this page.
            isExpanded = isEditing || !model.momentDraft.isEmpty
        }
        .onChange(of: model.editingMomentID) { editingMomentID in
            if editingMomentID != nil {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded = true
                }
            }
        }
    }
}

private struct MomentComposerView: View {
    @ObservedObject var model: NativeAppModel
    @StateObject private var richTextController = MomentRichTextController()

    private var tags: [String] {
        NativeMomentTag.extract(from: model.momentDraft.text)
    }

    private var tagSuggestions: [String] {
        guard let query = richTextController.activeTagQuery else { return [] }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Array(
            model.availableMomentTags
                .filter { normalizedQuery.isEmpty || $0.lowercased().hasPrefix(normalizedQuery) }
                .prefix(8)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(
                    model.editingMomentID == nil ? "发布一条微博" : "编辑微博",
                    systemImage: model.editingMomentID == nil ? "square.and.pencil" : "pencil"
                )
                    .font(.headline)
                Spacer()
                Text("\(model.momentDraft.text.count) / 500")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    richTextController.toggleBold()
                } label: {
                    Image(systemName: "bold")
                }
                .help("加粗选中的文字")
                .keyboardShortcut("b", modifiers: .command)

                Menu {
                    Button("默认颜色") {
                        richTextController.apply(color: nil)
                    }
                    Divider()
                    ForEach(NativeMomentTextColor.allCases) { color in
                        Button {
                            richTextController.apply(color: color)
                        } label: {
                            Label(color.label, systemImage: "circle.fill")
                                .foregroundStyle(color.swiftUIColor)
                        }
                    }
                } label: {
                    Label("文字颜色", systemImage: "paintpalette")
                }
                .help("修改选中文字的颜色")

                Spacer()

                Text("拖入或粘贴图片可直接添加")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            MomentRichTextEditor(
                text: $model.momentDraft.text,
                textRuns: $model.momentDraft.textRuns,
                controller: richTextController,
                onPasteImages: model.uploadMomentPastedImages
            )
                .frame(height: 63)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.quaternary)
                }

            if let query = richTextController.activeTagQuery, !tagSuggestions.isEmpty {
                MomentTagSuggestionMenu(
                    query: query,
                    tags: tagSuggestions,
                    onSelect: richTextController.completeTagSuggestion,
                    onDismiss: richTextController.dismissTagSuggestions
                )
            }

            if tags.isEmpty {
                Text("在正文中输入 #标签 添加标签；编辑时直接修改或删除 #标签 即可更新。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Label("标签", systemImage: "tag")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.tint.opacity(0.12), in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
            }

            if !model.momentDraft.images.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(model.momentDraft.images) { image in
                            ZStack(alignment: .topTrailing) {
                                MomentImage(
                                    media: image,
                                    store: model.store,
                                    loadMode: .thumbnail(maxPixelSize: 240)
                                )
                                    .frame(width: 96, height: 96)
                                    .clipShape(RoundedRectangle(cornerRadius: 9))

                                Button {
                                    model.removeMomentImage(image)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 22, height: 22)
                                        .background(.red, in: Circle())
                                        .overlay {
                                            Circle().stroke(.white.opacity(0.8), lineWidth: 1)
                                        }
                                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                                }
                                .buttonStyle(.plain)
                                .padding(6)
                                .help("移除图片")
                                .accessibilityLabel("移除图片 \(image.name)")
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            HStack(spacing: 12) {
                Button {
                    model.chooseMomentImages()
                } label: {
                    Label("添加图片", systemImage: "photo.on.rectangle.angled")
                }

                Text("最多 9 张图片")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if model.editingMomentID != nil {
                    Button("取消") {
                        model.cancelMomentEditing()
                    }
                    .disabled(model.isPublishingMoment)
                }

                Button {
                    model.publishMoment()
                } label: {
                    Label(
                        model.isPublishingMoment
                            ? "正在保存…"
                            : model.editingMomentID == nil ? "发布" : "保存修改",
                        systemImage: model.editingMomentID == nil ? "paperplane.fill" : "checkmark"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.momentDraft.isEmpty || model.isPublishingMoment)
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.quaternary)
        }
    }
}

private struct MomentTagSuggestionMenu: View {
    let query: String
    let tags: [String]
    let onSelect: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(
                    query.isEmpty ? "选择已有标签" : "匹配的标签",
                    systemImage: "number.circle"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("关闭标签建议")
            }

            ForEach(tags, id: \.self) { tag in
                Button {
                    onSelect(tag)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "tag.fill")
                            .foregroundStyle(.tint)
                        Text("#\(tag)")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Text("选择")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(10)
        .frame(maxWidth: 360, alignment: .leading)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary)
        }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("标签建议")
    }
}

private struct MomentCard: View {
    let moment: NativeMoment
    let store: LocalBlogStore
    let onOpenImage: (Int) -> Void
    let onEdit: () -> Void
    let onToggleFavorite: () -> Void
    let onSelectTag: (String) -> Void
    let onDelete: () -> Void

    private var displayContent: (text: String, runs: [NativeMomentTextRun]) {
        moment.displayContent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundStyle(.tint)
                Text("leon-book")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                HStack(alignment: .center, spacing: 8) {
                    Text(moment.createdAt.nativeDateLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Button(action: onToggleFavorite) {
                            Label(
                                moment.isFavorite ? "已收藏" : "收藏",
                                systemImage: moment.isFavorite ? "heart.fill" : "heart"
                            )
                            .foregroundStyle(moment.isFavorite ? .pink : .primary)
                            .frame(minWidth: 58, minHeight: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered)
                        .help(moment.isFavorite ? "取消收藏这条微博" : "收藏这条微博")
                        .accessibilityLabel(moment.isFavorite ? "取消收藏这条微博" : "收藏这条微博")

                        Button(action: onEdit) {
                            Label("编辑", systemImage: "pencil")
                                .frame(minWidth: 58, minHeight: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered)
                        .help("编辑这条微博")
                        .accessibilityLabel("编辑这条微博")

                        Button(action: confirmDeletion) {
                            Label("删除", systemImage: "trash")
                                .frame(minWidth: 58, minHeight: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .help("删除这条微博")
                        .accessibilityLabel("删除这条微博")
                    }
                }
            }
            if !displayContent.text.isEmpty {
                MomentStyledText(text: displayContent.text, runs: displayContent.runs)
            }

            if !moment.tags.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(moment.tags, id: \.self) { tag in
                            Button {
                                onSelectTag(tag)
                            } label: {
                                Text("#\(tag)")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.tint)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(.tint.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("筛选标签 #\(tag)")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            if !moment.images.isEmpty {
                MomentImageGrid(images: moment.images, store: store, onOpenImage: onOpenImage)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .strokeBorder(.quaternary)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func confirmDeletion() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "将这条微博移入回收站？"
        alert.informativeText = "微博和图片会保留 30 天，可在回收站中恢复，之后自动永久删除。"
        alert.addButton(withTitle: "移入回收站")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onDelete()
    }
}

private struct MomentStyledText: View {
    let text: String
    let runs: [NativeMomentTextRun]

    var body: some View {
        renderedText
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var renderedText: Text {
        let resolvedRuns = runs.map(\.text).joined() == text && !runs.isEmpty
            ? runs
            : [NativeMomentTextRun(text: text, bold: false, color: nil)]
        return resolvedRuns.reduce(Text("")) { partial, run in
            partial + styled(Text(run.text), run: run)
        }
    }

    private func styled(_ text: Text, run: NativeMomentTextRun) -> Text {
        let weighted = run.bold ? text.bold() : text
        return run.color.map { weighted.foregroundColor($0.swiftUIColor) } ?? weighted
    }
}

private struct MomentImageGrid: View {
    let images: [NativeMedia]
    let store: LocalBlogStore
    let onOpenImage: (Int) -> Void

    private let spacing: CGFloat = 6

    private var columns: Int {
        images.count == 1 ? 1 : images.count == 2 ? 2 : 3
    }

    private var imageTileSize: CGFloat {
        images.count == 1 ? 320 : images.count == 2 ? 176 : 128
    }

    private var imageHeight: CGFloat {
        images.count == 1 ? 240 : imageTileSize
    }

    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(imageTileSize), spacing: spacing),
            count: columns
        )
    }

    var body: some View {
        LazyVGrid(
            columns: gridColumns,
            alignment: .leading,
            spacing: spacing
        ) {
            ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                Button {
                    onOpenImage(index)
                } label: {
                    MomentImage(
                        media: image,
                        store: store,
                        loadMode: .thumbnail(maxPixelSize: 720)
                    )
                        .frame(width: imageTileSize, height: imageHeight)
                        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.primary.opacity(0.18), lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("放大浏览图片 \(image.name)")
                .accessibilityHint("点按打开图片浏览器")
            }
        }
    }
}

private enum MomentImageLoadMode: Equatable, Sendable {
    case thumbnail(maxPixelSize: Int)
    case fullSize

    var cacheKey: String {
        switch self {
        case let .thumbnail(maxPixelSize): return "thumbnail-\(maxPixelSize)"
        case .fullSize: return "full-size"
        }
    }
}

private struct MomentImage: View {
    let media: NativeMedia
    let store: LocalBlogStore
    let loadMode: MomentImageLoadMode

    @State private var image: NSImage?
    @State private var failedToLoad = false

    init(
        media: NativeMedia,
        store: LocalBlogStore,
        loadMode: MomentImageLoadMode = .thumbnail(maxPixelSize: 480)
    ) {
        self.media = media
        self.store = store
        self.loadMode = loadMode
    }

    var body: some View {
        ZStack {
            Color.clear
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if failedToLoad {
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .clipped()
        .task(id: "\(media.url)|\(loadMode.cacheKey)") {
            image = nil
            failedToLoad = false
            guard let url = await store.mediaURL(for: media.url) else {
                failedToLoad = true
                return
            }
            let decoded = await MomentImageLoader.shared.image(from: url, mode: loadMode)
            guard !Task.isCancelled else { return }
            image = decoded.image
            failedToLoad = image == nil
        }
        .accessibilityLabel(media.name)
    }
}

private actor MomentImageLoader {
    static let shared = MomentImageLoader()

    private let cache = NSCache<NSString, NSImage>()
    private let maximumConcurrentDecodes = 4
    private var activeDecodeCount = 0
    private var decodeWaiters: [CheckedContinuation<Void, Never>] = []

    init() {
        cache.countLimit = 512
        cache.totalCostLimit = 160 * 1_024 * 1_024
    }

    func image(from url: URL, mode: MomentImageLoadMode) async -> MomentImageDecodeResult {
        let key = "\(url.path)|\(mode.cacheKey)" as NSString
        if mode != .fullSize, let cached = cache.object(forKey: key) {
            return MomentImageDecodeResult(image: cached)
        }

        await acquireDecodeSlot()
        defer { releaseDecodeSlot() }

        guard !Task.isCancelled else { return MomentImageDecodeResult(image: nil) }
        if mode != .fullSize, let cached = cache.object(forKey: key) {
            return MomentImageDecodeResult(image: cached)
        }

        let decoded = await Task.detached(priority: .userInitiated) {
            MomentImageDecodeResult(image: MomentImageDecoder.load(from: url, mode: mode))
        }.value

        if mode != .fullSize, let image = decoded.image {
            cache.setObject(image, forKey: key, cost: imageCost(image))
        }
        return decoded
    }

    private func acquireDecodeSlot() async {
        if activeDecodeCount < maximumConcurrentDecodes {
            activeDecodeCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            decodeWaiters.append(continuation)
        }
    }

    private func releaseDecodeSlot() {
        if let waiter = decodeWaiters.first {
            decodeWaiters.removeFirst()
            waiter.resume()
        } else {
            activeDecodeCount = max(0, activeDecodeCount - 1)
        }
    }

    private func imageCost(_ image: NSImage) -> Int {
        let representation = image.representations.first
        let width = representation?.pixelsWide ?? Int(image.size.width)
        let height = representation?.pixelsHigh ?? Int(image.size.height)
        return max(1, width * height * 4)
    }
}

private enum MomentImageDecoder {
    static func load(from url: URL, mode: MomentImageLoadMode) -> NSImage? {
        if mode == .fullSize {
            return NSImage(contentsOf: url)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        guard case let .thumbnail(maxPixelSize) = mode else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)

        guard let cgImage else { return nil }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }
}

private struct MomentImageDecodeResult: @unchecked Sendable {
    let image: NSImage?
}

private struct MomentImageBrowserState: Identifiable {
    let id = UUID()
    let images: [NativeMedia]
    let initialIndex: Int
}

private struct MomentImageBrowserView: View {
    let images: [NativeMedia]
    let initialIndex: Int
    let store: LocalBlogStore

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex = 0
    @State private var scale: CGFloat = 1
    @State private var keyboardMonitor: Any?

    private var selectedImage: NativeMedia { images[selectedIndex] }
    private var browserSize: CGSize {
        let available = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1_440, height: 900)
        return CGSize(width: available.width * 0.94, height: available.height * 0.90)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(selectedImage.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text("\(selectedIndex + 1) / \(images.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    scale = max(1, scale - 0.5)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .disabled(scale <= 1)
                .help("缩小")
                Button {
                    scale = min(4, scale + 0.5)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .disabled(scale >= 4)
                .help("放大")
                Button("适合窗口") {
                    scale = 1
                }
                .disabled(scale == 1)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .help("关闭图片浏览器")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            HStack(spacing: 14) {
                Button {
                    showPreviousImage()
                } label: {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.system(size: 30))
                }
                .buttonStyle(.plain)
                .disabled(selectedIndex == 0)
                .accessibilityLabel("上一张图片")

                MomentZoomableImage(media: selectedImage, store: store, scale: $scale)
                    .id(selectedImage.id)

                Button {
                    showNextImage()
                } label: {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 30))
                }
                .buttonStyle(.plain)
                .disabled(selectedIndex == images.count - 1)
                .accessibilityLabel("下一张图片")
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            ScrollView(.horizontal) {
                HStack(spacing: 9) {
                    ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                        Button {
                            selectedIndex = index
                            scale = 1
                        } label: {
                            MomentImage(
                                media: image,
                                store: store,
                                loadMode: .thumbnail(maxPixelSize: 180)
                            )
                                .frame(width: 74, height: 74)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7)
                                        .strokeBorder(
                                            index == selectedIndex ? Color.accentColor : .clear,
                                            lineWidth: 3
                                        )
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("查看第 \(index + 1) 张图片")
                    }
                }
                .padding(14)
            }
            .scrollIndicators(.hidden)
            .frame(height: 104)
        }
        .frame(width: browserSize.width, height: browserSize.height)
        .background(Color.gray.opacity(0.72).ignoresSafeArea())
        .onAppear {
            selectedIndex = min(max(0, initialIndex), max(0, images.count - 1))
            installKeyboardMonitor()
        }
        .onDisappear {
            removeKeyboardMonitor()
        }
    }

    private func installKeyboardMonitor() {
        guard keyboardMonitor == nil else { return }

        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let navigationModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
            guard event.modifierFlags.intersection(navigationModifiers).isEmpty else {
                return event
            }

            switch event.keyCode {
            case 123:
                showPreviousImage()
                return nil
            case 124:
                showNextImage()
                return nil
            case 53:
                dismiss()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyboardMonitor() {
        guard let keyboardMonitor else { return }
        NSEvent.removeMonitor(keyboardMonitor)
        self.keyboardMonitor = nil
    }

    private func showPreviousImage() {
        guard selectedIndex > 0 else { return }
        selectedIndex -= 1
        scale = 1
    }

    private func showNextImage() {
        guard selectedIndex < images.count - 1 else { return }
        selectedIndex += 1
        scale = 1
    }
}

private struct MomentZoomableImage: View {
    let media: NativeMedia
    let store: LocalBlogStore
    @Binding var scale: CGFloat

    @State private var image: NSImage?
    @State private var failedToLoad = false
    @State private var gestureStartScale: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    Color.clear
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(
                                width: max(proxy.size.width, proxy.size.width * scale),
                                height: max(proxy.size.height, proxy.size.height * scale)
                            )
                    } else if failedToLoad {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
                .frame(
                    width: max(proxy.size.width, proxy.size.width * scale),
                    height: max(proxy.size.height, proxy.size.height * scale)
                )
            }
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = min(4, max(1, gestureStartScale * value))
                    }
                    .onEnded { _ in
                        gestureStartScale = scale
                    }
            )
        }
        .background(Color.gray.opacity(0.48), in: RoundedRectangle(cornerRadius: 12))
        .task(id: media.url) {
            guard let url = await store.mediaURL(for: media.url) else {
                failedToLoad = true
                return
            }
            let decoded = await MomentImageLoader.shared.image(from: url, mode: .fullSize)
            guard !Task.isCancelled else { return }
            image = decoded.image
            failedToLoad = image == nil
        }
        .accessibilityLabel("大图浏览：\(media.name)")
    }
}

private extension NativeMomentTextColor {
    var swiftUIColor: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        }
    }
}
