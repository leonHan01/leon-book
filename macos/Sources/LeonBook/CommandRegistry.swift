import Foundation

/// Stable, namespaced identifier shared by every command entry point.
public struct NativeCommandID: RawRepresentable, Hashable, Codable, Identifiable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var id: String { rawValue }

    public static let globalSearch = Self(rawValue: "search.global")
    public static let quickOpen = Self(rawValue: "search.quick-open")
    public static let commandPalette = Self(rawValue: "command.palette")
    public static let newArticle = Self(rawValue: "article.new")
    public static let saveDraft = Self(rawValue: "article.save-draft")
    public static let publishArticle = Self(rawValue: "article.publish")
    public static let dashboard = Self(rawValue: "navigation.dashboard")
    public static let articles = Self(rawValue: "navigation.articles")
    public static let graph = Self(rawValue: "navigation.graph")
    public static let moments = Self(rawValue: "navigation.moments")
    public static let today = Self(rawValue: "navigation.today")
    public static let trash = Self(rawValue: "navigation.trash")
    public static let settings = Self(rawValue: "navigation.settings")
    public static let articleBack = Self(rawValue: "navigation.article-back")
    public static let articleForward = Self(rawValue: "navigation.article-forward")
    public static let toggleArticleTabPin = Self(rawValue: "article-tab.toggle-pin")
    public static let closeArticleTab = Self(rawValue: "article-tab.close")
    public static let openArticle = Self(rawValue: "article.open")
    public static let reload = Self(rawValue: "data.reload")
    public static let backupNow = Self(rawValue: "backup.create")
    public static let captureMarkdownFolder = Self(rawValue: "capture.markdown-folder")

    public static let insertHeading2 = Self(rawValue: "editor.insert.heading-2")
    public static let insertTask = Self(rawValue: "editor.insert.task")
    public static let insertCallout = Self(rawValue: "editor.insert.callout")
    public static let insertCodeBlock = Self(rawValue: "editor.insert.code-block")
    public static let insertTable = Self(rawValue: "editor.insert.table")
    public static let insertWikiLink = Self(rawValue: "editor.insert.wiki-link")
    public static let insertEmbed = Self(rawValue: "editor.insert.embed")
    public static let insertBase = Self(rawValue: "editor.insert.base")
}

public enum NativeCommandSurface: String, Codable, Hashable, Sendable {
    case palette
    case menu
    case editorSlash
    case automation
}

public enum NativeCommandAvailability: String, Codable, Hashable, Sendable {
    case always
    case storageReady
    case storageReadyAndIdle
    case articleEditor
    case articleEditorAndIdle
    case activeArticleTab
    case articleBack
    case articleForward
}

public struct NativeCommandContext: Equatable, Sendable {
    public var storageReady: Bool
    public var isBusy: Bool
    public var isArticleEditor: Bool
    public var hasActiveArticleTab: Bool
    public var canNavigateArticleBack: Bool
    public var canNavigateArticleForward: Bool

    public init(
        storageReady: Bool = true,
        isBusy: Bool = false,
        isArticleEditor: Bool = false,
        hasActiveArticleTab: Bool = false,
        canNavigateArticleBack: Bool = false,
        canNavigateArticleForward: Bool = false
    ) {
        self.storageReady = storageReady
        self.isBusy = isBusy
        self.isArticleEditor = isArticleEditor
        self.hasActiveArticleTab = hasActiveArticleTab
        self.canNavigateArticleBack = canNavigateArticleBack
        self.canNavigateArticleForward = canNavigateArticleForward
    }
}

public struct NativeCommandShortcut: Codable, Hashable, Sendable {
    public enum Modifier: String, Codable, CaseIterable, Hashable, Sendable {
        case command
        case option
        case shift
        case control

        public var symbol: String {
            switch self {
            case .command: return "⌘"
            case .option: return "⌥"
            case .shift: return "⇧"
            case .control: return "⌃"
            }
        }
    }

    public let key: String
    public let modifiers: Set<Modifier>

    public init(key: String, modifiers: Set<Modifier>) {
        self.key = Self.normalizedKey(key)
        self.modifiers = modifiers
    }

