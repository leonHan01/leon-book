import AVKit
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct ArticleReaderView: View {
    @ObservedObject var model: NativeAppModel
    @ObservedObject var workspaceLayout: NativeWorkspaceLayoutState
    @ObservedObject var readingPreferences: NativeReadingPreferences
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var isPresentingHistory = false
    @State private var isPresentingCompactInspector = false
    @State private var readerInspectorDragStart: Double?

    var body: some View {
        VStack(spacing: 0) {
            if !model.articleTabs.isEmpty {
                ArticleTabBar(model: model)
                Divider()
            }

            Group {
                if let article = model.selectedArticle {
                    let outline = MarkdownOutline.items(in: article.body)
                    GeometryReader { proxy in
                        let usesCompactInspector = proxy.size.width < 980
                        ScrollViewReader { scrollProxy in
                            HStack(spacing: 0) {
                                articleScroll(
                                    article: article,
                                    usesCompactInspector: usesCompactInspector
                                )

                                if !usesCompactInspector && workspaceLayout.isReaderInspectorVisible {
                                    Rectangle()
                                        .fill(Color.secondary.opacity(0.18))
                                        .frame(width: 7)
                                        .contentShape(Rectangle())
                                        .onHover { hovering in
                                            if hovering { NSCursor.resizeLeftRight.push() }
                                            else { NSCursor.pop() }
                                        }
                                        .gesture(
                                            DragGesture()
                                                .onChanged { value in
                                                    if readerInspectorDragStart == nil {
                                                        readerInspectorDragStart = workspaceLayout.readerInspectorWidth
                                                    }
                                                    let start = readerInspectorDragStart
                                                        ?? workspaceLayout.readerInspectorWidth
                                                    workspaceLayout.readerInspectorWidth = min(
                                                        max(start - Double(value.translation.width), 260),
                                                        480
                                                    )
                                                }
                                                .onEnded { _ in readerInspectorDragStart = nil }
                                        )
                                    ArticleInspectorView(
                                        model: model,
                                        selectedPane: $workspaceLayout.readerInspectorPane,
                                        article: article,
                                        outline: outline,
                                        relations: model.selectedArticleRelations,
                                        globalGraph: model.articleGraph,
                                        onSelectOutline: { item in
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                scrollProxy.scrollTo(item.id, anchor: .top)
                                            }
                                        },
                                        onSelectCommentAnchor: { anchorID in
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                scrollProxy.scrollTo(anchorID, anchor: .top)
                                            }
                                        },
                                        onOpenArticle: model.openArticleLink,
                                        onConvertUnlinkedMention: model.convertUnlinkedMention
                                    )
                                    .frame(width: CGFloat(workspaceLayout.readerInspectorWidth))
                                }
                            }
                            .onChange(of: model.articleScrollRevision) { _ in
                                guard let anchorID = model.consumePendingArticleScrollAnchor() else { return }
                                DispatchQueue.main.async {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        scrollProxy.scrollTo(anchorID, anchor: .top)
                                    }
                                }
                            }
                            .sheet(isPresented: $isPresentingCompactInspector) {
                                ArticleInspectorView(
                                    model: model,
                                    selectedPane: $workspaceLayout.readerInspectorPane,
                                    article: article,
                                    outline: outline,
                                    relations: model.selectedArticleRelations,
                                    globalGraph: model.articleGraph,
                                    onSelectOutline: { item in
                                        isPresentingCompactInspector = false
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            scrollProxy.scrollTo(item.id, anchor: .top)
                                        }
                                    },
                                    onSelectCommentAnchor: { anchorID in
                                        isPresentingCompactInspector = false
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            scrollProxy.scrollTo(anchorID, anchor: .top)
                                        }
                                    },
                                    onOpenArticle: { slug in
                                        isPresentingCompactInspector = false
                                        model.openArticleLink(slug)
                                    },
                                    onConvertUnlinkedMention: model.convertUnlinkedMention
                                )
                                .frame(width: 390, height: 680)
                            }
                        }
                    }
                } else {
                    EmptyState(title: "选择一篇文章", message: "从左侧打开文章，或创建一篇新笔记。", actionTitle: "新文章") { model.newArticle() }
                }
            }
        }
        .sheet(isPresented: $isPresentingHistory) {
            ArticleHistoryView(model: model)
        }
    }

    private func articleScroll(article: NativeArticle, usesCompactInspector: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Label(
                        article.status.label,
                        systemImage: article.status == .published
                            ? "checkmark.circle.fill" : "pencil.circle.fill"
                    )
                    .foregroundStyle(article.status == .published ? .green : .orange)
                    Spacer()
                    if let summary = model.articles.first(where: { $0.slug == article.slug }) {
                        Button {
                            model.toggleArticleBookmark(summary)
                        } label: {
                            Label(
                                model.isBookmarked(.article(slug: article.slug)) ? "取消收藏" : "收藏文章",
                                systemImage: model.isBookmarked(.article(slug: article.slug)) ? "bookmark.fill" : "bookmark"
                            )
                        }
                    }
                    NativeWorkspaceLayoutMenu(model: model, workspaceLayout: workspaceLayout)
                    let outline = MarkdownOutline.items(in: article.body)
                    if !outline.isEmpty {
                        Menu {
                            ForEach(outline) { heading in
                                Button {
                                    model.bookmarkHeading(article: article, heading: heading)
                                } label: {
                                    let target = NativeBookmarkTarget.heading(
                                        slug: article.slug,
                                        heading: heading.title,
                                        anchorID: heading.id
                                    )
                                    Label(
                                        heading.title,
                                        systemImage: model.isBookmarked(target) ? "bookmark.fill" : "textformat.size"
                                    )
                                }
                            }
                        } label: {
                            Label("收藏标题", systemImage: "textformat.size")
                        }
                    }
                    Button {
                        if usesCompactInspector {
                            isPresentingCompactInspector = true
                        } else {
                            workspaceLayout.isReaderInspectorVisible.toggle()
                        }
                    } label: {
                        Label(
                            usesCompactInspector || !workspaceLayout.isReaderInspectorVisible ? "文章面板" : "隐藏面板",
                            systemImage: "sidebar.right"
                        )
                    }
                    .help(usesCompactInspector || !workspaceLayout.isReaderInspectorVisible ? "打开文章大纲与关系" : "隐藏文章大纲与关系")
                    Button("版本历史") {
                        model.refreshArticleHistory()
                        isPresentingHistory = true
                    }
                    Button("编辑") { model.editSelected() }
                    Button("移入回收站", role: .destructive) { Task { await model.deleteSelected() } }
                }

                Text(article.title)
                    .font(readingPreferences.profile.bodyFont.swiftUIFont(size: 38, weight: .bold))
                    .id(NativeArticleCommentAnchor.articleTopID)
                HStack(spacing: 12) {
                    Text(article.category)
                    Text("·")
                    Text("更新于 \(article.updatedAt.nativeDateLabel)")
                    if let wordCount = article.wordCount { Text("· \(wordCount) 字") }
                    Text("· \(article.pageViews) PV")
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                if !article.tags.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "tag.fill")
                            .foregroundStyle(.tint)
                        ForEach(article.tags, id: \.self) { tag in
                            Button {
                                model.showArticles(tag: tag)
                            } label: {
                                Text("#\(tag)")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("查看标签 #\(tag) 的文章")
                        }
                    }
                }

                if !article.excerpt.isEmpty {
                    Text(article.excerpt)
                        .font(readingPreferences.profile.bodyFont.swiftUIFont(
                            size: readingPreferences.typography.fontSize + 2
                        ))
                        .foregroundStyle(.secondary)
                }

                if let banner = article.banner {
                    NativeImageView(url: banner.url, alt: banner.alt, store: model.store)
                }

                Divider()
                MarkdownArticleBody(
                    body: article.body,
                    store: model.store,
                    articleLinks: model.articles,
                    rootArticleSlug: article.slug,
                    onOpenArticle: model.openArticleLink,
                    onToggleTask: { lineIndex, completed in
                        model.toggleArticleTask(
                            article: article,
                            lineIndex: lineIndex,
                            completed: completed
                        )
                    }
                )
                .background {
                    ArticleTextSelectionObserver { selectedText in
                        guard model.selectedArticle?.slug == article.slug else { return }
                        model.prepareArticleComment(from: selectedText, in: article.body)
                        if usesCompactInspector {
                            isPresentingCompactInspector = true
                        } else {
                            workspaceLayout.isReaderInspectorVisible = true
                        }
                        workspaceLayout.readerInspectorPane = .comments
                    }
                }

                let attachmentMedia = article.media.filter {
                    !MarkdownArticleBody.imageURLs(in: article.body).contains($0.url)
                }
                if !attachmentMedia.isEmpty {
                    Divider()
                    Text("媒体").font(.headline)
                    ForEach(attachmentMedia) { media in
                        if media.isVideo {
                            InlineVideoPlayer(media: media, store: model.store)
                        } else if media.isImage {
                            NativeImageView(url: media.url, alt: media.name, store: model.store)
                        } else {
                            Button {
                                model.openMedia(media)
                            } label: {
                                Label(media.name, systemImage: "doc.fill")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .help("打开导入的附件")
                        }
                    }
                }
            }
            .frame(maxWidth: CGFloat(readingPreferences.profile.readingWidth), alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(42)
        }
        .background(readingPreferences.profile.theme.background(system: systemColorScheme))
        .environment(
            \.colorScheme,
            readingPreferences.profile.theme.colorScheme(system: systemColorScheme)
        )
        .environment(\.nativeReadingTypography, readingPreferences.typography)
    }
}

