import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum EditorMarkdownBlockKind: String, CaseIterable, Identifiable {
    case paragraph
    case heading1
    case heading2
    case heading3
    case bulletedList
    case numberedList
    case task
    case quote
    case callout
    case code
    case table
    case math
    case divider

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paragraph: return "文本"
        case .heading1: return "一级标题"
        case .heading2: return "二级标题"
        case .heading3: return "三级标题"
        case .bulletedList: return "项目列表"
        case .numberedList: return "编号列表"
        case .task: return "待办事项"
        case .quote: return "引用"
        case .callout: return "提示块"
        case .code: return "代码块"
        case .table: return "表格"
        case .math: return "数学公式"
        case .divider: return "分割线"
        }
    }

    var systemImage: String {
        switch self {
        case .paragraph: return "text.alignleft"
        case .heading1, .heading2, .heading3: return "textformat.size"
        case .bulletedList: return "list.bullet"
        case .numberedList: return "list.number"
        case .task: return "checklist"
        case .quote: return "quote.opening"
        case .callout: return "lightbulb"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .table: return "tablecells"
        case .math: return "function"
        case .divider: return "minus"
        }
    }

    var detail: String {
        switch self {
        case .paragraph: return "普通正文块"
        case .heading1: return "最大的章节标题"
        case .heading2: return "二级章节标题"
        case .heading3: return "三级章节标题"
        case .bulletedList: return "无序列表项"
        case .numberedList: return "有序列表项"
        case .task: return "可勾选的任务"
        case .quote: return "引用一段内容"
        case .callout: return "突出提示信息"
        case .code: return "保留格式的代码"
        case .table: return "Markdown 表格"
        case .math: return "LaTeX 块级公式"
        case .divider: return "分隔上下内容"
        }
    }

    var searchKeywords: String {
        switch self {
        case .paragraph: return "text p paragraph 文本 正文"
        case .heading1: return "h1 heading title 一级 标题"
        case .heading2: return "h2 heading subtitle 二级 标题"
        case .heading3: return "h3 heading 三级 标题"
        case .bulletedList: return "bullet list ul 项目 无序 列表"
        case .numberedList: return "number list ol 编号 有序 列表"
        case .task: return "todo task checkbox 待办 任务"
        case .quote: return "quote blockquote 引用"
        case .callout: return "callout note tip 提示"
        case .code: return "code fence 代码"
        case .table: return "table grid 表格"
        case .math: return "math latex formula 公式 数学"
        case .divider: return "divider rule hr 分割线"
        }
    }

    var isListItem: Bool {
        self == .bulletedList || self == .numberedList || self == .task
    }

    var keepsNewlinesInsideBlock: Bool {
        self == .code || self == .table || self == .math
    }

    static func detect(in markdown: String) -> Self {
        let markdown = NativeBlockHierarchyMetadata.removingMarkers(from: markdown)
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { return .code }
        if trimmed.hasPrefix("$$") { return .math }
        if isTable(markdown) { return .table }
        if isDivider(trimmed) { return .divider }
        guard let firstLine = markdown.components(separatedBy: .newlines).first else { return .paragraph }
        let content = firstLine.drop { $0 == " " || $0 == "\t" }
        if content.hasPrefix("### ") { return .heading3 }
        if content.hasPrefix("## ") { return .heading2 }
        if content.hasPrefix("# ") { return .heading1 }
        if content.lowercased().hasPrefix("> [!note]")
            || content.lowercased().hasPrefix("> [!tip]")
            || content.lowercased().hasPrefix("> [!warning]") {
            return .callout
        }
        if content.hasPrefix("> ") { return .quote }
        if taskPrefixLength(in: content) != nil { return .task }
        if unorderedPrefixLength(in: content) != nil { return .bulletedList }
        if numberedPrefixLength(in: content) != nil { return .numberedList }
        return .paragraph
    }

    fileprivate static func isDivider(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let marker = compact.first,
              marker == "-" || marker == "*" || marker == "_" else { return false }
        return compact.allSatisfy { $0 == marker }
    }

    private static func isTable(_ markdown: String) -> Bool {
        let lines = markdown.components(separatedBy: .newlines)
        guard lines.count >= 2, lines[0].contains("|") else { return false }
        let delimiter = lines[1].trimmingCharacters(in: .whitespaces)
        let expression = try! NSRegularExpression(
            pattern: #"^\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?$"#
        )
        return expression.firstMatch(
            in: delimiter,
            range: NSRange(delimiter.startIndex..., in: delimiter)
        ) != nil
    }

    fileprivate static func unorderedPrefixLength<C: StringProtocol>(in content: C) -> Int? {
        guard let first = content.first, first == "-" || first == "+" || first == "*" else { return nil }
        let remainder = content.dropFirst()
        guard remainder.first?.isWhitespace == true else { return nil }
        return 2
    }

    fileprivate static func taskPrefixLength<C: StringProtocol>(in content: C) -> Int? {
        guard unorderedPrefixLength(in: content) != nil else { return nil }
        let remainder = content.dropFirst(2)
        guard remainder.count >= 3,
              remainder.first == "[",
              remainder.dropFirst(2).first == "]" else { return nil }
        let state = remainder.dropFirst().first
        guard state == " " || state == "x" || state == "X" else { return nil }
        return remainder.dropFirst(3).first?.isWhitespace == true ? 6 : 5
    }

    fileprivate static func numberedPrefixLength<C: StringProtocol>(in content: C) -> Int? {
        let digits = content.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let suffix = content.dropFirst(digits.count)
        guard let marker = suffix.first, marker == "." || marker == ")",
              suffix.dropFirst().first?.isWhitespace == true else { return nil }
        return digits.count + 2
    }
}

struct EditorMarkdownBlock: Identifiable, Equatable {
    let id: UUID
    var markdown: String
    var depth: Int
    var isCollapsed: Bool

    init(id: UUID = UUID(), markdown: String, depth: Int = 0, isCollapsed: Bool = false) {
        self.id = id
        self.markdown = markdown
        self.depth = min(max(depth, 0), 12)
        self.isCollapsed = isCollapsed
    }

    var kind: EditorMarkdownBlockKind { .detect(in: markdown) }
}

enum EditorBlockSelectionMode {
    case replace
    case extend(additive: Bool)
    case toggle
}

/// Owns selection invariants independently from SwiftUI and AppKit event handling.
/// The view translates input events into one of the small selection modes above.
struct EditorBlockSelection: Equatable {
    var focusedID: UUID?
    var selectedIDs: Set<UUID> = []
    var anchorID: UUID?

    mutating func reset() {
        focusedID = nil
        selectedIDs = []
        anchorID = nil
    }

    mutating func restore(focusedID: UUID?, selectedIDs: Set<UUID>) {
        self.focusedID = focusedID
        self.selectedIDs = selectedIDs
        anchorID = focusedID
    }

    mutating func reconcile(validIDs: [UUID]) {
        let valid = Set(validIDs)
        selectedIDs.formIntersection(valid)
        if let focusedID, !valid.contains(focusedID) {
            self.focusedID = nil
        }
        if let anchorID, !valid.contains(anchorID) {
            self.anchorID = nil
        }
        if selectedIDs.isEmpty, let focusedID {
            selectedIDs = [focusedID]
        }
    }

    mutating func focus(_ id: UUID, preservesSelection: Bool) {
        focusedID = id
        if !selectedIDs.contains(id), !preservesSelection {
            selectedIDs = [id]
            anchorID = id
        }
    }

    mutating func select(_ id: UUID, orderedIDs: [UUID], mode: EditorBlockSelectionMode) {
        switch mode {
        case let .extend(additive):
            guard let anchorID,
                  let anchor = orderedIDs.firstIndex(of: anchorID),
                  let current = orderedIDs.firstIndex(of: id) else {
                if additive {
                    if selectedIDs.contains(id), selectedIDs.count > 1 {
                        selectedIDs.remove(id)
                    } else {
                        selectedIDs.insert(id)
                    }
                } else {
                    selectedIDs = [id]
                }
                self.anchorID = id
                focusedID = id
                return
            }
            let range = min(anchor, current)...max(anchor, current)
            let rangeIDs = Set(range.map { orderedIDs[$0] })
            selectedIDs = additive ? selectedIDs.union(rangeIDs) : rangeIDs
        case .toggle:
            if selectedIDs.contains(id), selectedIDs.count > 1 {
                selectedIDs.remove(id)
            } else {
                selectedIDs.insert(id)
            }
            anchorID = id
        case .replace:
            selectedIDs = [id]
            anchorID = id
        }
        focusedID = id
    }

    mutating func selectAll(_ orderedIDs: [UUID], focusedID: UUID?) {
        selectedIDs = Set(orderedIDs)
        anchorID = orderedIDs.first
        self.focusedID = focusedID
    }

    mutating func escape(to id: UUID) {
        selectedIDs = [id]
        anchorID = id
        focusedID = nil
    }
}

/// A Markdown-preserving seam for the block editor. Articles continue to save
/// plain Markdown; this type only maps that source into editable visual units.
enum NativeBlockEditorDocument {
    static func parse(_ source: String) -> [EditorMarkdownBlock] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.isEmpty else { return [EditorMarkdownBlock(markdown: "")] }

        let lines = normalized.components(separatedBy: "\n")
        var result: [EditorMarkdownBlock] = []
        var current: [String] = []
        var currentKind: EditorMarkdownBlockKind?
        var activeFence: (marker: Character, count: Int)?
        var activeMath = false

        func appendCurrent() {
            guard !current.isEmpty else { return }
            result.append(EditorMarkdownBlock(markdown: current.joined(separator: "\n")))
            current.removeAll(keepingCapacity: true)
            currentKind = nil
        }

