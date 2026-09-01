import Foundation

public enum NativeArticleExtractionReplacement: String, CaseIterable, Identifiable {
    case link
    case embed
    case remove

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .link: return "替换为双链"
        case .embed: return "替换为嵌入"
        case .remove: return "仅移走选区"
        }
    }
}

public enum NativeArticleMergePosition: String, CaseIterable, Identifiable {
    case beginning
    case end

    public var id: String { rawValue }
}

public struct NativeArticleRefactorResult {
    public let primaryArticle: NativeArticle
    public let createdArticles: [NativeArticle]
    public let updatedArticleCount: Int
    public let removedSlugs: [String]

    public init(
        primaryArticle: NativeArticle,
        createdArticles: [NativeArticle] = [],
        updatedArticleCount: Int = 0,
        removedSlugs: [String] = []
    ) {
        self.primaryArticle = primaryArticle
        self.createdArticles = createdArticles
        self.updatedArticleCount = updatedArticleCount
        self.removedSlugs = removedSlugs
    }
}

struct MarkdownArticleSection: Equatable {
    let title: String
    let body: String
}

struct MarkdownArticleExtraction: Equatable {
    let sourceBody: String
    let extractedBody: String
}

public struct NativeArticleBlockReference: Equatable, Hashable, Identifiable {
    public let id: String
    public let preview: String

    public init(id: String, preview: String) {
        self.id = id
        self.preview = preview
    }

    public var scrollAnchorID: String { Self.scrollAnchorID(for: id) }

    public static func scrollAnchorID(for id: String) -> String {
        "markdown-block-\(id)"
    }
}

