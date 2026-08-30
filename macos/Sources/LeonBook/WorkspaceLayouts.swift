import Foundation
import SwiftUI

enum ArticleEditorMode: String, CaseIterable, Identifiable, Codable {
    case focus
    case livePreview
    case source
    case split

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focus: return "专注写作"
        case .livePreview: return "实时预览"
        case .source: return "源码"
        case .split: return "左右分栏"
        }
    }

    var systemImage: String {
        switch self {
        case .focus: return "arrow.up.left.and.arrow.down.right"
        case .livePreview: return "textformat"
        case .source: return "chevron.left.forwardslash.chevron.right"
        case .split: return "rectangle.split.2x1"
        }
    }

    var detail: String {
        switch self {
        case .focus: return "隐藏右侧面板，以行内格式专注正文"
        case .livePreview: return "在可编辑正文中即时显示 Markdown 格式"
        case .source: return "只显示未经渲染的 Markdown 源码"
        case .split: return "左侧编辑源码，右侧查看完整渲染效果"
        }
    }
}

enum NativeEditorSidebarPane: String, CaseIterable, Identifiable, Codable {
    case settings
    case properties
    case outline
    case links

    var id: String { rawValue }

    var title: String {
        switch self {
        case .settings: return "设置"
        case .properties: return "属性"
        case .outline: return "大纲"
        case .links: return "链接"
        }
    }

    var systemImage: String {
        switch self {
        case .settings: return "slider.horizontal.3"
        case .properties: return "list.bullet.rectangle"
        case .outline: return "list.bullet.indent"
        case .links: return "link"
        }
    }
}

enum ArticleInspectorPane: String, CaseIterable, Identifiable, Codable {
    case comments
    case context

    var id: String { rawValue }
}

enum NativeWorkspaceLayoutKind: String, CaseIterable, Identifiable, Codable {
    case writing
    case reading
    case reviewing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .writing: return "写作"
        case .reading: return "阅读"
        case .reviewing: return "审稿"
        }
    }

    var systemImage: String {
        switch self {
        case .writing: return "square.and.pencil"
        case .reading: return "book.pages"
        case .reviewing: return "text.bubble"
        }
    }

    var profileID: String { "builtin-\(rawValue)" }
}

enum NativeWorkspaceLayoutDestination: String, Codable {
    case editor
    case reader
}

