import Foundation

/// Portable Markdown metadata for editor-only block hierarchy and collapse state.
/// Readers remove the marker before semantic parsing, so ordinary Markdown remains clean.
enum NativeBlockHierarchyMetadata {
    private static let expression = try! NSRegularExpression(
        pattern: #"[ \t]*<!--\s*leon:block\s+depth=(\d+)(?:\s+collapsed=(true|false))?\s*-->[ \t]*"#,
        options: [.caseInsensitive]
    )

    static func extract(from markdown: String) -> (markdown: String, depth: Int, isCollapsed: Bool) {
        let range = NSRange(markdown.startIndex..., in: markdown)
        let matches = expression.matches(in: markdown, range: range)
        guard let match = matches.last else { return (markdown, 0, false) }
        let depth = Range(match.range(at: 1), in: markdown)
            .flatMap { Int(markdown[$0]) } ?? 0
        let isCollapsed = Range(match.range(at: 2), in: markdown)
            .map { markdown[$0].lowercased() == "true" } ?? false
        let cleaned = expression.stringByReplacingMatches(
            in: markdown,
            range: range,
            withTemplate: " "
        )
        return (
            cleaned.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
                .replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .newlines),
            min(max(depth, 0), 12),
            isCollapsed
        )
    }

    static func removingMarkers(from markdown: String) -> String {
        let range = NSRange(markdown.startIndex..., in: markdown)
        return expression.stringByReplacingMatches(in: markdown, range: range, withTemplate: " ")
    }

    static func attaching(to markdown: String, depth: Int, isCollapsed: Bool) -> String {
        guard depth > 0 || isCollapsed else { return markdown }
        let marker = "<!-- leon:block depth=\(min(max(depth, 0), 12)) collapsed=\(isCollapsed) -->"
        let lines = markdown.components(separatedBy: .newlines)
        if lines.count > 1,
           let last = lines.last,
           last.trimmingCharacters(in: .whitespaces).hasPrefix("^") {
            var updated = lines
            let contentIndex = max(0, updated.count - 2)
            updated[contentIndex] = updated[contentIndex].trimmingCharacters(in: .whitespaces) + " \(marker)"
            return updated.joined(separator: "\n")
        }
        let inlineID = try! NSRegularExpression(pattern: #"[ \t]+\^[A-Za-z0-9_-]+[ \t]*$"#)
        let range = NSRange(markdown.startIndex..., in: markdown)
        if let match = inlineID.firstMatch(in: markdown, range: range),
           let markerIndex = Range(match.range, in: markdown)?.lowerBound {
            return String(markdown[..<markerIndex]) + " \(marker)" + String(markdown[markerIndex...])
        }
        return markdown + " \(marker)"
    }
}
