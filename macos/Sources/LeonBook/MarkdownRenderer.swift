import Foundation
import SwiftUI

/// A local, dependency-free Markdown document renderer.
///
/// Image blocks are deliberately handled by `MarkdownArticleBody`: it resolves
/// `media/...` URLs through the workspace store before presenting them. This
/// view is responsible for the remaining CommonMark blocks plus the commonly
/// used GFM tables and task-list syntax.
struct MarkdownDocumentView: View {
    let markdown: String

    private var blocks: [MarkdownBlock] {
        MarkdownParser.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

private enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MarkdownListItem])
    case blockQuote(String)
    case codeBlock(language: String?, code: String)
    case thematicBreak
    case table(headers: [String], alignments: [MarkdownTableAlignment], rows: [[String]])
}

private struct MarkdownListItem {
    let depth: Int
    let marker: String
    let text: String
    let taskState: Bool?
}

private enum MarkdownTableAlignment {
    case leading
    case center
    case trailing
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case let .heading(level, text):
            inlineMarkdownText(text)
                .font(headingFont(for: level))
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .paragraph(text):
            inlineMarkdownText(text)
                .font(.system(size: 16, design: .serif))
                .lineSpacing(6)
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .list(items):
            MarkdownListView(items: items)

        case let .blockQuote(source):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.72))
                    .frame(width: 4)
                MarkdownDocumentView(markdown: source)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)

        case let .codeBlock(language, code):
            VStack(alignment: .leading, spacing: 8) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code.isEmpty ? " " : code)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2))
            }

        case .thematicBreak:
            Divider().padding(.vertical, 5)

        case let .table(headers, alignments, rows):
            MarkdownTableView(headers: headers, alignments: alignments, rows: rows)
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: .system(size: 32, weight: .bold, design: .serif)
        case 2: .system(size: 26, weight: .bold, design: .serif)
        case 3: .system(size: 22, weight: .semibold, design: .serif)
        case 4: .system(size: 19, weight: .semibold, design: .serif)
        case 5: .system(size: 17, weight: .semibold, design: .serif)
        default: .system(size: 16, weight: .semibold, design: .serif)
        }
    }
}

private struct MarkdownListView: View {
    let items: [MarkdownListItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Group {
                        if let taskState = item.taskState {
                            Image(systemName: taskState ? "checkmark.square.fill" : "square")
                                .foregroundStyle(taskState ? Color.accentColor : .secondary)
                        } else {
                            Text(item.marker)
                                .frame(minWidth: 20, alignment: .trailing)
                        }
                    }
                    .frame(width: 24, alignment: .trailing)

                    inlineMarkdownText(item.text)
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
        inlineMarkdownText(value)
            .font(isHeader ? .body.weight(.semibold) : .body)
            .frame(minWidth: 110, alignment: cellAlignment(at: index))
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
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            if let fence = fencedCodeOpening(in: lines[index]) {
                let result = consumeFencedCode(lines, from: index, fence: fence)
                blocks.append(.codeBlock(language: fence.language, code: result.code))
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
                blocks.append(.blockQuote(result.source))
                index = result.nextIndex
                continue
            }

            if listItem(in: lines[index]) != nil {
                let result = consumeList(lines, from: index)
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

        return blocks
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

    private static func listItem(in line: String) -> MarkdownListItem? {
        let expandedTabs = line.replacingOccurrences(of: "\t", with: "    ")
        let indentation = expandedTabs.prefix { $0 == " " }.count
        let content = expandedTabs.dropFirst(indentation)
        guard !content.isEmpty else { return nil }

        let marker: String
        let afterMarker: Substring
        if let first = content.first, ["-", "+", "*"].contains(first), content.dropFirst().first?.isWhitespace == true {
            marker = String(first)
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
        return MarkdownListItem(depth: indentation / 2, marker: marker, text: text, taskState: taskState)
    }

    private static func consumeList(_ lines: [String], from start: Int) -> (items: [MarkdownListItem], nextIndex: Int) {
        var index = start
        var items: [MarkdownListItem] = []
        while index < lines.count {
            if let item = listItem(in: lines[index]) {
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
            items.append(MarkdownListItem(depth: last.depth, marker: last.marker, text: "\(last.text)\n\(continuation)", taskState: last.taskState))
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
            table(at: index, in: lines) != nil
    }
}

private func inlineMarkdownText(_ source: String) -> Text {
    let fragments = source.components(separatedBy: "~~")
    let delimiterCount = fragments.count - 1

    // Strikethrough is a GFM extension. Parse it explicitly so that its
    // presentation does not depend on the system Markdown parser version.
    guard delimiterCount >= 2, delimiterCount.isMultiple(of: 2) else {
        return markdownInlineFragment(source)
    }

    return fragments.enumerated().reduce(Text("")) { rendered, fragment in
        let text = markdownInlineFragment(fragment.element)
        return rendered + (fragment.offset.isMultiple(of: 2) ? text : text.strikethrough())
    }
}

private func markdownInlineFragment(_ source: String) -> Text {
    if let attributed = try? AttributedString(markdown: source) {
        return Text(attributed)
    }
    return Text(source)
}
