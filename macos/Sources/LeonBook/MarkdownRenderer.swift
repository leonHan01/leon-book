import Foundation
import SwiftUI

struct MarkdownOutlineItem: Hashable, Identifiable {
    let id: String
    let level: Int
    let title: String
}

enum MarkdownOutline {
    static func items(in source: String) -> [MarkdownOutlineItem] {
        NativeParsedMarkdownDocument(source: source).outline
    }

    static func anchorID(for headingIndex: Int) -> String {
        "markdown-heading-\(headingIndex)"
    }
}

struct NativeParsedMarkdownDocument {
    let blocks: [MarkdownBlock]
    let outline: [MarkdownOutlineItem]

    init(source: String, lineOffset: Int = 0) {
        blocks = MarkdownParser.parse(source, lineOffset: lineOffset)
        var headings: [MarkdownOutlineItem] = []
        for block in blocks {
            guard case let .heading(level, title) = block else { continue }
            headings.append(MarkdownOutlineItem(
                id: MarkdownOutline.anchorID(for: headings.count),
                level: level,
                title: title
            ))
        }
        outline = headings
    }
}

/// Renders CommonMark/GFM. Local `/media` URLs are resolved by `MarkdownArticleBody`.
struct MarkdownDocumentView: View {
    let blocks: [MarkdownBlock]
    let articleLinks: [NativeArticleSummary]
    let onOpenArticle: (NativeArticleLinkDestination) -> Void
    let onToggleTask: ((Int, Bool) -> Void)?
    let headingIDs: [String]
    let lineOffset: Int
    @Environment(\.nativeReadingTypography) private var typography

    init(
        markdown: String,
        articleLinks: [NativeArticleSummary],
        onOpenArticle: @escaping (NativeArticleLinkDestination) -> Void,
        onToggleTask: ((Int, Bool) -> Void)? = nil,
        headingIDs: [String] = [],
        lineOffset: Int = 0
    ) {
        blocks = MarkdownParser.parse(markdown, lineOffset: lineOffset)
        self.articleLinks = articleLinks
        self.onOpenArticle = onOpenArticle
        self.onToggleTask = onToggleTask
        self.headingIDs = headingIDs
        self.lineOffset = lineOffset
    }

    init(
        blocks: [MarkdownBlock],
        articleLinks: [NativeArticleSummary],
        onOpenArticle: @escaping (NativeArticleLinkDestination) -> Void,
        onToggleTask: ((Int, Bool) -> Void)? = nil,
        headingIDs: [String] = [],
        lineOffset: Int = 0
    ) {
        self.blocks = blocks
        self.articleLinks = articleLinks
        self.onOpenArticle = onOpenArticle
        self.onToggleTask = onToggleTask
        self.headingIDs = headingIDs
        self.lineOffset = lineOffset
    }

    private var anchoredBlocks: [(block: MarkdownBlock, headingID: String?)] {
        var nextHeadingIndex = 0
        return blocks.map { block in
            guard case .heading = block else { return (block, nil) }
            defer { nextHeadingIndex += 1 }
            let headingID = nextHeadingIndex < headingIDs.count ? headingIDs[nextHeadingIndex] : nil
            return (block, headingID)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: typography.paragraphSpacing) {
            ForEach(Array(anchoredBlocks.enumerated()), id: \.offset) { _, anchoredBlock in
                if let headingID = anchoredBlock.headingID {
                    markdownBlockView(anchoredBlock.block)
                        .id(headingID)
                } else {
                    markdownBlockView(anchoredBlock.block)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(typography.bodyFont.swiftUIFont(size: typography.fontSize))
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.scheme == "leonbook",
                  components.host == "article" else {
                return .systemAction
            }
            let target = components.queryItems?.first(where: { $0.name == "target" })?.value
                ?? components.queryItems?.first(where: { $0.name == "slug" })?.value
                ?? ""
            let heading = components.queryItems?.first(where: { $0.name == "heading" })?.value
            guard !target.isEmpty || heading?.isEmpty == false else { return .systemAction }
            onOpenArticle(NativeArticleLinkDestination(
                target: target,
                resolvedSlug: components.queryItems?.first(where: { $0.name == "slug" })?.value,
                heading: heading,
                label: target
            ))
            return .handled
        })
    }

    private func markdownBlockView(_ block: MarkdownBlock) -> some View {
        MarkdownBlockView(
            block: block,
            articleLinks: articleLinks,
            onOpenArticle: onOpenArticle,
            onToggleTask: onToggleTask
        )
    }
}

struct MarkdownWebEmbed: Hashable {
    let url: URL
    let title: String
    let height: CGFloat
}

struct MarkdownHTMLComponent: Hashable {
    static let defaultHeight: CGFloat = 360