    public var isValid: Bool {
        key.count == 1 && !key.contains(where: { $0.isWhitespace || $0.isNewline })
    }

    public var displayLabel: String {
        let ordered: [Modifier] = [.control, .option, .shift, .command]
        return ordered.filter(modifiers.contains).map(\.symbol).joined() + key.uppercased()
    }

    private static func normalizedKey(_ key: String) -> String {
        String(key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(1))
    }
}

public struct NativeCommandTextInsertion: Hashable, Sendable {
    public let text: String
    public let cursorOffset: Int

    public init(text: String, cursorOffset: Int? = nil) {
        self.text = text
        self.cursorOffset = min(max(0, cursorOffset ?? (text as NSString).length), (text as NSString).length)
    }
}

public struct NativeCommandDefinition: Identifiable, Hashable, Sendable {
    public let id: NativeCommandID
    public let title: String
    public let detail: String
    public let keywords: String
    public let systemImage: String
    public let availability: NativeCommandAvailability
    public let surfaces: Set<NativeCommandSurface>
    public let defaultShortcut: NativeCommandShortcut?
    public let textInsertion: NativeCommandTextInsertion?

    public init(
        id: NativeCommandID,
        title: String,
        detail: String,
        keywords: String = "",
        systemImage: String,
        availability: NativeCommandAvailability = .storageReady,
        surfaces: Set<NativeCommandSurface> = [.palette, .menu],
        defaultShortcut: NativeCommandShortcut? = nil,
        textInsertion: NativeCommandTextInsertion? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.keywords = keywords
        self.systemImage = systemImage
        self.availability = availability
        self.surfaces = surfaces
        self.defaultShortcut = defaultShortcut
        self.textInsertion = textInsertion
    }

    public func isAvailable(in context: NativeCommandContext) -> Bool {
        switch availability {
        case .always:
            return true
        case .storageReady:
            return context.storageReady
        case .storageReadyAndIdle:
            return context.storageReady && !context.isBusy
        case .articleEditor:
            return context.storageReady && context.isArticleEditor
        case .articleEditorAndIdle:
            return context.storageReady && context.isArticleEditor && !context.isBusy
        case .activeArticleTab:
            return context.storageReady && context.hasActiveArticleTab
        case .articleBack:
            return context.storageReady && context.canNavigateArticleBack
        case .articleForward:
            return context.storageReady && context.canNavigateArticleForward
        }
    }
}

public struct NativeCommandRanking: Equatable, Sendable {
    public var pinned: [NativeCommandID]
    public var recent: [NativeCommandID]

    public init(pinned: [NativeCommandID] = [], recent: [NativeCommandID] = []) {
        self.pinned = pinned
        self.recent = recent
    }
}

public struct NativeCommandMatch: Identifiable, Hashable, Sendable {
    public let definition: NativeCommandDefinition
    public let isPinned: Bool
    public let isRecent: Bool
    public let score: Int

    public var id: NativeCommandID { definition.id }
}

/// Pure command catalog. Callers learn one search/lookup interface while the
/// registry owns fuzzy matching, availability and ranking rules.
public struct NativeCommandRegistry: Sendable {
    public static let builtIn = NativeCommandRegistry(definitions: builtInDefinitions)

    public let definitions: [NativeCommandDefinition]
    private let definitionsByID: [NativeCommandID: NativeCommandDefinition]

    public init(definitions: [NativeCommandDefinition]) {
        var seen = Set<NativeCommandID>()
        self.definitions = definitions.filter { seen.insert($0.id).inserted }
        definitionsByID = Dictionary(uniqueKeysWithValues: self.definitions.map { ($0.id, $0) })
    }

    public func definition(for id: NativeCommandID) -> NativeCommandDefinition? {
        definitionsByID[id]
    }

    public func commands(
        on surface: NativeCommandSurface,
        context: NativeCommandContext,
        includingUnavailable: Bool = false
    ) -> [NativeCommandDefinition] {
        definitions.filter { definition in
            definition.surfaces.contains(surface)
                && (includingUnavailable || definition.isAvailable(in: context))
        }
    }

