import SwiftUI

struct MomentCommentsView: View {
    @Environment(\.nativeAppPalette) private var appPalette

    @ObservedObject var model: NativeAppModel
    let moment: NativeMoment
    let store: LocalBlogStore
    @Environment(\.dismiss) private var dismiss
    @State private var comments: [NativeMomentComment] = []
    @State private var text = ""
    @State private var replyingTo: NativeMomentComment?
    @State private var pendingDeletion: NativeMomentComment?
    @State private var isLoading = true
    @State private var isMutating = false
    @State private var errorMessage: String?
    @FocusState private var isComposerFocused: Bool

    private var isBusy: Bool {
        isLoading || isMutating || model.isSavingMomentComment || model.isBackingUp
            || model.isRestoringBackup || model.isSwitchingWorkspace
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("微博评论", nativeIcon: "text.bubble")
                    .font(.headline)
                Text("\(comments.count)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isMutating)
            }
            .padding(20)

            VStack(alignment: .leading, spacing: 6) {
                if !moment.displayContent.text.isEmpty {
                    Text(moment.displayContent.text)
                        .lineLimit(3)
                }
                Text(moment.createdAt.nativeDateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            Divider()
            commentList
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let errorMessage {
                HStack(alignment: .top) {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Spacer()
                    Button("重试") { Task { await loadComments() } }
                        .disabled(isBusy)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            Divider()
            composer.padding(20)
        }
        .frame(width: 580, height: 680)
        .background(appPalette.surface)
        .interactiveDismissDisabled(isMutating)
        .task {
            await loadComments()
            isComposerFocused = true
        }
        .onChange(of: model.workspaceGeneration) { _ in dismiss() }
        .alert(item: $pendingDeletion) { comment in
            Alert(
                title: Text("删除这条评论？"),
                message: Text("该评论下的回复也会一并删除。"),
                primaryButton: .destructive(Text("删除")) {
                    Task { await deleteComment(comment) }
                },
                secondaryButton: .cancel()
            )
        }
    }

    @ViewBuilder
    private var commentList: some View {
        if isLoading && comments.isEmpty {
            ProgressView("正在加载评论…")
        } else if comments.isEmpty {
            VStack(spacing: 10) {
                NativeIcon.image("text.bubble", size: 32)
                    .foregroundStyle(.secondary)
                Text("还没有评论").font(.headline)
                Text("写下想法，开始这条微博的讨论。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            let commentsByID = Dictionary(uniqueKeysWithValues: comments.map { ($0.id, $0) })
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(comments) { comment in
                        MomentCommentRow(
                            comment: comment,
                            parent: comment.parentID.flatMap { commentsByID[$0] },
                            canDelete: comment.authorName == model.currentUser.name,
                            onReply: {
                                replyingTo = comment
                                isComposerFocused = true
                            },
                            onDelete: { pendingDeletion = comment }
                        )
                        .disabled(isBusy)
                    }
                }
                .padding(20)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let replyingTo {
                HStack {
                    Label(NativeLocalization.text("回复 \(replyingTo.authorName)"), nativeIcon: "arrowshape.turn.up.left", iconSize: 12)
                        .font(.caption.weight(.medium))
                    Spacer()
                    Button("取消回复") { self.replyingTo = nil }
                        .buttonStyle(.plain)
                }
                Text(replyingTo.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            TextEditor(text: $text)
                .font(.body)
                .frame(height: 86)
                .padding(6)
                .scrollContentBackground(.hidden)
                .background(appPalette.canvas, in: RoundedRectangle(cornerRadius: 8))
                .focused($isComposerFocused)
                .accessibilityLabel("评论内容")
                .onChange(of: text) { value in
                    if value.count > 2_000 { text = String(value.prefix(2_000)) }
                }

            HStack {
                Text("\(text.count)/2000")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if isMutating { ProgressView().controlSize(.small) }
                Button(LocalizedStringKey(replyingTo == nil ? "发表评论" : "回复")) {
                    Task { await submitComment() }
                }
                .nativePrimaryButton()
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .disabled(isBusy)
    }

    @MainActor
    private func loadComments() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await store.listMomentComments(momentID: moment.id)
            guard !Task.isCancelled, model.store === store else { return }
            comments = loaded
            model.updateMomentCommentCount(momentID: moment.id, count: loaded.count)
            if let replyingTo, !loaded.contains(where: { $0.id == replyingTo.id }) {
                self.replyingTo = nil
            }
            errorMessage = nil
        } catch {
            guard !Task.isCancelled, model.store === store else { return }
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func submitComment() async {
        guard !isBusy, model.store === store else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            try await model.createMomentComment(momentID: moment.id, text: text, parentID: replyingTo?.id)
            text = ""
            replyingTo = nil
            await loadComments()
            isComposerFocused = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func deleteComment(_ comment: NativeMomentComment) async {
        guard !isBusy, model.store === store else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            try await model.deleteMomentComment(comment)
            await loadComments()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct MomentCommentRow: View {
    @Environment(\.nativeAppPalette) private var appPalette

    let comment: NativeMomentComment
    let parent: NativeMomentComment?
    let canDelete: Bool
    let onReply: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(String(comment.authorName.prefix(1)).uppercased())
                    .font(.caption.bold())
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.15), in: Circle())
                Text(comment.authorName).font(.callout.weight(.semibold))
                Spacer()
                Text(comment.createdAt.nativeDateLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if canDelete {
                    Button(role: .destructive, action: onDelete) {
                        NativeIcon.image("trash")
                    }
                    .buttonStyle(.plain)
                    .help("删除评论")
                    .accessibilityLabel("删除评论")
                }
            }
            if let parent {
                VStack(alignment: .leading, spacing: 4) {
                    Label(NativeLocalization.text("回复 \(parent.authorName)"), nativeIcon: "arrowshape.turn.up.left")
                    Text(parent.text).lineLimit(2)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
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
        .padding(12)
        .background(appPalette.canvas, in: RoundedRectangle(cornerRadius: 10))
    }
}