    let html: String
    let height: CGFloat
}

enum MarkdownHTMLComponentParser {
    static func fromFence(_ source: String, infoString: String?) -> MarkdownHTMLComponent? {
        let options = infoString?
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init) ?? []
        guard options.first?.lowercased() == "html-render",
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let requestedHeight = options
            .first(where: { $0.lowercased().hasPrefix("height=") })?
            .split(separator: "=", maxSplits: 1)
            .last
            .flatMap { Double($0) }
            .map { CGFloat($0) } ?? MarkdownHTMLComponent.defaultHeight

        return MarkdownHTMLComponent(
            html: source,
            height: min(max(requestedHeight, 160), 1_200)
        )
    }
}

enum MarkdownWebEmbedParser {
    static func fromURL(_ source: String, title: String = "网页嵌入", height: CGFloat = 480) -> MarkdownWebEmbed? {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil,
              let url = components.url else { return nil }

        let safeHeight = min(max(height, 240), 800)
        let safeTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return MarkdownWebEmbed(
            url: url,
            title: safeTitle.isEmpty ? "网页嵌入" : safeTitle,
            height: safeHeight
        )
    }

    static func fromFence(_ source: String) -> MarkdownWebEmbed? {
        let content = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.range(of: #"(?is)^<iframe\b"#, options: .regularExpression) != nil {
            return fromHTML(content)
        }

        guard let urlLine = content.components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else { return nil }
        return fromURL(urlLine)
    }

    static func fromHTML(_ source: String) -> MarkdownWebEmbed? {
        guard source.range(of: #"(?is)^<iframe\b"#, options: .regularExpression) != nil else {
            return nil
        }

        let closingTag = source.range(of: #"</iframe\s*>"#, options: [.regularExpression, .caseInsensitive])
        let selfClosing = source.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/>")
        guard closingTag != nil || selfClosing else { return nil }

        if let closingTag,
           !source[closingTag.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }

        guard let sourceURL = attribute(named: "src", in: source) else { return nil }
        let title = attribute(named: "title", in: source)
            ?? attribute(named: "aria-label", in: source)
            ?? "网页嵌入"
        let height = attribute(named: "height", in: source)
            .flatMap { Double($0.replacingOccurrences(of: "px", with: "", options: .caseInsensitive)) }
            .map { CGFloat($0) } ?? 480
        return fromURL(sourceURL, title: title, height: height)
    }

    static func block(in lines: [String], from start: Int) -> (embed: MarkdownWebEmbed, nextIndex: Int)? {
        guard start < lines.count,
              lines[start].trimmingCharacters(in: .whitespacesAndNewlines)
                .range(of: #"(?is)^<iframe\b"#, options: .regularExpression) != nil else { return nil }

        var source = lines[start].trimmingCharacters(in: .whitespacesAndNewlines)
        var index = start
        while index + 1 < lines.count,
              source.range(of: #"</iframe\s*>"#, options: [.regularExpression, .caseInsensitive]) == nil,
              !source.hasSuffix("/>") {
            index += 1
            source += " " + lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let embed = fromHTML(source) else { return nil }
        return (embed, index + 1)
    }

    private static func attribute(named name: String, in source: String) -> String? {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*["']([^"']+)["']"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let valueRange = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[valueRange]).replacingOccurrences(of: "&amp;", with: "&")
    }
}

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MarkdownListItem])
    case blockQuote(String)
    case callout(MarkdownCallout)
    case codeBlock(language: String?, code: String)
    case htmlComponent(MarkdownHTMLComponent)
    case webEmbed(MarkdownWebEmbed)
    case thematicBreak
    case table(headers: [String], alignments: [MarkdownTableAlignment], rows: [[String]])
    case footnotes([(id: String, text: String)])
}

struct MarkdownListItem {
    let depth: Int
    let marker: String
    let text: String
    let taskState: Bool?
    let sourceLine: Int
}

struct MarkdownCallout {
    let kind: String
    let title: String
    let body: String
    let foldState: Character?

