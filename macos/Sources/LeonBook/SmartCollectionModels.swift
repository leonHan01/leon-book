import Foundation

public enum NativeSmartCollectionLayout: String, Codable, CaseIterable, Hashable, Identifiable {
    case list
    case table
    case cards

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .list: return "列表"
        case .table: return "表格"
        case .cards: return "卡片"
        }
    }

    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .table: return "tablecells"
        case .cards: return "rectangle.grid.2x2"
        }
    }
}

public enum NativeSmartCollectionMatchMode: String, Codable, CaseIterable, Hashable, Identifiable {
    case all
    case any

    public var id: String { rawValue }
    var label: String { self == .all ? "满足全部条件" : "满足任一条件" }
}

public enum NativeSmartCollectionField: String, Codable, CaseIterable, Hashable, Identifiable {
    case title
    case content
    case status
    case category
    case tag
    case property
    case updatedAt
    case publishedAt
    case wordCount
    case pageViews
    case sourcePath

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .title: return "标题"
        case .content: return "正文或摘要"
        case .status: return "状态"
        case .category: return "分类"
        case .tag: return "标签"
        case .property: return "属性"
        case .updatedAt: return "更新时间"
        case .publishedAt: return "发布时间"
        case .wordCount: return "字数"
        case .pageViews: return "阅读量"
        case .sourcePath: return "Markdown 路径"
        }
    }

    var isDate: Bool { self == .updatedAt || self == .publishedAt }
    var isNumber: Bool { self == .wordCount || self == .pageViews }
}

public enum NativeSmartCollectionOperator: String, Codable, CaseIterable, Hashable, Identifiable {
    case contains
    case equals
    case notEquals
    case before
    case after
    case lessThan
    case greaterThan
    case atMost
    case atLeast
    case startsWith
    case isEmpty
    case isNotEmpty

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .contains: return "包含"
        case .equals: return "等于"
        case .notEquals: return "不等于"
        case .before: return "早于"
        case .after: return "晚于"
        case .lessThan: return "小于"
        case .greaterThan: return "大于"
        case .atMost: return "小于等于"
        case .atLeast: return "大于等于"
        case .startsWith: return "开头是"
        case .isEmpty: return "为空"
        case .isNotEmpty: return "不为空"
        }
    }

    var needsValue: Bool { self != .isEmpty && self != .isNotEmpty }
}

public struct NativeSmartCollectionRule: Codable, Hashable, Identifiable {
    public var id: UUID
    public var field: NativeSmartCollectionField
    public var comparison: NativeSmartCollectionOperator
    public var value: String
    public var propertyKey: String

    public init(
        id: UUID = UUID(),
        field: NativeSmartCollectionField = .status,
        comparison: NativeSmartCollectionOperator = .equals,
        value: String = NativeArticleStatus.published.rawValue,
        propertyKey: String = ""
    ) {
        self.id = id
        self.field = field
        self.comparison = comparison
        self.value = value
        self.propertyKey = propertyKey
    }

    var compatibleOperators: [NativeSmartCollectionOperator] {
        if field.isDate { return [.after, .before, .atLeast, .atMost, .isEmpty, .isNotEmpty] }
        if field.isNumber { return [.greaterThan, .lessThan, .atLeast, .atMost, .equals, .notEquals] }
        if field == .status { return [.equals, .notEquals] }
        if field == .sourcePath { return [.contains, .startsWith, .equals, .notEquals, .isEmpty, .isNotEmpty] }
        return [.contains, .equals, .notEquals, .startsWith, .isEmpty, .isNotEmpty]
    }

    var isValid: Bool {
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKey = propertyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return (!comparison.needsValue || !normalizedValue.isEmpty)
            && (field != .property || !normalizedKey.isEmpty)
    }
}

public enum NativeArticleSortField: String, Codable, CaseIterable, Hashable, Identifiable {
    case updatedAt
    case publishedAt
    case title
    case category
    case status
    case wordCount
    case pageViews

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .updatedAt: return "更新时间"
        case .publishedAt: return "发布时间"
        case .title: return "标题"
        case .category: return "分类"
        case .status: return "状态"
        case .wordCount: return "字数"
        case .pageViews: return "阅读量"
        }
    }
}