        for line in lines {
            if activeMath {
                current.append(line)
                let semantic = NativeBlockHierarchyMetadata.removingMarkers(from: line)
                    .trimmingCharacters(in: .whitespaces)
                if semantic == "$$" {
                    activeMath = false
                    appendCurrent()
                }
                continue
            }

            if let fence = activeFence {
                current.append(line)
                if closesFence(line, fence: fence) {
                    activeFence = nil
                    appendCurrent()
                }
                continue
            }

            if let fence = opensFence(line) {
                appendCurrent()
                current = [line]
                currentKind = .code
                activeFence = fence
                continue
            }

            let semanticLine = NativeBlockHierarchyMetadata.removingMarkers(from: line)
                .trimmingCharacters(in: .whitespaces)
            if semanticLine.hasPrefix("$$") {
                appendCurrent()
                current = [line]
                currentKind = .math
                if semanticLine.dropFirst(2).contains("$$") {
                    appendCurrent()
                } else {
                    activeMath = true
                }
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                appendCurrent()
                continue
            }

            if isStandaloneBlockID(trimmed) {
                if current.isEmpty, !result.isEmpty {
                    result[result.count - 1].markdown += "\n\(line)"
                } else {
                    current.append(line)
                }
                continue
            }

            let kind = EditorMarkdownBlockKind.detect(in: line)
            let isIndentedContinuation = line.first?.isWhitespace == true

            if kind == .divider || kind == .heading1 || kind == .heading2 || kind == .heading3 {
                appendCurrent()
                result.append(EditorMarkdownBlock(markdown: line))
            } else if kind.isListItem {
                appendCurrent()
                current = [line]
                currentKind = kind
            } else if kind == .quote || kind == .callout {
                if currentKind == kind {
                    current.append(line)
                } else {
                    appendCurrent()
                    current = [line]
                    currentKind = kind
                }
            } else if isIndentedContinuation, currentKind?.isListItem == true {
                current.append(line)
            } else {
                if currentKind?.isListItem == true || currentKind == .quote || currentKind == .callout {
                    appendCurrent()
                }
                current.append(line)
                currentKind = .paragraph
            }
        }
        appendCurrent()
        let normalizedBlocks = result.map { block -> EditorMarkdownBlock in
            let metadata = NativeBlockHierarchyMetadata.extract(from: block.markdown)
            let inferredDepth = metadata.depth > 0
                ? metadata.depth : listIndentDepth(in: metadata.markdown)
            return EditorMarkdownBlock(
                id: block.id,
                markdown: removingListIndent(from: metadata.markdown, depth: inferredDepth),
                depth: inferredDepth,
                isCollapsed: metadata.isCollapsed
            )
        }
        return normalizedBlocks.isEmpty ? [EditorMarkdownBlock(markdown: "")] : normalizedBlocks
    }

    static func render(_ blocks: [EditorMarkdownBlock]) -> String {
        guard !blocks.isEmpty else { return "" }
        var output = ""
        for index in blocks.indices {
            if index > 0 {
                output += shouldJoinTightly(blocks[index - 1], blocks[index]) ? "\n" : "\n\n"
            }
            let block = blocks[index]
            output += NativeBlockHierarchyMetadata.attaching(
                to: applyingListIndent(
                    to: block.markdown.trimmingCharacters(in: .newlines),
                    depth: block.depth
                ),
                depth: block.depth,
                isCollapsed: block.isCollapsed
            )
        }
        return output
    }

    static func appending(_ markdownBlocks: [String], to source: String) -> String {
        guard !markdownBlocks.isEmpty else { return source }
        var targetBlocks = parse(source)
        if targetBlocks.count == 1,
           targetBlocks[0].markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            targetBlocks.removeAll()
        }
        targetBlocks.append(contentsOf: markdownBlocks.map { markdown in
            let metadata = NativeBlockHierarchyMetadata.extract(from: markdown)
            return EditorMarkdownBlock(
                markdown: metadata.markdown,
                depth: metadata.depth,
                isCollapsed: metadata.isCollapsed
            )
        })
        return render(targetBlocks)
    }

    static func descendantIDs(of rootIDs: Set<UUID>, in blocks: [EditorMarkdownBlock]) -> Set<UUID> {
        var result = rootIDs
        for rootIndex in blocks.indices where rootIDs.contains(blocks[rootIndex].id) {
            let depth = blocks[rootIndex].depth
            var index = rootIndex + 1
            while blocks.indices.contains(index), blocks[index].depth > depth {
                result.insert(blocks[index].id)
                index += 1
            }
        }
        return result
    }

    static func visibleBlocks(_ blocks: [EditorMarkdownBlock]) -> [EditorMarkdownBlock] {
        var collapsedDepths: [Int] = []
        var result: [EditorMarkdownBlock] = []
        for block in blocks {
            collapsedDepths.removeAll { $0 >= block.depth }
            guard collapsedDepths.isEmpty else { continue }
            result.append(block)
            if block.isCollapsed { collapsedDepths.append(block.depth) }
        }
        return result
    }

    static func hasDescendants(_ blockID: UUID, in blocks: [EditorMarkdownBlock]) -> Bool {
        guard let index = blocks.firstIndex(where: { $0.id == blockID }),
              blocks.indices.contains(index + 1) else { return false }
        return blocks[index + 1].depth > blocks[index].depth
    }

    static func syncedBlockReference(in markdown: String) -> String? {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let expression = try! NSRegularExpression(
            pattern: #"^!\[\[([^\[\]\r\n]+#\^[A-Za-z0-9_-]+)\]\]$"#
        )
        guard let match = expression.firstMatch(
            in: trimmed,
            range: NSRange(trimmed.startIndex..., in: trimmed)
        ), let range = Range(match.range(at: 1), in: trimmed) else { return nil }
        return String(trimmed[range])
    }

    static func converting(_ markdown: String, to kind: EditorMarkdownBlockKind) -> String {
        let anchor = trailingBlockID(in: markdown)
        let body = removingBlockSyntax(from: anchor.body)
        let converted: String
        switch kind {
        case .paragraph:
            converted = body
        case .heading1:
            converted = "# \(singleLine(body))"
        case .heading2:
            converted = "## \(singleLine(body))"
        case .heading3:
            converted = "### \(singleLine(body))"
        case .bulletedList:
            converted = "- \(singleLine(body))"
        case .numberedList:
            converted = "1. \(singleLine(body))"
        case .task:
            converted = "- [ ] \(singleLine(body))"
        case .quote:
            converted = body.components(separatedBy: .newlines)
                .map { $0.isEmpty ? ">" : "> \($0)" }
                .joined(separator: "\n")
        case .callout:
            let message = body.trimmingCharacters(in: .whitespacesAndNewlines)
            converted = message.isEmpty ? "> [!note] 提示\n> " : "> [!note] 提示\n> \(singleLine(message))"
        case .code:
            converted = "```\n\(body)\n```"
        case .table:
            let content = singleLine(body)
            converted = "| 内容 | 说明 |\n| --- | --- |\n| \(content) | |"
        case .math:
            converted = "$$\n\(body)\n$$"
        case .divider:
            converted = "---"
        }
        guard let id = anchor.id else { return converted }
        return attachingBlockID(id, to: converted)
    }

    static func split(_ markdown: String, atUTF16Location location: Int) -> (String, String)? {
        let source = markdown as NSString
        guard location >= 0, location <= source.length else { return nil }
        let selection = NSRange(location: location, length: 0)
        let left = source.substring(to: selection.location)
        let right = source.substring(from: selection.location)
        let kind = EditorMarkdownBlockKind.detect(in: markdown)

        if kind.keepsNewlinesInsideBlock { return nil }
        if kind == .divider { return (markdown, "") }

        if kind == .heading1 || kind == .heading2 || kind == .heading3 {
            return (left.trimmingCharacters(in: .newlines), removingBlockSyntax(from: right))
        }

        if kind.isListItem {
            let prefix = firstLinePrefix(in: markdown, kind: kind)
            let leftText = left.trimmingCharacters(in: .newlines)
            let leftContent = removingBlockSyntax(from: leftText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rightContent = right.trimmingCharacters(in: .whitespacesAndNewlines)
            if leftContent.isEmpty && rightContent.isEmpty {
                return ("", "")
            }
            return (leftText, prefix + rightContent)
        }

        return (
            left.trimmingCharacters(in: .newlines),
            right.trimmingCharacters(in: .newlines)
        )
    }

    static func blockID(in markdown: String) -> String? {
        trailingBlockID(in: markdown).id
    }

    static func ensuringBlockID(in markdown: String) -> (markdown: String, id: String) {
        if let existing = blockID(in: markdown) { return (markdown, existing) }
        let id = String(UUID().uuidString.lowercased().prefix(8))
        return (attachingBlockID(id, to: markdown), id)
    }

    static func removingBlockID(from markdown: String) -> String {
        trailingBlockID(in: markdown).body
    }

    @discardableResult
    static func move(
        _ blocks: inout [EditorMarkdownBlock],
        blockID: UUID,
        relativeTo destinationID: UUID
    ) -> Bool {
        move(&blocks, blockIDs: Set([blockID]), relativeTo: destinationID)
    }

    @discardableResult
    static func move(
        _ blocks: inout [EditorMarkdownBlock],
        blockIDs: Set<UUID>,
        relativeTo destinationID: UUID
    ) -> Bool {
        guard !blockIDs.isEmpty,
              !blockIDs.contains(destinationID),
              let destination = blocks.firstIndex(where: { $0.id == destinationID }) else { return false }
        let sourceIndexes = blocks.indices.filter { blockIDs.contains(blocks[$0].id) }
        guard !sourceIndexes.isEmpty else { return false }
        let movesAfterDestination = sourceIndexes[0] < destination
        let movingBlocks = sourceIndexes.map { blocks[$0] }
        let destinationDepth = blocks[destination].depth
        var destinationTailID = destinationID
        if movesAfterDestination {
            var index = destination + 1
            while blocks.indices.contains(index), blocks[index].depth > destinationDepth {
                if !blockIDs.contains(blocks[index].id) { destinationTailID = blocks[index].id }
                index += 1
            }
        }
        blocks.removeAll { blockIDs.contains($0.id) }
        guard let remainingDestination = blocks.firstIndex(where: {
            $0.id == (movesAfterDestination ? destinationTailID : destinationID)
        }) else { return false }
        let insertionIndex = movesAfterDestination ? remainingDestination + 1 : remainingDestination
        blocks.insert(contentsOf: movingBlocks, at: min(insertionIndex, blocks.count))
        return true
    }

    static func isCompletedTask(_ markdown: String) -> Bool {
        let trimmed = markdown.drop { $0 == " " || $0 == "\t" }
        guard taskPrefixLengthForDocument(in: trimmed) != nil else { return false }
        return trimmed.dropFirst(3).first == "x" || trimmed.dropFirst(3).first == "X"
    }

    static func togglingTask(_ markdown: String) -> String {
        let mutable = NSMutableString(string: markdown)
        let expression = try! NSRegularExpression(pattern: #"^(\s*[-+*]\s+)\[([ xX])\]"#)
        let fullRange = NSRange(location: 0, length: mutable.length)
        guard let match = expression.firstMatch(in: markdown, range: fullRange) else { return markdown }
        let stateRange = match.range(at: 2)
        let completed = mutable.substring(with: stateRange).lowercased() == "x"
        mutable.replaceCharacters(in: stateRange, with: completed ? " " : "x")
        return mutable as String
    }

    private static func shouldJoinTightly(_ lhs: EditorMarkdownBlock, _ rhs: EditorMarkdownBlock) -> Bool {
        let left = lhs.kind
        let right = rhs.kind
        if left == .numberedList && right == .numberedList { return true }
        let unordered: Set<EditorMarkdownBlockKind> = [.bulletedList, .task]
        return unordered.contains(left) && unordered.contains(right)
    }

    private static func opensFence(_ line: String) -> (marker: Character, count: Int)? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let count = trimmed.prefix { $0 == marker }.count
        return count >= 3 ? (marker, count) : nil
    }

    private static func closesFence(_ line: String, fence: (marker: Character, count: Int)) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.prefix { $0 == fence.marker }.count >= fence.count
    }

    private static func isStandaloneBlockID(_ line: String) -> Bool {
        guard line.hasPrefix("^"), line.count > 1 else { return false }
        return line.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private static func trailingBlockID(in markdown: String) -> (body: String, id: String?) {
        let expression = try! NSRegularExpression(
            pattern: #"(?:[ \t]+|^)(?:\^)([A-Za-z0-9_-]+)[ \t]*$"#,
            options: [.anchorsMatchLines]
        )
        let range = NSRange(markdown.startIndex..., in: markdown)
        guard let match = expression.matches(in: markdown, range: range).last,
              NSMaxRange(match.range) == range.length,
              let idRange = Range(match.range(at: 1), in: markdown),
              let markerRange = Range(match.range, in: markdown) else {
            return (markdown, nil)
        }
        var body = String(markdown[..<markerRange.lowerBound])
        body = body.trimmingCharacters(in: .newlines)
        return (body, String(markdown[idRange]))
    }

    private static func attachingBlockID(_ id: String, to markdown: String) -> String {
        let separator = markdown.contains("\n") || EditorMarkdownBlockKind.detect(in: markdown) == .code ? "\n" : " "
        return markdown + separator + "^\(id)"
    }

    private static func removingBlockSyntax(from markdown: String) -> String {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = EditorMarkdownBlockKind.detect(in: trimmed)
        switch kind {
        case .heading1: return String(trimmed.dropFirst(2))
        case .heading2: return String(trimmed.dropFirst(3))
        case .heading3: return String(trimmed.dropFirst(4))
        case .bulletedList:
            return dropPrefix(from: trimmed, count: EditorMarkdownBlockKind.unorderedPrefixLength(in: trimmed) ?? 0)
        case .numberedList:
            return dropPrefix(from: trimmed, count: EditorMarkdownBlockKind.numberedPrefixLength(in: trimmed) ?? 0)
        case .task:
            return dropPrefix(from: trimmed, count: EditorMarkdownBlockKind.taskPrefixLength(in: trimmed) ?? 0)
        case .quote:
            return trimmed.components(separatedBy: .newlines)
                .map { line in
                    let value = line.drop { $0 == " " || $0 == "\t" }
                    if value.hasPrefix("> ") { return String(value.dropFirst(2)) }
                    if value == ">" { return "" }
                    return String(value)
                }
                .joined(separator: "\n")
        case .callout:
            let lines = trimmed.components(separatedBy: .newlines)
            return lines.dropFirst().map { line in
                line.hasPrefix("> ") ? String(line.dropFirst(2)) : line
            }.joined(separator: "\n")
        case .code:
            let lines = trimmed.components(separatedBy: .newlines)
            guard lines.count >= 2 else { return "" }
            let closes = lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true
                || lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") == true
            return lines.dropFirst().dropLast(closes ? 1 : 0).joined(separator: "\n")
        case .table:
            return trimmed.components(separatedBy: .newlines).enumerated().compactMap { index, line in
                guard index != 1 else { return nil }
                let cells = line.split(separator: "|", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                return cells.isEmpty ? nil : cells.joined(separator: " · ")
            }.joined(separator: "\n")
        case .math:
            let lines = trimmed.components(separatedBy: .newlines)
            guard lines.count >= 2 else { return trimmed.replacingOccurrences(of: "$$", with: "") }
            let closes = lines.last?.trimmingCharacters(in: .whitespaces) == "$$"
            return lines.dropFirst().dropLast(closes ? 1 : 0).joined(separator: "\n")
        case .paragraph, .divider:
            return kind == .divider ? "" : trimmed
        }
    }

    private static func firstLinePrefix(in markdown: String, kind: EditorMarkdownBlockKind) -> String {
        let first = markdown.components(separatedBy: .newlines).first ?? markdown
        let trimmed = first.drop { $0 == " " || $0 == "\t" }
        let count: Int
        switch kind {
        case .task: count = EditorMarkdownBlockKind.taskPrefixLength(in: trimmed) ?? 6
        case .bulletedList: count = EditorMarkdownBlockKind.unorderedPrefixLength(in: trimmed) ?? 2
        case .numberedList: count = EditorMarkdownBlockKind.numberedPrefixLength(in: trimmed) ?? 3
        default: return ""
        }
        return String(trimmed.prefix(count))
    }

    private static func dropPrefix(from text: String, count: Int) -> String {
        String(text.dropFirst(min(count, text.count)))
    }

    private static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func listIndentDepth(in markdown: String) -> Int {
        guard EditorMarkdownBlockKind.detect(in: markdown).isListItem,
              let firstLine = markdown.components(separatedBy: .newlines).first else { return 0 }
        let spaces = firstLine.replacingOccurrences(of: "\t", with: "  ")
            .prefix { $0 == " " }.count
        return min(spaces / 2, 12)
    }

    private static func removingListIndent(from markdown: String, depth: Int) -> String {
        guard depth > 0, EditorMarkdownBlockKind.detect(in: markdown).isListItem else { return markdown }
        let count = depth * 2
        return markdown.components(separatedBy: .newlines).map { line in
            var value = line
            var removed = 0
            while removed < count, value.first == " " {
                value.removeFirst()
                removed += 1
            }
            return value
        }.joined(separator: "\n")
    }

    private static func applyingListIndent(to markdown: String, depth: Int) -> String {
        guard depth > 0, EditorMarkdownBlockKind.detect(in: markdown).isListItem else { return markdown }
        let prefix = String(repeating: "  ", count: depth)
        return markdown.components(separatedBy: .newlines)
            .map { prefix + $0 }
            .joined(separator: "\n")
    }

    private static func taskPrefixLengthForDocument<C: StringProtocol>(in content: C) -> Int? {
        EditorMarkdownBlockKind.taskPrefixLength(in: content)
    }
}

private enum EditorBlockKeyboardCommand {
    case duplicate
    case delete
    case copy
    case cut
    case paste
    case selectAllBlocks
    case escape
}

private extension NSPasteboard.PasteboardType {
    static let leonBookBlocks = Self("com.leonbook.markdown-blocks")
}

private final class NativeBlockNSTextView: NSTextView {
    var onMoveBlocks: ((Int) -> Void)?
    var onChangeIndent: ((Int) -> Void)?
    var onBlockCommand: ((EditorBlockKeyboardCommand) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains([.command, .option]) {
            if event.keyCode == 126 {
                onMoveBlocks?(-1)
                return
            }
            if event.keyCode == 125 {
                onMoveBlocks?(1)
                return
            }
        }
        if event.keyCode == 48 {
            onChangeIndent?(modifiers.contains(.shift) ? -1 : 1)
            return
        }
        if modifiers.contains(.command) {
            let command: EditorBlockKeyboardCommand?
            switch event.keyCode {
            case 2: command = .duplicate
            case 8 where selectedRange().length == 0: command = .copy
            case 7 where selectedRange().length == 0: command = .cut
            case 9: command = .paste
            case 51 where modifiers.contains(.shift): command = .delete
            case 0 where selectedRange().location == 0
                && selectedRange().length == (string as NSString).length:
                command = .selectAllBlocks
            default: command = nil
            }
            if let command, onBlockCommand?(command) == true { return }
        }
        if event.keyCode == 53, onBlockCommand?(.escape) == true {
            window?.makeFirstResponder(nil)
            return
        }
        super.keyDown(with: event)
    }
}

private struct NativeBlockTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let kind: EditorMarkdownBlockKind
    let typography: NativeReadingTypography
    let isEditable: Bool
    let shouldFocus: Bool
    let onFocus: () -> Void
    let onSplit: (NSRange) -> Void
    let onMergeBackward: () -> Void
    let onMoveBlocks: (Int) -> Void
    let onChangeIndent: (Int) -> Void
    let onBlockCommand: (EditorBlockKeyboardCommand) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NativeBlockNSTextView {
        let textView = NativeBlockNSTextView()
        textView.allowsUndo = true
        textView.backgroundColor = .clear
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isEditable = isEditable
        textView.isHorizontallyResizable = false
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.string = text
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.onMoveBlocks = onMoveBlocks
        textView.onChangeIndent = onChangeIndent
        textView.onBlockCommand = onBlockCommand
        applyStyling(to: textView)
        context.coordinator.updateHeight(of: textView)
        return textView
    }

    func updateNSView(_ textView: NativeBlockNSTextView, context: Context) {
        context.coordinator.parent = self
        textView.isEditable = isEditable
        textView.onMoveBlocks = onMoveBlocks
        textView.onChangeIndent = onChangeIndent
        textView.onBlockCommand = onBlockCommand
        if textView.string != text { textView.string = text }
        applyStyling(to: textView)
        context.coordinator.updateHeight(of: textView)
        if shouldFocus, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async {
                guard shouldFocus, let window = textView.window else { return }
                window.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            }
        }
    }

    private func applyStyling(to textView: NSTextView) {
        NativeMarkdownLiveStyler.apply(
            .livePreview,
            typography: typography,
            to: textView,
            editedRange: nil
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeBlockTextEditor

        init(parent: NativeBlockTextEditor) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocus()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.applyStyling(to: textView)
            updateHeight(of: textView)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)),
               !NSEvent.modifierFlags.contains(.shift),
               !parent.kind.keepsNewlinesInsideBlock {
                parent.onSplit(textView.selectedRange())
                return true
            }
            if commandSelector == #selector(NSResponder.deleteBackward(_:)),
               textView.selectedRange().location == 0,
               textView.selectedRange().length == 0 {
                parent.onMergeBackward()
                return true
            }
            return false
        }

        func updateHeight(of textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let measured = ceil(layoutManager.usedRect(for: textContainer).height + 4)
            let nextHeight = max(measured, parent.typography.fontSize + 10)
            if abs(parent.height - nextHeight) > 0.5 {
                DispatchQueue.main.async { self.parent.height = nextHeight }
            }
        }
    }
}