private struct ArticleTabBar: View {
    @ObservedObject var model: NativeAppModel

    var body: some View {
        HStack(spacing: 8) {
            Button(action: model.navigateArticleBack) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canNavigateArticleBack)
            .help("后退（⌘[）")

            Button(action: model.navigateArticleForward) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canNavigateArticleForward)
            .help("前进（⌘]）")

            Menu {
                if model.recentArticles.isEmpty {
                    Text("还没有最近文章")
                } else {
                    ForEach(model.recentArticles) { article in
                        Menu(article.title) {
                            Button("在当前标签页打开") { model.openArticleLink(article.slug) }
                            Button("在新标签页打开") {
                                model.openArticleLinkInNewTab(article.slug)
                            }
                        }
                    }
                }
            } label: {
                Label("最近文章", systemImage: "clock.arrow.circlepath")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("打开最近浏览的文章")

            Divider().frame(height: 22)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.articleTabs) { tab in
                        ArticleTabItem(
                            tab: tab,
                            title: model.articles.first(where: { $0.slug == tab.slug })?.title ?? tab.slug,
                            isActive: tab.id == model.activeArticleTabID,
                            onActivate: { model.activateArticleTab(tab.id) },
                            onTogglePin: { model.toggleArticleTabPin(tab.id) },
                            onClose: { model.closeArticleTab(tab.id) }
                        )
                    }
                }
                .padding(.vertical, 5)
            }

            Divider().frame(height: 22)

            Button(action: model.toggleActiveArticleTabPin) {
                Image(systemName: model.isActiveArticleTabPinned ? "pin.slash" : "pin")
            }
            .buttonStyle(.borderless)
            .help(model.isActiveArticleTabPinned ? "取消固定当前标签页" : "固定当前标签页")

            Button(action: model.closeActiveArticleTab) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("关闭当前标签页")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ArticleTabItem: View {
    let tab: NativeArticleTab
    let title: String
    let isActive: Bool
    let onActivate: () -> Void
    let onTogglePin: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onActivate) {
                HStack(spacing: 6) {
                    if tab.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                    }
                    Text(title)
                        .lineLimit(1)
                        .frame(maxWidth: 150, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title)\(tab.isPinned ? "，已固定" : "")")
            .accessibilityAddTraits(isActive ? .isSelected : [])

            if isHovered || isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .help("关闭标签页")
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            isActive ? Color.accentColor.opacity(0.17) : Color.primary.opacity(isHovered ? 0.08 : 0.04),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isActive ? Color.accentColor.opacity(0.35) : .clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(tab.isPinned ? "取消固定" : "固定标签页", action: onTogglePin)
            Button("关闭标签页", action: onClose)
        }
        .help(tab.isPinned ? "已固定；打开其他文章时不会替换此标签页" : title)
    }
}

