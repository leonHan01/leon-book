import Foundation

/// Foundation parses Markdown; these blocks preserve its structure for native SwiftUI layout.
struct MessageMarkdown {
    struct Block: Identifiable {
        enum Kind {
            case text, heading(Int), code(String?), rule, table, math(MathMarkup.Expression)
        }
        var id: Int
        var kind: Kind
        var text: AttributedString
        var indentation = 0
        var marker: String?
        var quoteDepth = 0
        var columns: [PresentationIntent.TableColumn] = []
        var rows: [[AttributedString]] = []
    }

    let blocks: [Block]

    init(_ source: String) {
        let math = MathMarkup(source)
        let compatibility = CJKStrongCompatibility(math.markdown)
        guard let parsed = try? AttributedString(markdown: compatibility.markdown, options: .init(
            allowsExtendedAttributes: false, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible
        )), !parsed.characters.isEmpty else {
            blocks = [Block(id: 0, kind: .text, text: AttributedString(source))]
            return
        }
        var result: [Block] = []
        var seenItems = Set<Int>()
        for (intent, range) in parsed.runs[\.presentationIntent] {
            let components = intent?.components ?? []
            let text = math.restore(Self.inlineText(compatibility.restore(AttributedString(parsed[range]))))
            if let table = components.first(where: { if case .table = $0.kind { return true }; return false }),
               case .table(let columns) = table.kind {
                if result.last?.id != table.identity {
                    var block = Block(id: table.identity, kind: .table, text: AttributedString())
                    block.columns = columns
                    Self.decorate(&block, components: components, seenItems: &seenItems)
                    result.append(block)
                }
                let row = components.compactMap { component -> Int? in
                    switch component.kind {
                    case .tableHeaderRow: return 0
                    case .tableRow(let index): return index
                    default: return nil
                    }
                }.first ?? 0
                let column = components.compactMap { component -> Int? in
                    if case .tableCell(let index) = component.kind { return index }; return nil
                }.first ?? 0
                let index = result.count - 1
                while result[index].rows.count <= row {
                    result[index].rows.append(Array(repeating: AttributedString(), count: columns.count))
                }
                if column < columns.count { result[index].rows[row][column] += text }
                continue
            }
            var block = Block(id: components.first?.identity ?? -result.count - 1, kind: .text, text: text)
            switch components.first?.kind {
            case .header(let level): block.kind = .heading(level)
            case .codeBlock(let language): block.kind = .code(language)
            case .thematicBreak: block.kind = .rule
            default: break
            }
            Self.decorate(&block, components: components, seenItems: &seenItems)
            result.append(block)
        }
        blocks = result.flatMap(Self.splitDisplayMath).enumerated().map { index, block in
            var block = block
            block.id = index
            return block
        }
    }

    private static func splitDisplayMath(_ block: Block) -> [Block] {
        switch block.kind {
        case .text, .heading: break
        default: return [block]
        }
        guard block.text.runs.contains(where: { $0[MathMarkup.Attribute.self]?.display == true }) else { return [block] }
        var result: [Block] = []
        var pending = AttributedString()
        func append(_ text: AttributedString, kind: Block.Kind) {
            let trimmed = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let range = text.range(of: trimmed) else { return }
            var part = block
            part.kind = kind
            part.text = AttributedString(text[range])
            if !result.isEmpty {
                part.marker = nil
                if block.marker != nil { part.indentation += 24 }
            }
            result.append(part)
        }
        for run in block.text.runs {
            let text = AttributedString(block.text[run.range])
            if let expression = run[MathMarkup.Attribute.self], expression.display {
                append(pending, kind: block.kind)
                pending = AttributedString()
                append(text, kind: .math(expression))
            } else {
                pending += text
            }
        }
        append(pending, kind: block.kind)
        return result
    }