    static func parse(_ source: String) -> MarkdownCallout? {
        let lines = source.components(separatedBy: .newlines)
        guard let first = lines.first else { return nil }
        let expression = try! NSRegularExpression(
            pattern: #"^\[!([A-Za-z0-9_-]+)\]([+-])?[ \t]*(.*)$"#,
            options: .caseInsensitive
        )
        guard let match = expression.firstMatch(
            in: first,
            range: NSRange(first.startIndex..., in: first)
        ), let kindRange = Range(match.range(at: 1), in: first) else { return nil }
        let kind = String(first[kindRange]).lowercased()
        let title = Range(match.range(at: 3), in: first).map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let foldState = Range(match.range(at: 2), in: first).flatMap { first[$0].first }
        return MarkdownCallout(
            kind: kind,
            title: title?.isEmpty == false ? title! : defaultTitle(for: kind),
            body: lines.dropFirst().joined(separator: "\n"),
            foldState: foldState
        )
    }

    private static func defaultTitle(for kind: String) -> String {
        switch kind {
        case "note": return "笔记"
        case "tip", "hint", "important": return "提示"
        case "warning", "caution", "attention": return "注意"
        case "danger", "error", "bug", "failure": return "警告"
        case "question", "help", "faq": return "问题"
        case "success", "check", "done": return "完成"
        case "quote", "cite": return "引用"
        default: return kind.capitalized
        }
    }
}

enum MarkdownTableAlignment {
    case leading
    case center
    case trailing
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let articleLinks: [NativeArticleSummary]
    let onOpenArticle: (NativeArticleLinkDestination) -> Void
    let onToggleTask: ((Int, Bool) -> Void)?
    @Environment(\.nativeReadingTypography) private var typography
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch block {
        case let .heading(level, text):
            inlineMarkdownText(text, articleLinks: articleLinks)
                .font(headingFont(for: level))
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .paragraph(text):
            inlineMarkdownText(text, articleLinks: articleLinks)
                .font(typography.bodyFont.swiftUIFont(size: typography.fontSize))
                .lineSpacing(typography.lineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .list(items):
            MarkdownListView(
                items: items,
                articleLinks: articleLinks,
                onToggleTask: onToggleTask
            )
                .font(typography.bodyFont.swiftUIFont(size: typography.fontSize))
                .lineSpacing(typography.lineSpacing)

        case let .blockQuote(source):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.72))
                    .frame(width: 4)
                MarkdownDocumentView(
                    markdown: source,
                    articleLinks: articleLinks,
                    onOpenArticle: onOpenArticle,
                    onToggleTask: nil
                )
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)

        case let .callout(callout):
            MarkdownCalloutView(
                callout: callout,
                articleLinks: articleLinks,
                onOpenArticle: onOpenArticle,
                onToggleTask: onToggleTask
            )

        case let .codeBlock(language, code):
            VStack(alignment: .leading, spacing: 8) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code.isEmpty ? " " : code)
                        .font(typography.codeFont.swiftUIFont(size: max(11, typography.fontSize - 2)))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .background(typography.theme.codeBackground(system: colorScheme), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2))
            }

        case let .htmlComponent(component):
            MarkdownHTMLComponentView(component: component)

        case let .webEmbed(embed):
            MarkdownWebEmbedView(embed: embed)

        case .thematicBreak:
            Divider().padding(.vertical, 5)

        case let .table(headers, alignments, rows):
            MarkdownTableView(
                headers: headers,
                alignments: alignments,
                rows: rows,
                articleLinks: articleLinks
            )

        case let .footnotes(notes):
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("[\(note.id)]")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.tint)
                        inlineMarkdownText(note.text, articleLinks: articleLinks)
                            .font(.footnote)
                    }
                }
            }
        }
    }

    private func headingFont(for level: Int) -> Font {
        let scale: CGFloat
        let weight: Font.Weight
        switch level {
        case 1: scale = 1.78; weight = .bold
        case 2: scale = 1.45; weight = .bold
        case 3: scale = 1.23; weight = .semibold
        case 4: scale = 1.08; weight = .semibold
        case 5: scale = 0.98; weight = .semibold
        default: scale = 0.92; weight = .semibold
        }
        return typography.bodyFont.swiftUIFont(
            size: max(13, typography.fontSize * scale),
            weight: weight
        )
    }
}

