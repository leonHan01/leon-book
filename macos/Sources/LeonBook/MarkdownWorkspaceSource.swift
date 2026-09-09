import Foundation

extension Notification.Name {
    static let leonBookMarkdownConfigurationChanged = Notification.Name("leonBook.markdownConfigurationChanged")
}

/// Controls where article Markdown is read from for one LeonBook user workspace.
/// SQLite, drafts, comments, revisions, media, and backups always remain in the
/// LeonBook workspace; only the authoritative Markdown root changes.
public enum NativeMarkdownWorkspaceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case copyImport
    case readOnlyMount
    case directEdit

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .copyImport: return "复制导入"
        case .readOnlyMount: return "只读挂载"
        case .directEdit: return "直接编辑"
        }
    }

    public var detail: String {
        switch self {
        case .copyImport:
            return "复制 Markdown 和附件到 LeonBook 工作区，之后与原目录互不影响。"
        case .readOnlyMount:
            return "直接读取并监听原目录；LeonBook 不会保存、移动或删除其中的 Markdown。"
        case .directEdit:
            return "直接读取并监听原目录；LeonBook 的保存、移动和删除会原子写回。"
        }
    }

    public var isReadOnly: Bool { self == .readOnlyMount }
    public var isMounted: Bool { self != .copyImport }
}

public struct NativeMarkdownWorkspaceSource: Codable, Equatable, Sendable {
    public let mode: NativeMarkdownWorkspaceMode
    public let directoryPath: String?

    public init(mode: NativeMarkdownWorkspaceMode, directoryPath: String? = nil) {
        self.mode = mode
        self.directoryPath = directoryPath
    }

    public static let managed = NativeMarkdownWorkspaceSource(mode: .copyImport)
}
