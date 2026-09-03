import AppKit
import SwiftUI

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
                Text(LocalizedStringKey(revision.reason.label))
                    .font(.subheadline.weight(.medium))
            }
            Text(revision.updatedAt.nativeDateLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Group {
                if revision.snapshot.title.isEmpty {
                    Text("未命名文章")
                } else {
                    Text(revision.snapshot.title)
                }
            }
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
    let title: LocalizedStringKey
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
