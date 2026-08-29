import Combine
import Foundation

@MainActor
final class NativeEditorSessionState: ObservableObject {
    @Published var draft: NativeEditorDraft
    @Published var bodySelection: NSRange
    @Published var autosaveStatus: String
    @Published var isAutosaving: Bool

    init(
        draft: NativeEditorDraft = NativeEditorDraft(),
        bodySelection: NSRange = NSRange(location: 0, length: 0),
        autosaveStatus: String = "尚未自动保存",
        isAutosaving: Bool = false
    ) {
        self.draft = draft
        self.bodySelection = bodySelection
        self.autosaveStatus = autosaveStatus
        self.isAutosaving = isAutosaving
    }
}

struct NativeMarkdownRefreshPlan: Equatable {
    let reloadsArticleList: Bool
    let reloadsSelectedArticle: Bool
    let reloadsSelectedSmartCollection: Bool
    let reloadsKnowledgeGraph: Bool
    let reloadsTrash: Bool
    let reloadsMoments: Bool
    let reloadsQuestions: Bool
    let reloadsActivity: Bool

    init(result: NativeMarkdownSyncResult, selectedArticleSlug: String?) {
        let changed = result.didChange
        let affectedSlugs = Set(result.affectedArticleSlugs)
        reloadsArticleList = changed
        reloadsSelectedArticle = selectedArticleSlug.map(affectedSlugs.contains) ?? false
        reloadsSelectedSmartCollection = changed
        reloadsKnowledgeGraph = changed
        reloadsTrash = result.deletedCount > 0
        reloadsMoments = false
        reloadsQuestions = false
        reloadsActivity = false
    }
}

struct NativeMomentTimelineGroup: Identifiable {
    let id: String
    let label: String
    var moments: [NativeMoment]
}

struct NativeMomentTagFilter: Identifiable, Hashable {
    let tag: String
    let count: Int

    var id: String {
        tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

struct NativeArticleTagFilter: Identifiable, Hashable {
    let tag: String
    let count: Int

    var id: String {
        tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

struct NativeArticleFolderFilter: Identifiable, Hashable {
    let path: String
    let count: Int

    var id: String { path }
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    var depth: Int { max(0, path.split(separator: "/").count - 1) }
}

struct NativeArticleSourceConflict: Identifiable {
    let external: NativeArticle
    let local: NativeArticleRevisionSnapshot

    var id: String { external.slug }
}

struct NativeArticleNavigationSnapshot: Codable {
    let tabs: [NativeArticleTab]
    let activeTabID: UUID?
    let recentSlugs: [String]
}

enum NativeArticleOpenDisposition {
    case currentTab
    case newTab
    case refreshActiveTab
}