    public func matches(
        _ query: String,
        on surface: NativeCommandSurface,
        context: NativeCommandContext,
        ranking: NativeCommandRanking = .init(),
        includingUnavailable: Bool = false
    ) -> [NativeCommandMatch] {
        let candidates = commands(
            on: surface,
            context: context,
            includingUnavailable: includingUnavailable
        )
        let needle = Self.normalized(query)
        let pinnedOrder = Dictionary(uniqueKeysWithValues: ranking.pinned.enumerated().map { ($0.element, $0.offset) })
        let recentOrder = Dictionary(uniqueKeysWithValues: ranking.recent.enumerated().map { ($0.element, $0.offset) })
        let definitionOrder = Dictionary(uniqueKeysWithValues: definitions.enumerated().map { ($0.element.id, $0.offset) })

        let matches: [NativeCommandMatch] = candidates.compactMap { definition in
            let score: Int
            if needle.isEmpty {
                score = 0
            } else {
                let titleScore = Self.fuzzyScore(needle, in: definition.title).map { $0 + 300 }
                let detailScore = Self.fuzzyScore(needle, in: definition.detail).map { $0 + 100 }
                let keywordScore = Self.fuzzyScore(needle, in: definition.keywords)
                guard let best = [titleScore, detailScore, keywordScore].compactMap({ $0 }).max() else {
                    return nil
                }
                score = best
            }
            return NativeCommandMatch(
                definition: definition,
                isPinned: pinnedOrder[definition.id] != nil,
                isRecent: recentOrder[definition.id] != nil,
                score: score
            )
        }

        return matches.sorted { lhs, rhs in
            let leftPinned = pinnedOrder[lhs.id]
            let rightPinned = pinnedOrder[rhs.id]
            if leftPinned != nil || rightPinned != nil {
                if leftPinned == nil { return false }
                if rightPinned == nil { return true }
                return leftPinned! < rightPinned!
            }
            if !needle.isEmpty, lhs.score != rhs.score { return lhs.score > rhs.score }

            let leftRecent = recentOrder[lhs.id]
            let rightRecent = recentOrder[rhs.id]
            if leftRecent != nil || rightRecent != nil {
                if leftRecent == nil { return false }
                if rightRecent == nil { return true }
                return leftRecent! < rightRecent!
            }
            return (definitionOrder[lhs.id] ?? .max) < (definitionOrder[rhs.id] ?? .max)
        }
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func fuzzyScore(_ query: String, in candidate: String) -> Int? {
        let haystack = Array(normalized(candidate))
        let needle = Array(query)
        guard !needle.isEmpty else { return 0 }

        if let exactRange = String(haystack).range(of: String(needle)) {
            let offset = String(haystack).distance(from: String(haystack).startIndex, to: exactRange.lowerBound)
            return 10_000 - offset * 20 - max(0, haystack.count - needle.count)
        }

        var searchIndex = 0
        var lastMatch = -2
        var score = 4_000
        for character in needle {
            guard let index = haystack[searchIndex...].firstIndex(of: character) else { return nil }
            score -= max(0, index - searchIndex) * 7
            if index == lastMatch + 1 { score += 45 }
            if index == 0 || haystack[index - 1].isWhitespace || "-_/·".contains(haystack[index - 1]) {
                score += 25
            }
            lastMatch = index
            searchIndex = index + 1
            if searchIndex >= haystack.count && character != needle.last { return nil }
        }
        return score - max(0, haystack.count - needle.count)
    }
}

public struct NativeCommandInvocation: Codable, Equatable, Sendable {
    public let id: NativeCommandID
    public let arguments: [String: String]

    public init(id: NativeCommandID, arguments: [String: String] = [:]) {
        self.id = id
        self.arguments = arguments
    }

    public static func newArticle(title: String?, content: String?, sourceURL: String?) -> Self {
        var arguments: [String: String] = [:]
        if let title { arguments["title"] = title }
        if let content { arguments["content"] = content }
        if let sourceURL { arguments["sourceURL"] = sourceURL }
        return Self(id: .newArticle, arguments: arguments)
    }

