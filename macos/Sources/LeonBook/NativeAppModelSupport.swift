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

enum NativeProjectionKind: Hashable, Sendable {
    case articleLibrary
    case smartCollection
    case momentFacets
}

struct NativeProjectionRebuildCoordinator {
    struct Token: Equatable, Sendable {
        let kind: NativeProjectionKind
        let generation: Int
    }

    private var generations: [NativeProjectionKind: Int] = [:]

    mutating func begin(_ kind: NativeProjectionKind) -> Token {
        invalidate(kind)
        return Token(kind: kind, generation: generations[kind, default: 0])
    }

    mutating func invalidate(_ kind: NativeProjectionKind) {
        generations[kind, default: 0] &+= 1
    }

    func isCurrent(_ token: Token) -> Bool {
        generations[token.kind, default: 0] == token.generation
    }
}

private struct NativeTagFacetValue {
    let tag: String
    let count: Int
}

enum NativeTagIdentity {
    static func facet(_ tag: String) -> String {
        tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    static func filter(_ tag: String) -> String {
        tag.folding(options: [.caseInsensitive], locale: .current)
    }
}

private struct NativeTagFacetAccumulator {
    private var valuesByID: [String: NativeTagFacetValue] = [:]

    mutating func count(
        _ rawTag: String,
        oncePerRecord countedIdentifiers: inout Set<String>
    ) -> String? {
        let normalized = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let identifier = NativeTagIdentity.facet(normalized)
        guard countedIdentifiers.insert(identifier).inserted else { return normalized }

        if let existing = valuesByID[identifier] {
            valuesByID[identifier] = NativeTagFacetValue(
                tag: existing.tag,
                count: existing.count + 1
            )
        } else {
            valuesByID[identifier] = NativeTagFacetValue(tag: normalized, count: 1)
        }
        return normalized
    }

    var sortedValues: [NativeTagFacetValue] {
        valuesByID.values.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.tag.localizedCaseInsensitiveCompare($1.tag) == .orderedAscending
        }
    }
}

/// Immutable indexes for the article library. Rebuilding happens when the
/// backing summaries change, rather than every time SwiftUI asks for `body`.
struct NativeArticleLibraryProjection: @unchecked Sendable {
    private struct Record {
        let articleIndex: Int
        let folderPath: String
        let searchableText: String
        let tagIdentifiers: Set<String>
    }

    private(set) var articles: [NativeArticleSummary]
    let publishedArticleCount: Int
    let draftArticleCount: Int
    let folderFilters: [NativeArticleFolderFilter]
    let tagFilters: [NativeArticleTagFilter]
    private let linkIdentityIndex: NativeArticleLinkIdentityIndex

    private var records: [Record]
    private var articleIndexBySlug: [String: Int]

    init(articles: [NativeArticleSummary] = []) {
        self.articles = articles

        var publishedArticleCount = 0
        var draftArticleCount = 0
        var folderCounts: [String: Int] = [:]
        var tagFacetAccumulator = NativeTagFacetAccumulator()
        var records: [Record] = []
        var articleIndexBySlug: [String: Int] = [:]

        records.reserveCapacity(articles.count)
        articleIndexBySlug.reserveCapacity(articles.count)

        for (articleIndex, article) in articles.enumerated() {
            switch article.status {
            case .published:
                publishedArticleCount += 1
            case .draft:
                draftArticleCount += 1
            }

            let folderPath = article.sourceFolderPath
            if !folderPath.isEmpty {
                let components = folderPath.split(separator: "/")
                for length in 1...components.count {
                    folderCounts[components.prefix(length).joined(separator: "/"), default: 0] += 1
                }
            }

            var countedFacetTags = Set<String>()
            var filterTagIdentifiers = Set<String>()
            filterTagIdentifiers.reserveCapacity(article.tags.count)
            for tag in article.tags {
                guard let normalized = tagFacetAccumulator.count(
                    tag,
                    oncePerRecord: &countedFacetTags
                ) else { continue }
                filterTagIdentifiers.insert(NativeTagIdentity.filter(normalized))
            }

            let searchableText = Self.searchIdentifier([
                article.title,
                article.category,
                article.excerpt,
                article.tags.joined(separator: " "),
            ].joined(separator: " "))

            records.append(Record(
                articleIndex: articleIndex,
                folderPath: folderPath,
                searchableText: searchableText,
                tagIdentifiers: filterTagIdentifiers
            ))
            articleIndexBySlug[article.slug] = articleIndex
        }

        self.publishedArticleCount = publishedArticleCount
        self.draftArticleCount = draftArticleCount
        self.folderFilters = folderCounts.map {
            NativeArticleFolderFilter(path: $0.key, count: $0.value)
        }
        .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        self.tagFilters = tagFacetAccumulator.sortedValues.map {
            NativeArticleTagFilter(tag: $0.tag, count: $0.count)
        }
        self.linkIdentityIndex = NativeArticleLinkIdentityIndex(articles)
        self.records = records
        self.articleIndexBySlug = articleIndexBySlug
    }

