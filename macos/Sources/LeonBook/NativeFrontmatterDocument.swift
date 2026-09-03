import Foundation

/// Semantic view of a Markdown frontmatter document. It keeps raw YAML values
/// for typed-property decoding while centralizing scalar, list, and comment
/// rules shared by managed Markdown and Obsidian import.
struct NativeFrontmatterDocument: Equatable {
    let body: String
    let values: [String: String]

    init(source: String) {
        var normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.hasPrefix("\u{feff}") { normalized.removeFirst() }

        let lines = normalized.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closingIndex = lines.indices.dropFirst().first(where: {
                  let marker = lines[$0].trimmingCharacters(in: .whitespaces)
                  return marker == "---" || marker == "..."
              }) else {
            body = normalized
            values = [:]
            return
        }

        var parsedValues: [String: String] = [:]
        var index = 1
        while index < closingIndex {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("#"),
                  let colon = line.firstIndex(of: ":") else {
                index += 1
                continue
            }

            let key = Self.scalarValue(
                from: String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            )
            guard NativeArticleProperties.isValidKey(key) else {
                index += 1
                continue
            }

            var raw = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            var childLines: [String] = []
            var next = index + 1
            while next < closingIndex {
                let candidate = lines[next]
                let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                if candidate.first?.isWhitespace == true
                    || candidateTrimmed.hasPrefix("-")
                    || candidateTrimmed.isEmpty {
                    childLines.append(candidate)
                    next += 1
                } else {
                    break
                }
            }

            if !childLines.isEmpty {
                if raw.isEmpty,
                   childLines.contains(where: {
                       $0.trimmingCharacters(in: .whitespaces).hasPrefix("-")
                   }) {
                    let items = childLines.compactMap { child -> String? in
                        let item = child.trimmingCharacters(in: .whitespaces)
                        guard item.hasPrefix("-") else { return nil }
                        return Self.scalarValue(
                            from: String(item.dropFirst()).trimmingCharacters(in: .whitespaces)
                        )
                    }
                    raw = Self.encodedInlineList(items)
                } else {
                    raw += "\n" + childLines.joined(separator: "\n")
                }
            }

            parsedValues[key] = raw.isEmpty ? "\"\"" : raw
            index = next
        }

        let bodyStart = closingIndex + 1
        body = bodyStart < lines.count
            ? lines[bodyStart...].joined(separator: "\n").trimmingCharacters(in: .newlines)
            : ""
        values = parsedValues
    }

    func rawValue(for keys: [String]) -> String? {
        for key in keys {
            if let pair = values.first(where: {
                $0.key.caseInsensitiveCompare(key) == .orderedSame
            }) {
                return pair.value
            }
        }
        return nil
    }

    func scalar(for keys: [String]) -> String? {
        rawValue(for: keys).map(Self.scalarValue(from:))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func list(for keys: [String]) -> [String] {
        guard let raw = rawValue(for: keys) else { return [] }
        return Self.listValues(from: raw)
    }

    static func scalarValue(from raw: String) -> String {
        let value = stripInlineComment(from: raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2 else { return value }
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            return (try? JSONDecoder().decode(String.self, from: Data(value.utf8)))
                ?? String(value.dropFirst().dropLast())
        }
        if value.hasPrefix("'") && value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value
    }

    private static func listValues(from raw: String) -> [String] {
        let value = stripInlineComment(from: raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("[") && value.hasSuffix("]") {
            return splitInlineList(String(value.dropFirst().dropLast()))
                .map { scalarValue(from: $0) }
                .filter { !$0.isEmpty }
        }
        if value.contains("\n") || value.hasPrefix("-") {
            return value.components(separatedBy: .newlines).compactMap { line in
                let item = line.trimmingCharacters(in: .whitespaces)
                return item.hasPrefix("-")
                    ? scalarValue(from: String(item.dropFirst()))
                    : nil
            }.filter { !$0.isEmpty }
        }
        let scalar = scalarValue(from: value)
        return scalar.split(whereSeparator: { ",，".contains($0) })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func splitInlineList(_ value: String) -> [String] {
        var results: [String] = []
        var current = ""
        var quote: Character?
        var isEscaping = false
        for character in value {
            if isEscaping {
                current.append(character)
                isEscaping = false
            } else if character == "\\", quote == "\"" {
                current.append(character)
                isEscaping = true
            } else if character == "\"" || character == "'" {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
                current.append(character)
            } else if character == ",", quote == nil {
                results.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        results.append(current.trimmingCharacters(in: .whitespaces))
        return results
    }

    private static func stripInlineComment(from value: String) -> String {
        var quote: Character?
        var previous: Character?
        var isEscaping = false
        for index in value.indices {
            let character = value[index]
            if isEscaping {
                isEscaping = false
            } else if character == "\\", quote == "\"" {
                isEscaping = true
            } else if character == "\"" || character == "'" {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
            } else if character == "#", quote == nil, previous?.isWhitespace == true {
                return String(value[..<index])
            }
            previous = character
        }
        return value
    }

    private static func encodedInlineList(_ values: [String]) -> String {
        let encoder = JSONEncoder()
        let encoded = values.map { value in
            (try? String(data: encoder.encode(value), encoding: .utf8)) ?? "\"\""
        }
        return "[\(encoded.joined(separator: ", "))]"
    }
}
