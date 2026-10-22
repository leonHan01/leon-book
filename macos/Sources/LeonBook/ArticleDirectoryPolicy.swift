import Foundation

/// Directory rules shared by navigation, article creation, and resource moves.
enum NativeArticleDirectoryPolicy {
    static let maximumDepth = 5
    static let defaultFolderPath = "未分类"

    static func depth(of path: String) -> Int {
        path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").count
    }

    static func validatedFolderPath(_ path: String, allowsRoot: Bool = false) throws -> String {
        let path = try MarkdownArticleSource.validatedRelativeDirectoryPath(path)
        guard allowsRoot || !path.isEmpty else {
            throw NativeStoreError.fileSystem("文章必须放在目录下，请选择所属目录。")
        }
        guard depth(of: path) <= maximumDepth else {
            throw NativeStoreError.fileSystem("目录最多支持 5 级，无法使用“\(path)”。")
        }
        return path
    }

    static func validateArticlePath(_ path: String) throws {
        let path = try MarkdownArticleSource.validatedRelativePath(path)
        _ = try validatedFolderPath(path.split(separator: "/").dropLast().joined(separator: "/"))
    }

    /// Existing external sources remain readable without moving their files.
    /// Root articles appear in Uncategorized; deeper sources are listed in the
    /// fifth directory, with their original source paths retained on each leaf.
    static func displayFolderPath(_ path: String) -> String {
        let components = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
        return components.isEmpty ? defaultFolderPath : components.prefix(maximumDepth).joined(separator: "/")
    }
}
