import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DashboardModuleEditor: View {
    @Environment(\.nativeAppPalette) private var appPalette

    @ObservedObject var model: NativeAppModel
    @State private var module: NativeDashboardModule
    let onApply: (NativeDashboardModule) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var previewsMarkdown = false
    @State private var isImporting = false
    @State private var errorMessage: String?

    init(model: NativeAppModel, module: NativeDashboardModule, onApply: @escaping (NativeDashboardModule) -> Void) {
        self.model = model
        _module = State(initialValue: module)
        self.onApply = onApply
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("编辑模块", nativeIcon: module.kind.symbol, iconSize: 24).font(.title2.weight(.semibold))
                Spacer()
                Text(LocalizedStringKey(module.kind.title)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("模块标题").font(.callout.weight(.medium))
                TextField(LocalizedStringKey(module.kind.title), text: $module.title)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(alignment: .top, spacing: 28) {
                Stepper(value: Binding(get: { module.preferredColumnSpan }, set: { module.setColumnSpan($0) }),
                        in: NativeDashboardGridMetrics.columnRange) {
                    Text(NativeLocalization.text("宽度：\(module.preferredColumnSpan)/12 列"))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("高度随内容", isOn: Binding(get: { module.heightRows == nil }, set: { module.heightRows = $0 ? nil : 12 }))
                    if module.heightRows != nil {
                        Stepper(value: Binding(get: { module.heightRows ?? 12 }, set: { module.heightRows = $0 }),
                                in: NativeDashboardGridMetrics.heightRange) {
                            Text(NativeLocalization.text("高度：\((module.heightRows ?? 12) * 24) 点"))
                        }
                    }
                }.frame(width: 220, alignment: .leading)
            }
            Divider()
            editor
            if let errorMessage {
                Label(errorMessage, nativeIcon: "exclamationmark.triangle", iconSize: 14)
                    .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("应用后，点击“保存首页”保留修改。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("应用") {
                    do {
                        _ = try NativeDashboardDocument(modules: [module]).validated()
                        onApply(module)
                        dismiss()
                    } catch { errorMessage = error.localizedDescription }
                }.nativePrimaryButton().keyboardShortcut(.defaultAction)
            }.disabled(isImporting)
        }
        .padding(28).frame(width: 640)
        .interactiveDismissDisabled(isImporting)
        .nativeAppTheme()
    }

    @ViewBuilder private var editor: some View {
        switch module.kind {
        case .text:
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("正文内容").font(.headline)
                    Spacer()
                    Toggle("预览 Markdown", isOn: $previewsMarkdown).toggleStyle(.switch).controlSize(.small)
                }
                if previewsMarkdown {
                    ScrollView {
                        MarkdownArticleBody(body: module.text, store: model.store, articleLinks: model.articles)
                            .padding(12)
                    }.frame(height: 280)
                } else {
                    TextEditor(text: $module.text)
                        .font(.system(size: 14, design: .monospaced))
                        .padding(8).frame(height: 280)
                        .background(appPalette.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(appPalette.border) }
                }
                Text("支持标题、列表、引用、链接等 Markdown 格式。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .image, .audio, .video:
            mediaEditor
        case .article:
            articlePicker
        case .todos:
            VStack(alignment: .leading, spacing: 16) {
                Text("与待办页共享任务，勾选状态会同步更新。")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("显示已完成的待办", isOn: $module.showsCompletedTodos)
                itemLimit
            }.padding(.vertical, 8)
        case .recentArticles:
            itemLimit.padding(.vertical, 8)
        case .quickNote:
            VStack(alignment: .leading, spacing: 8) {
                Text("引导语").font(.headline)
                TextField("从一篇新笔记开始。", text: $module.text, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...4)
            }
        case .statistics, .activity:
            Label("内容会随资料库自动更新。", nativeIcon: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary).padding(.vertical, 20)
        }
    }

    private var itemLimit: some View {
        Stepper(value: $module.itemLimit, in: 1...20) { Text(NativeLocalization.text("最多显示 \(module.itemLimit) 项")) }
    }

    private var mediaEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let media = module.media {
                if module.kind == .image {
                    NativeImageView(url: media.url, alt: media.name, store: model.store)
                        .frame(maxWidth: .infinity, maxHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                HStack(spacing: 12) {
                    NativeIcon.image(module.kind.symbol, size: 24).foregroundStyle(appPalette.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(media.name).lineLimit(2)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(media.size), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("更换文件…", action: chooseMedia).disabled(isImporting)
                }
            } else {
                Button(action: chooseMedia) {
                    VStack(spacing: 12) {
                        NativeIcon.image(module.kind.symbol, size: 32)
                        Text("选择本地文件…")
                        Text(LocalizedStringKey(module.kind == .image ? "支持 PNG、JPEG、HEIC 等图片" : module.kind == .audio ? "支持 MP3、M4A、WAV 等音频" : "支持 MP4、MOV 等视频"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                    .background(appPalette.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).disabled(isImporting)
            }
            if isImporting { ProgressView("正在导入文件…").controlSize(.small) }
            TextField("添加说明…", text: $module.text, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...4)
            Text("文件会复制到当前用户的资料库，原文件保持不变。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var articlePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("搜索文章标题…", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    let matches = model.articles.filter {
                        search.isEmpty || $0.title.localizedStandardContains(search) || $0.slug.localizedStandardContains(search)
                    }
                    if matches.isEmpty {
                        Text("没有匹配的文章").foregroundStyle(.secondary).padding(20)
                    }
                    ForEach(matches) { article in
                        Button { module.articleSlug = article.slug } label: {
                            HStack {
                                NativeIcon.image(module.articleSlug == article.slug ? "checkmark.circle.fill" : "doc.text")
                                    .foregroundStyle(module.articleSlug == article.slug ? appPalette.accent : appPalette.textSecondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(article.title).lineLimit(1)
                                    Text(article.sourceRelativePath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(module.articleSlug == article.slug ? appPalette.lightBlue : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(height: 250)
            if !module.articleSlug.isEmpty {
                Text(model.articleSummary(for: module.articleSlug)?.title ?? NativeLocalization.string("文章已移除，请编辑模块重新选择。", language: NativeLocalization.currentLanguage))
                    .font(.callout.weight(.medium))
            }
            Text("首页展示文章最新正文，编辑文章后会自动更新。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func chooseMedia() {
        guard !isImporting, model.canEditDashboard else { return }
        let activeStore = model.store, generation = model.workspaceGeneration
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = module.kind == .image ? [.image] : module.kind == .audio ? [.audio] : [.movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isImporting = true
        errorMessage = nil
        Task {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
                isImporting = false
            }
            do {
                let media = try await activeStore.importDashboardMedia(url, kind: module.kind)
                guard generation == model.workspaceGeneration else { return }
                module.media = media
                model.scheduleBackup()
            } catch {
                guard generation == model.workspaceGeneration else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}