    public static func openArticle(slug: String) -> Self {
        Self(id: .openArticle, arguments: ["slug": slug])
    }

    public static func search(query: String) -> Self {
        Self(id: .globalSearch, arguments: ["query": query])
    }

    public static var today: Self { Self(id: .today) }

    public static func editorInsertion(id: NativeCommandID, replacing range: NSRange) -> Self {
        Self(id: id, arguments: [
            "selectionLocation": String(range.location),
            "selectionLength": String(range.length),
        ])
    }
}

public struct NativeCommandPreferenceState: Codable, Equatable, Sendable {
    public var customShortcuts: [String: NativeCommandShortcut]
    public var disabledDefaultShortcuts: Set<String>
    public var pinnedCommandIDs: [String]
    public var recentCommandIDs: [String]

    public init(
        customShortcuts: [String: NativeCommandShortcut] = [:],
        disabledDefaultShortcuts: Set<String> = [],
        pinnedCommandIDs: [String] = [],
        recentCommandIDs: [String] = []
    ) {
        self.customShortcuts = customShortcuts
        self.disabledDefaultShortcuts = disabledDefaultShortcuts
        self.pinnedCommandIDs = pinnedCommandIDs
        self.recentCommandIDs = recentCommandIDs
    }
}

@MainActor
public final class NativeCommandPreferences: ObservableObject {
    public static let shared = NativeCommandPreferences()

    @Published public private(set) var state: NativeCommandPreferenceState

    private let defaults: UserDefaults
    private let defaultsKey: String
    private let registry: NativeCommandRegistry
    private let maximumRecentCount = 20
    private let maximumPinnedCount = 16

    public init(
        defaults: UserDefaults = .standard,
        defaultsKey: String = "leon-book.command-preferences.v1",
        registry: NativeCommandRegistry = .builtIn
    ) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        self.registry = registry
        if let data = defaults.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode(NativeCommandPreferenceState.self, from: data) {
            state = saved
        } else {
            state = NativeCommandPreferenceState()
        }
        sanitize()
    }

    public var ranking: NativeCommandRanking {
        NativeCommandRanking(
            pinned: state.pinnedCommandIDs.map(NativeCommandID.init(rawValue:)),
            recent: state.recentCommandIDs.map(NativeCommandID.init(rawValue:))
        )
    }

    public func shortcut(for definition: NativeCommandDefinition) -> NativeCommandShortcut? {
        if let custom = state.customShortcuts[definition.id.rawValue] { return custom }
        if state.disabledDefaultShortcuts.contains(definition.id.rawValue) { return nil }
        return definition.defaultShortcut
    }

    public func shortcut(for id: NativeCommandID) -> NativeCommandShortcut? {
        registry.definition(for: id).flatMap(shortcut(for:))
    }

    /// Returns the conflicting command without mutating preferences.
    @discardableResult
    public func setShortcut(_ shortcut: NativeCommandShortcut?, for id: NativeCommandID) -> NativeCommandID? {
        guard registry.definition(for: id) != nil else { return nil }
        if let shortcut {
            guard shortcut.isValid else { return id }
            if let conflict = conflictingCommand(for: shortcut, excluding: id) { return conflict }
            state.customShortcuts[id.rawValue] = shortcut
            state.disabledDefaultShortcuts.remove(id.rawValue)
        } else {
            state.customShortcuts.removeValue(forKey: id.rawValue)
            state.disabledDefaultShortcuts.insert(id.rawValue)
        }
        persist()
        return nil
    }

    public func resetShortcut(for id: NativeCommandID) {
        state.customShortcuts.removeValue(forKey: id.rawValue)
        state.disabledDefaultShortcuts.remove(id.rawValue)
        persist()
    }

    public func conflictingCommand(
        for shortcut: NativeCommandShortcut,
        excluding excludedID: NativeCommandID? = nil
    ) -> NativeCommandID? {
        registry.definitions.first { definition in
            definition.id != excludedID && self.shortcut(for: definition) == shortcut
        }?.id
    }