public struct NativeArticleSortDescriptor: Codable, Hashable, Identifiable {
    public var id: UUID
    public var field: NativeArticleSortField
    public var ascending: Bool

    public init(id: UUID = UUID(), field: NativeArticleSortField = .updatedAt, ascending: Bool = false) {
        self.id = id
        self.field = field
        self.ascending = ascending
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
            let components = Calendar.current.dateComponents([.year, .month], from: date)
            return "\(components.year ?? 0)年\(components.month ?? 0)月"
        }
    }
}

public enum NativeSmartCollectionColumnSource: String, Codable, CaseIterable, Hashable, Identifiable {
    case system
    case property
    case formula

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "文章字段"
        case .property: return "Property"
        case .formula: return "公式"
        }
    }
}

public enum NativeSmartCollectionSystemField: String, Codable, CaseIterable, Hashable, Identifiable {
    case title
    case status
    case category
    case tags
    case wordCount
    case pageViews
    case updatedAt
    case publishedAt
    case sourcePath

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .title: return "标题"
        case .status: return "状态"
        case .category: return "分类"
        case .tags: return "标签"
        case .wordCount: return "字数"
        case .pageViews: return "阅读量"
        case .updatedAt: return "更新时间"
        case .publishedAt: return "发布时间"
        case .sourcePath: return "Markdown 路径"
        }
    }
}

public enum NativeSmartCollectionSummary: String, Codable, CaseIterable, Hashable, Identifiable {
    case filled
    case empty
    case unique
    case sum
    case average
    case minimum
    case maximum
    case earliest
    case latest
    case checked
    case unchecked

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .filled: return "已填写"
        case .empty: return "空值"
        case .unique: return "唯一值"
        case .sum: return "求和"
        case .average: return "平均值"
        case .minimum: return "最小值"
        case .maximum: return "最大值"
        case .earliest: return "最早日期"
        case .latest: return "最晚日期"
        case .checked: return "已选中"
        case .unchecked: return "未选中"
        }
    }

    var baseName: String {
        switch self {
        case .filled: return "Filled"
        case .empty: return "Empty"
        case .unique: return "Unique"
        case .sum: return "Sum"
        case .average: return "Average"
        case .minimum: return "Min"
        case .maximum: return "Max"
        case .earliest: return "Earliest"
        case .latest: return "Latest"
        case .checked: return "Checked"
        case .unchecked: return "Unchecked"
        }
    }
}

public struct NativeSmartCollectionColumn: Codable, Hashable, Identifiable {
    public var id: UUID
    public var source: NativeSmartCollectionColumnSource
    public var key: String
    public var title: String
    public var width: Double
    public var isHidden: Bool
    public var propertyKind: NativeArticlePropertyKind
    public var summary: NativeSmartCollectionSummary?
    public var basePropertyOverride: String?

    public init(
        id: UUID = UUID(),
        source: NativeSmartCollectionColumnSource,
        key: String,
        title: String = "",
        width: Double = 140,
        isHidden: Bool = false,
        propertyKind: NativeArticlePropertyKind = .text,
        summary: NativeSmartCollectionSummary? = nil,
        basePropertyOverride: String? = nil
    ) {
        self.id = id
        self.source = source
        self.key = key
        self.title = title
        self.width = min(max(width, 80), 480)
        self.isHidden = isHidden
        self.propertyKind = propertyKind
        self.summary = summary
        self.basePropertyOverride = basePropertyOverride
    }

    public static func system(
        _ field: NativeSmartCollectionSystemField,
        width: Double = 140,
        summary: NativeSmartCollectionSummary? = nil
    ) -> Self {
        Self(source: .system, key: field.rawValue, title: field.label, width: width, summary: summary)
    }

    var displayTitle: String {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty { return normalized }
        if source == .system,
           let field = NativeSmartCollectionSystemField(rawValue: key) { return field.label }
        return key.isEmpty ? "未命名列" : key
    }

    var basePropertyName: String {
        if let basePropertyOverride,
           !basePropertyOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return basePropertyOverride
        }
        switch source {
        case .system:
            switch NativeSmartCollectionSystemField(rawValue: key) {
            case .title: return "file.name"
            case .updatedAt: return "file.mtime"
            case .sourcePath: return "file.path"
            default: return "note.\(key)"
            }
        case .property: return "note.\(key)"
        case .formula: return "formula.\(key)"
        }
    }
}

