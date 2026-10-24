import Foundation

public enum NativeArticleLibraryLayout: String, Codable, CaseIterable, Hashable, Identifiable {
    case list
    case table
    case cards
    case board
    case calendar

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .list: return "列表"
        case .table: return "表格"
        case .cards: return "卡片"
        case .board: return "看板"
        case .calendar: return "日历"
        }
    }

    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .table: return "tablecells"
        case .cards: return "rectangle.grid.2x2"
        case .board: return "rectangle.3.group"
        case .calendar: return "calendar"
        }
    }
}

public enum NativeArticleGroupField: String, Codable, CaseIterable, Hashable, Identifiable {
    case none
    case status
    case category
    case tag
    case updatedMonth

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "不分组"
        case .status: return "状态"
        case .category: return "分类"
        case .tag: return "首个标签"
        case .updatedMonth: return "更新月份"
        }
    }

    func label(for article: NativeArticleSummary) -> String {
        switch self {
        case .none: return "全部"
        case .status: return article.status.label
        case .category: return article.category.isEmpty ? "未分类" : article.category
        case .tag: return article.tags.first.map { "#\($0)" } ?? "无标签"
        case .updatedMonth:
            guard let date = NativeTimestamp.date(from: article.updatedAt) else { return "日期未知" }
            return date.formatted(.dateTime.year().month(.wide).locale(NativeLocalization.currentLanguage.locale))
        }
    }
}