    public func isPinned(_ id: NativeCommandID) -> Bool {
        state.pinnedCommandIDs.contains(id.rawValue)
    }

    public func togglePinned(_ id: NativeCommandID) {
        if let index = state.pinnedCommandIDs.firstIndex(of: id.rawValue) {
            state.pinnedCommandIDs.remove(at: index)
        } else {
            state.pinnedCommandIDs.insert(id.rawValue, at: 0)
            state.pinnedCommandIDs = Array(state.pinnedCommandIDs.prefix(maximumPinnedCount))
        }
        persist()
    }

    public func recordUse(_ id: NativeCommandID) {
        state.recentCommandIDs.removeAll(where: { $0 == id.rawValue })
        state.recentCommandIDs.insert(id.rawValue, at: 0)
        state.recentCommandIDs = Array(state.recentCommandIDs.prefix(maximumRecentCount))
        persist()
    }

    public func resetAll() {
        state = NativeCommandPreferenceState()
        persist()
    }

    private func sanitize() {
        let validIDs = Set(registry.definitions.map { $0.id.rawValue })
        state.customShortcuts = state.customShortcuts.filter { validIDs.contains($0.key) && $0.value.isValid }
        state.disabledDefaultShortcuts = state.disabledDefaultShortcuts.intersection(validIDs)
        state.pinnedCommandIDs = Array(state.pinnedCommandIDs.filter(validIDs.contains).uniqued().prefix(maximumPinnedCount))
        state.recentCommandIDs = Array(state.recentCommandIDs.filter(validIDs.contains).uniqued().prefix(maximumRecentCount))
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: defaultsKey)
        }
        objectWillChange.send()
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

private extension NativeCommandRegistry {
    static let builtInDefinitions: [NativeCommandDefinition] = coreDefinitions
        + NativeFirstPartyModules.commandDefinitions