private struct MarkdownCalloutView: View {
    let callout: MarkdownCallout
    let articleLinks: [NativeArticleSummary]
    let onOpenArticle: (NativeArticleLinkDestination) -> Void
    let onToggleTask: ((Int, Bool) -> Void)?
    @State private var isExpanded: Bool

    init(
        callout: MarkdownCallout,
        articleLinks: [NativeArticleSummary],
        onOpenArticle: @escaping (NativeArticleLinkDestination) -> Void,
        onToggleTask: ((Int, Bool) -> Void)?
    ) {
        self.callout = callout
        self.articleLinks = articleLinks
        self.onOpenArticle = onOpenArticle
        self.onToggleTask = onToggleTask
        _isExpanded = State(initialValue: callout.foldState != "-")
    }

    private var tint: Color {
        switch callout.kind {
        case "warning", "caution", "attention": return .orange
        case "danger", "error", "bug", "failure": return .red
        case "success", "check", "done": return .green
        case "question", "help", "faq": return .purple
        case "tip", "hint", "important": return .mint
        default: return .blue
        }
    }

    private var icon: String {
        switch callout.kind {
        case "warning", "caution", "attention": return "exclamationmark.triangle.fill"
        case "danger", "error", "bug", "failure": return "xmark.octagon.fill"
        case "success", "check", "done": return "checkmark.circle.fill"
        case "question", "help", "faq": return "questionmark.circle.fill"
        case "tip", "hint", "important": return "lightbulb.fill"
        case "quote", "cite": return "quote.opening"
        default: return "info.circle.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if callout.foldState == nil {
                label
                content
            } else {
                DisclosureGroup(isExpanded: $isExpanded) {
                    content.padding(.top, 8)
                } label: {
                    label
                }
            }
        }
        .padding(14)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(tint.opacity(0.85))
                .frame(width: 4)
        }
    }

    private var label: some View {
        Label(callout.title, systemImage: icon)
            .font(.headline)
            .foregroundStyle(tint)
    }

    @ViewBuilder private var content: some View {
        if !callout.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            MarkdownDocumentView(
                markdown: callout.body,
                articleLinks: articleLinks,
                onOpenArticle: onOpenArticle,
                onToggleTask: nil
            )
        }
    }
}