public struct NativeSmartCollectionFormula: Codable, Hashable, Identifiable {
    public var id: UUID
    public var key: String
    public var name: String
    public var expression: String

    public init(
        id: UUID = UUID(),
        key: String = "formula",
        name: String = "公式",
        expression: String = "0"
    ) {
        self.id = id
        self.key = key
        self.name = name
        self.expression = expression
    }

    var isValid: Bool {
        !key.isEmpty
            && (key.first?.isLetter == true || key.first == "_")
            && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            && !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The recursive filter shape used by standard Obsidian Bases. Raw expressions
/// are retained when LeonBook cannot evaluate a plugin-provided function yet;
/// this keeps the `.base` round-trip lossless while query execution remains
/// conservative instead of accidentally showing unrelated notes.
public indirect enum NativeSmartCollectionFilter: Codable, Hashable {
    case rule(NativeSmartCollectionRule)
    case expression(String)
    case and([NativeSmartCollectionFilter])
    case or([NativeSmartCollectionFilter])
    case not([NativeSmartCollectionFilter])

    private enum CodingKeys: String, CodingKey { case kind, rule, expression, children }
    private enum Kind: String, Codable { case rule, expression, and, or, not }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .rule:
            self = .rule(try container.decode(NativeSmartCollectionRule.self, forKey: .rule))
        case .expression:
            self = .expression(try container.decode(String.self, forKey: .expression))
        case .and:
            self = .and(try container.decode([Self].self, forKey: .children))
        case .or:
            self = .or(try container.decode([Self].self, forKey: .children))
        case .not:
            self = .not(try container.decode([Self].self, forKey: .children))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .rule(rule):
            try container.encode(Kind.rule, forKey: .kind)
            try container.encode(rule, forKey: .rule)
        case let .expression(expression):
            try container.encode(Kind.expression, forKey: .kind)
            try container.encode(expression, forKey: .expression)
        case let .and(children):
            try container.encode(Kind.and, forKey: .kind)
            try container.encode(children, forKey: .children)
        case let .or(children):
            try container.encode(Kind.or, forKey: .kind)
            try container.encode(children, forKey: .children)
        case let .not(children):
            try container.encode(Kind.not, forKey: .kind)
            try container.encode(children, forKey: .children)
        }
    }

    var ruleCount: Int {
        switch self {
        case .rule: return 1
        case .expression: return 0
        case let .and(children), let .or(children), let .not(children):
            return children.reduce(0) { $0 + $1.ruleCount }
        }
    }

    var expressionCount: Int {
        switch self {
        case .rule: return 0
        case .expression: return 1
        case let .and(children), let .or(children), let .not(children):
            return children.reduce(0) { $0 + $1.expressionCount }
        }
    }

    var allRulesAreValid: Bool {
        switch self {
        case let .rule(rule): return rule.isValid
        case .expression: return true
        case let .and(children), let .or(children), let .not(children):
            return children.allSatisfy(\.allRulesAreValid)
        }
    }

    var legacyProjection: (mode: NativeSmartCollectionMatchMode, rules: [NativeSmartCollectionRule])? {
        switch self {
        case let .rule(rule): return (.all, [rule])
        case let .and(children):
            guard children.allSatisfy({ if case .rule = $0 { true } else { false } }) else { return nil }
            return (.all, children.compactMap { if case let .rule(rule) = $0 { rule } else { nil } })
        case let .or(children):
            guard children.allSatisfy({ if case .rule = $0 { true } else { false } }) else { return nil }
            return (.any, children.compactMap { if case let .rule(rule) = $0 { rule } else { nil } })
        case .expression, .not:
            return nil
        }
    }
}

