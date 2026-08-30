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
        case .divider: return "divider rule hr 分割线"
        }
    }

    var isListItem: Bool {
        self == .bulletedList || self == .numberedList || self == .task
    }

    static func detect(in markdown: String) -> Self {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { return .code }
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

    init(id: UUID = UUID(), markdown: String) {
        self.id = id
        self.markdown = markdown
    }

    var kind: EditorMarkdownBlockKind { .detect(in: markdown) }
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

        func appendCurrent() {
            guard !current.isEmpty else { return }
            result.append(EditorMarkdownBlock(markdown: current.joined(separator: "\n")))
            current.removeAll(keepingCapacity: true)
            currentKind = nil
        }

        for line in lines {
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
        return result.isEmpty ? [EditorMarkdownBlock(markdown: "")] : result
    }

    static func render(_ blocks: [EditorMarkdownBlock]) -> String {
        guard !blocks.isEmpty else { return "" }
        var output = ""
        for index in blocks.indices {
            if index > 0 {
                output += shouldJoinTightly(blocks[index - 1], blocks[index]) ? "\n" : "\n\n"
            }
            output += blocks[index].markdown.trimmingCharacters(in: .newlines)
        }
        return output
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

        if kind == .code { return nil }
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
        guard blockID != destinationID,
              let source = blocks.firstIndex(where: { $0.id == blockID }),
              let destination = blocks.firstIndex(where: { $0.id == destinationID }) else { return false }
        let block = blocks.remove(at: source)
        blocks.insert(block, at: min(destination, blocks.count))
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

    private static func taskPrefixLengthForDocument<C: StringProtocol>(in content: C) -> Int? {
        EditorMarkdownBlockKind.taskPrefixLength(in: content)
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

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
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
        applyStyling(to: textView)
        context.coordinator.updateHeight(of: textView)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.parent = self
        textView.isEditable = isEditable
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
               parent.kind != .code {
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

struct ArticleBlockEditor: View {
    @Binding var source: String
    let articleReference: String
    let isEditable: Bool
    let typography: NativeReadingTypography

    @State private var blocks: [EditorMarkdownBlock] = []
    @State private var focusedBlockID: UUID?
    @State private var draggedBlockID: UUID?
    @State private var dropTargetBlockID: UUID?
    @State private var dropTargetIsAfter = false
    @State private var editorHeights: [UUID: CGFloat] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("块编辑", systemImage: "square.grid.3x1.folder.badge.plus")
                    .font(.subheadline.weight(.medium))
                Text("拖动左侧手柄搬运整块 · Enter 新建块 · Shift+Enter 换行")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button { insertBlock(after: blocks.last?.id) } label: {
                    Label("添加块", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(!isEditable)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(blocks) { block in
                        blockRow(block)
                            .onDrop(
                                of: [UTType.text],
                                delegate: EditorBlockDropDelegate(
                                    destinationID: block.id,
                                    blocks: $blocks,
                                    draggedID: $draggedBlockID,
                                    dropTargetID: $dropTargetBlockID,
                                    dropTargetIsAfter: $dropTargetIsAfter,
                                    onMove: commit
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
        .onAppear { reloadBlocks(from: source) }
        .onChange(of: source) { updatedSource in
            guard NativeBlockEditorDocument.render(blocks) != updatedSource else { return }
            reloadBlocks(from: updatedSource)
        }
    }

    @ViewBuilder
    private func blockRow(_ block: EditorMarkdownBlock) -> some View {
        let index = blocks.firstIndex(where: { $0.id == block.id }) ?? 0
        HStack(alignment: .top, spacing: 7) {
            HStack(spacing: 1) {
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
                    .onDrag {
                        draggedBlockID = block.id
                        dropTargetBlockID = nil
                        dropTargetIsAfter = false
                        return NSItemProvider(object: block.id.uuidString as NSString)
                    }

                Menu {
                    blockTypeMenu(for: block.id)
                    Divider()
                    Button("复制块链接", systemImage: "link") { copyBlockLink(block.id) }
                    Button("创建副本", systemImage: "plus.square.on.square") { duplicate(block.id) }
                    Button("整块上移", systemImage: "arrow.up") { move(block.id, offset: -1) }
                        .disabled(index == 0)
                    Button("整块下移", systemImage: "arrow.down") { move(block.id, offset: 1) }
                        .disabled(index == blocks.count - 1)
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
            .foregroundStyle(focusedBlockID == block.id ? Color.accentColor : Color.secondary.opacity(0.7))
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
                    onFocus: { focusedBlockID = block.id },
                    onSplit: { split(block.id, selection: $0) },
                    onMergeBackward: { mergeBackward(block.id) }
                )
                .frame(height: editorHeights[block.id] ?? typography.fontSize + 10)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    focusedBlockID == block.id ? Color.accentColor.opacity(0.055) : Color.clear,
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
                    Button("创建副本", systemImage: "plus.square.on.square") { duplicate(block.id) }
                        .disabled(!isEditable)
                    Button("整块上移", systemImage: "arrow.up") { move(block.id, offset: -1) }
                        .disabled(!isEditable || index == 0)
                    Button("整块下移", systemImage: "arrow.down") { move(block.id, offset: 1) }
                        .disabled(!isEditable || index == blocks.count - 1)
                    Divider()
                    Button("删除", systemImage: "trash", role: .destructive) { remove(block.id) }
                        .disabled(!isEditable)
                }

                if let query = slashQuery(for: block), focusedBlockID == block.id {
                    EditorBlockSlashMenu(
                        query: query,
                        kinds: slashKinds(matching: query),
                        onSelect: { applySlashKind($0, to: block.id) }
                    )
                }
            }
        }
        .contentShape(Rectangle())
        .overlay(alignment: dropTargetIsAfter ? .bottom : .top) {
            if dropTargetBlockID == block.id, draggedBlockID != block.id {
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
                    Label(kind.title, systemImage: kind.systemImage)
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
                return EditorMarkdownBlock(id: id, markdown: parsedBlock.markdown)
            }
            if unused.indices.contains(index) {
                let id = unused.remove(at: index).id
                return EditorMarkdownBlock(id: id, markdown: parsedBlock.markdown)
            }
            return parsedBlock
        }
    }

    private func commit() {
        source = NativeBlockEditorDocument.render(blocks)
    }

    private func insertBlock(after id: UUID?, kind: EditorMarkdownBlockKind = .paragraph) {
        let markdown = NativeBlockEditorDocument.converting("", to: kind)
        let newBlock = EditorMarkdownBlock(markdown: markdown)
        let insertionIndex = id.flatMap { current in
            blocks.firstIndex(where: { $0.id == current }).map { $0 + 1 }
        } ?? blocks.count
        blocks.insert(newBlock, at: min(insertionIndex, blocks.count))
        focusedBlockID = newBlock.id
        commit()
    }

    private func split(_ id: UUID, selection: NSRange) {
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
            commit()
            return
        }
        blocks[index].markdown = parts.0
        let next = EditorMarkdownBlock(markdown: parts.1)
        blocks.insert(next, at: index + 1)
        focusedBlockID = next.id
        commit()
    }

    private func mergeBackward(_ id: UUID) {
        guard let index = blocks.firstIndex(where: { $0.id == id }), index > 0 else { return }
        let current = blocks[index]
        let previous = blocks[index - 1]
        if current.markdown.isEmpty {
            blocks.remove(at: index)
        } else if previous.kind == .divider {
            blocks.remove(at: index - 1)
        } else if previous.kind == .code {
            focusedBlockID = previous.id
            return
        } else {
            let currentBody = NativeBlockEditorDocument.converting(current.markdown, to: .paragraph)
            let separator = previous.markdown.isEmpty || currentBody.isEmpty ? "" : " "
            blocks[index - 1].markdown += separator + currentBody
            blocks.remove(at: index)
        }
        focusedBlockID = blocks.indices.contains(index - 1) ? blocks[index - 1].id : blocks.first?.id
        commit()
    }

    private func convert(_ id: UUID, to kind: EditorMarkdownBlockKind) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[index].markdown = NativeBlockEditorDocument.converting(blocks[index].markdown, to: kind)
        focusedBlockID = id
        commit()
    }

    private func toggleTask(_ id: UUID) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[index].markdown = NativeBlockEditorDocument.togglingTask(blocks[index].markdown)
        commit()
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

    private func applySlashKind(_ kind: EditorMarkdownBlockKind, to id: UUID) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[index].markdown = NativeBlockEditorDocument.converting("", to: kind)
        focusedBlockID = id
        commit()
    }

    private func duplicate(_ id: UUID) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        // A duplicated block must not keep the original addressable ID.
        let markdown = NativeBlockEditorDocument.removingBlockID(from: blocks[index].markdown)
        let copy = EditorMarkdownBlock(markdown: markdown)
        blocks.insert(copy, at: index + 1)
        focusedBlockID = copy.id
        commit()
    }

    private func remove(_ id: UUID) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks.remove(at: index)
        if blocks.isEmpty { blocks = [EditorMarkdownBlock(markdown: "")] }
        focusedBlockID = blocks[min(index, blocks.count - 1)].id
        commit()
    }

    private func move(_ id: UUID, offset: Int) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard blocks.indices.contains(destination) else { return }
        withAnimation(.easeInOut(duration: 0.14)) {
            blocks.swapAt(index, destination)
        }
        commit()
    }

    private func copyBlockLink(_ blockID: UUID) {
        guard let index = blocks.firstIndex(where: { $0.id == blockID }) else { return }
        let result = NativeBlockEditorDocument.ensuringBlockID(in: blocks[index].markdown)
        blocks[index].markdown = result.markdown
        commit()
        let target = articleReference.trimmingCharacters(in: .whitespacesAndNewlines)
        let reference = target.isEmpty ? "[[#^\(result.id)]]" : "[[\(target)#^\(result.id)]]"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reference, forType: .string)
    }
}