struct NativeWorkspaceLayoutProfile: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var systemImage: String
    var builtInKind: NativeWorkspaceLayoutKind?
    var destination: NativeWorkspaceLayoutDestination
    var editorMode: ArticleEditorMode
    var editorSidebarPane: NativeEditorSidebarPane
    var isEditorSidebarVisible: Bool
    var readerInspectorPane: ArticleInspectorPane
    var isReaderInspectorVisible: Bool
    var tabs: [NativeArticleTab]
    var activeTabID: UUID?
    var navigationSidebarWidth: Double
    var editorSidebarWidth: Double
    var readerInspectorWidth: Double
    var splitFraction: Double

    init(
        id: String,
        name: String,
        systemImage: String,
        builtInKind: NativeWorkspaceLayoutKind? = nil,
        destination: NativeWorkspaceLayoutDestination,
        editorMode: ArticleEditorMode,
        editorSidebarPane: NativeEditorSidebarPane,
        isEditorSidebarVisible: Bool,
        readerInspectorPane: ArticleInspectorPane,
        isReaderInspectorVisible: Bool,
        tabs: [NativeArticleTab] = [],
        activeTabID: UUID? = nil,
        navigationSidebarWidth: Double = 250,
        editorSidebarWidth: Double = 300,
        readerInspectorWidth: Double = 320,
        splitFraction: Double = 0.5
    ) {
        self.id = id
        self.name = name
        self.systemImage = systemImage
        self.builtInKind = builtInKind
        self.destination = destination
        self.editorMode = editorMode
        self.editorSidebarPane = editorSidebarPane
        self.isEditorSidebarVisible = isEditorSidebarVisible
        self.readerInspectorPane = readerInspectorPane
        self.isReaderInspectorVisible = isReaderInspectorVisible
        self.tabs = tabs
        self.activeTabID = activeTabID
        self.navigationSidebarWidth = navigationSidebarWidth
        self.editorSidebarWidth = editorSidebarWidth
        self.readerInspectorWidth = readerInspectorWidth
        self.splitFraction = splitFraction
        self = normalized
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, systemImage, builtInKind, kind, destination, editorMode
        case editorSidebarPane, isEditorSidebarVisible, readerInspectorPane, isReaderInspectorVisible
        case tabs, activeTabID, navigationSidebarWidth, editorSidebarWidth, readerInspectorWidth, splitFraction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyKind = try container.decodeIfPresent(NativeWorkspaceLayoutKind.self, forKey: .kind)
        let builtIn = try container.decodeIfPresent(NativeWorkspaceLayoutKind.self, forKey: .builtInKind)
            ?? legacyKind
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id)
                ?? builtIn?.profileID ?? UUID().uuidString.lowercased(),
            name: try container.decodeIfPresent(String.self, forKey: .name)
                ?? builtIn?.title ?? "工作区",
            systemImage: try container.decodeIfPresent(String.self, forKey: .systemImage)
                ?? builtIn?.systemImage ?? "rectangle.3.group",
            builtInKind: builtIn,
            destination: try container.decodeIfPresent(NativeWorkspaceLayoutDestination.self, forKey: .destination)
                ?? .editor,
            editorMode: try container.decodeIfPresent(ArticleEditorMode.self, forKey: .editorMode)
                ?? .livePreview,
            editorSidebarPane: try container.decodeIfPresent(NativeEditorSidebarPane.self, forKey: .editorSidebarPane)
                ?? .settings,
            isEditorSidebarVisible: try container.decodeIfPresent(Bool.self, forKey: .isEditorSidebarVisible)
                ?? true,
            readerInspectorPane: try container.decodeIfPresent(ArticleInspectorPane.self, forKey: .readerInspectorPane)
                ?? .context,
            isReaderInspectorVisible: try container.decodeIfPresent(Bool.self, forKey: .isReaderInspectorVisible)
                ?? true,
            tabs: try container.decodeIfPresent([NativeArticleTab].self, forKey: .tabs) ?? [],
            activeTabID: try container.decodeIfPresent(UUID.self, forKey: .activeTabID),
            navigationSidebarWidth: try container.decodeIfPresent(Double.self, forKey: .navigationSidebarWidth) ?? 250,
            editorSidebarWidth: try container.decodeIfPresent(Double.self, forKey: .editorSidebarWidth) ?? 300,
            readerInspectorWidth: try container.decodeIfPresent(Double.self, forKey: .readerInspectorWidth) ?? 320,
            splitFraction: try container.decodeIfPresent(Double.self, forKey: .splitFraction) ?? 0.5
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(systemImage, forKey: .systemImage)
        try container.encodeIfPresent(builtInKind, forKey: .builtInKind)
        try container.encode(destination, forKey: .destination)
        try container.encode(editorMode, forKey: .editorMode)
        try container.encode(editorSidebarPane, forKey: .editorSidebarPane)
        try container.encode(isEditorSidebarVisible, forKey: .isEditorSidebarVisible)
        try container.encode(readerInspectorPane, forKey: .readerInspectorPane)
        try container.encode(isReaderInspectorVisible, forKey: .isReaderInspectorVisible)
        try container.encode(tabs, forKey: .tabs)
        try container.encodeIfPresent(activeTabID, forKey: .activeTabID)
        try container.encode(navigationSidebarWidth, forKey: .navigationSidebarWidth)
        try container.encode(editorSidebarWidth, forKey: .editorSidebarWidth)
        try container.encode(readerInspectorWidth, forKey: .readerInspectorWidth)
        try container.encode(splitFraction, forKey: .splitFraction)
    }

    var normalized: Self {
        var result = self
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.name = String((trimmedName.isEmpty ? "工作区" : trimmedName).prefix(40))
        result.tabs = Array(tabs.prefix(20))
        result.navigationSidebarWidth = min(max(navigationSidebarWidth, 210), 380)
        result.editorSidebarWidth = min(max(editorSidebarWidth, 240), 460)
        result.readerInspectorWidth = min(max(readerInspectorWidth, 260), 480)
        result.splitFraction = min(max(splitFraction, 0.25), 0.75)
        if !result.tabs.contains(where: { $0.id == result.activeTabID }) {
            result.activeTabID = result.tabs.first?.id
        }
        return result
    }

    static func defaultProfile(for kind: NativeWorkspaceLayoutKind) -> Self {
        switch kind {
        case .writing:
            return Self(
                id: kind.profileID,
                name: kind.title,
                systemImage: kind.systemImage,
                builtInKind: kind,
                destination: .editor,
                editorMode: .livePreview,
                editorSidebarPane: .settings,
                isEditorSidebarVisible: true,
                readerInspectorPane: .context,
                isReaderInspectorVisible: true,
                editorSidebarWidth: 300,
                splitFraction: 0.55
            )
        case .reading:
            return Self(
                id: kind.profileID,
                name: kind.title,
                systemImage: kind.systemImage,
                builtInKind: kind,
                destination: .reader,
                editorMode: .livePreview,
                editorSidebarPane: .outline,
                isEditorSidebarVisible: false,
                readerInspectorPane: .context,
                isReaderInspectorVisible: false,
                readerInspectorWidth: 320
            )
        case .reviewing:
            return Self(
                id: kind.profileID,
                name: kind.title,
                systemImage: kind.systemImage,
                builtInKind: kind,
                destination: .reader,
                editorMode: .split,
                editorSidebarPane: .links,
                isEditorSidebarVisible: true,
                readerInspectorPane: .comments,
                isReaderInspectorVisible: true,
                editorSidebarWidth: 340,
                readerInspectorWidth: 360,
                splitFraction: 0.5
            )
        }
    }
}