public struct NativeSmartCollectionView: Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var baseType: String
    public var layout: NativeSmartCollectionLayout
    public var filter: NativeSmartCollectionFilter?
    public var sorts: [NativeArticleSortDescriptor]
    public var groupBy: NativeArticleGroupField
    public var columns: [NativeSmartCollectionColumn]
    public var limit: Int?

    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String = "视图",
        baseType: String? = nil,
        layout: NativeSmartCollectionLayout = .table,
        filter: NativeSmartCollectionFilter? = nil,
        sorts: [NativeArticleSortDescriptor] = [NativeArticleSortDescriptor()],
        groupBy: NativeArticleGroupField = .none,
        columns: [NativeSmartCollectionColumn] = NativeSmartCollection.defaultColumns,
        limit: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.baseType = baseType ?? layout.rawValue
        self.layout = layout
        self.filter = filter
        self.sorts = Array(sorts.prefix(3))
        self.groupBy = groupBy
        self.columns = Array(columns.prefix(30))
        self.limit = limit.map { max(1, $0) }
    }
}

public struct NativeSmartCollection: Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var matchMode: NativeSmartCollectionMatchMode
    public var rules: [NativeSmartCollectionRule]
    public var sorts: [NativeArticleSortDescriptor]
    public var groupBy: NativeArticleGroupField
    public var layout: NativeSmartCollectionLayout
    public var columns: [NativeSmartCollectionColumn]
    public var formulas: [NativeSmartCollectionFormula]
    public var filter: NativeSmartCollectionFilter?
    public var views: [NativeSmartCollectionView]
    public var activeViewID: String?
    public var sourceYAML: String?
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String = "新智能集合",
        matchMode: NativeSmartCollectionMatchMode = .all,
        rules: [NativeSmartCollectionRule] = [],
        sorts: [NativeArticleSortDescriptor] = [NativeArticleSortDescriptor()],
        groupBy: NativeArticleGroupField = .none,
        layout: NativeSmartCollectionLayout = .list,
        columns: [NativeSmartCollectionColumn] = NativeSmartCollection.defaultColumns,
        formulas: [NativeSmartCollectionFormula] = [],
        filter: NativeSmartCollectionFilter? = nil,
        views: [NativeSmartCollectionView] = [],
        activeViewID: String? = nil,
        sourceYAML: String? = nil,
        createdAt: String = NativeTimestamp.string(from: Date()),
        updatedAt: String = NativeTimestamp.string(from: Date())
    ) {
        self.id = id
        self.name = name
        self.matchMode = matchMode
        self.rules = rules
        self.sorts = Array(sorts.prefix(3))
        self.groupBy = groupBy
        self.layout = layout
        self.columns = Array(columns.prefix(30))
        self.formulas = Array(formulas.prefix(20))
        self.filter = filter
        self.views = views
        self.activeViewID = activeViewID
        self.sourceYAML = sourceYAML
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static var defaultColumns: [NativeSmartCollectionColumn] {
        [
            .system(.title, width: 220),
            .system(.status, width: 90),
            .system(.category, width: 120),
            .system(.tags, width: 160),
            .system(.updatedAt, width: 130),
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, matchMode, rules, sorts, groupBy, layout, columns, formulas
        case filter, views, activeViewID, sourceYAML, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased(),
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "新智能集合",
            matchMode: try container.decodeIfPresent(NativeSmartCollectionMatchMode.self, forKey: .matchMode) ?? .all,
            rules: try container.decodeIfPresent([NativeSmartCollectionRule].self, forKey: .rules) ?? [],
            sorts: try container.decodeIfPresent([NativeArticleSortDescriptor].self, forKey: .sorts)
                ?? [NativeArticleSortDescriptor()],
            groupBy: try container.decodeIfPresent(NativeArticleGroupField.self, forKey: .groupBy) ?? .none,
            layout: try container.decodeIfPresent(NativeSmartCollectionLayout.self, forKey: .layout) ?? .list,
            columns: try container.decodeIfPresent([NativeSmartCollectionColumn].self, forKey: .columns)
                ?? Self.defaultColumns,
            formulas: try container.decodeIfPresent([NativeSmartCollectionFormula].self, forKey: .formulas) ?? [],
            filter: try container.decodeIfPresent(NativeSmartCollectionFilter.self, forKey: .filter),
            views: try container.decodeIfPresent([NativeSmartCollectionView].self, forKey: .views) ?? [],
            activeViewID: try container.decodeIfPresent(String.self, forKey: .activeViewID),
            sourceYAML: try container.decodeIfPresent(String.self, forKey: .sourceYAML),
            createdAt: try container.decodeIfPresent(String.self, forKey: .createdAt)
                ?? NativeTimestamp.string(from: Date()),
            updatedAt: try container.decodeIfPresent(String.self, forKey: .updatedAt)
                ?? NativeTimestamp.string(from: Date())
        )
    }

    var selectedView: NativeSmartCollectionView? {
        if let activeViewID,
           let selected = views.first(where: { $0.id == activeViewID }) { return selected }
        return views.first
    }

    var effectiveFilter: NativeSmartCollectionFilter? {
        let global = filter ?? Self.legacyFilter(matchMode: matchMode, rules: rules)
        guard let viewFilter = selectedView?.filter else { return global }
        guard let global else { return viewFilter }
        return .and([global, viewFilter])
    }

    var unsupportedFilterExpressionCount: Int {
        effectiveFilter?.expressionCount ?? 0
    }

    var hasAdvancedFilter: Bool {
        guard let filter else { return false }
        return filter.legacyProjection == nil
    }

    public func materialized(viewID: String?) -> Self {
        var result = self
        let requested = viewID.flatMap { identifier in views.first(where: { $0.id == identifier }) }
        guard let view = requested ?? selectedView else { return result }
        result.activeViewID = view.id
        result.layout = view.layout
        result.sorts = view.sorts
        result.groupBy = view.groupBy
        result.columns = view.columns
        return result
    }

    mutating func synchronizeActiveView() {
        guard !views.isEmpty else { return }
        let index = activeViewID.flatMap { identifier in views.firstIndex(where: { $0.id == identifier }) } ?? 0
        views[index].layout = layout
        if NativeSmartCollectionLayout(rawValue: views[index].baseType) != nil {
            views[index].baseType = layout.rawValue
        }
        views[index].sorts = Array(sorts.prefix(3))
        views[index].groupBy = groupBy
        views[index].columns = Array(columns.prefix(30))
        activeViewID = views[index].id
    }

    static func legacyFilter(
        matchMode: NativeSmartCollectionMatchMode,
        rules: [NativeSmartCollectionRule]
    ) -> NativeSmartCollectionFilter? {
        guard !rules.isEmpty else { return nil }
        let children = rules.map(NativeSmartCollectionFilter.rule)
        return matchMode == .all ? .and(children) : .or(children)
    }
}