private struct MarkdownListView: View {
    let items: [MarkdownListItem]
    let articleLinks: [NativeArticleSummary]
    let onToggleTask: ((Int, Bool) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Group {
                        if let taskState = item.taskState {
                            Button {
                                onToggleTask?(item.sourceLine, !taskState)
                            } label: {
                                Image(systemName: taskState ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(taskState ? Color.accentColor : .secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(onToggleTask == nil)
                            .accessibilityLabel(taskState ? "标记为未完成" : "标记为已完成")
                        } else {
                            Text(item.marker)
                                .frame(minWidth: 20, alignment: .trailing)
                        }
                    }
                    .frame(width: 24, alignment: .trailing)

                    inlineMarkdownText(item.text, articleLinks: articleLinks)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(item.depth) * 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownTableView: View {
    let headers: [String]
    let alignments: [MarkdownTableAlignment]
    let rows: [[String]]
    let articleLinks: [NativeArticleSummary]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                        tableCell(header, index: index, isHeader: true)
                    }
                }

                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(headers.indices, id: \.self) { index in
                            tableCell(index < row.count ? row[index] : "", index: index, isHeader: false)
                        }
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.secondary.opacity(0.24))
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func tableCell(_ value: String, index: Int, isHeader: Bool) -> some View {
        inlineMarkdownText(value, articleLinks: articleLinks)
            .font(isHeader ? .body.weight(.semibold) : .body)
            // Grid assigns every cell in a column the same width. Expanding into
            // that assigned width keeps each cell's fill and borders continuous
            // when another row contains longer text.
            .frame(minWidth: 110, maxWidth: .infinity, alignment: cellAlignment(at: index))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isHeader ? Color.secondary.opacity(0.1) : Color.clear)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.secondary.opacity(0.18)).frame(height: 1)
            }
            .overlay(alignment: .trailing) {
                Rectangle().fill(Color.secondary.opacity(0.18)).frame(width: 1)
            }
    }

    private func cellAlignment(at index: Int) -> Alignment {
        guard index < alignments.count else { return Alignment.leading }
        switch alignments[index] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

private enum MarkdownParser {
    static func parse(_ source: String, lineOffset: Int = 0) -> [MarkdownBlock] {
        let extracted = extractFootnotes(from: source.components(separatedBy: .newlines))
        let lines = extracted.lines
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            if let result = MarkdownWebEmbedParser.block(in: lines, from: index) {
                blocks.append(.webEmbed(result.embed))
                index = result.nextIndex
                continue
            }

            if let fence = fencedCodeOpening(in: lines[index]) {
                let result = consumeFencedCode(lines, from: index, fence: fence)
                if let component = MarkdownHTMLComponentParser.fromFence(
                    result.code,
                    infoString: fence.language
                ) {
                    blocks.append(.htmlComponent(component))
                } else if fence.language?.lowercased() == "embed",
                   let embed = MarkdownWebEmbedParser.fromFence(result.code) {
                    blocks.append(.webEmbed(embed))
                } else {
                    blocks.append(.codeBlock(language: fence.language, code: result.code))
                }
                index = result.nextIndex
                continue
            }

            if isIndentedCodeLine(lines[index]) {
                let result = consumeIndentedCode(lines, from: index)
                blocks.append(.codeBlock(language: nil, code: result.code))
                index = result.nextIndex
                continue
            }

            if let heading = atxHeading(in: lines[index]) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if index + 1 < lines.count,
               !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
               let level = setextHeadingLevel(in: lines[index + 1]) {
                blocks.append(.heading(level: level, text: lines[index].trimmingCharacters(in: .whitespaces)))
                index += 2
                continue
            }

            if isThematicBreak(lines[index]) {
                blocks.append(.thematicBreak)
                index += 1
                continue
            }

            if isBlockQuote(lines[index]) {
                let result = consumeBlockQuote(lines, from: index)
                if let callout = MarkdownCallout.parse(result.source) {
                    blocks.append(.callout(callout))
                } else {
                    blocks.append(.blockQuote(result.source))
                }
                index = result.nextIndex
                continue
            }

            if listItem(in: lines[index], sourceLine: lineOffset + index) != nil {
                let result = consumeList(lines, from: index, lineOffset: lineOffset)
                blocks.append(.list(result.items))
                index = result.nextIndex
                continue
            }

            if let table = table(at: index, in: lines) {
                blocks.append(table.block)
                index = table.nextIndex
                continue
            }

            let result = consumeParagraph(lines, from: index)
            if !result.text.isEmpty {
                blocks.append(.paragraph(result.text))
            }
            index = result.nextIndex
        }

        if !extracted.notes.isEmpty { blocks.append(.footnotes(extracted.notes)) }

        return blocks
    }

    private static func extractFootnotes(
        from sourceLines: [String]
    ) -> (lines: [String], notes: [(id: String, text: String)]) {
        let expression = try! NSRegularExpression(pattern: #"^\[\^([^\]]+)\]:[ \t]*(.*)$"#)
        var lines = sourceLines
        var notes: [(id: String, text: String)] = []
        for index in sourceLines.indices {
            let line = sourceLines[index]
            guard let match = expression.firstMatch(
                in: line,
                range: NSRange(line.startIndex..., in: line)
            ), let idRange = Range(match.range(at: 1), in: line),
               let textRange = Range(match.range(at: 2), in: line) else { continue }
            notes.append((String(line[idRange]), String(line[textRange])))
            lines[index] = ""
        }
        return (lines, notes)
    }

    private static func atxHeading(in line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix { $0 == "#" }
        guard !hashes.isEmpty, hashes.count <= 6 else { return nil }
        let remainder = trimmed.dropFirst(hashes.count)
        guard remainder.first?.isWhitespace == true else { return nil }
        let text = remainder.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"[ \t]+#+[ \t]*$"#, with: "", options: .regularExpression)
        return (hashes.count, text)
    }

    private static func setextHeadingLevel(in line: String) -> Int? {
        let marker = line.trimmingCharacters(in: .whitespaces)
        guard marker.count >= 1, marker.allSatisfy({ $0 == "=" || $0 == "-" }) else { return nil }
        return marker.first == "=" ? 1 : 2
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let marker = line.filter { !$0.isWhitespace }
        guard marker.count >= 3, let first = marker.first, ["*", "-", "_"].contains(first) else { return false }
        return marker.allSatisfy { $0 == first }
    }

    private static func fencedCodeOpening(in line: String) -> (marker: Character, length: Int, language: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let run = trimmed.prefix { $0 == marker }
        guard run.count >= 3 else { return nil }
        let language = String(trimmed.dropFirst(run.count)).trimmingCharacters(in: .whitespaces)
        return (marker, run.count, language.isEmpty ? nil : language)
    }

    private static func consumeFencedCode(_ lines: [String], from start: Int, fence: (marker: Character, length: Int, language: String?)) -> (code: String, nextIndex: Int) {
        var index = start + 1
        var code: [String] = []
        while index < lines.count {
            let candidate = lines[index].trimmingCharacters(in: .whitespaces)
            let run = candidate.prefix { $0 == fence.marker }
            if run.count >= fence.length, candidate.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty {
                return (code.joined(separator: "\n"), index + 1)
            }
            code.append(lines[index])
            index += 1
        }
        return (code.joined(separator: "\n"), index)
    }

    private static func isIndentedCodeLine(_ line: String) -> Bool {
        line.hasPrefix("    ") || line.hasPrefix("\t")
    }

    private static func consumeIndentedCode(_ lines: [String], from start: Int) -> (code: String, nextIndex: Int) {
        var index = start
        var code: [String] = []
        while index < lines.count {
            if lines[index].hasPrefix("    ") {
                code.append(String(lines[index].dropFirst(4)))
            } else if lines[index].hasPrefix("\t") {
                code.append(String(lines[index].dropFirst()))
            } else if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                code.append("")
            } else {
                break
            }
            index += 1
        }
        while code.last == "" { code.removeLast() }
        return (code.joined(separator: "\n"), index)
    }

    private static func isBlockQuote(_ line: String) -> Bool {
        line.drop { $0 == " " || $0 == "\t" }.first == ">"
    }

    private static func consumeBlockQuote(_ lines: [String], from start: Int) -> (source: String, nextIndex: Int) {
        var index = start
        var quoteLines: [String] = []
        while index < lines.count {
            let line = lines[index]
            let trimmedLeading = line.drop { $0 == " " || $0 == "\t" }
            if trimmedLeading.first == ">" {
                var content = String(trimmedLeading.dropFirst())
                if content.first == " " { content.removeFirst() }
                quoteLines.append(content)
                index += 1
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                quoteLines.append("")
                index += 1
            } else {
                break
            }
        }
        while quoteLines.last == "" { quoteLines.removeLast() }
        return (quoteLines.joined(separator: "\n"), index)
    }

    private static func listItem(in line: String, sourceLine: Int = 0) -> MarkdownListItem? {
        let expandedTabs = line.replacingOccurrences(of: "\t", with: "    ")
        let indentation = expandedTabs.prefix { $0 == " " }.count
        let content = expandedTabs.dropFirst(indentation)
        guard !content.isEmpty else { return nil }

        let marker: String
        let afterMarker: Substring
        if let first = content.first, ["-", "+", "*"].contains(first), content.dropFirst().first?.isWhitespace == true {
            marker = "•"
            afterMarker = content.dropFirst().drop { $0.isWhitespace }
        } else {
            let digits = content.prefix { $0.isNumber }
            guard !digits.isEmpty,
                  let separator = content.dropFirst(digits.count).first,
                  separator == "." || separator == ")",
                  content.dropFirst(digits.count + 1).first?.isWhitespace == true else { return nil }
            marker = "\(digits)\(separator)"
            afterMarker = content.dropFirst(digits.count + 1).drop { $0.isWhitespace }
        }

        var text = String(afterMarker)
        var taskState: Bool?
        if text.hasPrefix("[ ] ") {
            taskState = false
            text.removeFirst(4)
        } else if text.prefix(3).lowercased() == "[x]" {
            taskState = true
            text.removeFirst(3)
            if text.first == " " { text.removeFirst() }
        }
        return MarkdownListItem(
            depth: indentation / 2,
            marker: marker,
            text: text,
            taskState: taskState,
            sourceLine: sourceLine
        )
    }

    private static func consumeList(
        _ lines: [String],
        from start: Int,
        lineOffset: Int
    ) -> (items: [MarkdownListItem], nextIndex: Int) {
        var index = start
        var items: [MarkdownListItem] = []
        while index < lines.count {
            if let item = listItem(in: lines[index], sourceLine: lineOffset + index) {
                items.append(item)
                index += 1
                continue
            }

            if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                let nextIndex = index + 1
                if nextIndex < lines.count, listItem(in: lines[nextIndex]) != nil {
                    index = nextIndex
                    continue
                }
                break
            }

            let indentation = lines[index].prefix { $0 == " " || $0 == "\t" }.count
            guard indentation > 0, !items.isEmpty else { break }
            let last = items.removeLast()
            let continuation = lines[index].trimmingCharacters(in: .whitespaces)
            items.append(MarkdownListItem(
                depth: last.depth,
                marker: last.marker,
                text: "\(last.text)\n\(continuation)",
                taskState: last.taskState,
                sourceLine: last.sourceLine
            ))
            index += 1
        }
        return (items, index)
    }

    private static func table(at index: Int, in lines: [String]) -> (block: MarkdownBlock, nextIndex: Int)? {
        guard index + 1 < lines.count,
              let headers = tableCells(in: lines[index]),
              let delimiterCells = tableCells(in: lines[index + 1]),
              headers.count > 1,
              headers.count == delimiterCells.count else { return nil }

        let alignments = delimiterCells.compactMap(tableAlignment(in:))
        guard alignments.count == headers.count else { return nil }

        var rows: [[String]] = []
        var nextIndex = index + 2
        while nextIndex < lines.count, let row = tableCells(in: lines[nextIndex]), !row.isEmpty {
            rows.append(Array(row.prefix(headers.count)) + Array(repeating: "", count: max(0, headers.count - row.count)))
            nextIndex += 1
        }
        return (.table(headers: headers, alignments: alignments, rows: rows), nextIndex)
    }

    private static func tableCells(in line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var content = line.trimmingCharacters(in: .whitespaces)
        if content.first == "|" { content.removeFirst() }
        if content.last == "|" { content.removeLast() }
        return content.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func tableAlignment(in cell: String) -> MarkdownTableAlignment? {
        let marker = cell.trimmingCharacters(in: .whitespaces)
        let content = marker.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        guard !content.isEmpty, content.allSatisfy({ $0 == "-" }) else { return nil }
        if marker.hasPrefix(":") && marker.hasSuffix(":") { return .center }
        if marker.hasSuffix(":") { return .trailing }
        return .leading
    }

    private static func consumeParagraph(_ lines: [String], from start: Int) -> (text: String, nextIndex: Int) {
        var index = start
        var paragraph: [String] = []
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).isEmpty { break }
            if !paragraph.isEmpty && beginsBlock(at: index, in: lines) { break }
            paragraph.append(lines[index])
            index += 1
        }
        return (paragraph.joined(separator: "\n"), index)
    }

    private static func beginsBlock(at index: Int, in lines: [String]) -> Bool {
        fencedCodeOpening(in: lines[index]) != nil ||
            isIndentedCodeLine(lines[index]) ||
            atxHeading(in: lines[index]) != nil ||
            isThematicBreak(lines[index]) ||
            isBlockQuote(lines[index]) ||
            listItem(in: lines[index]) != nil ||
            MarkdownWebEmbedParser.block(in: lines, from: index) != nil ||
            table(at: index, in: lines) != nil
    }
}

