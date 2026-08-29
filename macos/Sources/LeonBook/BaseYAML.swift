import Foundation

/// Small YAML representation tailored to Obsidian Base files. It deliberately
/// keeps scalar tokens in their original YAML form so fields LeonBook does not
/// understand can survive a read/edit/write cycle without being re-typed.
indirect enum NativeBaseYAMLValue {
    case scalar(String)
    case mapping([NativeBaseYAMLPair])
    case sequence([NativeBaseYAMLValue])
    case block(style: String, lines: [String])

    var pairs: [NativeBaseYAMLPair]? {
        guard case let .mapping(value) = self else { return nil }
        return value
    }

    var items: [NativeBaseYAMLValue]? {
        guard case let .sequence(value) = self else { return nil }
        return value
    }

    var scalarToken: String? {
        guard case let .scalar(value) = self else { return nil }
        return value
    }

    func value(forKey key: String) -> NativeBaseYAMLValue? {
        guard case let .mapping(pairs) = self else { return nil }
        return pairs.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value
    }

    mutating func set(_ value: NativeBaseYAMLValue?, forKey key: String) {
        guard case var .mapping(pairs) = self else { return }
        if let index = pairs.firstIndex(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
            if let value { pairs[index].value = value }
            else { pairs.remove(at: index) }
        } else if let value {
            pairs.append(NativeBaseYAMLPair(key: key, value: value))
        }
        self = .mapping(pairs)
    }
}

struct NativeBaseYAMLPair {
    var key: String
    var value: NativeBaseYAMLValue
}

struct NativeBaseYAMLDocument {
    var root: NativeBaseYAMLValue

    init(source: String) throws {
        var parser = NativeBaseYAMLParser(source: source)
        root = try parser.parse()
    }

    init(root: NativeBaseYAMLValue = .mapping([])) {
        self.root = root
    }

    func rendered() -> String {
        NativeBaseYAMLRenderer.render(root) + "\n"
    }
}

private struct NativeBaseYAMLParser {
    private struct Line {
        let indent: Int
        let content: String
        let original: String
    }

    private var lines: [Line]
    private var index = 0

    init(source: String) {
        lines = source.components(separatedBy: .newlines).compactMap { sourceLine in
            let expanded = sourceLine.replacingOccurrences(of: "\t", with: "  ")
            let trimmed = expanded.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("#"),
                  trimmed != "---",
                  trimmed != "..." else { return nil }
            let indent = expanded.prefix(while: { $0 == " " }).count
            return Line(indent: indent, content: trimmed, original: expanded)
        }
    }

    mutating func parse() throws -> NativeBaseYAMLValue {
        guard let first = lines.first else { return .mapping([]) }
        return try parseBlock(indent: first.indent)
    }

    private mutating func parseBlock(indent: Int) throws -> NativeBaseYAMLValue {
        guard index < lines.count else { return .mapping([]) }
        if lines[index].content == "-" || lines[index].content.hasPrefix("- ") {
            return try parseSequence(indent: indent)
        }
        return try parseMapping(indent: indent)
    }

    private mutating func parseMapping(indent: Int) throws -> NativeBaseYAMLValue {
        var pairs: [NativeBaseYAMLPair] = []
        while index < lines.count {
            let line = lines[index]
            guard line.indent == indent,
                  line.content != "-",
                  !line.content.hasPrefix("- ") else { break }
            guard let pair = splitPair(line.content) else {
                throw NativeStoreError.fileSystem("Base YAML 第 \(index + 1) 行不是有效键值")
            }
            index += 1
            let value = try parseValue(after: pair.value, parentIndent: indent)
            pairs.append(NativeBaseYAMLPair(key: decodeScalar(pair.key), value: value))
        }
        return .mapping(pairs)
    }

    private mutating func parseSequence(indent: Int) throws -> NativeBaseYAMLValue {
        var items: [NativeBaseYAMLValue] = []
        while index < lines.count {
            let line = lines[index]
            guard line.indent == indent,
                  line.content == "-" || line.content.hasPrefix("- ") else { break }
            let rest = line.content == "-" ? "" : String(line.content.dropFirst(2))
            index += 1

            if rest.isEmpty {
                if index < lines.count, lines[index].indent > indent {
                    items.append(try parseBlock(indent: lines[index].indent))
                } else {
                    items.append(.scalar("null"))
                }
                continue
            }

            if let firstPair = splitPair(rest) {
                let firstValue = try parseValue(after: firstPair.value, parentIndent: indent)
                var pairs = [NativeBaseYAMLPair(key: decodeScalar(firstPair.key), value: firstValue)]
                if index < lines.count,
                   lines[index].indent > indent,
                   lines[index].content != "-",
                   !lines[index].content.hasPrefix("- ") {
                    let continuationIndent = lines[index].indent
                    if case let .mapping(continuation) = try parseMapping(indent: continuationIndent) {
                        pairs.append(contentsOf: continuation)
                    }
                }
                items.append(.mapping(pairs))
            } else {
                items.append(.scalar(stripInlineComment(rest)))
            }
        }
        return .sequence(items)
    }