public enum NativeBookmarkTarget: Codable, Hashable {
    case article(slug: String)
    case heading(slug: String, heading: String, anchorID: String)
    case search(query: String)
    case graph

    var systemImage: String {
        switch self {
        case .article: return "doc.text"
        case .heading: return "textformat.size"
        case .search: return "magnifyingglass"
        case .graph: return "point.3.connected.trianglepath.dotted"
        }
    }
}

public struct NativeBookmark: Codable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var groupName: String
    public var target: NativeBookmarkTarget
    public var createdAt: String

    public init(
        id: String = UUID().uuidString.lowercased(),
        title: String,
        groupName: String = "",
        target: NativeBookmarkTarget,
        createdAt: String = NativeTimestamp.string(from: Date())
    ) {
        self.id = id
        self.title = title
        self.groupName = groupName
        self.target = target
        self.createdAt = createdAt
    }
}

public enum NativeSmartCollectionEvaluator {
    public static func articles(
        from source: [NativeArticle],
        matching collection: NativeSmartCollection
    ) -> [NativeArticle] {
        let filtered = source.filter { article in
            guard let filter = collection.effectiveFilter else { return true }
            return matches(article, filter: filter)
        }
        let sorts = collection.sorts.isEmpty
            ? [NativeArticleSortDescriptor()]
            : Array(collection.sorts.prefix(3))
        return filtered.sorted { lhs, rhs in
            for descriptor in sorts {
                let comparison = compare(lhs, rhs, field: descriptor.field)
                if comparison != .orderedSame {
                    return descriptor.ascending
                        ? comparison == .orderedAscending
                        : comparison == .orderedDescending
                }
            }
            return lhs.slug < rhs.slug
        }
    }