private func inlineMarkdownText(_ source: String, articleLinks: [NativeArticleSummary]) -> Text {
    let highlighted = source.components(separatedBy: "==")
    let highlightDelimiterCount = highlighted.count - 1
    if highlightDelimiterCount >= 2, highlightDelimiterCount.isMultiple(of: 2) {
        return highlighted.enumerated().reduce(Text("")) { rendered, fragment in
            rendered + strikethroughMarkdownText(
                fragment.element,
                articleLinks: articleLinks,
                highlighted: !fragment.offset.isMultiple(of: 2)
            )
        }
    }
    return strikethroughMarkdownText(source, articleLinks: articleLinks, highlighted: false)
}

private func strikethroughMarkdownText(
    _ source: String,
    articleLinks: [NativeArticleSummary],
    highlighted: Bool
) -> Text {
    let fragments = source.components(separatedBy: "~~")
    let delimiterCount = fragments.count - 1

    // Strikethrough is a GFM extension. Parse it explicitly so that its
    // presentation does not depend on the system Markdown parser version.
    guard delimiterCount >= 2, delimiterCount.isMultiple(of: 2) else {
        return markdownInlineFragment(
            source,
            articleLinks: articleLinks,
            highlighted: highlighted
        )
    }

    return fragments.enumerated().reduce(Text("")) { rendered, fragment in
        let text = markdownInlineFragment(
            fragment.element,
            articleLinks: articleLinks,
            highlighted: highlighted
        )
        return rendered + (fragment.offset.isMultiple(of: 2) ? text : text.strikethrough())
    }
}