    private mutating func parseValue(after rawValue: String, parentIndent: Int) throws -> NativeBaseYAMLValue {
        let token = stripInlineComment(rawValue).trimmingCharacters(in: .whitespaces)
        if token == "|" || token == ">" || token.hasPrefix("|-") || token.hasPrefix(">-") {
            var content: [String] = []
            while index < lines.count, lines[index].indent > parentIndent {
                content.append(lines[index].original)
                index += 1
            }
            return .block(style: token, lines: content)
        }
        if !token.isEmpty { return .scalar(token) }
        guard index < lines.count, lines[index].indent > parentIndent else {
            return .scalar("null")
        }
        return try parseBlock(indent: lines[index].indent)
    }

    private func splitPair(_ source: String) -> (key: String, value: String)? {
        var singleQuoted = false
        var doubleQuoted = false
        var squareDepth = 0
        var roundDepth = 0
        var escaped = false
        for index in source.indices {
            let character = source[index]
            if escaped { escaped = false; continue }
            if character == "\\", doubleQuoted { escaped = true; continue }
            if character == "'", !doubleQuoted { singleQuoted.toggle(); continue }
            if character == "\"", !singleQuoted { doubleQuoted.toggle(); continue }
            guard !singleQuoted, !doubleQuoted else { continue }
            if character == "[" { squareDepth += 1; continue }
            if character == "]" { squareDepth = max(0, squareDepth - 1); continue }
            if character == "(" { roundDepth += 1; continue }
            if character == ")" { roundDepth = max(0, roundDepth - 1); continue }
            if character == ":", squareDepth == 0, roundDepth == 0 {
                return (
                    String(source[..<index]).trimmingCharacters(in: .whitespaces),
                    String(source[source.index(after: index)...]).trimmingCharacters(in: .whitespaces)
                )
            }
        }
        return nil
    }

    private func stripInlineComment(_ source: String) -> String {
        var singleQuoted = false
        var doubleQuoted = false
        var escaped = false
        var previous: Character?
        for index in source.indices {
            let character = source[index]
            if escaped { escaped = false; previous = character; continue }
            if character == "\\", doubleQuoted { escaped = true; previous = character; continue }
            if character == "'", !doubleQuoted { singleQuoted.toggle() }
            if character == "\"", !singleQuoted { doubleQuoted.toggle() }
            if character == "#", !singleQuoted, !doubleQuoted,
               previous == nil || previous?.isWhitespace == true {
                return String(source[..<index]).trimmingCharacters(in: .whitespaces)
            }
            previous = character
        }
        return source.trimmingCharacters(in: .whitespaces)
    }

    private func decodeScalar(_ source: String) -> String {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2 else { return value }
        if value.first == "'", value.last == "'" {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if value.first == "\"", value.last == "\"" {
            let data = Data(value.utf8)
            return (try? JSONDecoder().decode(String.self, from: data)) ?? String(value.dropFirst().dropLast())
        }
        return value
    }
}

private enum NativeBaseYAMLRenderer {
    static func render(_ value: NativeBaseYAMLValue) -> String {
        render(value, indent: 0).joined(separator: "\n")
    }

    private static func render(_ value: NativeBaseYAMLValue, indent: Int) -> [String] {
        let padding = String(repeating: " ", count: indent)
        switch value {
        case let .scalar(token):
            return [padding + token]
        case let .block(style, lines):
            return [padding + style] + lines
        case let .mapping(pairs):
            return pairs.flatMap { pair in
                let key = encodeKey(pair.key)
                switch pair.value {
                case let .scalar(token):
                    return [padding + key + ": " + token]
                case let .block(style, lines):
                    return [padding + key + ": " + style] + lines
                default:
                    return [padding + key + ":"] + render(pair.value, indent: indent + 2)
                }
            }
        case let .sequence(items):
            return items.flatMap { item in
                switch item {
                case let .scalar(token):
                    return [padding + "- " + token]
                case let .mapping(pairs) where !pairs.isEmpty:
                    var output: [String] = []
                    let first = pairs[0]
                    let key = encodeKey(first.key)
                    switch first.value {
                    case let .scalar(token):
                        output.append(padding + "- " + key + ": " + token)
                    default:
                        output.append(padding + "- " + key + ":")
                        output.append(contentsOf: render(first.value, indent: indent + 4))
                    }
                    if pairs.count > 1 {
                        output.append(contentsOf: render(.mapping(Array(pairs.dropFirst())), indent: indent + 2))
                    }
                    return output
                default:
                    return [padding + "-"] + render(item, indent: indent + 2)
                }
            }
        }
    }

    private static func encodeKey(_ source: String) -> String {
        let safe = !source.isEmpty && source.allSatisfy {
            $0.isLetter || $0.isNumber || "._-/".contains($0)
        }
        return safe ? source : "'" + source.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