@MainActor
final class NativeWorkspaceLayoutState: ObservableObject {
    private struct Archive: Codable {
        var profilesByUser: [String: [NativeWorkspaceLayoutProfile]] = [:]
        var activeProfileIDByUser: [String: String] = [:]

        private enum CodingKeys: String, CodingKey { case profilesByUser, activeProfileIDByUser }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            profilesByUser = try container.decodeIfPresent(
                [String: [NativeWorkspaceLayoutProfile]].self,
                forKey: .profilesByUser
            ) ?? [:]
            activeProfileIDByUser = try container.decodeIfPresent(
                [String: String].self,
                forKey: .activeProfileIDByUser
            ) ?? [:]
        }
    }

    @Published private(set) var profiles: [NativeWorkspaceLayoutProfile] = []
    @Published private(set) var activeLayoutID = NativeWorkspaceLayoutKind.writing.profileID
    @Published var editorMode = ArticleEditorMode.livePreview
    @Published var editorSidebarPane = NativeEditorSidebarPane.settings
    @Published var isEditorSidebarVisible = true
    @Published var readerInspectorPane = ArticleInspectorPane.context
    @Published var isReaderInspectorVisible = true
    @Published var navigationSidebarWidth: Double = 250
    @Published var editorSidebarWidth: Double = 300
    @Published var readerInspectorWidth: Double = 320
    @Published var splitFraction: Double = 0.5

    private let defaults: UserDefaults
    private let defaultsKey = "leon-book.workspace-layouts.v2"
    private let legacyDefaultsKey = "leon-book.workspace-layouts.v1"
    private var archive: Archive
    private var currentUserID: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = defaults.data(forKey: defaultsKey) ?? defaults.data(forKey: legacyDefaultsKey)
        archive = data.flatMap { try? JSONDecoder().decode(Archive.self, from: $0) } ?? Archive()
    }

    var activeProfile: NativeWorkspaceLayoutProfile? {
        profiles.first(where: { $0.id == activeLayoutID })
    }

    var activeName: String { activeProfile?.name ?? "工作区" }
    var activeSystemImage: String { activeProfile?.systemImage ?? "rectangle.3.group" }

    func prepare(for userID: String) {
        reloadArchive()
        currentUserID = userID
        profiles = profilesForUser(userID)
        let requestedID = archive.activeProfileIDByUser[userID]
        activeLayoutID = profiles.contains(where: { $0.id == requestedID })
            ? requestedID! : NativeWorkspaceLayoutKind.writing.profileID
        if !profiles.contains(where: { $0.id == activeLayoutID }) {
            activeLayoutID = profiles[0].id
        }
        if let profile = activeProfile { apply(profile) }
    }

    func portableState(for userID: String) -> NativePortableLayoutState {
        if currentUserID != userID { prepare(for: userID) }
        return NativePortableLayoutState(
            profiles: profiles,
            activeProfileID: activeLayoutID
        )
    }

    func applyPortableState(_ state: NativePortableLayoutState, for userID: String) {
        var imported: [NativeWorkspaceLayoutProfile] = []
        var seenIDs = Set<String>()
        for profile in state.profiles.prefix(50) {
            let id = profile.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id.count <= 120, seenIDs.insert(id).inserted else { continue }
            imported.append(profile.normalized)
        }
        for kind in NativeWorkspaceLayoutKind.allCases
            where !imported.contains(where: { $0.id == kind.profileID }) {
            imported.append(.defaultProfile(for: kind))
        }
        guard !imported.isEmpty else { return }
        let activeID = imported.contains(where: { $0.id == state.activeProfileID })
            ? state.activeProfileID
            : NativeWorkspaceLayoutKind.writing.profileID
        archive.profilesByUser[userID] = imported
        archive.activeProfileIDByUser[userID] = activeID
        persistArchive()
        currentUserID = userID
        profiles = imported
        activeLayoutID = activeID
        if let profile = activeProfile { apply(profile) }
    }

    @discardableResult
    func activate(_ id: String, for userID: String) -> NativeWorkspaceLayoutProfile? {
        if currentUserID != userID { prepare(for: userID) }
        guard let profile = profiles.first(where: { $0.id == id }) else { return nil }
        activeLayoutID = profile.id
        apply(profile)
        archive.activeProfileIDByUser[userID] = profile.id
        persistArchive()
        return profile
    }

    @discardableResult
    func saveActiveLayout(
        for userID: String,
        destination: NativeWorkspaceLayoutDestination,
        tabs: [NativeArticleTab],
        activeTabID: UUID?
    ) -> NativeWorkspaceLayoutProfile? {
        if currentUserID != userID { prepare(for: userID) }
        guard let index = profiles.firstIndex(where: { $0.id == activeLayoutID }) else { return nil }
        var profile = currentProfile(
            identity: profiles[index],
            destination: destination,
            tabs: tabs,
            activeTabID: activeTabID
        ).normalized
        if let builtIn = profile.builtInKind {
            profile.id = builtIn.profileID
        }
        profiles[index] = profile
        storeProfiles(for: userID)
        return profile
    }

    @discardableResult
    func createLayout(
        named name: String,
        for userID: String,
        destination: NativeWorkspaceLayoutDestination,
        tabs: [NativeArticleTab],
        activeTabID: UUID?,
        navigationSidebarWidth: Double,
        editorSidebarWidth: Double,
        readerInspectorWidth: Double,
        splitFraction: Double
    ) -> NativeWorkspaceLayoutProfile {
        if currentUserID != userID { prepare(for: userID) }
        var identity = activeProfile ?? .defaultProfile(for: .writing)
        identity.id = UUID().uuidString.lowercased()
        identity.name = uniqueName(name)
        identity.systemImage = "rectangle.3.group"
        identity.builtInKind = nil
        self.navigationSidebarWidth = navigationSidebarWidth
        self.editorSidebarWidth = editorSidebarWidth
        self.readerInspectorWidth = readerInspectorWidth
        self.splitFraction = splitFraction
        let profile = currentProfile(
            identity: identity,
            destination: destination,
            tabs: tabs,
            activeTabID: activeTabID
        ).normalized
        profiles.append(profile)
        activeLayoutID = profile.id
        apply(profile)
        storeProfiles(for: userID)
        return profile
    }

    func renameActiveLayout(to name: String, for userID: String) {
        guard let index = profiles.firstIndex(where: { $0.id == activeLayoutID }),
              profiles[index].builtInKind == nil else { return }
        profiles[index].name = uniqueName(name, excluding: profiles[index].id)
        profiles[index] = profiles[index].normalized
        storeProfiles(for: userID)
    }

    @discardableResult
    func deleteActiveLayout(for userID: String) -> NativeWorkspaceLayoutProfile? {
        guard profiles.count > 1,
              let index = profiles.firstIndex(where: { $0.id == activeLayoutID }),
              profiles[index].builtInKind == nil else { return activeProfile }
        profiles.remove(at: index)
        let next = profiles[min(index, profiles.count - 1)]
        activeLayoutID = next.id
        apply(next)
        storeProfiles(for: userID)
        return next
    }

    @discardableResult
    func resetActiveLayout(for userID: String) -> NativeWorkspaceLayoutProfile? {
        guard let kind = activeProfile?.builtInKind,
              let index = profiles.firstIndex(where: { $0.id == activeLayoutID }) else { return activeProfile }
        let profile = NativeWorkspaceLayoutProfile.defaultProfile(for: kind)
        profiles[index] = profile
        apply(profile)
        storeProfiles(for: userID)
        return profile
    }

    func updateGeometry(
        navigationSidebarWidth: Double,
        editorSidebarWidth: Double,
        readerInspectorWidth: Double,
        splitFraction: Double
    ) {
        self.navigationSidebarWidth = min(max(navigationSidebarWidth, 210), 380)
        self.editorSidebarWidth = min(max(editorSidebarWidth, 240), 460)
        self.readerInspectorWidth = min(max(readerInspectorWidth, 260), 480)
        self.splitFraction = min(max(splitFraction, 0.25), 0.75)
    }

    func isModified(
        destination: NativeWorkspaceLayoutDestination,
        tabs: [NativeArticleTab],
        activeTabID: UUID?
    ) -> Bool {
        guard let activeProfile else { return false }
        return currentProfile(
            identity: activeProfile,
            destination: destination,
            tabs: tabs,
            activeTabID: activeTabID
        ).normalized != activeProfile.normalized
    }

    private func currentProfile(
        identity: NativeWorkspaceLayoutProfile,
        destination: NativeWorkspaceLayoutDestination,
        tabs: [NativeArticleTab],
        activeTabID: UUID?
    ) -> NativeWorkspaceLayoutProfile {
        NativeWorkspaceLayoutProfile(
            id: identity.id,
            name: identity.name,
            systemImage: identity.systemImage,
            builtInKind: identity.builtInKind,
            destination: destination,
            editorMode: editorMode,
            editorSidebarPane: editorSidebarPane,
            isEditorSidebarVisible: isEditorSidebarVisible,
            readerInspectorPane: readerInspectorPane,
            isReaderInspectorVisible: isReaderInspectorVisible,
            tabs: tabs,
            activeTabID: activeTabID,
            navigationSidebarWidth: navigationSidebarWidth,
            editorSidebarWidth: editorSidebarWidth,
            readerInspectorWidth: readerInspectorWidth,
            splitFraction: splitFraction
        )
    }

    private func profilesForUser(_ userID: String) -> [NativeWorkspaceLayoutProfile] {
        var stored = archive.profilesByUser[userID] ?? []
        for kind in NativeWorkspaceLayoutKind.allCases where !stored.contains(where: { $0.id == kind.profileID }) {
            stored.append(.defaultProfile(for: kind))
        }
        return stored.map(\.normalized)
    }

    private func apply(_ profile: NativeWorkspaceLayoutProfile) {
        editorMode = profile.editorMode
        editorSidebarPane = profile.editorSidebarPane
        isEditorSidebarVisible = profile.isEditorSidebarVisible
        readerInspectorPane = profile.readerInspectorPane
        isReaderInspectorVisible = profile.isReaderInspectorVisible
        navigationSidebarWidth = profile.navigationSidebarWidth
        editorSidebarWidth = profile.editorSidebarWidth
        readerInspectorWidth = profile.readerInspectorWidth
        splitFraction = profile.splitFraction
    }

    private func uniqueName(_ source: String, excluding excludedID: String? = nil) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = String((trimmed.isEmpty ? "工作区" : trimmed).prefix(40))
        let used = Set(profiles.filter { $0.id != excludedID }.map { $0.name.lowercased() })
        guard used.contains(base.lowercased()) else { return base }
        var suffix = 2
        while used.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
    }

    private func storeProfiles(for userID: String) {
        archive.profilesByUser[userID] = profiles
        archive.activeProfileIDByUser[userID] = activeLayoutID
        persistArchive()
    }

    private func persistArchive() {
        guard let data = try? JSONEncoder().encode(archive) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    private func reloadArchive() {
        let data = defaults.data(forKey: defaultsKey) ?? defaults.data(forKey: legacyDefaultsKey)
        guard let data,
              let stored = try? JSONDecoder().decode(Archive.self, from: data) else { return }
        archive = stored
    }
}