    private static func decorate(_ block: inout Block, components: [PresentationIntent.IntentType], seenItems: inout Set<Int>) {
        let items = components.filter { if case .listItem = $0.kind { return true }; return false }
        block.indentation = max(0, items.count - 1) * 20
        block.quoteDepth = components.filter { $0.kind == .blockQuote }.count
        if let item = items.first, case .listItem(let ordinal) = item.kind {
            if seenItems.insert(item.identity).inserted {
                let list = components.first { $0.kind == .orderedList || $0.kind == .unorderedList }
                block.marker = list?.kind == .orderedList ? "\(ordinal)." : "•"
            } else {
                block.indentation += 24
            }
        }
    }

    private static func inlineText(_ source: AttributedString) -> AttributedString {
        var result = AttributedString()
        for run in source.runs {
            var part = AttributedString(source[run.range])
            // Chat messages keep ordinary line breaks, including inside lists and quotes.
            if run.inlinePresentationIntent?.contains(.softBreak) == true { part = AttributedString("\n") }
            part.presentationIntent = nil
            if let url = part.link, !isAllowedLink(url) { part.link = nil }
            // Images display their alt text, without fetching remote resources.
            part.imageURL = nil
            result += part
        }
        return result
    }

    static func isAllowedLink(_ url: URL) -> Bool {
        ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }
}

/// Match Android's handling of punctuation next to bold delimiters while letting
/// Foundation continue to parse code, escapes, links and the surrounding Markdown.
private struct CJKStrongCompatibility {
    let markdown: String
    private let replacements: [String: String]

    init(_ source: String) {
        let chars = Array(source)
        let candidates = chars.indices.filter { index in
            let scalars = chars[index].unicodeScalars
            guard scalars.count == 1, let scalar = scalars.first, scalar.value >= 128,
                  CharacterSet.punctuationCharacters.contains(scalar) else { return false }
            return index >= 2 && chars[index - 1] == "*" && chars[index - 2] == "*"
                || index + 2 < chars.count && chars[index + 1] == "*" && chars[index + 2] == "*"
        }
        guard !candidates.isEmpty else { markdown = source; replacements = [:]; return }
        // Entity decoding may introduce private-use characters absent from the source.
        let original = try? AttributedString(markdown: source, options: .init(failurePolicy: .returnPartiallyParsedIfPossible))
        var occupied = Set(source.unicodeScalars.map(\.value))
        if let original {
            occupied.formUnion(String(original.characters).unicodeScalars.map(\.value))
            for run in original.runs { if let url = run.link { occupied.formUnion(url.absoluteString.unicodeScalars.map(\.value)) } }
        }
        var output = chars, mapping: [String: String] = [:], byOriginal: [Character: Character] = [:]
        var next: UInt32 = 0xE000
        for index in candidates {
            let value = chars[index]
            var replacement = byOriginal[value]
            if replacement == nil {
                while next <= 0xF8FF && occupied.contains(next) { next += 1 }
                guard next <= 0xF8FF, let scalar = UnicodeScalar(next) else { continue }
                replacement = Character(scalar); next += 1
                byOriginal[value] = replacement
                mapping[String(replacement!)] = String(value)
            }
            output[index] = replacement!
        }
        markdown = String(output)
        replacements = mapping
    }

    func restore(_ text: AttributedString) -> AttributedString {
        var result = AttributedString()
        for run in text.runs {
            var part = AttributedString(text[run.range])
            for (placeholder, original) in replacements {
                while let range = part.range(of: placeholder) {
                    var value = AttributedString(original)
                    if let attributes = part[range].runs.first?.attributes { value.setAttributes(attributes) }
                    part.replaceSubrange(range, with: value)
                }
                if let url = part.link {
                    let encoded = placeholder.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? placeholder
                    let restored = url.absoluteString.replacingOccurrences(of: placeholder, with: original)
                        .replacingOccurrences(of: encoded, with: original.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? original)
                    part.link = URL(string: restored)
                }
            }
            result += part
        }
        return result
    }
}
