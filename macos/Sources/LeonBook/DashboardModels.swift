import Foundation
import Combine

enum NativeDashboardModuleKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case text, image, audio, video, article, todos, quickNote, statistics, recentArticles, activity

    var id: String { rawValue }
    var title: String {
        switch self {
        case .text: return "文字 / Markdown"
        case .image: return "图片"
        case .audio: return "音频 / MP3"
        case .video: return "视频"
        case .article: return "文章内容"
        case .todos: return "待办清单"
        case .quickNote: return "快速写作"
        case .statistics: return "内容统计"
        case .recentArticles: return "最近编辑"
        case .activity: return "创作活动"
        }
    }
    var subtitle: String {
        switch self {
        case .text: return "写下介绍、灵感或一段 Markdown"
        case .image: return "展示照片、插画与图片说明"
        case .audio: return "播放音乐、播客或本地录音"
        case .video: return "在首页播放本地视频"
        case .article: return "固定一篇文章，展示最新正文"
        case .todos: return "添加和勾选待办，与待办页同步"
        case .quickNote: return "随时开始一篇新文章"
        case .statistics: return "查看文章、草稿和微博数量"
        case .recentArticles: return "继续最近编辑的文章"
        case .activity: return "回顾过去一年的创作记录"
        }
    }
    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "play.rectangle"
        case .article: return "doc.text"
        case .todos: return "checklist"
        case .quickNote: return "square.and.pencil"
        case .statistics: return "chart.bar"
        case .recentArticles: return "clock"
        case .activity: return "calendar"
        }
    }
    var isMedia: Bool { self == .image || self == .audio || self == .video }
}

enum NativeDashboardModuleWidth: String, Codable, CaseIterable, Identifiable, Sendable {
    case full, half
    var id: String { rawValue }
    var title: String { self == .full ? "整行" : "半宽" }
}

struct NativeDashboardModule: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var kind: NativeDashboardModuleKind
    var title = ""
    var width = NativeDashboardModuleWidth.full
    var text = ""
    var media: NativeMedia?
    var articleSlug = ""
    var itemLimit = 5
    var showsCompletedTodos = false
    // Optional grid dimensions keep existing full/half-width documents readable.
    // A missing height follows the content, rounded up to the vertical grid.
    var columnSpan: Int?
    var heightRows: Int?

    var preferredColumnSpan: Int { columnSpan ?? (width == .half ? 6 : 12) }

    mutating func setColumnSpan(_ columns: Int) {
        columnSpan = columns
        width = columns <= 6 ? .half : .full
    }

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? NativeLocalization.string(kind.title, language: NativeLocalization.currentLanguage) : title
    }
}

struct NativeDashboardDocument: Codable, Equatable, Sendable {
    var version = 1
    var revision = 0
    // Empty values retain the localized welcome text for new workspaces.
    var title = ""
    var subtitle = ""
    var modules: [NativeDashboardModule] = []

    static let standard = NativeDashboardDocument(modules: [
        NativeDashboardModule(kind: .quickNote),
        NativeDashboardModule(kind: .statistics),
        NativeDashboardModule(kind: .recentArticles),
        NativeDashboardModule(kind: .activity),
    ])

    func validated() throws -> Self {
        guard version == 1 else { throw NativeDashboardError.unsupportedVersion }
        guard revision >= 0, revision < Int.max, modules.count <= 100,
              Set(modules.map(\.id)).count == modules.count,
              title.count <= 200, subtitle.count <= 1_000,
              modules.allSatisfy({ module in
                  module.title.count <= 200 && module.text.count <= 100_000
                      && (1...20).contains(module.itemLimit)
                      && (module.columnSpan.map { NativeDashboardGridMetrics.columnRange.contains($0) } ?? true)
                      && (module.heightRows.map { NativeDashboardGridMetrics.heightRange.contains($0) } ?? true)
                      && (module.media == nil || (module.kind.isMedia && module.media?.kind == module.kind.rawValue))
              }) else { throw NativeDashboardError.invalidDocument }
        return self
    }

    mutating func move(_ id: UUID, by offset: Int) {
        guard let source = modules.firstIndex(where: { $0.id == id }),
              modules.indices.contains(source + offset) else { return }
        modules.swapAt(source, source + offset)
    }

    /// A drop takes the target's original slot: after it when dragging down,
    /// before it when dragging up. This also makes the final slot reachable.
    mutating func move(_ id: UUID, onto target: UUID) {
        guard id != target, let source = modules.firstIndex(where: { $0.id == id }),
              let destination = modules.firstIndex(where: { $0.id == target }) else { return }
        let module = modules.remove(at: source)
        modules.insert(module, at: destination)
    }

    /// Preserve reading order when wrapping grid spans into rows.
    func rows(compact: Bool) -> [[NativeDashboardModule]] {
        var result: [[NativeDashboardModule]] = []
        for module in modules {
            if !compact, let last = result.last,
               last.reduce(0, { $0 + $1.preferredColumnSpan }) + module.preferredColumnSpan <= 12 {
                result[result.count - 1].append(module)
            } else {
                result.append([module])
            }
        }
        return result
    }
}

enum NativeDashboardError: LocalizedError {
    case unsupportedVersion, invalidDocument, conflict
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return NativeLocalization.string(NativeLocalization.text("首页配置来自更新版本，请升级后再编辑。"), language: NativeLocalization.currentLanguage)
        case .invalidDocument: return NativeLocalization.string(NativeLocalization.text("首页配置无法读取或内容超出限制，原有配置已保留。"), language: NativeLocalization.currentLanguage)
        case .conflict: return NativeLocalization.string(NativeLocalization.text("首页已在其他窗口更新。请取消编辑后重新修改，避免覆盖最新内容。"), language: NativeLocalization.currentLanguage)
        }
    }
}

/// Keep unfinished layout edits while navigating to an article or another page.
@MainActor
final class NativeDashboardEditingState: ObservableObject {
    @Published var draft: NativeDashboardDocument?

    func dropModule(_ id: UUID, onto target: UUID) {
        draft?.move(id, onto: target)
    }

    func update(_ module: NativeDashboardModule) {
        guard let index = draft?.modules.firstIndex(where: { $0.id == module.id }) else { return }
        draft?.modules[index] = module
    }

    func resizeModule(_ resized: NativeDashboardModule) {
        guard let index = draft?.modules.firstIndex(where: { $0.id == resized.id }) else { return }
        // A resize only owns dimensions, never content changed elsewhere.
        draft?.modules[index].width = resized.width
        draft?.modules[index].columnSpan = resized.columnSpan
        draft?.modules[index].heightRows = resized.heightRows
    }
}
