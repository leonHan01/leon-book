import Foundation

public enum NativeArticlePropertyKind: String, Codable, CaseIterable, Hashable, Identifiable {
    case text
    case list
    case number
    case date
    case checkbox
    case tags

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .text: return "文本"
        case .list: return "列表"
        case .number: return "数字"
        case .date: return "日期"
        case .checkbox: return "复选框"
        case .tags: return "标签"
        }
    }

    var systemImage: String {
        switch self {
        case .text: return "textformat"
        case .list: return "list.bullet"
        case .number: return "number"
        case .date: return "calendar"
        case .checkbox: return "checkmark.square"
        case .tags: return "tag"
        }
    }
}

/// A typed article property stored as `{ "kind": ..., "value": ... }`.
/// The decoder also accepts the legacy scalar/array JSON written by older builds.
public struct NativeArticlePropertyValue: Codable, Hashable, ExpressibleByStringLiteral {
    public let kind: NativeArticlePropertyKind
    public let value: String

    public init(kind: NativeArticlePropertyKind, value: String) {
        self.kind = kind
        self.value = value
    }

    public init(stringLiteral value: String) {
        self.init(kind: .text, value: value)
    }

    public static func text(_ value: String) -> Self {
        Self(kind: .text, value: value)
    }

    public static func list(_ values: [String]) -> Self {
        Self(kind: .list, value: encodedList(normalizedList(values)))
    }

    public static func number(_ value: Double) -> Self {
        Self(kind: .number, value: formattedNumber(value))
    }

    public static func date(_ value: String) -> Self {
        Self(kind: .date, value: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func checkbox(_ value: Bool) -> Self {
        Self(kind: .checkbox, value: value ? "true" : "false")
    }

    public static func tags(_ values: [String]) -> Self {
        Self(kind: .tags, value: encodedList(normalizedList(values)))
    }

    public static func fromEditor(kind: NativeArticlePropertyKind, text: String) -> Self {
        switch kind {
        case .text:
            return .text(text)
        case .list:
            return .list(splitEditorList(text))
        case .number:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return Self(kind: .number, value: Double(trimmed).map(formattedNumber) ?? trimmed)
        case .date:
            return .date(text)
        case .checkbox:
            return .checkbox(parseBoolean(text) ?? false)
        case .tags:
            return .tags(splitEditorList(text).map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "#＃"))
            })
        }
    }

    public static func fromYAML(_ source: String) -> Self {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if let values = decodedList(trimmed) ?? decodedInlineYAMLList(trimmed) ?? decodedBlockList(trimmed) {
            return .list(values)
        }
        if let boolean = parseBoolean(trimmed) { return .checkbox(boolean) }
        if isValidDate(trimmed) { return .date(trimmed) }
        if let number = Double(trimmed), number.isFinite { return .number(number) }
        return .text(decodedScalar(trimmed))
    }

    public var editorText: String {
        switch kind {
        case .list, .tags:
            return listValues.joined(separator: ", ")
        default:
            return value
        }
    }

    public var listValues: [String] {
        switch kind {
        case .list, .tags:
            return Self.decodedList(value) ?? Self.splitEditorList(value)
        case .text:
            return [value].filter { !$0.isEmpty }
        default:
            return [value]
        }
    }

    public var booleanValue: Bool {
        Self.parseBoolean(value) ?? false
    }

    public var isValid: Bool {
        switch kind {
        case .text, .list, .tags:
            return true
        case .number:
            return Double(value)?.isFinite == true
        case .date:
            return Self.isValidDate(value)
        case .checkbox:
            return Self.parseBoolean(value) != nil
        }
    }

    public var searchValues: [String] {
        switch kind {
        case .list, .tags: return listValues
        default: return [value]
        }
    }

    public var searchText: String {
        searchValues.joined(separator: " ")
    }

    public var yamlValue: String {
        switch kind {
        case .text:
            return Self.quoted(value)
        case .list, .tags:
            return "[\(listValues.map(Self.quoted).joined(separator: ", "))]"
        case .number:
            return Double(value).map(Self.formattedNumber) ?? value
        case .date:
            return value
        case .checkbox:
            return booleanValue ? "true" : "false"
        }
    }

    public func contains(_ substring: String) -> Bool {
        searchText.localizedCaseInsensitiveContains(substring)
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case type
        case value
    }

    public init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self),
           keyed.contains(.kind) || keyed.contains(.type) {
            let decodedKind = try keyed.decodeIfPresent(NativeArticlePropertyKind.self, forKey: .kind)
                ?? keyed.decode(NativeArticlePropertyKind.self, forKey: .type)
            self.init(kind: decodedKind, value: try keyed.decodeIfPresent(String.self, forKey: .value) ?? "")
            return
        }

        let single = try decoder.singleValueContainer()
        if let string = try? single.decode(String.self) {
            self = Self.fromYAML(string)
        } else if let boolean = try? single.decode(Bool.self) {
            self = .checkbox(boolean)
        } else if let number = try? single.decode(Double.self) {
            self = .number(number)
        } else if let values = try? single.decode([String].self) {
            self = .list(values)
        } else {
            self = .text("")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(value, forKey: .value)
    }
}

