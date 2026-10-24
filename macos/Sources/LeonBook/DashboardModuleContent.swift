import AppKit
import LeonBookTodoModule
import SwiftUI

struct DashboardModuleContent: View {
    @Environment(\.nativeAppPalette) private var appPalette

    @ObservedObject var model: NativeAppModel
    let module: NativeDashboardModule
    let isEditing: Bool
    let availableWidth: CGFloat
    let contentHeight: CGFloat?
    let onConfigure: () -> Void

    private var mediaHeight: CGFloat? {
        contentHeight.map { max(120, $0 - (module.text.isEmpty ? 0 : 52) - (module.kind == .video ? 28 : 0)) }
    }

    var body: some View {
        switch module.kind {
        case .text:
            if module.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                placeholder("写下想放在首页的内容")
            } else {
                MarkdownArticleBody(body: module.text, store: model.store, articleLinks: model.articles,
                                    onOpenArticle: model.openArticleLink)
            }
        case .image, .audio, .video:
            if let media = module.media {
                VStack(alignment: .leading, spacing: 12) {
                    if module.kind == .image {
                        NativeImageView(url: media.url, alt: module.text.isEmpty ? media.name : module.text, store: model.store)
                            .frame(maxWidth: .infinity, maxHeight: mediaHeight == nil ? 420 : nil)
                            .frame(height: mediaHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else if module.kind == .audio {
                        NativeAudioEmbedView(reference: media.url, title: media.name, store: model.store, sourceRelativePath: nil)
                    } else {
                        InlineVideoPlayer(media: media, store: model.store, preferredHeight: mediaHeight)
                    }
                    if !module.text.isEmpty {
                        Text(module.text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            } else {
                placeholder("选择一个本地文件")
            }
        case .article:
            if module.articleSlug.isEmpty {
                placeholder("选择要展示的文章")
            } else {
                DashboardArticleContent(model: model, slug: module.articleSlug, expandsToContent: contentHeight != nil)
            }
        case .todos:
            DashboardTodoContent(model: model, module: module, isEditing: isEditing)
        case .quickNote:
            Button { model.executeCommand(.newArticle) } label: {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(module.text.isEmpty ? NativeLocalization.string("从一篇新笔记开始。", language: NativeLocalization.currentLanguage) : module.text)
                            .font(.system(size: 15)).foregroundStyle(.secondary)
                        Label("新文章", nativeIcon: "plus", iconSize: 14).font(.callout.weight(.medium))
                    }
                    Spacer()
                    NativeIcon.image("arrow.up.right", size: 14).foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(appPalette.buttonBlue, in: Circle())
                }
                .padding(.vertical, 12).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(isEditing)
        case .statistics:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: availableWidth < 300 ? 1 : availableWidth < 600 ? 2 : 4), alignment: .leading, spacing: 16) {
                StatCard(title: "全部文章", value: "\(model.articles.count)")
                StatCard(title: "已发布", value: "\(model.publishedArticleCount)")
                StatCard(title: "草稿", value: "\(model.draftArticleCount)")
                StatCard(title: "微博", value: "\(model.totalMomentCount)")
            }
        case .recentArticles:
            VStack(alignment: .leading, spacing: 6) {
                if model.articles.isEmpty {
                    Text("还没有文章").foregroundStyle(.secondary).padding(.vertical, 14)
                } else {
                    ForEach(Array(model.articles.prefix(module.itemLimit))) { article in
                        ArticleRow(article: article) { model.selectSlug(article.slug) }
                    }
                }
                Button { model.showAllArticles() } label: { Label("查看全部", nativeIcon: "arrow.right") }
                    .buttonStyle(.borderless).font(.caption).padding(.top, 6)
            }.disabled(isEditing)
        case .activity:
            ActivityHeatmapView(activity: model.activity, showsTitle: false)
        }
    }

    private func placeholder(_ title: LocalizedStringKey) -> some View {
        VStack(spacing: 12) {
            NativeIcon.image(module.kind.symbol, size: 32)
            Text(title).font(.callout)
            if isEditing {
                Button("设置内容", action: onConfigure).buttonStyle(.bordered)
            } else {
                Text("点击“编辑首页”设置模块内容").font(.caption)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(appPalette.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct DashboardArticleContent: View {
    @ObservedObject var model: NativeAppModel
    let slug: String
    let expandsToContent: Bool
    @State private var article: NativeArticle?
    @State private var errorMessage: String?

    private var summary: NativeArticleSummary? { model.articleSummary(for: slug) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let article, summary != nil {
                HStack(alignment: .firstTextBaseline) {
                    Text(article.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Spacer()
                    Button { model.openArticleLink(slug) } label: {
                        Label("打开文章", nativeIcon: "arrow.up.right")
                    }.buttonStyle(.borderless).font(.caption)
                }
                if expandsToContent {
                    articleBody(article)
                } else {
                    ScrollView { articleBody(article) }.frame(height: 300)
                }
            } else if let errorMessage {
                Label(errorMessage, nativeIcon: "doc.badge.ellipsis", iconSize: 14)
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 16)
            } else {
                ProgressView("正在加载文章…").frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .task(id: "\(slug)|\(summary?.updatedAt ?? "missing")") {
            article = nil
            errorMessage = nil
            guard summary != nil else {
                errorMessage = NativeLocalization.string("文章已移除，请编辑模块重新选择。", language: NativeLocalization.currentLanguage)
                return
            }
            do {
                let loaded = try await model.store.getArticle(slug: slug)
                guard !Task.isCancelled else { return }
                article = loaded
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder private func articleBody(_ article: NativeArticle) -> some View {
        if RichArticleDocument.isHTML(article.body) {
            RichArticleReader(bodyHTML: article.body, store: model.store,
                              sourceRelativePath: article.sourceRelativePath, fontSize: 15,
                              onOpenLink: { url in
                if url.scheme == "leonbook" { model.handleAutomationURL(url) }
                else { NSWorkspace.shared.open(url) }
            })
        } else {
            MarkdownArticleBody(body: article.body, store: model.store, articleLinks: model.articles,
                                sourceRelativePath: article.sourceRelativePath, rootArticleSlug: slug,
                                onOpenArticle: model.openArticleLink)
        }
    }
}

private struct DashboardTodoContent: View {
    @Environment(\.nativeAppPalette) private var appPalette

    @ObservedObject var model: NativeAppModel
    let module: NativeDashboardModule
    let isEditing: Bool
    @State private var title = ""

    private var projection: TodoListProjection {
        TodoListProjection(items: model.todoSession.items, filter: module.showsCompletedTodos ? .all : .open)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.isTodoModuleEnabled {
                Label("待办功能已停用，可在设置中启用。", nativeIcon: "checklist")
                    .foregroundStyle(.secondary)
            } else {
                if let error = model.todoSession.loadError {
                    Text(error).font(.caption).foregroundStyle(.red)
                    Button("重试") { Task { try? await model.reloadTodos() } }
                } else if !model.todoSession.hasLoaded {
                    ProgressView("正在加载待办…")
                } else {
                    ForEach(Array(projection.items.prefix(module.itemLimit))) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Button { Task { _ = await model.toggleTodo(item) } } label: {
                                NativeIcon.image(item.isCompleted ? "checkmark.circle.fill" : "circle", size: 18)
                                    .foregroundStyle(item.isCompleted ? appPalette.accent : appPalette.textSecondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(item.isCompleted ? "标记为未完成" : "标记为已完成"))
                            .disabled(!model.canWriteTodos || isEditing)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).strikethrough(item.isCompleted)
                                    .foregroundStyle(item.isCompleted ? appPalette.textSecondary : appPalette.textPrimary)
                                if let dueDay = item.dueDay {
                                    Text(dueDay).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    if projection.items.isEmpty {
                        Text("这里的待办都完成了，添加下一件想做的事吧。")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                }
                HStack {
                    TextField("添加一项待办…", text: $title)
                        .textFieldStyle(.roundedBorder).onSubmit(addTodo)
                    Button(action: addTodo) { NativeIcon.image("plus") }
                        .accessibilityLabel("添加待办")
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.disabled(!model.canWriteTodos || isEditing)
                HStack {
                    Text(NativeLocalization.text("\(projection.openCount) 项待完成")).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.openTodos() } label: { Label("查看全部", nativeIcon: "arrow.right") }
                        .buttonStyle(.borderless).disabled(isEditing)
                }.font(.caption)
            }
        }
    }

    private func addTodo() {
        guard !isEditing, model.canWriteTodos, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let submitted = title
        Task {
            if await model.saveTodoDraft(TodoDraft(title: submitted)), title == submitted { title = "" }
        }
    }
}
