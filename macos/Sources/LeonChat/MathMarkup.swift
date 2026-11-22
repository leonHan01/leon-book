import Foundation

/// Protect LaTeX before Foundation's Markdown parser consumes its escapes and emphasis.
struct MathMarkup {
    struct Expression: Hashable {
        let latex: String
        let display: Bool
        let source: String
        var complete = true
    }

    enum Attribute: AttributedStringKey {
        typealias Value = Expression
        static let name = "leon.math"
    }

    let markdown: String
    private let expressions: [(token: String, expression: Expression)]

    init(_ source: String) {
        guard source.contains("$") || source.contains("\\(") || source.contains("\\[") else {
            markdown = source
            expressions = []
            return
        }
        let input = source as NSString
        let prefix = "LEONMATH" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + "X"
        let protected = Self.protectedRanges(source)
        var expressions: [(String, Expression)] = []
        var output = ""
        var cursor = 0
        var copied = 0
        while cursor < input.length {
            if let range = protected.first(where: { NSLocationInRange(cursor, $0) }) {
                cursor = NSMaxRange(range)
                continue
            }
            // Destinations and reference definitions belong to Markdown, not to math.
            if Self.matches(input, "](", at: cursor), !Self.escaped(input, at: cursor) {
                cursor = Self.linkEnd(input, from: cursor + 2)
                continue
            }
            if input.character(at: cursor) == 60,
               let end = Self.find(input, ">", from: cursor + 1) {
                cursor = end + 1
                continue
            }
            var open = "", close = ""
            if !Self.escaped(input, at: cursor) {
                if Self.matches(input, "\\(", at: cursor) { open = "\\("; close = "\\)" }
                else if Self.matches(input, "\\[", at: cursor) { open = "\\["; close = "\\]" }
                else if input.character(at: cursor) == 36, cursor == 0 || input.character(at: cursor - 1) != 36 {
                    open = Self.matches(input, "$$", at: cursor) ? "$$" : "$"
                    close = open
                }
            }
            if open.isEmpty { cursor += 1; continue }
            let display = open == "\\[" || open == "$$"
            let start = cursor + (open as NSString).length
            if open == "$", start >= input.length || Self.whitespace(input.character(at: start))
                || cursor > 0 && Self.digit(input.character(at: cursor - 1)) {
                cursor += 1
                continue
            }
            var end = Self.find(input, close, from: start)
            if open == "$", let found = end {
                let content = input.substring(with: NSRange(location: start, length: found - start))
                if content.contains("\n") || found == start || Self.whitespace(input.character(at: found - 1))
                    || found + 1 < input.length && (Self.digit(input.character(at: found + 1)) || input.character(at: found + 1) == 36) {
                    end = nil
                }
            }
            let finish: Int
            let expression: Expression
            if let end, end > start {
                finish = end + (close as NSString).length
                let raw = input.substring(with: NSRange(location: cursor, length: finish - cursor))
                var latex = input.substring(with: NSRange(location: start, length: end - start))
                latex = Self.unquote(latex, input: input, opening: cursor).trimmingCharacters(in: .whitespacesAndNewlines)
                if latex.isEmpty { cursor = finish; continue }
                expression = Expression(latex: latex, display: display, source: raw)
            } else if open.hasPrefix("\\") || display {
                // Preserve unfinished backslash delimiters instead of silently unescaping them.
                finish = display ? input.length : start
                let raw = input.substring(with: NSRange(location: cursor, length: finish - cursor))
                expression = Expression(latex: "", display: false, source: raw, complete: false)
            } else {
                cursor += 1
                continue
            }
            let token = prefix + String(expressions.count) + "END"
            output += input.substring(with: NSRange(location: copied, length: cursor - copied)) + token
            expressions.append((token, expression))
            cursor = finish
            copied = finish
        }
        output += input.substring(from: copied)
        self.markdown = output
        self.expressions = expressions
    }

    func restore(_ text: AttributedString) -> AttributedString {
        var result = text
        for (token, expression) in expressions {
            while let range = result.range(of: token) {
                var replacement = AttributedString(expression.source)
                if let attributes = result[range].runs.first?.attributes { replacement.setAttributes(attributes) }
                if expression.complete { replacement[Attribute.self] = expression }
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }

    private static func protectedRanges(_ source: String) -> [NSRange] {
        var ranges: [NSRange] = []
        if let parsed = try? AttributedString(markdown: source, options: .init(
            failurePolicy: .returnPartiallyParsedIfPossible, appliesSourcePositionAttributes: true
        )) {
            for run in parsed.runs {
                let code = run.inlinePresentationIntent?.contains(.code) == true || run.presentationIntent?.components.contains {
                    if case .codeBlock = $0.kind { return true }; return false
                } == true
                if code || run.link != nil || run.imageURL != nil,
                   let position = run.markdownSourcePosition, let range = Range(position, in: source) {
                    ranges.append(NSRange(range, in: source))
                }
            }
        }
        if let regex = try? NSRegularExpression(pattern: #"(?m)^ {0,3}\[[^\]\n]+\]:[^\n]*"#) {
            ranges += regex.matches(in: source, range: NSRange(location: 0, length: (source as NSString).length)).map(\.range)
        }
        return ranges
    }

    private static func matches(_ source: NSString, _ value: String, at index: Int) -> Bool {
        let length = (value as NSString).length
        return index + length <= source.length && source.substring(with: NSRange(location: index, length: length)) == value
    }

    private static func escaped(_ source: NSString, at index: Int) -> Bool {
        var index = index, count = 0
        while index > 0 && source.character(at: index - 1) == 92 { count += 1; index -= 1 }
        return count % 2 != 0
    }

    private static func find(_ source: NSString, _ delimiter: String, from start: Int) -> Int? {
        var cursor = start
        while cursor < source.length {
            let range = source.range(of: delimiter, range: NSRange(location: cursor, length: source.length - cursor))
            if range.location == NSNotFound { return nil }
            if !escaped(source, at: range.location) { return range.location }
            cursor = NSMaxRange(range)
        }
        return nil
    }

    private static func whitespace(_ value: unichar) -> Bool {
        UnicodeScalar(value).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
    }
    private static func digit(_ value: unichar) -> Bool { value >= 48 && value <= 57 }

    private static func linkEnd(_ source: NSString, from start: Int) -> Int {
        var depth = 1, cursor = start
        while cursor < source.length {
            let char = source.character(at: cursor)
            if !escaped(source, at: cursor) {
                if char == 40 { depth += 1 }
                if char == 41 { depth -= 1; if depth == 0 { return cursor + 1 } }
            }
            cursor += 1
        }
        return start
    }

    private static func unquote(_ latex: String, input: NSString, opening: Int) -> String {
        let before = input.substring(to: opening).components(separatedBy: "\n").last ?? ""
        let depth = before.filter { $0 == ">" }.count
        guard depth > 0, let regex = try? NSRegularExpression(pattern: "(?m)^[ \\t]*(?:>[ \\t]?){\(depth)}") else { return latex }
        return regex.stringByReplacingMatches(in: latex, range: NSRange(location: 0, length: (latex as NSString).length), withTemplate: "")
    }
}
