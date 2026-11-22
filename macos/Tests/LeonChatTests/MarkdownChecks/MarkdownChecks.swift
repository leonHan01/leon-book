import Foundation
@testable import LeonChat

@main
struct MarkdownChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "MarkdownChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func main() throws {
        let paragraphs = MessageMarkdown("你好 **粗体** *斜体* ~~删除~~ `代码`\n第二行 🚀\n\n第三段")
        try check(paragraphs.blocks.count == 2, "Paragraphs merged")
        let text = paragraphs.blocks[0].text
        try check(String(text.characters) == "你好 粗体 斜体 删除 代码\n第二行 🚀", "Inline syntax or chat line breaks changed")
        for intent: InlinePresentationIntent in [.stronglyEmphasized, .emphasized, .strikethrough, .code] {
            try check(text.runs.contains { $0.inlinePresentationIntent?.contains(intent) == true }, "Inline style missing: \(intent)")
        }
        let chinese = MessageMarkdown("**对应方式：**感受氛围。\n**经典情节：**冯小刚饰演的六爷\n**怎么体验：**可以漫步。")
        let chineseText = chinese.blocks.map { String($0.text.characters) }.joined()
        try check(chineseText == "对应方式：感受氛围。\n经典情节：冯小刚饰演的六爷\n怎么体验：可以漫步。", "Chinese punctuation left bold markers visible")
        let boldLabels = chinese.blocks.flatMap { block in block.text.runs.compactMap { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true ? String(block.text[run.range].characters) : nil
        }}
        try check(boldLabels == ["对应方式：", "经典情节：", "怎么体验："], "Chinese labels were not independently bold")
        let literals = MessageMarkdown(#"`**原文：**内容` 和 \*\*转义：\*\*内容"#).blocks[0].text
        try check(String(literals.characters) == "**原文：**内容 和 **转义：**内容", "Code or escaped delimiters changed")
        let reference = MessageMarkdown("[链接][标签：**]\n\n[标签：**]: https://example.com/path").blocks[0].text
        try check(reference.runs.contains { $0.link?.absoluteString == "https://example.com/path" }, "Chinese punctuation broke reference links")
        let mixed = MessageMarkdown("| 内容 |\n| --- |\n| **说明：**正文 |\n\n`**代码：**正文` &#xE000;\n\n[地址](https://example.com/**：**)")
        try check(String(mixed.blocks[0].rows[1][0].characters) == "说明：正文" && mixed.blocks[0].rows[1][0].runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }, "Table label lost bold")
        try check(String(mixed.blocks[1].text.characters).contains("**代码：**正文") && String(mixed.blocks[1].text.characters).contains("\u{E000}"), "Code or decoded private-use character changed")
        try check(mixed.blocks[2].text.runs.contains { $0.link?.absoluteString == "https://example.com/**%EF%BC%9A**" }, "Link destination changed")
        let blocks = MessageMarkdown("# 标题\n\n- 第一项\n  - 嵌套\n\n    第二段\n- 第二项\n\n3. 第三项\n4. 第四项\n\n> 引用\n> 下一行\n\n---").blocks
        if case .heading(1) = blocks[0].kind {} else { throw NSError(domain: "heading", code: 1) }
        try check(blocks[1].marker == "•" && blocks[2].marker == "•" && blocks[2].indentation == 20, "Nested list lost markers or indentation")
        try check(blocks[3].marker == nil && blocks[3].indentation == 44, "Continuation paragraph duplicated a bullet")
        try check(blocks[5].marker == "3." && blocks[6].marker == "4.", "Ordered list start number lost")
        try check(blocks[7].quoteDepth == 1 && String(blocks[7].text.characters) == "引用\n下一行", "Quote or line break missing")
        if case .rule = blocks[8].kind {} else { throw NSError(domain: "rule", code: 1) }

        let code = MessageMarkdown("```swift\n  let x = \"**原样**\"\nprint(x)\n```").blocks[0]
        if case .code("swift") = code.kind {} else { throw NSError(domain: "code", code: 1) }
        try check(String(code.text.characters) == "  let x = \"**原样**\"\nprint(x)\n", "Code whitespace or literal Markdown changed")
        let unfinished = MessageMarkdown("```\n**未完成代码**").blocks[0]
        try check(String(unfinished.text.characters).contains("**未完成代码**"), "Unclosed code fence lost content")

        let table = MessageMarkdown("| 名称 | 数值 | 备注 |\n| :--- | ---: | :---: |\n| **第一** | 1 | |\n| | 2 | 完成 |").blocks[0]
        try check(table.columns.count == 3 && table.rows.count == 3, "Table shape lost")
        try check(table.columns[1].alignment == .right && table.columns[2].alignment == .center, "Column alignment lost")
        try check(String(table.rows[1][0].characters) == "第一" && table.rows[1][2].characters.isEmpty && table.rows[2][0].characters.isEmpty, "Empty cells shifted columns")
        try check(table.rows[1][0].runs.first?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true, "Table inline style lost")

        let links = MessageMarkdown("[网站](https://example.com) [危险](javascript:alert) [文件](file:///tmp/x) ![说明](https://example.com/x.png)").blocks[0].text
        try check(links.runs.compactMap(\.link).map(\.absoluteString) == ["https://example.com"], "Unsupported link scheme enabled")
        try check(links.runs.allSatisfy { $0.imageURL == nil }, "Remote image retained")
        try check(String(links.characters).contains("说明"), "Image alt text lost")
        try check(String(MessageMarkdown("**未闭合 🚀").blocks[0].text.characters) == "**未闭合 🚀", "Malformed inline Markdown lost content")
        print("PASS: Markdown inline styles, chat line breaks, headings, nested/ordered lists, quotes and dividers")
        print("PASS: fenced code literals, incomplete syntax, table alignment/empty cells and allowed links")
    }
}