enum ArticleKnowledgeComposer {
    static func extract(
        from body: String,
        selectedRange: NSRange,
        targetSlug: String,
        replacement: NativeArticleExtractionReplacement
    ) throws -> MarkdownArticleExtraction {
        let source = body as NSString
        guard selectedRange.location != NSNotFound,
              selectedRange.location >= 0,
              selectedRange.length > 0,
              NSMaxRange(selectedRange) <= source.length else {
            throw NativeStoreError.invalidArticleSelection
        }
        let extracted = source.substring(with: selectedRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !extracted.isEmpty else { throw NativeStoreError.invalidArticleSelection }

        let replacementText: String
        switch replacement {
        case .link: replacementText = "[[\(targetSlug)]]"
        case .embed: replacementText = "![[\(targetSlug)]]"
        case .remove: replacementText = ""
        }
        let mutable = NSMutableString(string: body)
        mutable.replaceCharacters(in: selectedRange, with: replacementText)
        return MarkdownArticleExtraction(
            sourceBody: normalizedBody(mutable as String),
            extractedBody: extracted
        )
    }

    static func level2Sections(in body: String) -> (preamble: String, sections: [MarkdownArticleSection]) {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var headings: [(index: Int, title: String)] = []
        var activeFence: (marker: Character, length: Int)?

        for (index, line) in lines.enumerated() {
            if let fence = activeFence {
                if closesFence(line, fence: fence) { activeFence = nil }
                continue
            }
            if let fence = opensFence(line) {
                activeFence = fence
                continue
            }
            guard let title = level2HeadingTitle(line) else { continue }
            headings.append((index, title))
        }
        guard !headings.isEmpty else { return (normalizedBody(body), []) }

        let preamble = lines[..<headings[0].index]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var sections: [MarkdownArticleSection] = []
        for (offset, heading) in headings.enumerated() {
            let end = offset + 1 < headings.count ? headings[offset + 1].index : lines.count
            let contentStart = min(heading.index + 1, end)
            let content = lines[contentStart..<end]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            sections.append(MarkdownArticleSection(title: heading.title, body: content))
        }
        return (preamble, sections)
    }

    static func splitIndexBody(
        preamble: String,
        targets: [(title: String, slug: String)],
        replacement: NativeArticleExtractionReplacement
    ) -> String {
        let references = targets.map { target -> String in
            switch replacement {
            case .link: return "- [[\(target.slug)|\(target.title)]]"
            case .embed: return "![[\(target.slug)]]"
            case .remove: return ""
            }
        }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return normalizedBody([preamble, references].filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.joined(separator: "\n\n"))
    }

    static func mergedBody(
        source: NativeArticle,
        destination: NativeArticle,
        position: NativeArticleMergePosition
    ) -> String {
        let sourceSection = "## \(source.title)\n\n\(source.body)"
        switch position {
        case .beginning:
            return normalizedBody("\(sourceSection)\n\n\(destination.body)")
        case .end:
            return normalizedBody("\(destination.body)\n\n\(sourceSection)")
        }
    }

    static func retargetingArticleReferences(
        in body: String,
        source: NativeArticle,
        destinationSlug: String
    ) -> String {
        let targets = Set([
            source.slug,
            source.title,
            source.sourceRelativePath,
            withoutMarkdownExtension(source.sourceRelativePath),
        ].map(normalizedReference))
        let expression = try! NSRegularExpression(pattern: #"(!?)\[\[([^\[\]\r\n]+)\]\]"#)
        let mutable = NSMutableString(string: body)
        let matches = expression.matches(in: body, range: NSRange(body.startIndex..., in: body))
        for match in matches.reversed() {
            guard let innerRange = Range(match.range(at: 2), in: body) else { continue }
            let inner = String(body[innerRange])
            let aliasParts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let destinationParts = aliasParts[0].split(
                separator: "#",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            let target = normalizedReference(String(destinationParts[0]))
            guard targets.contains(target) else { continue }

            var replacement = destinationSlug
            if destinationParts.count == 2 { replacement += "#\(destinationParts[1])" }
            if aliasParts.count == 2 { replacement += "|\(aliasParts[1])" }
            mutable.replaceCharacters(in: match.range(at: 2), with: replacement)
        }
        return mutable as String
    }

    static func fragment(in body: String, selector: String?) -> String? {
        guard let selector = selector?.trimmingCharacters(in: .whitespacesAndNewlines),
              !selector.isEmpty else { return normalizedBody(body) }
        if selector.hasPrefix("^") {
            return block(in: body, identifier: String(selector.dropFirst()))
        }
        return headingSection(in: body, title: selector)
    }

    static func blockReferences(in body: String) -> [NativeArticleBlockReference] {
        let lines = body.components(separatedBy: .newlines)
        let expression = blockMarkerExpression(identifier: nil)
        var activeFence: (marker: Character, length: Int)?
        var references: [NativeArticleBlockReference] = []
        var seen = Set<String>()

        for line in lines {
            if let fence = activeFence {
                if closesFence(line, fence: fence) { activeFence = nil }
                continue
            }
            if let fence = opensFence(line) {
                activeFence = fence
                continue
            }
            guard let match = expression.firstMatch(
                in: line,
                range: NSRange(line.startIndex..., in: line)
            ), let idRange = Range(match.range(at: 1), in: line) else { continue }
            let id = String(line[idRange])
            guard seen.insert(id).inserted,
                  let fragment = block(in: body, identifier: id) else { continue }
            let preview = NativeBlockHierarchyMetadata.removingMarkers(from: fragment)
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(
                    of: #"(?:^|\s)\^[A-Za-z0-9-]+(?=\s|$)"#,
                    with: "",
                    options: .regularExpression
                )
                .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            references.append(NativeArticleBlockReference(
                id: id,
                preview: String(preview.prefix(160))
            ))
        }
        return references
    }

    static func toggleTask(in body: String, lineIndex: Int, completed: Bool) throws -> String {
        var lines = body.components(separatedBy: .newlines)
        guard lines.indices.contains(lineIndex) else { throw NativeStoreError.notFound }
        let expression = try! NSRegularExpression(pattern: #"^(\s*[-+*]\s+)\[([^\]])\](\s+.*)$"#)
        let line = lines[lineIndex]
        let range = NSRange(line.startIndex..., in: line)
        guard let match = expression.firstMatch(in: line, range: range),
              let prefixRange = Range(match.range(at: 1), in: line),
              let suffixRange = Range(match.range(at: 3), in: line) else {
            throw NativeStoreError.notFound
        }
        lines[lineIndex] = "\(line[prefixRange])[\(completed ? "x" : " ")]\(line[suffixRange])"
        return lines.joined(separator: "\n")
    }

    private static func headingSection(in body: String, title: String) -> String? {
        let lines = body.components(separatedBy: .newlines)
        var start: Int?
        var level = 0
        var activeFence: (marker: Character, length: Int)?
        for index in lines.indices {
            let line = lines[index]
            if let fence = activeFence {
                if closesFence(line, fence: fence) { activeFence = nil }
                continue
            }
            if let fence = opensFence(line) {
                activeFence = fence
                continue
            }
            guard let heading = heading(in: line) else { continue }
            if let start, heading.level <= level {
                return normalizedBody(lines[start..<index].joined(separator: "\n"))
            }
            if start == nil, heading.title.caseInsensitiveCompare(title) == .orderedSame {
                start = index + 1
                level = heading.level
            }
        }
        guard let start else { return nil }
        return normalizedBody(lines[start...].joined(separator: "\n"))
    }

    private static func block(in body: String, identifier: String) -> String? {
        guard !identifier.isEmpty else { return nil }
        let lines = body.components(separatedBy: .newlines)
        let expression = blockMarkerExpression(identifier: identifier)
        var markerIndex: Int?
        var activeFence: (marker: Character, length: Int)?
        for index in lines.indices {
            let line = lines[index]
            if let fence = activeFence {
                if closesFence(line, fence: fence) { activeFence = nil }
                continue
            }
            if let fence = opensFence(line) {
                activeFence = fence
                continue
            }
            if expression.firstMatch(
                in: line,
                range: NSRange(line.startIndex..., in: line)
            ) != nil {
                markerIndex = index
                break
            }
        }
        guard let markerIndex else { return nil }

        let markerLine = lines[markerIndex]
        let cleaned = expression.stringByReplacingMatches(
            in: markerLine,
            range: NSRange(markerLine.startIndex..., in: markerLine),
            withTemplate: ""
        ).trimmingCharacters(in: .whitespaces)
        if !cleaned.isEmpty { return cleaned }

        var start = markerIndex
        while start > 0, !lines[start - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            start -= 1
        }
        guard start < markerIndex else { return nil }
        return normalizedBody(lines[start..<markerIndex].joined(separator: "\n"))
    }

    private static func blockMarkerExpression(identifier: String?) -> NSRegularExpression {
        let capture = identifier.map(NSRegularExpression.escapedPattern(for:))
            ?? "([A-Za-z0-9-]+)"
        return try! NSRegularExpression(pattern: #"(?:^|\s)\^"# + capture + #"\s*$"#)
    }

    private static func level2HeadingTitle(_ line: String) -> String? {
        guard let heading = heading(in: line), heading.level == 2 else { return nil }
        return heading.title
    }

    private static func heading(in line: String) -> (level: Int, title: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix { $0 == "#" }
        guard !hashes.isEmpty, hashes.count <= 6 else { return nil }
        let remainder = trimmed.dropFirst(hashes.count)
        guard remainder.first?.isWhitespace == true else { return nil }
        let title = remainder.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"[ \t]+#+[ \t]*$"#, with: "", options: .regularExpression)
        return title.isEmpty ? nil : (hashes.count, title)
    }

    private static func opensFence(_ line: String) -> (marker: Character, length: Int)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let run = trimmed.prefix { $0 == marker }
        return run.count >= 3 ? (marker, run.count) : nil
    }

    private static func closesFence(_ line: String, fence: (marker: Character, length: Int)) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let run = trimmed.prefix { $0 == fence.marker }
        return run.count >= fence.length
            && trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func normalizedBody(_ body: String) -> String {
        body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func withoutMarkdownExtension(_ path: String) -> String {
        path.lowercased().hasSuffix(".md") ? String(path.dropLast(3)) : path
    }

    private static func normalizedReference(_ value: String) -> String {
        withoutMarkdownExtension(value)
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "./"))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

/// Stable read-only interface used by transclusion views and tests. Keeping
/// fragment selection here prevents the renderer from owning Markdown edits.
public enum NativeArticleEmbed {
    public static func fragment(in body: String, selector: String? = nil) -> String? {
        ArticleKnowledgeComposer.fragment(in: body, selector: selector)
    }

    public static func blockReferences(in body: String) -> [NativeArticleBlockReference] {
        ArticleKnowledgeComposer.blockReferences(in: body)
    }
}