private final class EditorBlockUndoCoordinator: ObservableObject {
    struct Restoration {
        let blocks: [EditorMarkdownBlock]
        let focusedID: UUID?
        let selectedIDs: Set<UUID>
    }

    @Published private(set) var restoration: Restoration?
    weak var undoManager: UndoManager?
    var current = Restoration(blocks: [], focusedID: nil, selectedIDs: [])

    func connect(to undoManager: UndoManager?) {
        self.undoManager = undoManager
    }

    func synchronize(
        blocks: [EditorMarkdownBlock],
        focusedID: UUID?,
        selectedIDs: Set<UUID>
    ) {
        current = Restoration(blocks: blocks, focusedID: focusedID, selectedIDs: selectedIDs)
    }

    func register(_ snapshot: Restoration, actionName: String) {
        guard snapshot.blocks != current.blocks else { return }
        undoManager?.registerUndo(withTarget: self) { target in
            target.restore(snapshot, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    private func restore(_ snapshot: Restoration, actionName: String) {
        let inverse = current
        undoManager?.registerUndo(withTarget: self) { target in
            target.restore(inverse, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        current = snapshot
        restoration = snapshot
    }
}

struct ArticleBlockEditor: View {
    @Binding var source: String
    let documentID: String
    let sourceSlug: String?
    let articleReference: String
    let isEditable: Bool
    let typography: NativeReadingTypography
    let articleDestinations: [NativeArticleSummary]
    let onTransferBlocks: (
        [String],
        String?,
        String,
        EditorBlockTransferOperation
    ) async -> EditorBlockTransferReceipt?
    let onUndoTransfer: (EditorBlockTransferReceipt) async -> Bool

    @Environment(\.undoManager) private var undoManager
    @StateObject private var undoCoordinator = EditorBlockUndoCoordinator()
    @State private var blocks: [EditorMarkdownBlock] = []
    @State private var blockSelection = EditorBlockSelection()
    @State private var draggedBlockIDs: Set<UUID> = []
    @State private var dragDidRegisterUndo = false
    @State private var dropTargetBlockID: UUID?
    @State private var dropTargetIsAfter = false
    @State private var editorHeights: [UUID: CGFloat] = [:]
    @State private var transferRequest: EditorBlockTransferRequest?
    @State private var lastTransferReceipt: EditorBlockTransferReceipt?
    @State private var isUndoingTransfer = false
    @State private var customTemplates = EditorBlockTemplateCatalog.loadCustom()

    private var visibleBlocks: [EditorMarkdownBlock] {
        NativeBlockEditorDocument.visibleBlocks(blocks)
    }

    private var focusedBlockID: UUID? {
        get { blockSelection.focusedID }
        nonmutating set { blockSelection.focusedID = newValue }
    }

    private var selectedBlockIDs: Set<UUID> {
        get { blockSelection.selectedIDs }
        nonmutating set { blockSelection.selectedIDs = newValue }
    }

    private var selectionAnchorID: UUID? {
        get { blockSelection.anchorID }
        nonmutating set { blockSelection.anchorID = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("块编辑", systemImage: "square.grid.3x1.folder.badge.plus")
                    .font(.subheadline.weight(.medium))
                if selectedBlockIDs.count > 1 {
                    Text("已选择 \(selectedBlockIDs.count) 块 · 拖动手柄可成组搬运")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("⌘点手柄/⇧连选 · 拖动搬运 · ⌥⌘↑↓ 键盘移动")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button { undoManager?.undo() } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("撤销块操作（⌘Z）")
                .disabled(undoManager == nil)

                Button { undoManager?.redo() } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .buttonStyle(.borderless)
                .help("重做块操作（⇧⌘Z）")
                .disabled(undoManager == nil)

                Menu {
                    Section("内置模板") {
                        ForEach(EditorBlockTemplateCatalog.builtIn) { template in
                            Button(template.name) { insertTemplate(template, after: focusedBlockID) }
                        }
                    }
                    if !customTemplates.isEmpty {
                        Section("我的模板") {
                            ForEach(customTemplates) { template in
                                Button(template.name) { insertTemplate(template, after: focusedBlockID) }
                            }
                        }
                    }
                    Divider()
                    Button("将所选块保存为模板…", systemImage: "square.and.arrow.down") {
                        saveSelectionAsTemplate()
                    }
                    .disabled(selectedBlockIDs.isEmpty)
                    if !customTemplates.isEmpty {
                        Menu("删除自定义模板", systemImage: "trash") {
                            ForEach(customTemplates) { template in
                                Button(template.name, role: .destructive) { deleteTemplate(template) }
                            }
                        }
                    }
                } label: {
                    Label("模板", systemImage: "square.stack.3d.up")
                }
                .menuStyle(.borderlessButton)
                .disabled(!isEditable)

                Menu {
                    Button("移动到其他笔记…", systemImage: "arrow.right.doc.on.clipboard") {
                        presentTransfer(.move)
                    }
                    .disabled(sourceSlug == nil)
                    Button("复制到其他笔记…", systemImage: "doc.on.doc") {
                        presentTransfer(.copy)
                    }
                    Button("创建同步块到其他笔记…", systemImage: "arrow.triangle.2.circlepath") {
                        presentTransfer(.sync)
                    }
                    .disabled(sourceSlug == nil)
                    if let lastTransferReceipt {
                        Divider()
                        Button("撤销上次\(lastTransferReceipt.operation.localizedShortTitle)", systemImage: "arrow.uturn.backward.circle") {
                            undoLastTransfer(lastTransferReceipt)
                        }
                        .disabled(isUndoingTransfer)
                    }
                } label: {
                    Label("跨笔记", systemImage: "rectangle.2.swap")
                }
                .menuStyle(.borderlessButton)
                .disabled(!isEditable || selectedBlockIDs.isEmpty || articleDestinations.isEmpty)

                Button { insertBlock(after: nil) } label: {
                    Label("添加块", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(!isEditable)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(visibleBlocks) { block in
                        blockRow(block)
                            .onDrop(
                                of: [UTType.text],
                                delegate: EditorBlockDropDelegate(
                                    destinationID: block.id,
                                    blocks: $blocks,
                                    draggedIDs: $draggedBlockIDs,
                                    dropTargetID: $dropTargetBlockID,
                                    dropTargetIsAfter: $dropTargetIsAfter,
                                    onMove: { before in
                                        if dragDidRegisterUndo {
                                            commit()
                                        } else {
                                            finishStructuralChange(
                                                from: before,
                                                actionName: selectedBlockIDs.count > 1 ? "移动多个块" : "移动块"
                                            )
                                            dragDidRegisterUndo = true
                                        }
                                    },
                                    onDrop: {
                                        dragDidRegisterUndo = false
                                    }
                                )
                            )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary) }
        }
        .onAppear {
            reloadBlocks(from: source)
            undoCoordinator.connect(to: undoManager)
            synchronizeUndoCoordinator()
        }
        .onChange(of: undoManager) { manager in
            undoCoordinator.connect(to: manager)
        }
        .onChange(of: documentID) { _ in
            undoManager?.removeAllActions(withTarget: undoCoordinator)
            blockSelection.reset()
            reloadBlocks(from: source)
            synchronizeUndoCoordinator()
        }
        .onChange(of: source) { updatedSource in
            if let receipt = lastTransferReceipt,
               let sourceAfter = receipt.sourceAfter,
               updatedSource != sourceAfter.body {
                lastTransferReceipt = nil
            }
            guard NativeBlockEditorDocument.render(blocks) != updatedSource else { return }
            reloadBlocks(from: updatedSource)
            synchronizeUndoCoordinator()
        }
        .onReceive(undoCoordinator.$restoration.compactMap { $0 }) { restoration in
            blocks = restoration.blocks
            blockSelection.restore(
                focusedID: restoration.focusedID,
                selectedIDs: restoration.selectedIDs
            )
            commit()
            synchronizeUndoCoordinator()
        }
        .sheet(item: $transferRequest) { request in
            EditorBlockTransferSheet(
                request: request,
                articles: articleDestinations,
                onTransfer: performTransfer
            )
        }
    }

    @ViewBuilder
    private func blockRow(_ block: EditorMarkdownBlock) -> some View {
        let index = blocks.firstIndex(where: { $0.id == block.id }) ?? 0
        HStack(alignment: .top, spacing: 7) {
            HStack(spacing: 1) {
                if NativeBlockEditorDocument.hasDescendants(block.id, in: blocks) {
                    Button { toggleCollapsed(block.id) } label: {
                        Image(systemName: block.isCollapsed ? "chevron.right" : "chevron.down")
                            .frame(width: 16, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help(Text(LocalizedStringKey(block.isCollapsed ? "展开子块" : "折叠子块")))
                } else {
                    Color.clear.frame(width: 16, height: 24)
                }

                Button { insertBlock(after: block.id) } label: {
                    Image(systemName: "plus")
                        .frame(width: 19, height: 24)
                }
                .buttonStyle(.plain)
                .help("在下方添加块")

                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 21, height: 24)
                    .contentShape(Rectangle())
                    .help("按住并拖动，搬运整个内容块")
                    .accessibilityLabel("拖动内容块")
                    .onTapGesture {
                        select(block.id, modifiers: NSEvent.modifierFlags)
                    }
                    .onDrag {
                        let selectedIDs = selectedBlockIDs.contains(block.id)
                            ? selectedBlockIDs : Set([block.id])
                        let movingIDs = NativeBlockEditorDocument.descendantIDs(
                            of: selectedIDs,
                            in: blocks
                        )
                        selectedBlockIDs = movingIDs
                        selectionAnchorID = block.id
                        draggedBlockIDs = movingIDs
                        dragDidRegisterUndo = false
                        dropTargetBlockID = nil
                        dropTargetIsAfter = false
                        let payload = movingIDs.map(\.uuidString).sorted().joined(separator: ",")
                        return NSItemProvider(object: payload as NSString)
                    }

                Menu {
                    blockTypeMenu(for: block.id)
                    Divider()
                    Button("复制块链接", systemImage: "link") { copyBlockLink(block.id) }
                    Button("复制所选块", systemImage: "doc.on.doc") {
                        copyBlocks(anchoredAt: block.id, cutsSource: false)
                    }
                    Button("剪切所选块", systemImage: "scissors") {
                        copyBlocks(anchoredAt: block.id, cutsSource: true)
                    }
                    Button("粘贴块", systemImage: "doc.on.clipboard") { _ = pasteBlocks(after: block.id) }
                        .disabled(NSPasteboard.general.string(forType: .leonBookBlocks) == nil)
                    Button("创建副本", systemImage: "plus.square.on.square") { duplicate(block.id) }
                    Button("整块上移", systemImage: "arrow.up") { move(block.id, offset: -1) }
                        .disabled(index == 0)
                    Button("整块下移", systemImage: "arrow.down") { move(block.id, offset: 1) }
                        .disabled(index == blocks.count - 1)
                    Button("增加缩进", systemImage: "increase.indent") { changeIndent(block.id, delta: 1) }
                    Button("减少缩进", systemImage: "decrease.indent") { changeIndent(block.id, delta: -1) }
                        .disabled(block.depth == 0)
                    if NativeBlockEditorDocument.hasDescendants(block.id, in: blocks) {
                        Button(LocalizedStringKey(block.isCollapsed ? "展开子块" : "折叠子块"), systemImage: "rectangle.compress.vertical") {
                            toggleCollapsed(block.id)
                        }
                    }
                    Divider()
                    Button("删除", systemImage: "trash", role: .destructive) { remove(block.id) }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                        .frame(width: 19, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("打开块菜单")
            }
            .foregroundStyle(selectedBlockIDs.contains(block.id) ? Color.accentColor : Color.secondary.opacity(0.7))
            .opacity(isEditable ? 1 : 0.45)
            .disabled(!isEditable)

            if block.kind == .task {
                Button { toggleTask(block.id) } label: {
                    Image(systemName: NativeBlockEditorDocument.isCompletedTask(block.markdown)
                        ? "checkmark.square.fill" : "square")
                        .font(.system(size: typography.fontSize))
                        .foregroundStyle(NativeBlockEditorDocument.isCompletedTask(block.markdown) ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 7)
                .disabled(!isEditable)
            }

            VStack(alignment: .leading, spacing: 4) {
                NativeBlockTextEditor(
                    text: binding(for: block.id),
                    height: heightBinding(for: block.id),
                    kind: block.kind,
                    typography: typography,
                    isEditable: isEditable && block.kind != .divider,
                    shouldFocus: focusedBlockID == block.id,
                    onFocus: { focus(block.id) },
                    onSplit: { split(block.id, selection: $0) },
                    onMergeBackward: { mergeBackward(block.id) },
                    onMoveBlocks: { if isEditable { move(block.id, offset: $0) } },
                    onChangeIndent: { if isEditable { changeIndent(block.id, delta: $0) } },
                    onBlockCommand: { handleKeyboardCommand($0, for: block.id) }
                )
                .frame(height: editorHeights[block.id] ?? typography.fontSize + 10)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    selectedBlockIDs.contains(block.id)
                        ? Color.accentColor.opacity(focusedBlockID == block.id ? 0.11 : 0.065)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .overlay(alignment: .leading) {
                    if block.kind == .divider {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.32))
                            .frame(height: 1)
                            .padding(.horizontal, 8)
                            .allowsHitTesting(false)
                    }
                }
                .contextMenu {
                    blockTypeMenu(for: block.id)
                        .disabled(!isEditable)
                    Divider()
                    Button("复制块链接", systemImage: "link") { copyBlockLink(block.id) }
                        .disabled(!isEditable)
                    Button("复制所选块", systemImage: "doc.on.doc") {
                        copyBlocks(anchoredAt: block.id, cutsSource: false)
                    }
                    Button("剪切所选块", systemImage: "scissors") {
                        copyBlocks(anchoredAt: block.id, cutsSource: true)
                    }
                    .disabled(!isEditable)
                    Button("粘贴块", systemImage: "doc.on.clipboard") { _ = pasteBlocks(after: block.id) }
                        .disabled(!isEditable || NSPasteboard.general.string(forType: .leonBookBlocks) == nil)
                    Button("创建副本", systemImage: "plus.square.on.square") { duplicate(block.id) }
                        .disabled(!isEditable)
                    Button("整块上移", systemImage: "arrow.up") { move(block.id, offset: -1) }
                        .disabled(!isEditable || index == 0)
                    Button("整块下移", systemImage: "arrow.down") { move(block.id, offset: 1) }
                        .disabled(!isEditable || index == blocks.count - 1)
                    Button("增加缩进", systemImage: "increase.indent") { changeIndent(block.id, delta: 1) }
                        .disabled(!isEditable || index == 0)
                    Button("减少缩进", systemImage: "decrease.indent") { changeIndent(block.id, delta: -1) }
                        .disabled(!isEditable || block.depth == 0)
                    Divider()
                    Button("删除", systemImage: "trash", role: .destructive) { remove(block.id) }
                        .disabled(!isEditable)
                }

                if let reference = NativeBlockEditorDocument.syncedBlockReference(in: block.markdown) {
                    Label("同步块 · \(reference)", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 8)
                }

                if let query = slashQuery(for: block), focusedBlockID == block.id {
                    EditorBlockSlashMenu(
                        query: query,
                        kinds: slashKinds(matching: query),
                        templates: templates(matching: query),
                        onSelect: { applySlashKind($0, to: block.id) },
                        onSelectTemplate: { applyTemplate($0, replacing: block.id) }
                    )
                }
            }
        }
        .padding(.leading, CGFloat(block.depth) * 22)
        .contentShape(Rectangle())
        .onTapGesture {
            select(block.id, modifiers: NSEvent.modifierFlags)
        }
        .overlay(alignment: dropTargetIsAfter ? .bottom : .top) {
            if dropTargetBlockID == block.id, !draggedBlockIDs.contains(block.id) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                }
                .offset(y: dropTargetIsAfter ? 2 : -2)
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func blockTypeMenu(for id: UUID) -> some View {
        Menu("转换为", systemImage: "arrow.triangle.2.circlepath") {
            ForEach(EditorMarkdownBlockKind.allCases) { kind in
                Button { convert(id, to: kind) } label: {
                    Label(LocalizedStringKey(kind.title), systemImage: kind.systemImage)
                }
            }
        }
    }

    private func binding(for id: UUID) -> Binding<String> {
        Binding(
            get: { blocks.first(where: { $0.id == id })?.markdown ?? "" },
            set: { value in
                guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
                blocks[index].markdown = value
                commit()
            }
        )
    }

    private func heightBinding(for id: UUID) -> Binding<CGFloat> {
        Binding(
            get: { editorHeights[id] ?? typography.fontSize + 10 },
            set: { editorHeights[id] = $0 }
        )
    }

    private func reloadBlocks(from updatedSource: String) {
        let parsed = NativeBlockEditorDocument.parse(updatedSource)
        var unused = blocks
        blocks = parsed.enumerated().map { index, parsedBlock in
            if let match = unused.firstIndex(where: { $0.markdown == parsedBlock.markdown }) {
                let id = unused.remove(at: match).id
                return EditorMarkdownBlock(
                    id: id,
                    markdown: parsedBlock.markdown,
                    depth: parsedBlock.depth,
                    isCollapsed: parsedBlock.isCollapsed
                )
            }
            if unused.indices.contains(index) {
                let id = unused.remove(at: index).id
                return EditorMarkdownBlock(
                    id: id,
                    markdown: parsedBlock.markdown,
                    depth: parsedBlock.depth,
                    isCollapsed: parsedBlock.isCollapsed
                )
            }
            return parsedBlock
        }
        blockSelection.reconcile(validIDs: blocks.map(\.id))
    }

    private func commit() {
        source = NativeBlockEditorDocument.render(blocks)
        synchronizeUndoCoordinator()
    }

    private func synchronizeUndoCoordinator() {
        undoCoordinator.synchronize(
            blocks: blocks,
            focusedID: focusedBlockID,
            selectedIDs: selectedBlockIDs
        )
    }

    private func finishStructuralChange(
        from previousBlocks: [EditorMarkdownBlock],
        previousFocusedID: UUID? = nil,
        previousSelectedIDs: Set<UUID>? = nil,
        actionName: String
    ) {
        let previous = EditorBlockUndoCoordinator.Restoration(
            blocks: previousBlocks,
            focusedID: previousFocusedID ?? undoCoordinator.current.focusedID,
            selectedIDs: previousSelectedIDs ?? undoCoordinator.current.selectedIDs
        )
        commit()
        undoCoordinator.register(previous, actionName: actionName)
    }

    private func focus(_ id: UUID) {
        let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        blockSelection.focus(
            id,
            preservesSelection: modifiers.contains(.command) || modifiers.contains(.shift)
        )
        synchronizeUndoCoordinator()
    }

    private func select(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        let mode: EditorBlockSelectionMode
        if flags.contains(.shift) {
            mode = .extend(additive: flags.contains(.command))
        } else if flags.contains(.command) {
            mode = .toggle
        } else {
            mode = .replace
        }
        blockSelection.select(id, orderedIDs: blocks.map(\.id), mode: mode)
        synchronizeUndoCoordinator()
    }

    private func operationIDs(for id: UUID) -> Set<UUID> {
        NativeBlockEditorDocument.descendantIDs(
            of: selectedBlockIDs.contains(id) ? selectedBlockIDs : Set([id]),
            in: blocks
        )
    }

    private func handleKeyboardCommand(
        _ command: EditorBlockKeyboardCommand,
        for id: UUID
    ) -> Bool {
        switch command {
        case .copy:
            return copyBlocks(anchoredAt: id, cutsSource: false)
        case .cut:
            guard isEditable else { return false }
            return copyBlocks(anchoredAt: id, cutsSource: true)
        case .paste:
            guard isEditable else { return false }
            return pasteBlocks(after: id)
        case .duplicate:
            guard isEditable else { return false }
            duplicate(id)
            return true
        case .delete:
            guard isEditable else { return false }
            remove(id)
            return true
        case .selectAllBlocks:
            blockSelection.selectAll(blocks.map(\.id), focusedID: id)
            synchronizeUndoCoordinator()
            return true
        case .escape:
            blockSelection.escape(to: id)
            synchronizeUndoCoordinator()
            return true
        }
    }

    @discardableResult
    private func copyBlocks(anchoredAt id: UUID, cutsSource: Bool) -> Bool {
        let ids = operationIDs(for: id)
        let copied = blocks.filter { ids.contains($0.id) }
        guard !copied.isEmpty else { return false }
        let baseDepth = copied.map(\.depth).min() ?? 0
        let portable = copied.map { block in
            EditorMarkdownBlock(
                markdown: cutsSource
                    ? block.markdown
                    : NativeBlockEditorDocument.removingBlockID(from: block.markdown),
                depth: block.depth - baseDepth,
                isCollapsed: block.isCollapsed
            )
        }
        let markdown = NativeBlockEditorDocument.render(portable)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .leonBookBlocks)
        NSPasteboard.general.setString(
            NativeBlockHierarchyMetadata.removingMarkers(from: markdown),
            forType: .string
        )
        if cutsSource { deleteBlocks(ids, actionName: ids.count > 1 ? "剪切多个块" : "剪切块") }
        return true
    }

    private func pasteBlocks(after id: UUID) -> Bool {
        guard let markdown = NSPasteboard.general.string(forType: .leonBookBlocks),
              !markdown.isEmpty else { return false }
        let pasted = NativeBlockEditorDocument.parse(markdown)
        guard !pasted.isEmpty else { return false }
        let before = blocks
        let sourceIndex = blocks.firstIndex(where: { $0.id == id })
        let baseDepth = sourceIndex.map { blocks[$0].depth } ?? 0
        var insertionIndex = sourceIndex.map { $0 + 1 } ?? blocks.count
        if let sourceIndex {
            while blocks.indices.contains(insertionIndex),
                  blocks[insertionIndex].depth > blocks[sourceIndex].depth {
                insertionIndex += 1
            }
        }
        let inserted = pasted.map { block in
            EditorMarkdownBlock(
                markdown: block.markdown,
                depth: min(block.depth + baseDepth, 12),
                isCollapsed: block.isCollapsed
            )
        }
        blocks.insert(contentsOf: inserted, at: min(insertionIndex, blocks.count))
        selectedBlockIDs = Set(inserted.map(\.id))
        selectionAnchorID = inserted.first?.id
        focusedBlockID = inserted.first?.id
        finishStructuralChange(
            from: before,
            actionName: inserted.count > 1 ? "粘贴多个块" : "粘贴块"
        )
        return true
    }

    private func insertBlock(after id: UUID?, kind: EditorMarkdownBlockKind = .paragraph) {
        let before = blocks
        let previousFocus = focusedBlockID
        let previousSelection = selectedBlockIDs
        let markdown = NativeBlockEditorDocument.converting("", to: kind)
        let sourceIndex = id.flatMap { current in blocks.firstIndex(where: { $0.id == current }) }
        let newBlock = EditorMarkdownBlock(
            markdown: markdown,
            depth: sourceIndex.map { blocks[$0].depth } ?? 0
        )
        var insertionIndex = sourceIndex.map { $0 + 1 } ?? blocks.count
        if let sourceIndex {
            while blocks.indices.contains(insertionIndex),
                  blocks[insertionIndex].depth > blocks[sourceIndex].depth {
                insertionIndex += 1
            }
        }
        blocks.insert(newBlock, at: min(insertionIndex, blocks.count))
        focusedBlockID = newBlock.id
        selectedBlockIDs = [newBlock.id]
        selectionAnchorID = newBlock.id
        finishStructuralChange(
            from: before,
            previousFocusedID: previousFocus,
            previousSelectedIDs: previousSelection,
            actionName: "添加块"
        )
    }

    private func split(_ id: UUID, selection: NSRange) {
        let before = blocks
        let previousFocus = focusedBlockID
        let previousSelection = selectedBlockIDs
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        let source = blocks[index].markdown as NSString
        guard selection.location <= source.length,
              NSMaxRange(selection) <= source.length else { return }
        let withoutSelection = source.replacingCharacters(in: selection, with: "")
        guard let parts = NativeBlockEditorDocument.split(
            withoutSelection,
            atUTF16Location: selection.location
        ) else { return }
        if blocks[index].kind.isListItem, parts.0.isEmpty, parts.1.isEmpty {
            blocks[index].markdown = ""
            focusedBlockID = id
            selectedBlockIDs = [id]
            finishStructuralChange(
                from: before,
                previousFocusedID: previousFocus,
                previousSelectedIDs: previousSelection,
                actionName: "退出列表块"
            )
            return
        }
        blocks[index].markdown = parts.0
        let next = EditorMarkdownBlock(markdown: parts.1, depth: blocks[index].depth)
        blocks.insert(next, at: index + 1)
        focusedBlockID = next.id
        selectedBlockIDs = [next.id]
        selectionAnchorID = next.id
        finishStructuralChange(
            from: before,
            previousFocusedID: previousFocus,
            previousSelectedIDs: previousSelection,
            actionName: "拆分块"
        )
    }

    private func mergeBackward(_ id: UUID) {
        let before = blocks
        let previousFocus = focusedBlockID
        let previousSelection = selectedBlockIDs
        guard let index = blocks.firstIndex(where: { $0.id == id }), index > 0 else { return }
        let current = blocks[index]
        let previous = blocks[index - 1]
        if current.markdown.isEmpty {
            blocks.remove(at: index)
        } else if previous.kind == .divider {
            blocks.remove(at: index - 1)
        } else if previous.kind == .code {
            focusedBlockID = previous.id
            selectedBlockIDs = [previous.id]
            selectionAnchorID = previous.id
            synchronizeUndoCoordinator()
            return
        } else {
            let currentBody = NativeBlockEditorDocument.converting(current.markdown, to: .paragraph)
            let separator = previous.markdown.isEmpty || currentBody.isEmpty ? "" : " "
            blocks[index - 1].markdown += separator + currentBody
            blocks.remove(at: index)
        }
        focusedBlockID = blocks.indices.contains(index - 1) ? blocks[index - 1].id : blocks.first?.id
        selectedBlockIDs = Set([focusedBlockID].compactMap { $0 })
        selectionAnchorID = focusedBlockID
        finishStructuralChange(
            from: before,
            previousFocusedID: previousFocus,
            previousSelectedIDs: previousSelection,
            actionName: "合并块"
        )
    }

    private func convert(_ id: UUID, to kind: EditorMarkdownBlockKind) {
        let ids = operationIDs(for: id)
        let before = blocks
        for index in blocks.indices where ids.contains(blocks[index].id) {
            blocks[index].markdown = NativeBlockEditorDocument.converting(blocks[index].markdown, to: kind)
        }
        focusedBlockID = id
        selectedBlockIDs = ids
        finishStructuralChange(
            from: before,
            actionName: ids.count > 1 ? "转换多个块" : "转换块"
        )
    }

    private func toggleTask(_ id: UUID) {
        let before = blocks
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[index].markdown = NativeBlockEditorDocument.togglingTask(blocks[index].markdown)
        finishStructuralChange(from: before, actionName: "切换待办")
    }

    private func slashQuery(for block: EditorMarkdownBlock) -> String? {
        let trimmed = block.markdown.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/"), !trimmed.contains("\n") else { return nil }
        return String(trimmed.dropFirst())
    }

    private func slashKinds(matching query: String) -> [EditorMarkdownBlockKind] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return Array(EditorMarkdownBlockKind.allCases.prefix(8)) }
        return EditorMarkdownBlockKind.allCases.filter { kind in
            kind.title.localizedCaseInsensitiveContains(normalized)
                || kind.detail.localizedCaseInsensitiveContains(normalized)
                || kind.rawValue.localizedCaseInsensitiveContains(normalized)
                || kind.searchKeywords.localizedCaseInsensitiveContains(normalized)
        }.prefix(8).map { $0 }
    }

    private func templates(matching query: String) -> [EditorBlockTemplate] {
        let all = EditorBlockTemplateCatalog.builtIn + customTemplates
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return Array(EditorBlockTemplateCatalog.builtIn.prefix(3)) }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(normalized)
        }.prefix(5).map { $0 }
    }

    private func applySlashKind(_ kind: EditorMarkdownBlockKind, to id: UUID) {
        let before = blocks
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[index].markdown = NativeBlockEditorDocument.converting("", to: kind)
        focusedBlockID = id
        selectedBlockIDs = [id]
        finishStructuralChange(from: before, actionName: "转换块")
    }

    private func applyTemplate(_ template: EditorBlockTemplate, replacing id: UUID) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        let before = blocks
        let baseDepth = blocks[index].depth
        let inserted = NativeBlockEditorDocument.parse(template.body).map { block in
            EditorMarkdownBlock(
                markdown: NativeBlockEditorDocument.removingBlockID(from: block.markdown),
                depth: min(baseDepth + block.depth, 12),
                isCollapsed: block.isCollapsed
            )
        }
        blocks.remove(at: index)
        blocks.insert(contentsOf: inserted, at: index)
        selectedBlockIDs = Set(inserted.map(\.id))
        selectionAnchorID = inserted.first?.id
        focusedBlockID = inserted.first?.id
        finishStructuralChange(from: before, actionName: "插入模板“\(template.name)”")
    }

    private func insertTemplate(_ template: EditorBlockTemplate, after id: UUID?) {
        let before = blocks
        let sourceIndex = id.flatMap { current in blocks.firstIndex(where: { $0.id == current }) }
        let baseDepth = sourceIndex.map { blocks[$0].depth } ?? 0
        var insertionIndex = sourceIndex.map { $0 + 1 } ?? blocks.count
        if let sourceIndex {
            while blocks.indices.contains(insertionIndex),
                  blocks[insertionIndex].depth > blocks[sourceIndex].depth {
                insertionIndex += 1
            }
        }
        let inserted = NativeBlockEditorDocument.parse(template.body).map { block in
            EditorMarkdownBlock(
                markdown: NativeBlockEditorDocument.removingBlockID(from: block.markdown),
                depth: min(baseDepth + block.depth, 12),
                isCollapsed: block.isCollapsed
            )
        }
        blocks.insert(contentsOf: inserted, at: min(insertionIndex, blocks.count))
        selectedBlockIDs = Set(inserted.map(\.id))
        selectionAnchorID = inserted.first?.id
        focusedBlockID = inserted.first?.id
        finishStructuralChange(from: before, actionName: "插入模板“\(template.name)”")
    }

    private func saveSelectionAsTemplate() {
        let roots = selectedBlockIDs.isEmpty
            ? Set([focusedBlockID].compactMap { $0 }) : selectedBlockIDs
        let ids = NativeBlockEditorDocument.descendantIDs(of: roots, in: blocks)
        let selected = blocks.filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return }
        let field = NSTextField(string: "")
        field.placeholderString = "例如：项目复盘"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        let alert = NSAlert()
        alert.messageText = "保存块模板"
        alert.informativeText = "之后可从模板菜单或输入 /模板名 快速插入。"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let baseDepth = selected.map(\.depth).min() ?? 0
        let portable = selected.map { block in
            EditorMarkdownBlock(
                markdown: NativeBlockEditorDocument.removingBlockID(from: block.markdown),
                depth: block.depth - baseDepth,
                isCollapsed: block.isCollapsed
            )
        }
        customTemplates.append(EditorBlockTemplate(
            name: name,
            body: NativeBlockEditorDocument.render(portable)
        ))
        EditorBlockTemplateCatalog.saveCustom(customTemplates)
    }

    private func deleteTemplate(_ template: EditorBlockTemplate) {
        customTemplates.removeAll { $0.id == template.id }
        EditorBlockTemplateCatalog.saveCustom(customTemplates)
    }

    private func duplicate(_ id: UUID) {
        let ids = operationIDs(for: id)
        let before = blocks
        let sourceIndexes = blocks.indices.filter { ids.contains(blocks[$0].id) }
        guard let insertionIndex = sourceIndexes.last.map({ $0 + 1 }) else { return }
        let copies = sourceIndexes.map { index in
            EditorMarkdownBlock(
                markdown: NativeBlockEditorDocument.removingBlockID(from: blocks[index].markdown),
                depth: blocks[index].depth,
                isCollapsed: blocks[index].isCollapsed
            )
        }
        blocks.insert(contentsOf: copies, at: insertionIndex)
        selectedBlockIDs = Set(copies.map(\.id))
        selectionAnchorID = copies.first?.id
        focusedBlockID = copies.first?.id
        finishStructuralChange(
            from: before,
            actionName: copies.count > 1 ? "复制多个块" : "复制块"
        )
    }

    private func remove(_ id: UUID) {
        let ids = operationIDs(for: id)
        deleteBlocks(ids, actionName: ids.count > 1 ? "删除多个块" : "删除块")
    }

    private func deleteBlocks(_ ids: Set<UUID>, actionName: String) {
        let before = blocks
        let firstIndex = blocks.firstIndex(where: { ids.contains($0.id) }) ?? 0
        blocks.removeAll { ids.contains($0.id) }
        if blocks.isEmpty { blocks = [EditorMarkdownBlock(markdown: "")] }
        focusedBlockID = blocks[min(firstIndex, blocks.count - 1)].id
        selectedBlockIDs = Set([focusedBlockID].compactMap { $0 })
        selectionAnchorID = focusedBlockID
        finishStructuralChange(
            from: before,
            actionName: actionName
        )
    }

    private func move(_ id: UUID, offset: Int) {
        let ids = operationIDs(for: id)
        let before = blocks
        let indexes = blocks.indices.filter { ids.contains(blocks[$0].id) }
        guard let first = indexes.first, let last = indexes.last else { return }
        let rootDepth = blocks[first].depth
        let destinationID: UUID
        if offset < 0 {
            var destination = first - 1
            while destination >= 0, blocks[destination].depth > rootDepth {
                destination -= 1
            }
            guard destination >= 0, blocks[destination].depth == rootDepth else { return }
            destinationID = blocks[destination].id
        } else {
            var destination = last + 1
            while blocks.indices.contains(destination), blocks[destination].depth > rootDepth {
                destination += 1
            }
            guard blocks.indices.contains(destination), blocks[destination].depth == rootDepth else { return }
            destinationID = blocks[destination].id
        }
        guard NativeBlockEditorDocument.move(
            &blocks,
            blockIDs: ids,
            relativeTo: destinationID
        ) else { return }
        withAnimation(.easeInOut(duration: 0.14)) {
            selectedBlockIDs = ids
        }
        focusedBlockID = id
        finishStructuralChange(
            from: before,
            actionName: ids.count > 1 ? "移动多个块" : "移动块"
        )
    }

    private func changeIndent(_ id: UUID, delta: Int) {
        guard delta == -1 || delta == 1 else { return }
        let ids = operationIDs(for: id)
        let indexes = blocks.indices.filter { ids.contains(blocks[$0].id) }
        guard let first = indexes.first else { return }
        if delta > 0 {
            guard first > 0 else { return }
            let previousDepth = blocks[first - 1].depth
            guard blocks[first].depth <= previousDepth else { return }
        } else {
            guard blocks[first].depth > 0 else { return }
        }
        let before = blocks
        for index in indexes {
            blocks[index].depth = min(max(blocks[index].depth + delta, 0), 12)
        }
        selectedBlockIDs = ids
        focusedBlockID = id
        finishStructuralChange(
            from: before,
            actionName: delta > 0 ? "增加块缩进" : "减少块缩进"
        )
    }

    private func toggleCollapsed(_ id: UUID) {
        guard let index = blocks.firstIndex(where: { $0.id == id }),
              NativeBlockEditorDocument.hasDescendants(id, in: blocks) else { return }
        let before = blocks
        blocks[index].isCollapsed.toggle()
        focusedBlockID = id
        selectedBlockIDs = [id]
        selectionAnchorID = id
        finishStructuralChange(
            from: before,
            actionName: blocks[index].isCollapsed ? "折叠子块" : "展开子块"
        )
    }

    private func copyBlockLink(_ blockID: UUID) {
        let before = blocks
        guard let index = blocks.firstIndex(where: { $0.id == blockID }) else { return }
        let result = NativeBlockEditorDocument.ensuringBlockID(in: blocks[index].markdown)
        blocks[index].markdown = result.markdown
        finishStructuralChange(from: before, actionName: "添加块链接")
        let target = articleReference.trimmingCharacters(in: .whitespacesAndNewlines)
        let reference = target.isEmpty ? "[[#^\(result.id)]]" : "[[\(target)#^\(result.id)]]"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reference, forType: .string)
    }

    private func presentTransfer(_ operation: EditorBlockTransferOperation) {
        let roots = selectedBlockIDs.isEmpty
            ? Set([focusedBlockID].compactMap { $0 }) : selectedBlockIDs
        let ids = NativeBlockEditorDocument.descendantIDs(of: roots, in: blocks)
        guard !ids.isEmpty else { return }
        transferRequest = EditorBlockTransferRequest(operation: operation, blockIDs: ids)
    }

    @MainActor
    private func performTransfer(
        _ request: EditorBlockTransferRequest,
        to article: NativeArticleSummary
    ) async -> Bool {
        let before = blocks
        var nextBlocks = blocks
        let movingBlocks = nextBlocks.filter { request.blockIDs.contains($0.id) }
        guard !movingBlocks.isEmpty else { return false }
        let transferBaseDepth = movingBlocks.map(\.depth).min() ?? 0
        let transferredMarkdown: [String]
        let sourceAfter: String?
        switch request.operation {
        case .copy:
            transferredMarkdown = movingBlocks.map { block in
                NativeBlockHierarchyMetadata.attaching(
                    to: block.markdown,
                    depth: block.depth - transferBaseDepth,
                    isCollapsed: block.isCollapsed
                )
            }
            sourceAfter = nil
        case .move:
            transferredMarkdown = movingBlocks.map { block in
                NativeBlockHierarchyMetadata.attaching(
                    to: block.markdown,
                    depth: block.depth - transferBaseDepth,
                    isCollapsed: block.isCollapsed
                )
            }
            nextBlocks.removeAll { request.blockIDs.contains($0.id) }
            if nextBlocks.isEmpty { nextBlocks = [EditorMarkdownBlock(markdown: "")] }
            sourceAfter = NativeBlockEditorDocument.render(nextBlocks)
        case .sync:
            guard let sourceSlug else { return false }
            var references: [String] = []
            for index in nextBlocks.indices where request.blockIDs.contains(nextBlocks[index].id) {
                let result = NativeBlockEditorDocument.ensuringBlockID(in: nextBlocks[index].markdown)
                nextBlocks[index].markdown = result.markdown
                references.append("![[\(sourceSlug)#^\(result.id)]]")
            }
            transferredMarkdown = references
            sourceAfter = NativeBlockEditorDocument.render(nextBlocks)
        }
        guard let receipt = await onTransferBlocks(
            transferredMarkdown,
            sourceAfter,
            article.slug,
            request.operation
        ) else {
            blocks = before
            return false
        }
        lastTransferReceipt = receipt
        if request.operation != .copy {
            let firstIndex = before.firstIndex(where: { request.blockIDs.contains($0.id) }) ?? 0
            blocks = nextBlocks
            focusedBlockID = blocks[min(firstIndex, blocks.count - 1)].id
            selectedBlockIDs = Set([focusedBlockID].compactMap { $0 })
            selectionAnchorID = focusedBlockID
            commit()
        }
        return true
    }

    private func undoLastTransfer(_ receipt: EditorBlockTransferReceipt) {
        isUndoingTransfer = true
        Task {
            let succeeded = await onUndoTransfer(receipt)
            await MainActor.run {
                isUndoingTransfer = false
                guard succeeded else { return }
                lastTransferReceipt = nil
                if let sourceBefore = receipt.sourceBefore {
                    source = sourceBefore.body
                    reloadBlocks(from: sourceBefore.body)
                    synchronizeUndoCoordinator()
                }
            }
        }
    }
}

enum EditorBlockTransferOperation: String {
    case move
    case copy
    case sync

    var title: String {
        switch self {
        case .move: return "移动到其他笔记"
        case .copy: return "复制到其他笔记"
        case .sync: return "同步到其他笔记"
        }
    }
    var shortTitle: String {
        switch self {
        case .move: return "跨笔记移动"
        case .copy: return "跨笔记复制"
        case .sync: return "同步块创建"
        }
    }
    var localizedShortTitle: String {
        NativeLocalization.string(shortTitle, language: NativeLocalization.currentLanguage)
    }
    var actionTitle: String {
        switch self {
        case .move: return "移动到这里"
        case .copy: return "复制到这里"
        case .sync: return "同步到这里"
        }
    }
    var systemImage: String {
        switch self {
        case .move: return "arrow.right.doc.on.clipboard"
        case .copy: return "doc.on.doc"
        case .sync: return "arrow.triangle.2.circlepath"
        }
    }
}

struct EditorBlockTransferReceipt {
    let operation: EditorBlockTransferOperation
    let sourceBefore: NativeArticle?
    let sourceAfter: NativeArticle?
    let targetBefore: NativeArticle
    let targetAfter: NativeArticle
}

private struct EditorBlockTransferRequest: Identifiable {
    let id = UUID()
    let operation: EditorBlockTransferOperation
    let blockIDs: Set<UUID>
}

private struct EditorBlockTransferSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: EditorBlockTransferRequest
    let articles: [NativeArticleSummary]
    let onTransfer: (EditorBlockTransferRequest, NativeArticleSummary) async -> Bool

    @State private var query = ""
    @State private var transferringSlug: String?

    private var filteredArticles: [NativeArticleSummary] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return articles }
        return articles.filter {
            $0.title.localizedCaseInsensitiveContains(normalized)
                || $0.slug.localizedCaseInsensitiveContains(normalized)
                || $0.tags.contains(where: { $0.localizedCaseInsensitiveContains(normalized) })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Label(LocalizedStringKey(request.operation.title), systemImage: request.operation.systemImage)
                        .font(.title2.weight(.semibold))
                    Text("已选择 \(request.blockIDs.count) 个内容块")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(transferExplanation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .disabled(transferringSlug != nil)
            }
            .padding(18)

            TextField("搜索目标笔记", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 18)
                .padding(.bottom, 12)

            Divider()

            if filteredArticles.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("没有匹配的目标笔记")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredArticles) { article in
                    Button {
                        transferringSlug = article.slug
                        Task {
                            if await onTransfer(request, article) { dismiss() }
                            else { transferringSlug = nil }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: article.status == .published ? "doc.text.fill" : "doc.badge.ellipsis")
                                .foregroundStyle(article.status == .published ? .blue : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(article.title)
                                    .foregroundStyle(.primary)
                                Text(article.slug)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if transferringSlug == article.slug {
                                ProgressView().controlSize(.small)
                            } else {
                                Text(LocalizedStringKey(request.operation.actionTitle))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(transferringSlug != nil)
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 520, height: 500)
    }

    private var transferExplanation: String {
        switch request.operation {
        case .move: return "来源和目标笔记会一起保存；失败时两边都不会改变。"
        case .copy: return "目标笔记会立即保存，当前笔记保持不变。"
        case .sync: return "目标将保存实时引用；原块更新后，嵌入内容会同步显示。"
        }
    }
}

private struct EditorBlockSlashMenu: View {
    let query: String
    let kinds: [EditorMarkdownBlockKind]
    let templates: [EditorBlockTemplate]
    let onSelect: (EditorMarkdownBlockKind) -> Void
    let onSelectTemplate: (EditorBlockTemplate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(query.isEmpty ? "基础块" : "转换块"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 5)

            if kinds.isEmpty, templates.isEmpty {
                Text("没有匹配的块类型或模板")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            } else {
                ForEach(kinds) { kind in
                    Button { onSelect(kind) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: kind.systemImage)
                                .frame(width: 20)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(LocalizedStringKey(kind.title))
                                    .font(.callout.weight(.medium))
                                Text(LocalizedStringKey(kind.detail))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if !templates.isEmpty {
                    Divider()
                    Text("模板")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                    ForEach(templates) { template in
                        Button { onSelectTemplate(template) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "square.stack.3d.up")
                                    .frame(width: 20)
                                    .foregroundStyle(.tint)
                                Text(template.name)
                                    .font(.callout.weight(.medium))
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(4)
        .frame(maxWidth: 330)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary) }
    }
}

private struct EditorBlockDropDelegate: DropDelegate {
    let destinationID: UUID
    @Binding var blocks: [EditorMarkdownBlock]
    @Binding var draggedIDs: Set<UUID>
    @Binding var dropTargetID: UUID?
    @Binding var dropTargetIsAfter: Bool
    let onMove: ([EditorMarkdownBlock]) -> Void
    let onDrop: () -> Void

    func dropEntered(info: DropInfo) {
        dropTargetID = destinationID
        guard !draggedIDs.isEmpty,
              !draggedIDs.contains(destinationID),
              let source = blocks.firstIndex(where: { draggedIDs.contains($0.id) }),
              let destination = blocks.firstIndex(where: { $0.id == destinationID }) else { return }
        dropTargetIsAfter = source < destination
        let before = blocks
        var reordered = blocks
        guard NativeBlockEditorDocument.move(
            &reordered,
            blockIDs: draggedIDs,
            relativeTo: destinationID
        ) else { return }
        withAnimation(.easeInOut(duration: 0.14)) {
            blocks = reordered
        }
        onMove(before)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dropTargetID = destinationID
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dropTargetID == destinationID { dropTargetID = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedIDs = []
        dropTargetID = nil
        dropTargetIsAfter = false
        onDrop()
        return true
    }
}