private struct ArticleInspectorView: View {
    @ObservedObject var model: NativeAppModel
    @Binding var selectedPane: ArticleInspectorPane
    let article: NativeArticle
    let outline: [MarkdownOutlineItem]
    let relations: NativeArticleRelations
    let globalGraph: NativeArticleGraph
    let onSelectOutline: (MarkdownOutlineItem) -> Void
    let onSelectCommentAnchor: (String) -> Void
    let onOpenArticle: (String) -> Void
    let onConvertUnlinkedMention: (NativeArticleMention) -> Void
    private var localGraph: NativeArticleGraph {
        let relatedSlugs = Set(
            [article.slug]
                + relations.incoming.map(\.slug)
                + relations.outgoing.map(\.slug)
        )
        let nodes = globalGraph.nodes.filter { relatedSlugs.contains($0.slug) }
        let edges = globalGraph.edges.filter {
            relatedSlugs.contains($0.sourceSlug) && relatedSlugs.contains($0.targetSlug)
        }
        return NativeArticleGraph(nodes: nodes, edges: edges)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Label("阅读面板", systemImage: "sidebar.right")
                        .font(.headline)
                    Spacer()
                    Text(selectedPane == .comments ? "划词评论" : "上下文导航")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("阅读面板", selection: $selectedPane) {
                    Text("评论 \(model.articleComments.count)").tag(ArticleInspectorPane.comments)
                    Text("文章").tag(ArticleInspectorPane.context)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if selectedPane == .comments {
                ArticleCommentsSidebar(
                    model: model,
                    article: article,
                    onSelectAnchor: onSelectCommentAnchor
                )
            } else {
                contextNavigation
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: model.articleCommentSelectionRevision) { _ in
            if model.pendingArticleCommentSelection != nil {
                selectedPane = .comments
            }
        }
    }

    private var contextNavigation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ArticleInspectorSection(
                    title: "大纲",
                    systemImage: "list.bullet.indent",
                    count: outline.count
                ) {
                    if outline.isEmpty {
                        ArticleInspectorEmpty(message: "正文中还没有标题")
                    } else {
                        ArticleTableOfContents(items: outline, onSelect: onSelectOutline)
                    }
                }

                ArticleInspectorSection(
                    title: "反向链接",
                    systemImage: "arrow.uturn.backward",
                    count: relations.incoming.count
                ) {
                    articleLinks(relations.incoming, emptyMessage: "还没有文章链接到这里")
                }

                ArticleInspectorSection(
                    title: "出链",
                    systemImage: "arrow.up.forward",
                    count: relations.outgoing.count
                ) {
                    articleLinks(relations.outgoing, emptyMessage: "正文中还没有有效双链")
                }

                ArticleInspectorSection(
                    title: "未链接提及",
                    systemImage: "text.magnifyingglass",
                    count: relations.unlinkedMentions.count
                ) {
                    if relations.unlinkedMentions.isEmpty {
                        ArticleInspectorEmpty(message: "其他文章尚未直接提及本文标题")
                    } else {
                        ForEach(relations.unlinkedMentions) { mention in
                            ArticleUnlinkedMentionRow(
                                mention: mention,
                                onOpen: { onOpenArticle(mention.article.slug) },
                                onConvert: { onConvertUnlinkedMention(mention) }
                            )
                        }
                    }
                }

                ArticleInspectorSection(
                    title: "局部关系图",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    count: max(0, localGraph.nodes.count - 1)
                ) {
                    ArticleLocalGraphView(
                        graph: localGraph,
                        selectedSlug: article.slug,
                        onOpenArticle: onOpenArticle
                    )
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func articleLinks(_ articles: [NativeArticleSummary], emptyMessage: String) -> some View {
        if articles.isEmpty {
            ArticleInspectorEmpty(message: emptyMessage)
        } else {
            ForEach(articles) { relatedArticle in
                ArticleInspectorLinkRow(article: relatedArticle) {
                    onOpenArticle(relatedArticle.slug)
                }
            }
        }
    }
}

private struct ArticleCommentsSidebar: View {
    @ObservedObject var model: NativeAppModel
    let article: NativeArticle
    let onSelectAnchor: (String) -> Void
    @State private var commentText = ""
    @State private var replyingTo: NativeArticleComment?
    @State private var commentPendingDeletion: NativeArticleComment?
    @FocusState private var isComposerFocused: Bool

    private var commentsByID: [String: NativeArticleComment] {
        Dictionary(uniqueKeysWithValues: model.articleComments.map { ($0.id, $0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            commentComposer
                .padding(12)

            Divider()

            if model.articleComments.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("还没有评论")
                        .font(.headline)
                    Text("拖选或双击正文中的文字，即可针对原文发表评论；也可以直接评论整篇文章。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.articleComments) { comment in
                            ArticleCommentRow(
                                comment: comment,
                                parent: comment.parentID.flatMap { commentsByID[$0] },
                                canDelete: comment.authorName == model.currentUser.name,
                                onSelectSelection: { selection in
                                    let currentAnchor = NativeArticleCommentAnchor.selection(
                                        for: selection.quote,
                                        in: article.body
                                    )?.anchorID ?? selection.anchorID
                                    onSelectAnchor(currentAnchor)
                                },
                                onReply: {
                                    model.clearPendingArticleCommentSelection()
                                    replyingTo = comment
                                    isComposerFocused = true
                                },
                                onDelete: { commentPendingDeletion = comment }
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
        .onAppear {
            guard model.pendingArticleCommentSelection != nil else { return }
            DispatchQueue.main.async { isComposerFocused = true }
        }
        .onChange(of: model.articleCommentSelectionRevision) { _ in
            guard model.pendingArticleCommentSelection != nil else { return }
            replyingTo = nil
            isComposerFocused = true
        }
        .onChange(of: article.slug) { _ in
            commentText = ""
            replyingTo = nil
        }
        .alert(item: $commentPendingDeletion) { comment in
            Alert(
                title: Text("删除这条评论？"),
                message: Text("该评论下的回复也会一并删除。"),
                primaryButton: .destructive(Text("删除")) {
                    Task { await model.deleteArticleComment(comment) }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var commentComposer: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let replyingTo {
                HStack(spacing: 7) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .foregroundStyle(.tint)
                    Text("回复 \(replyingTo.authorName)")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button {
                        self.replyingTo = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help("取消回复")
                }
            } else if let selection = model.pendingArticleCommentSelection {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("评论所选原文", systemImage: "quote.opening")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                        Spacer()
                        Button(action: model.clearPendingArticleCommentSelection) {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .help("改为评论整篇文章")
                    }
                    Text(selection.quote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(9)
                .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Label("评论整篇文章", systemImage: "text.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $commentText)
                .font(.callout)
                .frame(minHeight: 62, maxHeight: 96)
                .padding(5)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.2))
                }
                .focused($isComposerFocused)
                .onChange(of: commentText) { value in
                    if value.count > 2_000 {
                        commentText = String(value.prefix(2_000))
                    }
                }

            HStack {
                Text("\(commentText.count)/2000")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isSavingArticleComment {
                    ProgressView().controlSize(.small)
                }
                Button(replyingTo == nil ? "发表评论" : "回复") {
                    let parentID = replyingTo?.id
                    Task {
                        if await model.createArticleComment(text: commentText, parentID: parentID) {
                            commentText = ""
                            replyingTo = nil
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(
                    commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.isSavingArticleComment
                )
            }
        }
    }
}

private struct ArticleCommentRow: View {
    let comment: NativeArticleComment
    let parent: NativeArticleComment?
    let canDelete: Bool
    let onSelectSelection: (NativeArticleCommentSelection) -> Void
    let onReply: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(String(comment.authorName.prefix(1)).uppercased())
                    .font(.caption.bold())
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor.opacity(0.17), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(comment.authorName)
                        .font(.caption.weight(.semibold))
                    Text(comment.createdAt.nativeDateLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Menu {
                    Button("回复", action: onReply)
                    if canDelete {
                        Divider()
                        Button("删除", role: .destructive, action: onDelete)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if let parent {
                Label("回复 \(parent.authorName)", systemImage: "arrowshape.turn.up.left")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let selection = comment.selection {
                Button {
                    onSelectSelection(selection)
                } label: {
                    HStack(alignment: .top, spacing: 7) {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.65))
                            .frame(width: 3)
                        Text(selection.quote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("回到评论对应的原文")
            }

            Text(comment.text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("回复", action: onReply)
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(.tint)
        }
        .padding(11)
        .padding(.leading, comment.parentID == nil ? 0 : 14)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.13))
        }
    }
}

private struct ArticleTextSelectionObserver: NSViewRepresentable {
    let onSelection: (String) -> Void

    func makeNSView(context: Context) -> ArticleTextSelectionObserverView {
        ArticleTextSelectionObserverView(onSelection: onSelection)
    }

    func updateNSView(_ nsView: ArticleTextSelectionObserverView, context: Context) {
        nsView.onSelection = onSelection
    }

    static func dismantleNSView(_ nsView: ArticleTextSelectionObserverView, coordinator: ()) {
        nsView.stopMonitoring()
    }
}

private final class ArticleTextSelectionObserverView: NSView {
    var onSelection: (String) -> Void
    private var eventMonitor: Any?
    private var mouseDownLocation: NSPoint?

    init(onSelection: @escaping (String) -> Void) {
        self.onSelection = onSelection
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func stopMonitoring() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        mouseDownLocation = nil
    }

    private func handle(_ event: NSEvent) {
        guard let window, event.window === window else { return }
        let localPoint = convert(event.locationInWindow, from: nil)
        switch event.type {
        case .leftMouseDown:
            mouseDownLocation = bounds.contains(localPoint) ? localPoint : nil
        case .leftMouseUp:
            guard let start = mouseDownLocation, bounds.contains(localPoint) else {
                mouseDownLocation = nil
                return
            }
            mouseDownLocation = nil
            let dragged = hypot(localPoint.x - start.x, localPoint.y - start.y) >= 3
            guard dragged || event.clickCount >= 2 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self, weak window] in
                guard let self, let window,
                      let selection = NativeReadableTextSelection.read(in: window) else { return }
                self.onSelection(selection)
            }
        default:
            break
        }
    }
}

private enum NativeReadableTextSelection {
    static func read(in window: NSWindow) -> String? {
        if let textView = window.firstResponder as? NSTextView {
            let range = textView.selectedRange()
            guard range.length > 0, NSMaxRange(range) <= (textView.string as NSString).length else {
                return nil
            }
            return normalized((textView.string as NSString).substring(with: range))
        }

        let pasteboard = NSPasteboard.general
        let snapshot = NativePasteboardSnapshot(pasteboard: pasteboard)
        let previousChangeCount = pasteboard.changeCount
        guard NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil),
              pasteboard.changeCount != previousChangeCount else { return nil }
        let selectedText = pasteboard.string(forType: .string)
        snapshot.restore(to: pasteboard)
        return selectedText.flatMap(normalized)
    }

    private static func normalized(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private struct NativePasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        items = pasteboard.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        } ?? []
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }
}

private struct ArticleInspectorSection<Content: View>: View {
    let title: String
    let systemImage: String
    let count: Int
    @ViewBuilder let content: () -> Content
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(11)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.13))
        }
    }
}

private struct ArticleTableOfContents: View {
    let items: [MarkdownOutlineItem]
    let onSelect: (MarkdownOutlineItem) -> Void

    private var baseLevel: Int {
        items.map(\.level).min() ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(items) { item in
                Button {
                    onSelect(item)
                } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Color.secondary.opacity(0.55))
                            .frame(width: 4, height: 4)
                        Text(item.title)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.leading, CGFloat(max(0, item.level - baseLevel)) * 12)
                .padding(.vertical, 4)
                .help("跳转到“\(item.title)”")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("文章大纲")
    }
}

struct ArticleInspectorLinkRow: View {
    let article: NativeArticleSummary
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: article.status == .published ? "doc.text" : "doc.text.fill")
                    .foregroundStyle(article.status == .published ? Color.accentColor : .orange)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(article.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    Text("\(article.status.label) · \(article.updatedAt.nativeDateLabel)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .articleHoverPreview(article)
        .accessibilityLabel("打开文章：\(article.title)")
    }
}

struct ArticleUnlinkedMentionRow: View {
    let mention: NativeArticleMention
    let onOpen: () -> Void
    let onConvert: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Image(systemName: "quote.bubble")
                            .foregroundStyle(.purple)
                        Text(mention.article.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                        Text("\(mention.count) 处")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(mention.snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .articleHoverPreview(mention.article)

            Button(action: onConvert) {
                Label("将 \(mention.count) 处提及转为双链", systemImage: "link.badge.plus")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 6)
        .accessibilityLabel("未链接提及来自：\(mention.article.title)，共 \(mention.count) 处")
    }
}

struct ArticleInspectorEmpty: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
    }
}

private struct ArticleLocalGraphView: View {
    let graph: NativeArticleGraph
    let selectedSlug: String
    let onOpenArticle: (String) -> Void

    private var displayedNodes: [NativeArticleSummary] {
        guard let selected = graph.nodes.first(where: { $0.slug == selectedSlug }) else {
            return Array(graph.nodes.prefix(9))
        }
        let neighbors = graph.nodes
            .filter { $0.slug != selectedSlug }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return [selected] + Array(neighbors.prefix(8))
    }

    private var displayedEdges: [NativeArticleGraphEdge] {
        let slugs = Set(displayedNodes.map(\.slug))
        return graph.edges.filter { slugs.contains($0.sourceSlug) && slugs.contains($0.targetSlug) }
    }

    var body: some View {
        if displayedNodes.isEmpty {
            ArticleInspectorEmpty(message: "当前文章尚未进入关系图")
        } else {
            GeometryReader { proxy in
                let positions = ArticleLocalGraphLayout.positions(
                    for: displayedNodes,
                    selectedSlug: selectedSlug,
                    in: proxy.size
                )
                ZStack {
                    Canvas { context, _ in
                        for edge in displayedEdges {
                            guard let source = positions[edge.sourceSlug],
                                  let target = positions[edge.targetSlug] else { continue }
                            var path = Path()
                            path.move(to: source)
                            path.addLine(to: target)
                            let color: Color
                            if edge.sourceSlug == selectedSlug {
                                color = .accentColor
                            } else if edge.targetSlug == selectedSlug {
                                color = .orange
                            } else {
                                color = .secondary
                            }
                            context.stroke(path, with: .color(color.opacity(0.55)), lineWidth: 1.2)
                        }
                    }

                    ForEach(displayedNodes) { node in
                        if let position = positions[node.slug] {
                            ArticleLocalGraphNode(
                                article: node,
                                isSelected: node.slug == selectedSlug
                            ) {
                                if node.slug != selectedSlug { onOpenArticle(node.slug) }
                            }
                            .position(position)
                        }
                    }
                }
            }
            .frame(height: 250)
            .overlay(alignment: .bottomTrailing) {
                if graph.nodes.count > displayedNodes.count {
                    Text("另有 \(graph.nodes.count - displayedNodes.count) 个邻居")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("局部关系图，共 \(graph.nodes.count) 个文章节点")
        }
    }
}

private struct ArticleLocalGraphNode: View {
    let article: NativeArticleSummary
    let isSelected: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            Text(article.title)
                .font(.caption2.weight(isSelected ? .bold : .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: isSelected ? 96 : 80, height: isSelected ? 42 : 36)
                .background(
                    isSelected ? Color.accentColor.opacity(0.2) : Color(nsColor: .windowBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isSelected ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.28)
                        )
                }
        }
        .buttonStyle(.plain)
        .articleHoverPreview(article)
        .help(isSelected ? "当前文章" : "打开文章：\(article.title)")
    }
}

private enum ArticleLocalGraphLayout {
    static func positions(
        for nodes: [NativeArticleSummary],
        selectedSlug: String,
        in size: CGSize
    ) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var positions: [String: CGPoint] = [:]
        let selected = nodes.first(where: { $0.slug == selectedSlug }) ?? nodes[0]
        positions[selected.slug] = center
        let neighbors = nodes.filter { $0.slug != selected.slug }
        guard !neighbors.isEmpty else { return positions }

        let radiusX = max(76, size.width / 2 - 46)
        let radiusY = max(72, size.height / 2 - 32)
        for (index, node) in neighbors.enumerated() {
            let angle = -Double.pi / 2 + Double(index) * 2 * Double.pi / Double(neighbors.count)
            positions[node.slug] = CGPoint(
                x: center.x + radiusX * CGFloat(cos(angle)),
                y: center.y + radiusY * CGFloat(sin(angle))
            )
        }
        return positions
    }
}

private struct ArticleHoverPreviewModifier: ViewModifier {
    let article: NativeArticleSummary
    @State private var isPresented = false
    @State private var hoverTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { isHovering in
                hoverTask?.cancel()
                guard isHovering else {
                    isPresented = false
                    return
                }
                hoverTask = Task {
                    try? await Task.sleep(nanoseconds: 320_000_000)
                    guard !Task.isCancelled else { return }
                    isPresented = true
                }
            }
            .popover(isPresented: $isPresented, arrowEdge: .leading) {
                ArticleHoverPreviewCard(article: article)
            }
            .onDisappear { hoverTask?.cancel() }
    }
}

private struct ArticleHoverPreviewCard: View {
    let article: NativeArticleSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: article.status == .published ? "doc.text" : "doc.text.fill")
                    .foregroundStyle(article.status == .published ? Color.accentColor : .orange)
                Text(article.status.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(article.updatedAt.nativeDateLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(article.title)
                .font(.headline)
            Text(article.excerpt.isEmpty ? "暂无摘要" : article.excerpt)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(6)
            if !article.tags.isEmpty {
                Text(article.tags.prefix(5).map { "#\($0)" }.joined(separator: "  "))
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            HStack(spacing: 10) {
                Label(article.category, systemImage: "folder")
                Label("\(article.wordCount) 字", systemImage: "character.cursor.ibeam")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }
}

private extension View {
    func articleHoverPreview(_ article: NativeArticleSummary) -> some View {
        modifier(ArticleHoverPreviewModifier(article: article))
    }
}

struct ArticleHistoryView: View {
    @ObservedObject var model: NativeAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRevisionID: Int?

    private var selectedRevision: NativeArticleRevision? {
        guard let selectedRevisionID else { return model.articleRevisions.first }
        return model.articleRevisions.first { $0.id == selectedRevisionID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("版本历史", systemImage: "clock.arrow.circlepath")
                        .font(.title2.weight(.semibold))
                    Text(model.currentArticleHistoryTitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("自动版本保留 30 天")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            if model.articleRevisions.isEmpty {
                EmptyState(
                    title: "还没有历史版本",
                    message: "停止输入 3 秒后会生成第一份自动保存；再次正式保存文章时，也会保留保存前的版本。",
                    actionTitle: "关闭"
                ) {
                    dismiss()
                }
            } else {
                HSplitView {
                    List(model.articleRevisions, selection: $selectedRevisionID) { revision in
                        ArticleRevisionRow(revision: revision)
                            .tag(revision.id)
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 230, idealWidth: 270, maxWidth: 340)

                    if let selectedRevision {
                        ArticleRevisionDiffView(
                            revision: selectedRevision,
                            current: model.currentArticleHistorySnapshot
                        ) {
                            if model.restoreArticleRevision(selectedRevision) {
                                dismiss()
                            }
                        }
                        .frame(minWidth: 650)
                    }
                }
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .task {
            model.refreshArticleHistory()
            selectNewestRevisionIfNeeded()
        }
        .onChange(of: model.articleRevisions.map(\.id)) { _ in
            selectNewestRevisionIfNeeded()
        }
    }

    private func selectNewestRevisionIfNeeded() {
        guard selectedRevisionID == nil || selectedRevision == nil else { return }
        selectedRevisionID = model.articleRevisions.first?.id
    }
}

private struct ArticleRevisionRow: View {
    let revision: NativeArticleRevision

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: revision.reason == .autosave ? "bolt.circle" : "tray.full")
                    .foregroundStyle(revision.reason == .autosave ? Color.accentColor : Color.orange)
                Text(revision.reason.label)
                    .font(.subheadline.weight(.medium))
            }
            Text(revision.updatedAt.nativeDateLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(revision.snapshot.title.isEmpty ? "未命名文章" : revision.snapshot.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 5)
    }
}

private struct ArticleRevisionDiffView: View {
    let revision: NativeArticleRevision
    let current: NativeArticleRevisionSnapshot
    let onRestore: () -> Void

    private var diff: NativeArticleLineDiff {
        NativeArticleLineDiff(previous: revision.snapshot.body, current: current.body)
    }

    private var metadataChanges: [String] {
        var changes: [String] = []
        if revision.snapshot.title != current.title { changes.append("标题") }
        if revision.snapshot.category != current.category { changes.append("分类") }
        if revision.snapshot.tags != current.tags { changes.append("标签") }
        if revision.snapshot.excerpt != current.excerpt { changes.append("摘要") }
        if revision.snapshot.status != current.status { changes.append("状态") }
        if revision.snapshot.banner != current.banner { changes.append("封面") }
        if revision.snapshot.media != current.media { changes.append("附件") }
        return changes
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("与当前内容比较")
                        .font(.headline)
                    HStack(spacing: 10) {
                        Label("删除 \(diff.removedLineOffsets.count) 行", systemImage: "minus.circle")
                            .foregroundStyle(.red)
                        Label("新增 \(diff.addedLineOffsets.count) 行", systemImage: "plus.circle")
                            .foregroundStyle(.green)
                        if !metadataChanges.isEmpty {
                            Text("属性变化：\(metadataChanges.joined(separator: "、"))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
                Spacer()
                Button(action: onRestore) {
                    Label("恢复此版本", systemImage: "arrow.uturn.backward.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)

            Divider()

            HSplitView {
                ArticleRevisionCodeColumn(
                    title: "历史版本",
                    source: revision.snapshot.body,
                    highlightedOffsets: diff.removedLineOffsets,
                    highlightColor: .red
                )
                ArticleRevisionCodeColumn(
                    title: "当前内容",
                    source: current.body,
                    highlightedOffsets: diff.addedLineOffsets,
                    highlightColor: .green
                )
            }
        }
    }
}

private struct ArticleRevisionCodeColumn: View {
    let title: String
    let source: String
    let highlightedOffsets: Set<Int>
    let highlightColor: Color

    private var lines: [String] {
        source.components(separatedBy: .newlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(lines.count) 行")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1)")
                                .foregroundStyle(.tertiary)
                                .frame(width: 38, alignment: .trailing)
                            Text(lines[index].isEmpty ? " " : lines[index])
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            highlightedOffsets.contains(index)
                                ? highlightColor.opacity(0.14)
                                : Color.clear
                        )
                    }
                }
                .padding(.vertical, 6)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

private enum MarkdownArticleBlock {
    case image(url: String, alt: String)
    case base(reference: String)
    case transclusion(reference: String)
    case text(markdown: String, headingIDs: [String], lineOffset: Int)
}

struct MarkdownArticleBody: View {
    let markdown: String
    let store: LocalBlogStore
    let articleLinks: [NativeArticleSummary]
    let onOpenArticle: (NativeArticleLinkDestination) -> Void
    let onToggleTask: ((Int, Bool) -> Void)?
    let embeddedSlugs: Set<String>
    @Environment(\.nativeReadingTypography) private var typography

    init(
        body: String,
        store: LocalBlogStore,
        articleLinks: [NativeArticleSummary] = [],
        rootArticleSlug: String? = nil,
        embeddedSlugs: Set<String> = [],
        onOpenArticle: @escaping (NativeArticleLinkDestination) -> Void = { _ in },
        onToggleTask: ((Int, Bool) -> Void)? = nil
    ) {
        markdown = body
        self.store = store
        self.articleLinks = articleLinks
        self.onOpenArticle = onOpenArticle
        self.onToggleTask = onToggleTask
        self.embeddedSlugs = rootArticleSlug.map { embeddedSlugs.union([$0]) } ?? embeddedSlugs
    }

    private var blocks: [MarkdownArticleBlock] { Self.markdownBlocks(in: markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: max(12, typography.paragraphSpacing)) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .image(url, alt):
                    NativeImageView(url: url, alt: alt, store: store)
                case let .base(reference):
                    SmartCollectionEmbedView(
                        reference: reference,
                        store: store,
                        onOpenArticle: onOpenArticle
                    )
                case let .transclusion(reference):
                    MarkdownArticleTransclusionView(
                        reference: reference,
                        store: store,
                        articleLinks: articleLinks,
                        embeddedSlugs: embeddedSlugs,
                        onOpenArticle: onOpenArticle
                    )
                case let .text(markdown, headingIDs, lineOffset):
                    MarkdownDocumentView(
                        markdown: markdown,
                        articleLinks: articleLinks,
                        onOpenArticle: onOpenArticle,
                        onToggleTask: onToggleTask,
                        headingIDs: headingIDs,
                        lineOffset: lineOffset
                    )
                }
            }
        }
    }

    static func imageURLs(in markdown: String) -> Set<String> {
        Set(markdownBlocks(in: markdown).compactMap { block in
            guard case let .image(url, _) = block else { return nil }
            return url
        })
    }

    private static func markdownBlocks(in markdown: String) -> [MarkdownArticleBlock] {
        var nextHeadingIndex = 0
        func textBlock(_ source: String, lineOffset: Int) -> MarkdownArticleBlock {
            let headingCount = MarkdownOutline.items(in: source).count
            let headingIDs = (0..<headingCount).map { offset in
                MarkdownOutline.anchorID(for: nextHeadingIndex + offset)
            }
            nextHeadingIndex += headingCount
            return .text(markdown: source, headingIDs: headingIDs, lineOffset: lineOffset)
        }

        let expression = try! NSRegularExpression(
            pattern: #"!\[([^\]]*)\]\(([^)\s]+)\)|!\[\[([^\[\]\r\n]+)\]\]|(?s:```base[^\r\n]*\r?\n(.*?)\r?\n```)"#
        )
        let searchRange = NSRange(markdown.startIndex..., in: markdown)
        let matches = expression.matches(in: markdown, range: searchRange)
        guard !matches.isEmpty else {
            return markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? [] : [textBlock(markdown, lineOffset: 0)]
        }

        var blocks: [MarkdownArticleBlock] = []
        var cursor = markdown.startIndex
        for match in matches {
            guard let matchRange = Range(match.range, in: markdown) else { continue }
            let rawText = String(markdown[cursor..<matchRange.lowerBound])
            let textBefore = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !textBefore.isEmpty {
                let baseLine = markdown[..<cursor].filter { $0 == "\n" }.count
                let leadingLines = rawText.prefix { $0.isWhitespace }.filter { $0 == "\n" }.count
                blocks.append(textBlock(textBefore, lineOffset: baseLine + leadingLines))
            }
            if let baseRange = Range(match.range(at: 4), in: markdown) {
                let config = String(markdown[baseRange])
                let reference = config.components(separatedBy: .newlines).compactMap { line -> String? in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let colon = trimmed.firstIndex(of: ":") else { return nil }
                    let key = trimmed[..<colon].lowercased()
                    guard key == "id" || key == "name" || key == "source" else { return nil }
                    return String(trimmed[trimmed.index(after: colon)...])
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
                }.first ?? config.trimmingCharacters(in: .whitespacesAndNewlines)
                blocks.append(.base(reference: reference.hasSuffix(".base") ? reference : "\(reference).base"))
            } else if let referenceRange = Range(match.range(at: 3), in: markdown) {
                let reference = String(markdown[referenceRange])
                let target = NativeArticleLink.Reference(rawValue: reference).target
                if URL(fileURLWithPath: target).pathExtension.caseInsensitiveCompare("base") == .orderedSame {
                    blocks.append(.base(reference: reference))
                } else {
                    blocks.append(.transclusion(reference: reference))
                }
            } else if let altRange = Range(match.range(at: 1), in: markdown),
                      let urlRange = Range(match.range(at: 2), in: markdown) {
                blocks.append(.image(url: String(markdown[urlRange]), alt: String(markdown[altRange])))
            }
            cursor = matchRange.upperBound
        }

        let rawTrailingText = String(markdown[cursor...])
        let trailingText = rawTrailingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailingText.isEmpty {
            let baseLine = markdown[..<cursor].filter { $0 == "\n" }.count
            let leadingLines = rawTrailingText.prefix { $0.isWhitespace }.filter { $0 == "\n" }.count
            blocks.append(textBlock(trailingText, lineOffset: baseLine + leadingLines))
        }
        return blocks
    }
}

private struct MarkdownArticleTransclusionView: View {
    let reference: String
    let store: LocalBlogStore
    let articleLinks: [NativeArticleSummary]
    let embeddedSlugs: Set<String>
    let onOpenArticle: (NativeArticleLinkDestination) -> Void
    @State private var article: NativeArticle?
    @State private var errorMessage: String?

    private var parsed: NativeArticleLink.Reference { .init(rawValue: reference) }
    private var target: NativeArticleSummary? { NativeArticleLink.resolve(reference, in: articleLinks) }

    var body: some View {
        Group {
            if let target, embeddedSlugs.contains(target.slug) {
                transclusionMessage("检测到循环嵌入：\(target.title)", systemImage: "arrow.triangle.2.circlepath")
            } else if let article {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        if let destination = NativeArticleLink.destination(for: reference, in: articleLinks) {
                            onOpenArticle(destination)
                        }
                    } label: {
                        Label(article.title, systemImage: "doc.text")
                            .font(.headline)
                    }
                    .buttonStyle(.plain)

                    if let fragment = NativeArticleEmbed.fragment(
                        in: article.body,
                        selector: parsed.heading
                    ) {
                        AnyView(MarkdownArticleBody(
                            body: fragment,
                            store: store,
                            articleLinks: articleLinks,
                            embeddedSlugs: embeddedSlugs.union([article.slug]),
                            onOpenArticle: onOpenArticle
                        ))
                    } else {
                        transclusionMessage("未找到嵌入片段 #\(parsed.heading ?? "")", systemImage: "questionmark.folder")
                    }
                }
                .padding(16)
                .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.24))
                }
            } else if let errorMessage {
                transclusionMessage(errorMessage, systemImage: "exclamationmark.triangle")
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在载入嵌入…").foregroundStyle(.secondary)
                }
            }
        }
        .task(id: target?.slug) {
            guard article == nil else { return }
            guard let target else {
                errorMessage = "找不到嵌入文章：\(parsed.target)"
                return
            }
            guard !embeddedSlugs.contains(target.slug) else { return }
            do { article = try await store.getArticle(slug: target.slug) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func transclusionMessage(_ message: String, systemImage: String) -> some View {
        Label(message, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct MarkdownWebEmbedView: View {
    let embed: MarkdownWebEmbed

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(embed.title, systemImage: "safari")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    NSWorkspace.shared.open(embed.url)
                } label: {
                    Label("在浏览器中打开", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.secondary.opacity(0.08))

            MarkdownEmbeddedWebView(url: embed.url)
                .frame(maxWidth: .infinity, minHeight: embed.height, maxHeight: embed.height)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.24))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct MarkdownHTMLComponentView: View {
    let component: MarkdownHTMLComponent

    var body: some View {
        MarkdownHTMLWebView(html: component.html)
            .frame(maxWidth: .infinity, minHeight: component.height, maxHeight: component.height)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.2))
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel("HTML 组件")
    }
}

private struct MarkdownHTMLWebView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        loadHTML(in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        loadHTML(in: webView, coordinator: context.coordinator)
    }

    private func loadHTML(in webView: WKWebView, coordinator: Coordinator) {
        let document = Self.document(containing: html)
        guard coordinator.loadedDocument != document else { return }
        coordinator.loadedDocument = document
        webView.loadHTMLString(document, baseURL: nil)
    }

    private static func document(containing html: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            :root { color-scheme: light dark; }
            *, *::before, *::after { box-sizing: border-box; }
            html, body { min-height: 100%; }
            body {
              margin: 0;
              padding: 16px;
              overflow: auto;
              color: CanvasText;
              background: Canvas;
              font-family: -apple-system, BlinkMacSystemFont, sans-serif;
            }
            img, video, canvas, svg { max-width: 100%; }
          </style>
        </head>
        <body>
        \(html)
        </body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedDocument: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            if navigationAction.navigationType == .linkActivated {
                if Self.isHTTPURL(url) { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
                return
            }

            decisionHandler(url.scheme?.lowercased() == "about" ? .allow : .cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               Self.isHTTPURL(url) {
                NSWorkspace.shared.open(url)
            }
            return nil
        }

        private static func isHTTPURL(_ url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased() else { return false }
            return ["http", "https"].contains(scheme)
        }
    }
}

private struct MarkdownEmbeddedWebView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil,
                  let url = navigationAction.request.url,
                  isAllowed(url) else { return nil }
            webView.load(URLRequest(url: url))
            return nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url, isAllowed(url) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        private func isAllowed(_ url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased() else { return false }
            return ["http", "https"].contains(scheme)
        }
    }
}

