import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ArticleExportRequest: Identifiable {
    let id = UUID()
    let articles: [NativeArticleSummary]
    let store: LocalBlogStore
}

struct ArticleExportButton: View {
    let articles: [NativeArticleSummary]
    let store: LocalBlogStore
    var compact = false
    @State private var request: ArticleExportRequest?

    var body: some View {
        Button {
            request = ArticleExportRequest(articles: articles, store: store)
        } label: {
            Label(
                "导出与分享…", nativeIcon: ArticleActionIcon.Kind.export.symbol,
                iconSize: compact ? NativeIcon.Size.toolbar : NativeIcon.Size.standard
            )
                .labelStyle(ArticleExportLabelStyle(compact: compact))
        }
        .disabled(articles.isEmpty)
        .help("导出 PDF、独立 HTML 或包含附件的文章包")
        .sheet(item: $request) { request in
            ArticleExportSheet(articles: request.articles, store: request.store)
        }
    }
}

private struct ArticleExportLabelStyle: LabelStyle {
    let compact: Bool
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.icon.frame(width: 30, height: 30).contentShape(Rectangle())
                .accessibilityLabel("导出与分享…")
        } else { HStack { configuration.icon; configuration.title } }
    }
}

struct ArticleExportSheet: View {
    let articles: [NativeArticleSummary]
    let store: LocalBlogStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSlugs: Set<String>
    @State private var search = ""
    @State private var format = ArticleExportFormat.pdf
    @State private var includeMetadata = true
    @StateObject private var job = ArticleExportJob()

    init(articles: [NativeArticleSummary], store: LocalBlogStore) {
        self.articles = articles; self.store = store
        _selectedSlugs = State(initialValue: Set(articles.map(\.slug)))
    }

    private var selected: [NativeArticleSummary] { articles.filter { selectedSlugs.contains($0.slug) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("导出与分享").font(.title2.weight(.semibold))
            Text("导出已保存的文章。批量导出会生成 ZIP，每篇文章保留为独立文件。")
                .font(.callout).foregroundStyle(.secondary)

            if let output = job.output {
                Spacer()
                Label("导出完成", nativeIcon: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
                Text(output.lastPathComponent).textSelection(.enabled)
                HStack {
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                    ShareLink(item: output) { Label("分享…", nativeIcon: "square.and.arrow.up") }
                }
                Spacer()
            } else {
                Picker("导出格式", selection: $format) {
                    ForEach(ArticleExportFormat.allCases) { option in
                        Text(LocalizedStringKey(option.label)).tag(option)
                    }
                }.disabled(job.isExporting)
                Text(LocalizedStringKey(format.description)).font(.caption).foregroundStyle(.secondary)
                Toggle("包含分类、标签、更新时间和摘要", isOn: $includeMetadata)
                    .disabled(job.isExporting)

                if articles.count > 1 {
                    HStack {
                        Text(NativeLocalization.text("已选择 \(selectedSlugs.count) / \(articles.count) 篇文章"))
                        Spacer()
                        Button("全选") { selectedSlugs = Set(articles.map(\.slug)) }
                        Button("全不选") { selectedSlugs.removeAll() }
                    }.disabled(job.isExporting)
                    TextField("筛选要导出的文章", text: $search).textFieldStyle(.roundedBorder).disabled(job.isExporting)
                    List(articles.filter { search.isEmpty || $0.title.localizedStandardContains(search) }) { article in
                        Toggle(isOn: Binding(
                            get: { selectedSlugs.contains(article.slug) },
                            set: { if $0 { selectedSlugs.insert(article.slug) } else { selectedSlugs.remove(article.slug) } }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(article.title).lineLimit(1)
                                Text(article.category).font(.caption).foregroundStyle(.secondary)
                            }
                        }.toggleStyle(.checkbox)
                    }.listStyle(.bordered).disabled(job.isExporting)
                } else {
                    Text(articles.first?.title ?? "").font(.headline)
                    Spacer()
                }
                if job.isExporting {
                    ProgressView(value: Double(job.completed), total: Double(max(1, selected.count)))
                    Text(job.currentTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let error = job.error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            }
            Divider()
            HStack {
                if job.isExporting {
                    Button("取消导出") { job.cancel() }.disabled(job.isCancelling)
                }
                Spacer()
                Button(job.output == nil ? "关闭" : "完成") { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(job.isExporting)
                if job.output == nil {
                    Button("导出…") { job.chooseDestination(articles: selected, store: store, format: format, includeMetadata: includeMetadata) }
                        .keyboardShortcut(.defaultAction).disabled(selectedSlugs.isEmpty || job.isExporting)
                }
            }
        }
        .padding(24)
        .frame(width: 600, height: articles.count > 1 ? 620 : 420)
        .disabled(job.isChoosingDestination)
        .interactiveDismissDisabled(job.isExporting || job.isChoosingDestination)
        .onDisappear { job.cancel() }
    }
}

@MainActor
final class ArticleExportJob: ObservableObject {
    @Published private(set) var isExporting = false
    @Published private(set) var isChoosingDestination = false
    @Published private(set) var isCancelling = false
    @Published private(set) var completed = 0
    @Published private(set) var currentTitle = ""
    @Published private(set) var error: String?
    @Published private(set) var output: URL?
    private var task: Task<Void, Never>?

    func chooseDestination(articles: [NativeArticleSummary], store: LocalBlogStore, format: ArticleExportFormat, includeMetadata: Bool) {
        guard !articles.isEmpty, !isExporting, !isChoosingDestination else { return }
        let panel = NSSavePanel()
        let ext = format.fileExtension(count: articles.count)
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (articles.count == 1 ? ArticleExportDocument.filename(articles[0].title, fallback: "Article") : "LeonBook Articles") + "." + ext
        panel.title = NativeLocalization.text("导出文章")
        isChoosingDestination = true
        panel.begin { [weak self] response in
            guard let self else { return }
            self.isChoosingDestination = false
            guard response == .OK, let url = panel.url else { return }
            self.start(slugs: articles.map(\.slug), store: store, format: format, includeMetadata: includeMetadata, destination: url)
        }
    }

    private func start(slugs: [String], store: LocalBlogStore, format: ArticleExportFormat, includeMetadata: Bool, destination: URL) {
        isExporting = true; isCancelling = false; error = nil; completed = 0; output = nil
        task = Task { [self] in
            defer { isExporting = false; isCancelling = false; task = nil }
            do {
                try await ArticleExportService.export(slugs: slugs, store: store, format: format, includeMetadata: includeMetadata, destination: destination) { [weak self] completed, title in
                    self?.completed = completed; self?.currentTitle = title
                }
                output = destination
            } catch is CancellationError { /* Keep the sheet open for another attempt. */ }
            catch { self.error = error.localizedDescription }
        }
    }

    func cancel() { if isExporting { isCancelling = true; task?.cancel() } }
}