private func markdownInlineFragment(
    _ source: String,
    articleLinks: [NativeArticleSummary],
    highlighted: Bool
) -> Text {
    let normalizedSource = MarkdownTypography.normalizedFootnotes(
        in: MarkdownTypography.normalizedCJKSpacing(in: source)
    )
    let resolvedSource = MarkdownArticleLinkRenderer.markdown(from: normalizedSource, articleLinks: articleLinks)
    if var attributed = try? AttributedString(markdown: resolvedSource) {
        if highlighted { attributed.backgroundColor = Color.yellow.opacity(0.35) }
        return Text(attributed)
    }
    return Text(resolvedSource)
}

private enum MarkdownTypography {
    private static let cjkPunctuationSpacing = try! NSRegularExpression(
        pattern: #"([，。！？；：、])[ \t]+(?=\p{Han})"#
    )

    static func normalizedCJKSpacing(in source: String) -> String {
        cjkPunctuationSpacing.stringByReplacingMatches(
            in: source,
            range: NSRange(source.startIndex..., in: source),
            withTemplate: "$1"
        )
    }

    static func normalizedFootnotes(in source: String) -> String {
        source
            .replacingOccurrences(
                of: #"\^\[([^\]\r\n]+)\]"#,
                with: "（$1）",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\[\^([^\]\r\n]+)\]"#,
                with: "〔$1〕",
                options: .regularExpression
            )
    }
}