private struct EditorBlockSlashMenu: View {
    let query: String
    let kinds: [EditorMarkdownBlockKind]
    let onSelect: (EditorMarkdownBlockKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(query.isEmpty ? "基础块" : "转换块")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 5)

            if kinds.isEmpty {
                Text("没有匹配的块类型")
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
                                Text(kind.title)
                                    .font(.callout.weight(.medium))
                                Text(kind.detail)
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
    @Binding var draggedID: UUID?
    @Binding var dropTargetID: UUID?
    @Binding var dropTargetIsAfter: Bool
    let onMove: () -> Void

    func dropEntered(info: DropInfo) {
        dropTargetID = destinationID
        guard let draggedID,
              draggedID != destinationID,
              let source = blocks.firstIndex(where: { $0.id == draggedID }),
              let destination = blocks.firstIndex(where: { $0.id == destinationID }) else { return }
        dropTargetIsAfter = source < destination
        var reordered = blocks
        guard NativeBlockEditorDocument.move(
            &reordered,
            blockID: draggedID,
            relativeTo: destinationID
        ) else { return }
        withAnimation(.easeInOut(duration: 0.14)) {
            blocks = reordered
        }
        onMove()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dropTargetID = destinationID
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dropTargetID == destinationID { dropTargetID = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        dropTargetID = nil
        dropTargetIsAfter = false
        onMove()
        return true
    }
}