    private static func matches(_ article: NativeArticle, filter: NativeSmartCollectionFilter) -> Bool {
        switch filter {
        case let .rule(rule): return matches(article, rule: rule)
        case .expression: return false
        case let .and(children): return children.allSatisfy { matches(article, filter: $0) }
        case let .or(children): return children.contains { matches(article, filter: $0) }
        case let .not(children): return !children.contains { matches(article, filter: $0) }
        }
    }

    private static func matches(_ article: NativeArticle, rule: NativeSmartCollectionRule) -> Bool {
        if rule.field.isNumber {
            let number = rule.field == .wordCount
                ? Double(article.wordCount ?? NativeWritingMetrics.characterCount(of: article.body))
                : Double(article.pageViews)
            return compare(number, rule: rule)
        }

        if rule.field.isDate {
            let stored = rule.field == .updatedAt ? article.updatedAt : article.publishedAt
            if rule.comparison == .isEmpty { return stored == nil || stored?.isEmpty == true }
            if rule.comparison == .isNotEmpty { return stored?.isEmpty == false }
            guard let stored, let lhs = NativeTimestamp.date(from: stored), let rhs = parsedDate(rule.value) else {
                return false
            }
            switch rule.comparison {
            case .after, .atLeast: return lhs >= rhs
            case .before: return lhs < rhs
            case .atMost: return lhs <= rhs
            default: return false
            }
        }

        let candidates: [String]
        switch rule.field {
        case .title: candidates = [article.title]
        case .content: candidates = [article.body, article.excerpt]
        case .status: candidates = [article.status.rawValue]
        case .category: candidates = [article.category]
        case .tag: candidates = article.tags
        case .property:
            let key = folded(rule.propertyKey)
            candidates = article.properties.flatMap { propertyKey, propertyValue in
                folded(propertyKey) == key ? propertyValue.searchValues : []
            }
        case .sourcePath: candidates = [article.sourceRelativePath]
        case .updatedAt, .publishedAt, .wordCount, .pageViews:
            candidates = []
        }
        return compare(candidates, rule: rule)
    }

    private static func compare(_ candidates: [String], rule: NativeSmartCollectionRule) -> Bool {
        let values = candidates.map(folded)
        let expected = folded(rule.value)
        switch rule.comparison {
        case .contains: return values.contains { $0.contains(expected) }
        case .equals: return values.contains(expected)
        case .notEquals: return !values.contains(expected)
        case .startsWith: return values.contains { $0.hasPrefix(expected) }
        case .isEmpty: return values.isEmpty || values.allSatisfy { $0.isEmpty }
        case .isNotEmpty: return values.contains { !$0.isEmpty }
        case .before, .after, .lessThan, .greaterThan, .atMost, .atLeast: return false
        }
    }

    private static func compare(_ number: Double, rule: NativeSmartCollectionRule) -> Bool {
        guard let expected = Double(rule.value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        switch rule.comparison {
        case .equals: return number == expected
        case .notEquals: return number != expected
        case .lessThan: return number < expected
        case .greaterThan: return number > expected
        case .atMost: return number <= expected
        case .atLeast: return number >= expected
        default: return false
        }
    }

    private static func compare(
        _ lhs: NativeArticle,
        _ rhs: NativeArticle,
        field: NativeArticleSortField
    ) -> ComparisonResult {
        switch field {
        case .updatedAt: return lhs.updatedAt.compare(rhs.updatedAt)
        case .publishedAt: return (lhs.publishedAt ?? "").compare(rhs.publishedAt ?? "")
        case .title: return lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        case .category: return lhs.category.localizedCaseInsensitiveCompare(rhs.category)
        case .status: return lhs.status.rawValue.compare(rhs.status.rawValue)
        case .wordCount:
            return compareNumbers(
                lhs.wordCount ?? NativeWritingMetrics.characterCount(of: lhs.body),
                rhs.wordCount ?? NativeWritingMetrics.characterCount(of: rhs.body)
            )
        case .pageViews: return compareNumbers(lhs.pageViews, rhs.pageViews)
        }
    }

    private static func compareNumbers(_ lhs: Int, _ rhs: Int) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private static func folded(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func parsedDate(_ value: String) -> Date? {
        if let date = NativeTimestamp.date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}