private struct NativeWorkspaceLayoutEditorRequest: Identifiable {
    enum Mode { case create, edit }
    let id = UUID()
    let mode: Mode
}

struct NativeWorkspaceLayoutMenu: View {
    @ObservedObject var model: NativeAppModel
    @ObservedObject var workspaceLayout: NativeWorkspaceLayoutState
    @State private var editorRequest: NativeWorkspaceLayoutEditorRequest?

    private var currentDestination: NativeWorkspaceLayoutDestination {
        model.section == .reader ? .reader : .editor
    }

    private var isModified: Bool {
        workspaceLayout.isModified(
            destination: currentDestination,
            tabs: model.articleTabs,
            activeTabID: model.activeArticleTabID
        )
    }

    var body: some View {
        Menu {
            Section("切换工作区") {
                ForEach(workspaceLayout.profiles) { profile in
                    Button {
                        guard let activated = workspaceLayout.activate(profile.id, for: model.currentUser.id) else { return }
                        apply(activated)
                    } label: {
                        Label(
                            profile.name,
                            systemImage: workspaceLayout.activeLayoutID == profile.id
                                ? "checkmark" : profile.systemImage
                        )
                    }
                }
            }

            Divider()

            Button {
                _ = workspaceLayout.saveActiveLayout(
                    for: model.currentUser.id,
                    destination: currentDestination,
                    tabs: model.articleTabs,
                    activeTabID: model.activeArticleTabID
                )
            } label: {
                Label("保存当前工作区", systemImage: "square.and.arrow.down")
            }

            Button {
                editorRequest = NativeWorkspaceLayoutEditorRequest(mode: .create)
            } label: {
                Label("另存为新工作区…", systemImage: "plus.rectangle.on.rectangle")
            }

            Button {
                editorRequest = NativeWorkspaceLayoutEditorRequest(mode: .edit)
            } label: {
                Label("名称与尺寸…", systemImage: "slider.horizontal.3")
            }

            if workspaceLayout.activeProfile?.builtInKind != nil {
                Button {
                    if let profile = workspaceLayout.resetActiveLayout(for: model.currentUser.id) { apply(profile) }
                } label: {
                    Label("恢复内置默认布局", systemImage: "arrow.counterclockwise")
                }
            } else {
                Button(role: .destructive) {
                    if let profile = workspaceLayout.deleteActiveLayout(for: model.currentUser.id) { apply(profile) }
                } label: {
                    Label("删除当前工作区", systemImage: "trash")
                }
            }
        } label: {
            Label(
                isModified ? "\(workspaceLayout.activeName) · 未保存" : workspaceLayout.activeName,
                systemImage: workspaceLayout.activeSystemImage
            )
        }
        .help("切换或保存包含标签页、侧栏和分栏状态的工作区")
        .sheet(item: $editorRequest) { request in
            NativeWorkspaceLayoutEditorSheet(
                mode: request.mode,
                initialName: request.mode == .create ? "新工作区" : workspaceLayout.activeName,
                navigationSidebarWidth: workspaceLayout.navigationSidebarWidth,
                editorSidebarWidth: workspaceLayout.editorSidebarWidth,
                readerInspectorWidth: workspaceLayout.readerInspectorWidth,
                splitFraction: workspaceLayout.splitFraction
            ) { name, navigationWidth, editorWidth, readerWidth, fraction in
                workspaceLayout.updateGeometry(
                    navigationSidebarWidth: navigationWidth,
                    editorSidebarWidth: editorWidth,
                    readerInspectorWidth: readerWidth,
                    splitFraction: fraction
                )
                switch request.mode {
                case .create:
                    let profile = workspaceLayout.createLayout(
                        named: name,
                        for: model.currentUser.id,
                        destination: currentDestination,
                        tabs: model.articleTabs,
                        activeTabID: model.activeArticleTabID,
                        navigationSidebarWidth: navigationWidth,
                        editorSidebarWidth: editorWidth,
                        readerInspectorWidth: readerWidth,
                        splitFraction: fraction
                    )
                    apply(profile)
                case .edit:
                    workspaceLayout.renameActiveLayout(to: name, for: model.currentUser.id)
                    _ = workspaceLayout.saveActiveLayout(
                        for: model.currentUser.id,
                        destination: currentDestination,
                        tabs: model.articleTabs,
                        activeTabID: model.activeArticleTabID
                    )
                }
            }
        }
    }