struct NativeImageView: View {
    let url: String
    let alt: String
    let store: LocalBlogStore

    @State private var image: NSImage?
    @State private var failedToLoad = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 680)
                    .accessibilityLabel(alt)
            } else if failedToLoad {
                Label("无法加载图片：\(alt)", systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView("正在加载图片…")
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .task(id: url) {
            guard let fileURL = await store.mediaURL(for: url) else {
                failedToLoad = true
                return
            }
            let decoded = await Task.detached(priority: .userInitiated) {
                NativeImageDecodeResult(
                    image: NativeImageLoader.thumbnail(from: fileURL, maxPixelSize: 2_400)
                )
            }.value
            guard !Task.isCancelled else { return }
            image = decoded.image
            failedToLoad = image == nil
        }
    }
}

private struct NativeImageDecodeResult: @unchecked Sendable {
    let image: NSImage?
}

private enum NativeImageLoader {
    static func thumbnail(from url: URL, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

private struct InlineVideoPlayer: View {
    let media: NativeMedia
    let store: LocalBlogStore

    @State private var player: AVPlayer?
    @State private var failedToLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let player {
                NativeAVPlayerView(player: player)
                    .frame(minHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel(media.name)
            } else if failedToLoad {
                Label("无法加载视频：\(media.name)", systemImage: "video.slash")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                ProgressView("正在加载视频…")
                    .frame(maxWidth: .infinity, minHeight: 320)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }

            Label(media.name, systemImage: "video")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .task(id: media.url) {
            guard let url = await store.mediaURL(for: media.url),
                  FileManager.default.fileExists(atPath: url.path) else {
                failedToLoad = true
                return
            }
            player = AVPlayer(url: url)
        }
        .onDisappear { player?.pause() }
    }
}

private struct NativeAVPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = true
        playerView.player = player
        return playerView
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        playerView.player = player
    }

    static func dismantleNSView(_ playerView: AVPlayerView, coordinator: ()) {
        playerView.player?.pause()
        playerView.player = nil
    }
}