    static let coreDefinitions: [NativeCommandDefinition] = [
        .init(
            id: .commandPalette,
            title: "打开命令面板",
            detail: "搜索并执行所有可用命令",
            keywords: "command palette 命令",
            systemImage: "command",
            availability: .always,
            defaultShortcut: .init(key: "p", modifiers: [.command])
        ),
        .init(
            id: .newArticle,
            title: "新建文章",
            detail: "打开空白写作页",
            keywords: "create write note",
            systemImage: "square.and.pencil",
            defaultShortcut: .init(key: "n", modifiers: [.command])
        ),
        .init(
            id: .saveDraft,
            title: "保存草稿",
            detail: "保存当前编辑器内容",
            keywords: "save draft",
            systemImage: "tray.and.arrow.down",
            availability: .articleEditorAndIdle,
            defaultShortcut: .init(key: "s", modifiers: [.command])
        ),
        .init(id: .dashboard, title: "前往概览", detail: "打开活动概览", keywords: "home dashboard", systemImage: "rectangle.grid.2x2"),
        .init(id: .articles, title: "前往全部文章", detail: "浏览文章列表", keywords: "notes article", systemImage: "doc.text"),
        .init(id: .moments, title: "前往微博", detail: "浏览和发布微博", keywords: "moment post", systemImage: "rectangle.3.group"),
        .init(id: .today, title: "前往今日微博", detail: "只查看今天发布的微博", keywords: "today calendar", systemImage: "calendar"),
        .init(id: .trash, title: "前往回收站", detail: "恢复或彻底删除内容", keywords: "delete restore", systemImage: "trash"),
        .init(
            id: .settings,
            title: "前往设置",
            detail: "管理资料库、命令和备份",
            keywords: "preferences hotkey shortcut",
            systemImage: "gearshape",
            availability: .always,
            defaultShortcut: .init(key: ",", modifiers: [.command])
        ),
        .init(
            id: .articleBack,
            title: "文章导航后退",
            detail: "回到当前标签页的上一篇文章",
            keywords: "back previous",
            systemImage: "chevron.backward",
            availability: .articleBack,
            defaultShortcut: .init(key: "[", modifiers: [.command])
        ),
        .init(
            id: .articleForward,
            title: "文章导航前进",
            detail: "前往当前标签页的下一篇文章",
            keywords: "forward next",
            systemImage: "chevron.forward",
            availability: .articleForward,
            defaultShortcut: .init(key: "]", modifiers: [.command])
        ),
        .init(
            id: .toggleArticleTabPin,
            title: "固定或取消固定当前标签页",
            detail: "避免当前文章标签页被替换",
            keywords: "pin tab",
            systemImage: "pin",
            availability: .activeArticleTab
        ),
        .init(
            id: .closeArticleTab,
            title: "关闭当前文章标签页",
            detail: "关闭当前打开的文章标签页",
            keywords: "close tab",
            systemImage: "xmark",
            availability: .activeArticleTab
        ),
        .init(
            id: .reload,
            title: "刷新资料库",
            detail: "重新读取本地文章和微博",
            keywords: "reload refresh rescan",
            systemImage: "arrow.clockwise",
            availability: .storageReadyAndIdle,
            defaultShortcut: .init(key: "r", modifiers: [.command])
        ),
        .init(
            id: .openArticle,
            title: "按 slug 打开文章",
            detail: "供 URL、App Intent 和未来 CLI 调用",
            keywords: "automation open slug",
            systemImage: "doc.text.magnifyingglass",
            surfaces: [.automation]
        ),
        .init(
            id: .insertHeading2,
            title: "二级标题",
            detail: "插入 ## 标题",
            keywords: "heading h2 标题",
            systemImage: "textformat.size",
            availability: .articleEditor,
            surfaces: [.palette, .menu, .editorSlash],
            textInsertion: .init(text: "## ")
        ),
        .init(
            id: .insertTask,
            title: "任务列表",
            detail: "插入可勾选任务",
            keywords: "task todo checkbox",
            systemImage: "checklist",
            availability: .articleEditor,
            surfaces: [.palette, .menu, .editorSlash],
            textInsertion: .init(text: "- [ ] ")
        ),
        .init(
            id: .insertCallout,
            title: "Callout",
            detail: "插入提示块",
            keywords: "note tip warning 提示",
            systemImage: "quote.bubble",
            availability: .articleEditor,
            surfaces: [.palette, .menu, .editorSlash],
            textInsertion: .init(text: "> [!note] 标题\n> ")
        ),
        .init(
            id: .insertCodeBlock,
            title: "代码块",
            detail: "插入围栏代码块",
            keywords: "code fence",
            systemImage: "chevron.left.forwardslash.chevron.right",
            availability: .articleEditor,
            surfaces: [.palette, .menu, .editorSlash],
            textInsertion: .init(text: "```\n\n```", cursorOffset: 4)
        ),
        .init(
            id: .insertTable,
            title: "表格",
            detail: "插入两列表格",
            keywords: "table grid",
            systemImage: "tablecells",
            availability: .articleEditor,
            surfaces: [.palette, .menu, .editorSlash],
            textInsertion: .init(text: "| 列 1 | 列 2 |\n| --- | --- |\n|  |  |")
        ),
        .init(
            id: .insertWikiLink,
            title: "文章双链",
            detail: "插入 [[文章]]",
            keywords: "wikilink link",
            systemImage: "link",
            availability: .articleEditor,
            surfaces: [.palette, .menu, .editorSlash],
            textInsertion: .init(text: "[[]]", cursorOffset: 2)
        ),
        .init(
            id: .insertEmbed,
            title: "嵌入文章或块",
            detail: "插入 ![[文章#标题]]",
            keywords: "embed transclude block",
            systemImage: "doc.on.doc",
            availability: .articleEditor,
            surfaces: [.palette, .menu, .editorSlash],
            textInsertion: .init(text: "![[]]", cursorOffset: 3)
        ),
        .init(
            id: .insertBase,
            title: "嵌入智能集合",
            detail: "插入 ![[集合名称.base]]",
            keywords: "base collection database",
            systemImage: "tablecells.badge.ellipsis",
            availability: .articleEditor,
            surfaces: [.palette, .menu, .editorSlash],
            textInsertion: .init(text: "![[集合名称.base]]")
        ),
    ]
}