    private func apply(_ profile: NativeWorkspaceLayoutProfile) {
        if !profile.tabs.isEmpty {
            model.restoreWorkspaceTabs(profile.tabs, activeTabID: profile.activeTabID)
        }
        switch profile.destination {
        case .editor: model.section = .editor
        case .reader: model.section = model.selectedArticle == nil ? .articles : .reader
        }
    }
}

private struct NativeWorkspaceLayoutEditorSheet: View {
    let mode: NativeWorkspaceLayoutEditorRequest.Mode
    let onSave: (String, Double, Double, Double, Double) -> Void
    @State private var name: String
    @State private var navigationSidebarWidth: Double
    @State private var editorSidebarWidth: Double
    @State private var readerInspectorWidth: Double
    @State private var splitFraction: Double
    @Environment(\.dismiss) private var dismiss

    init(
        mode: NativeWorkspaceLayoutEditorRequest.Mode,
        initialName: String,
        navigationSidebarWidth: Double,
        editorSidebarWidth: Double,
        readerInspectorWidth: Double,
        splitFraction: Double,
        onSave: @escaping (String, Double, Double, Double, Double) -> Void
    ) {
        self.mode = mode
        self.onSave = onSave
        _name = State(initialValue: initialName)
        _navigationSidebarWidth = State(initialValue: navigationSidebarWidth)
        _editorSidebarWidth = State(initialValue: editorSidebarWidth)
        _readerInspectorWidth = State(initialValue: readerInspectorWidth)
        _splitFraction = State(initialValue: splitFraction)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(mode == .create ? "新建工作区" : "编辑工作区")
                .font(.title2.weight(.semibold))
            Text("工作区会保存文章标签、激活标签、面板、侧栏宽度和编辑分栏比例。")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("工作区名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .disabled(mode == .edit && (name == "写作" || name == "阅读" || name == "审稿"))

            geometrySlider("导航侧栏", value: $navigationSidebarWidth, range: 210...380, suffix: "pt")
            geometrySlider("编辑侧栏", value: $editorSidebarWidth, range: 240...460, suffix: "pt")
            geometrySlider("阅读面板", value: $readerInspectorWidth, range: 260...480, suffix: "pt")
            geometrySlider("编辑分栏", value: $splitFraction, range: 0.25...0.75, suffix: "%", multiplier: 100)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button(mode == .create ? "创建" : "保存") {
                    onSave(name, navigationSidebarWidth, editorSidebarWidth, readerInspectorWidth, splitFraction)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private func geometrySlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String,
        multiplier: Double = 1
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range)
                    .frame(width: 240)
                Text("\(Int((value.wrappedValue * multiplier).rounded()))\(suffix)")
                    .monospacedDigit()
                    .frame(width: 60, alignment: .trailing)
            }
        }
    }
}
