import AppKit
import SwiftUI

struct TrashView: View {
    @ObservedObject var model: NativeAppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("回收站")
                        .font(.title2.weight(.semibold))
                    Text("删除的文章和微博会保留 30 天，之后自动永久删除。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("清空回收站", role: .destructive, action: confirmEmptyTrash)
                    .disabled(model.trashItems.isEmpty || model.isLoading)
            }
            .padding(22)
            Divider()

            if model.trashItems.isEmpty {
                EmptyState(
                    title: "回收站是空的",
                    message: "删除的文章和微博会先出现在这里。",
                    actionTitle: "返回概览"
                ) {
                    model.section = .dashboard
                }
            } else {
                List(model.trashItems) { item in
                    TrashRow(
                        item: item,
                        onRestore: { model.restoreTrash(item) },
                        onPermanentDelete: { confirmPermanentDelete(item) }
                    )
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 7, leading: 18, bottom: 7, trailing: 18))
                }
                .listStyle(.plain)
            }
        }
    }

    private func confirmPermanentDelete(_ item: NativeTrashItem) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "彻底删除“\(item.title)”？"
        alert.informativeText = "内容和关联的本地媒体会立即永久删除，无法恢复。"
        alert.addButton(withTitle: "永久删除")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.permanentlyDeleteTrash(item)
    }

    private func confirmEmptyTrash() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清空回收站？"
        alert.informativeText = "回收站中的所有文章、微博和关联媒体都会立即永久删除，无法恢复。"
        alert.addButton(withTitle: "清空回收站")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.emptyTrash()
    }
}

private struct TrashRow: View {
    let item: NativeTrashItem
    let onRestore: () -> Void
    let onPermanentDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.orange.opacity(0.12))
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: item.kind.systemImage)
                        .foregroundStyle(.orange)
                }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.headline)
                    Text(item.kind.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
                Text(item.preview.isEmpty ? "无摘要" : item.preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("删除于 \(item.deletedAt.nativeDateLabel) · 将于 \(item.expiresAt.nativeDateLabel) 自动永久删除")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Button("恢复", action: onRestore)
                    .buttonStyle(.bordered)
                Button("永久删除", role: .destructive, action: onPermanentDelete)
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary)
                .allowsHitTesting(false)
        }
    }
}