public enum NativeArticlePropertyError: LocalizedError, Equatable {
    case invalidKey(String)
    case invalidValue(String)
    case tooMany
    case destinationExists(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidKey(key): return "属性名“\(key)”无效；请使用文字、数字、空格、点、下划线或连字符。"
        case let .invalidValue(key): return "属性“\(key)”的值与所选类型不匹配。"
        case .tooMany: return "每篇文章最多保存 100 个属性。"
        case let .destinationExists(key): return "已有名为“\(key)”且值不同的属性，无法统一重命名。"
        }
    }
}

/// The property module owns validation, case-insensitive key semantics and workspace rename rules.
public enum NativeArticleProperties {
    public static func validated(
        _ properties: [String: NativeArticlePropertyValue]
    ) throws -> [String: NativeArticlePropertyValue] {
        guard properties.count <= 100 else { throw NativeArticlePropertyError.tooMany }
        var result: [String: NativeArticlePropertyValue] = [:]
        for (rawKey, value) in properties {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidKey(key) else { throw NativeArticlePropertyError.invalidKey(rawKey) }
            guard value.isValid else { throw NativeArticlePropertyError.invalidValue(key) }
            if let existing = result.keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
                result.removeValue(forKey: existing)
            }
            result[key] = NativeArticlePropertyValue.fromEditor(kind: value.kind, text: value.editorText)
        }
        return result
    }

    public static func renaming(
        _ oldKey: String,
        to newKey: String,
        in properties: [String: NativeArticlePropertyValue]
    ) throws -> [String: NativeArticlePropertyValue] {
        let old = oldKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidKey(destination) else { throw NativeArticlePropertyError.invalidKey(newKey) }
        guard let sourceKey = properties.keys.first(where: {
            $0.caseInsensitiveCompare(old) == .orderedSame
        }), let sourceValue = properties[sourceKey] else { return properties }

        var result = properties
        if let existingKey = result.keys.first(where: {
            $0 != sourceKey && $0.caseInsensitiveCompare(destination) == .orderedSame
        }), result[existingKey] != sourceValue {
            throw NativeArticlePropertyError.destinationExists(existingKey)
        }
        result.removeValue(forKey: sourceKey)
        if let existingKey = result.keys.first(where: {
            $0.caseInsensitiveCompare(destination) == .orderedSame
        }) {
            result.removeValue(forKey: existingKey)
        }
        result[destination] = sourceValue
        return try validated(result)
    }

    public static func isValidKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80,
              !trimmed.contains(":"), !trimmed.contains("["), !trimmed.contains("]"),
              !trimmed.contains("\n"), !trimmed.contains("\r") else { return false }
        let allowed = CharacterSet.letters
            .union(.decimalDigits)
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "._-"))
        return trimmed.unicodeScalars.allSatisfy(allowed.contains)
    }
}

private extension NativeArticlePropertyValue {
    static func formattedNumber(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return value.rounded() == value ? String(Int64(value)) : String(value)
    }

    static func normalizedList(_ values: [String]) -> [String] {
        var result: [String] = []
        for rawValue in values {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  !result.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { continue }
            result.append(value)
        }
        return Array(result.prefix(100))
    }

    static func splitEditorList(_ source: String) -> [String] {
        normalizedList(source.split(whereSeparator: { ",，\n".contains($0) }).map(String.init))
    }

    static func encodedList(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values),
              let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }

    static func decodedList(_ source: String) -> [String]? {
        guard let data = source.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return normalizedList(values)
    }

    static func decodedBlockList(_ source: String) -> [String]? {
        guard source.contains("\n") else { return nil }
        let values = source.components(separatedBy: .newlines).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("-") else { return nil }
            return decodedScalar(
                String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return values.isEmpty ? nil : normalizedList(values)
    }

    static func decodedInlineYAMLList(_ source: String) -> [String]? {
        guard source.hasPrefix("["), source.hasSuffix("]") else { return nil }
        var values: [String] = []
        var current = ""
        var quote: Character?
        var isEscaping = false
        for character in source.dropFirst().dropLast() {
            if isEscaping {
                current.append(character)
                isEscaping = false
            } else if character == "\\", quote != nil {
                current.append(character)
                isEscaping = true
            } else if character == "\"" || character == "'" {
                if quote == character { quote = nil } else if quote == nil { quote = character }
                current.append(character)
            } else if character == ",", quote == nil {
                values.append(decodedScalar(current.trimmingCharacters(in: .whitespacesAndNewlines)))
                current = ""
            } else {
                current.append(character)
            }
        }
        values.append(decodedScalar(current.trimmingCharacters(in: .whitespacesAndNewlines)))
        return normalizedList(values)
    }

    static func decodedScalar(_ source: String) -> String {
        guard source.count >= 2 else { return source }
        if source.hasPrefix("\"") && source.hasSuffix("\"") {
            return (try? JSONDecoder().decode(String.self, from: Data(source.utf8)))
                ?? String(source.dropFirst().dropLast())
        }
        if source.hasPrefix("'") && source.hasSuffix("'") {
            return String(source.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return source
    }

    static func parseBoolean(_ source: String) -> Bool? {
        switch source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return nil
        }
    }

    static func isValidDate(_ source: String) -> Bool {
        let segments = source.split(separator: "-", omittingEmptySubsequences: false)
        guard segments.count == 3,
              segments[0].count == 4, segments[1].count == 2, segments[2].count == 2,
              let year = Int(segments[0]), let month = Int(segments[1]), let day = Int(segments[2]) else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
        let result = calendar.dateComponents([.year, .month, .day], from: date)
        return result.year == year && result.month == month && result.day == day
    }

    static func quoted(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else { return "\"\"" }
        return string
    }
}
