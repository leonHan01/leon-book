import SwiftUI

/// Tokens keep overlapping requests from dismissing each other's feedback.
struct NativeLoadingOperations {
    enum Kind: String {
        case article, articleEdit, articleDetails, history, dashboard, questions, graph, refresh, trash, resources, backupOverview

        var title: String {
            switch self {
            case .article: return NativeLocalization.text("正在打开文章…")
            case .articleEdit: return NativeLocalization.text("正在更新文章…")
            case .articleDetails: return NativeLocalization.text("正在加载评论和关联文章…")
            case .history: return NativeLocalization.text("正在加载版本历史…")
            case .dashboard: return NativeLocalization.text("正在加载首页…")
            case .questions: return NativeLocalization.text("正在加载问题…")
            case .graph: return NativeLocalization.text("正在加载关系图…")
            case .refresh: return NativeLocalization.text("正在刷新…")
            case .trash: return NativeLocalization.text("正在处理回收站…")
            case .resources: return NativeLocalization.text("正在处理文件…")
            case .backupOverview: return NativeLocalization.text("正在读取备份快照…")
            }
        }
    }

    private var requests: [(id: UUID, kind: Kind)] = []
    var current: Kind? { requests.last?.kind }
    func contains(_ kind: Kind) -> Bool { requests.contains { $0.kind == kind } }

    mutating func begin(_ kind: Kind) -> UUID {
        let id = UUID()
        requests.append((id, kind))
        return id
    }

    mutating func end(_ id: UUID) { requests.removeAll { $0.id == id } }
    mutating func reset() { requests.removeAll() }
}

struct NativeLoadingStatus: View {
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(verbatim: title).font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("loading-status")
    }
}

struct NativeLoadingPlaceholder: View {
    let title: String

    var body: some View {
        NativeLoadingStatus(title: title)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 140)
    }
}

/// Keep useful content visible during refresh. Fast operations never flash a
/// spinner; cancellation and disappearance cannot reveal a stale indicator.
private struct NativeLoadingFeedback: ViewModifier {
    let title: String?
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if let title, isVisible {
                NativeLoadingStatus(title: title)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(14)
                    .allowsHitTesting(false)
            }
        }
        .task(id: title != nil) {
            isVisible = false
            guard title != nil else { return }
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
                try Task.checkCancellation()
                isVisible = true
            } catch { }
        }
    }
}

extension View {
    func nativeLoadingFeedback(_ title: String?) -> some View {
        modifier(NativeLoadingFeedback(title: title))
    }
}

extension NativeAppModel {
    var loadingFeedbackTitle: String? {
        if isRestoringBackup { return NativeLocalization.text("正在恢复备份…") }
        if isSwitchingWorkspace { return NativeLocalization.text("正在切换工作区…") }
        if isImportingObsidianVault { return NativeLocalization.text("正在导入文件…") }
        if isScanningObsidianVault { return NativeLocalization.text("正在扫描文件…") }
        if isBackingUp { return NativeLocalization.text("正在备份…") }
        if isValidatingBackup { return NativeLocalization.text("正在校验备份…") }
        if isUploadingMedia { return NativeLocalization.text("正在导入媒体…") }
        if isSaving || isSavingDashboard || isRenamingArticleProperty { return NativeLocalization.text("正在保存…") }
        if isPublishingMoment || isPublishingQuestion || isPublishingQuestionAnswer {
            return NativeLocalization.text("正在发布…")
        }
        if isSavingArticleComment || isSavingMomentComment { return NativeLocalization.text("正在保存评论…") }
        if let operation = loadingOperations.current { return operation.title }
        if isLoadingMoreMoments { return NativeLocalization.text("正在加载微博…") }
        if isLoading { return NativeLocalization.text("正在加载…") }
        if isSynchronizingPortableSidecar { return NativeLocalization.text("正在同步…") }
        return nil
    }
}