private enum MarkdownArticleLinkRenderer {
    static func markdown(from source: String, articleLinks: [NativeArticleSummary]) -> String {
        let expression = try! NSRegularExpression(pattern: #"(?<!!)\[\[([^\[\]\r\n]+)\]\]"#)
        let searchRange = NSRange(source.startIndex..., in: source)
        let matches = expression.matches(in: source, range: searchRange)
        guard !matches.isEmpty else { return source }

        var rendered = ""
        var cursor = source.startIndex
        for match in matches {
            guard let matchRange = Range(match.range, in: source) else { continue }
            rendered += source[cursor..<matchRange.lowerBound]
            if let referenceRange = Range(match.range(at: 1), in: source),
               let destination = NativeArticleLink.destination(
                for: String(source[referenceRange]),
                in: articleLinks
               ),
               let url = internalURL(destination) {
                rendered += "[\(escapedLabel(destination.label))](\(url))"
            } else {
                rendered += source[matchRange]
            }
            cursor = matchRange.upperBound
        }
        rendered += source[cursor...]
        return rendered
    }

    private static func internalURL(_ destination: NativeArticleLinkDestination) -> String? {
        var components = URLComponents()
        components.scheme = "leonbook"
        components.host = "article"
        components.queryItems = [URLQueryItem(name: "target", value: destination.target)]
        if let slug = destination.resolvedSlug {
            components.queryItems?.append(URLQueryItem(name: "slug", value: slug))
        }
        if let heading = destination.heading {
            components.queryItems?.append(URLQueryItem(name: "heading", value: heading))
        }
        return components.string
    }

    private static func escapedLabel(_ label: String) -> String {
        label
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }
}
