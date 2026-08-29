import Foundation
import LeonBookModuleKit

public enum CaptureFirstPartyModule: FirstPartyModule {
    public static let id = FirstPartyModuleID(rawValue: "capture")
    public static let descriptor = FirstPartyModuleDescriptor(
        id: id,
        name: "采集",
        summary: "扫描与导入普通 Markdown 文件夹或 Obsidian Vault。",
        systemImage: "square.and.arrow.down",
        permissions: [.fileRead, .contentWrite],
        commands: [
            .init(
                id: "capture.markdown-folder",
                title: "采集 Markdown 文件夹",
                detail: "扫描普通文件夹或 Obsidian Vault",
                keywords: "capture import vault 采集 导入",
                systemImage: "square.and.arrow.down",
                availability: .storageReadyAndIdle,
                surfaces: [.palette],
                requiredPermissions: [.fileRead]
            ),
        ],
        eventNames: ["capture.scan-requested", "capture.scanned", "capture.imported", "capture.failed"]
    )
}

public struct FirstPartyCaptureCandidate: Equatable, Sendable {
    public let url: URL
    public let isMarkdown: Bool

    public init(url: URL, isMarkdown: Bool) {
        self.url = url
        self.isMarkdown = isMarkdown
    }
}

/// Owns traversal safety: only regular, non-symlink files resolved inside the
/// selected root can reach the Obsidian parser.
public enum FirstPartyCaptureFilePolicy {
    public static func candidate(
        for url: URL,
        root: URL,
        resourceValues: URLResourceValues
    ) -> FirstPartyCaptureCandidate? {
        guard resourceValues.isRegularFile == true, resourceValues.isSymbolicLink != true else {
            return nil
        }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        guard isInside(resolved, root: resolvedRoot) else { return nil }
        return FirstPartyCaptureCandidate(
            url: resolved,
            isMarkdown: resolved.pathExtension.caseInsensitiveCompare("md") == .orderedSame
        )
    }

    public static func isInside(_ candidate: URL, root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}