    func resolveArticleLink(_ reference: String) -> NativeArticleSummary? {
        linkIdentityIndex.resolve(reference)
    }

    func filteredArticles(
        searchText: String,
        resolvedSearchText: String,
        searchMatchSlugs: Set<String>,
        selectedTags: Set<String>,
        selectedFolderPath: String?
    ) -> [NativeArticleSummary] {
        let query = Self.searchIdentifier(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
        let resolvedQuery = Self.searchIdentifier(resolvedSearchText)
        let selectedTagIdentifiers = Set(selectedTags.map(NativeTagIdentity.filter))

        let filtersBySearch = !query.isEmpty
        let filtersByTag = !selectedTagIdentifiers.isEmpty
        let filtersByFolder = selectedFolderPath != nil
        let usesResolvedSearch = filtersBySearch && resolvedQuery == query
        guard usesResolvedSearch || filtersByTag || filtersByFolder else {
            return articles
        }

        return records.compactMap { record in
            let article = articles[record.articleIndex]
            if usesResolvedSearch,
               !searchMatchSlugs.contains(article.slug) {
                return nil
            }

            if filtersByTag,
               record.tagIdentifiers.isDisjoint(with: selectedTagIdentifiers) {
                return nil
            }
            if let selectedFolderPath,
               record.folderPath != selectedFolderPath,
               !record.folderPath.hasPrefix(selectedFolderPath + "/") {
                return nil
            }
            return article
        }
    }

    func localSearchMatchSlugs(searchText: String) -> Set<String> {
        let query = Self.searchIdentifier(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return [] }

        var matches = Set<String>()
        matches.reserveCapacity(min(records.count, 256))
        for (index, record) in records.enumerated() {
            if index.isMultiple(of: 256), Task.isCancelled { return [] }
            if record.searchableText.contains(query) {
                matches.insert(articles[record.articleIndex].slug)
            }
        }
        return matches
    }

    func articles(for slugs: [String]) -> [NativeArticleSummary] {
        slugs.compactMap { slug in
            articleIndexBySlug[slug].map { articles[$0] }
        }
    }

    func pageViews(for slug: String) -> Int? {
        articleIndexBySlug[slug].map { articles[$0].pageViews }
    }

    @discardableResult
    mutating func updatePageViews(for slug: String, to pageViews: Int) -> Bool {
        guard let articleIndex = articleIndexBySlug[slug] else { return false }
        articles[articleIndex].pageViews = pageViews
        return true
    }

    private static func searchIdentifier(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

final class NativeProjectionBatch<Element>: @unchecked Sendable {
    let elements: [Element]

    init(_ elements: [Element]) {
        self.elements = elements
    }
}

struct NativeMomentFacetProjection: @unchecked Sendable {
    let tagFilters: [NativeMomentTagFilter]
    let months: [NativeMomentMonth]
    let years: [Int]

    init(
        records: [NativeMomentFacetRecord] = [],
        calendar: Calendar = .current
    ) {
        var tagFacetAccumulator = NativeTagFacetAccumulator()
        var months = Set<NativeMomentMonth>()

        for record in records {
            var countedTags = Set<String>()
            for tag in record.tags {
                _ = tagFacetAccumulator.count(tag, oncePerRecord: &countedTags)
            }

            guard let date = NativeTimestamp.date(from: record.createdAt) else { continue }
            let components = calendar.dateComponents([.year, .month], from: date)
            if let year = components.year, let month = components.month {
                months.insert(NativeMomentMonth(year: year, month: month))
            }
        }

        tagFilters = tagFacetAccumulator.sortedValues.map {
            NativeMomentTagFilter(tag: $0.tag, count: $0.count)
        }
        self.months = months.sorted {
            $0.year == $1.year ? $0.month > $1.month : $0.year > $1.year
        }
        years = Set(months.map(\.year)).sorted(by: >)
    }
}

struct NativeMomentTimelineProjection {
    let groups: [NativeMomentTimelineGroup]

    init(
        moments: [NativeMoment] = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        var groups: [NativeMomentTimelineGroup] = []
        groups.reserveCapacity(min(moments.count, 366))

        for moment in moments {
            guard let date = NativeTimestamp.date(from: moment.createdAt) else {
                groups.append(NativeMomentTimelineGroup(
                    id: "unknown-\(moment.id)",
                    label: moment.createdAt.isEmpty ? "未知日期" : moment.createdAt,
                    moments: [moment]
                ))
                continue
            }

            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day else { continue }
            let id = String(format: "%04d-%02d-%02d", year, month, day)
            if let lastIndex = groups.indices.last, groups[lastIndex].id == id {
                groups[lastIndex].moments.append(moment)
            } else {
                groups.append(NativeMomentTimelineGroup(
                    id: id,
                    label: Self.dateLabel(for: date, now: now, calendar: calendar),
                    moments: [moment]
                ))
            }
        }
        self.groups = groups
    }

    private static func dateLabel(for date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "今天" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天"
        }
        return date.formatted(date: .long, time: .omitted)
    }
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
