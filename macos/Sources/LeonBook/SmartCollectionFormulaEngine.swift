import Foundation

public enum NativeBaseValue: Equatable, Hashable {
    case empty
    case string(String)
    case number(Double)
    case boolean(Bool)
    case date(Date)
    case list([String])

    public var displayText: String {
        switch self {
        case .empty: return ""
        case let .string(value): return value
        case let .number(value):
            guard value.isFinite else { return "" }
            return value.rounded() == value
                ? String(Int(value))
                : String(format: "%.2f", value).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
        case let .boolean(value): return value ? "✓" : ""
        case let .date(value): return Self.dateFormatter.string(from: value)
        case let .list(values): return values.joined(separator: ", ")
        }
    }

    var numberValue: Double? {
        switch self {
        case let .number(value): return value
        case let .string(value): return Double(value)
        default: return nil
        }
    }

    var dateValue: Date? {
        switch self {
        case let .date(value): return value
        case let .string(value): return Self.parseDate(value)
        default: return nil
        }
    }

    var booleanValue: Bool {
        switch self {
        case .empty: return false
        case let .boolean(value): return value
        case let .number(value): return value != 0
        case let .string(value): return !value.isEmpty && value.lowercased() != "false"
        case let .list(values): return !values.isEmpty
        case .date: return true
        }
    }

    var isEmpty: Bool {
        switch self {
        case .empty: return true
        case let .string(value): return value.isEmpty
        case let .list(values): return values.isEmpty
        default: return false
        }
    }

    fileprivate static func parseDate(_ source: String) -> Date? {
        if let timestamp = NativeTimestamp.date(from: source) { return timestamp }
        return dateFormatter.date(from: source)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// Pure formula and summary module shared by tables, embeds and tests.
public enum NativeSmartCollectionFormulaEngine {
    public static func value(
        for column: NativeSmartCollectionColumn,
        article: NativeArticleSummary,
        collection: NativeSmartCollection,
        now: Date = Date()
    ) -> NativeBaseValue {
        switch column.source {
        case .system:
            return systemValue(column.key, article: article)
        case .property:
            return propertyValue(column.key, article: article)
        case .formula:
            return formulaValue(column.key, article: article, collection: collection, now: now)
        }
    }

    public static func formulaValue(
        _ key: String,
        article: NativeArticleSummary,
        collection: NativeSmartCollection,
        now: Date = Date()
    ) -> NativeBaseValue {
        evaluateFormula(key, article: article, collection: collection, now: now, visited: [])
    }

    public static func summary(
        _ operation: NativeSmartCollectionSummary,
        column: NativeSmartCollectionColumn,
        articles: [NativeArticleSummary],
        collection: NativeSmartCollection,
        now: Date = Date()
    ) -> NativeBaseValue {
        let values = articles.map { value(for: column, article: $0, collection: collection, now: now) }
        switch operation {
        case .filled: return .number(Double(values.filter { !$0.isEmpty }.count))
        case .empty: return .number(Double(values.filter(\.isEmpty).count))
        case .unique:
            return .number(Double(Set(values.filter { !$0.isEmpty }.map(\.displayText)).count))
        case .sum:
            return .number(values.compactMap(\.numberValue).reduce(0, +))
        case .average:
            let numbers = values.compactMap(\.numberValue)
            return numbers.isEmpty ? .empty : .number(numbers.reduce(0, +) / Double(numbers.count))
        case .minimum:
            return values.compactMap(\.numberValue).min().map(NativeBaseValue.number) ?? .empty
        case .maximum:
            return values.compactMap(\.numberValue).max().map(NativeBaseValue.number) ?? .empty
        case .earliest:
            return values.compactMap(\.dateValue).min().map(NativeBaseValue.date) ?? .empty
        case .latest:
            return values.compactMap(\.dateValue).max().map(NativeBaseValue.date) ?? .empty
        case .checked:
            return .number(Double(values.filter { $0.booleanValue }.count))
        case .unchecked:
            return .number(Double(values.filter { !$0.booleanValue }.count))
        }
    }

    private static func evaluateFormula(
        _ key: String,
        article: NativeArticleSummary,
        collection: NativeSmartCollection,
        now: Date,
        visited: Set<String>
    ) -> NativeBaseValue {
        let normalized = key.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !visited.contains(normalized),
              let formula = collection.formulas.first(where: {
                  $0.key.caseInsensitiveCompare(key) == .orderedSame
              }) else { return .empty }
        var nextVisited = visited
        nextVisited.insert(normalized)
        var parser = FormulaParser(
            source: formula.expression,
            now: now,
            resolve: { identifier in
                if identifier.lowercased().hasPrefix("formula.") {
                    return evaluateFormula(
                        String(identifier.dropFirst("formula.".count)),
                        article: article,
                        collection: collection,
                        now: now,
                        visited: nextVisited
                    )
                }
                if let nested = collection.formulas.first(where: {
                    $0.key.caseInsensitiveCompare(identifier) == .orderedSame
                }) {
                    return evaluateFormula(
                        nested.key,
                        article: article,
                        collection: collection,
                        now: now,
                        visited: nextVisited
                    )
                }
                if identifier.lowercased().hasPrefix("file.") {
                    return systemValue(identifier, article: article)
                }
                let propertyKey = identifier.lowercased().hasPrefix("note.")
                    ? String(identifier.dropFirst("note.".count)) : identifier
                let property = propertyValue(propertyKey, article: article)
                return property.isEmpty ? systemValue(propertyKey, article: article) : property
            },
            property: { propertyValue($0, article: article) }
        )
        return parser.parse()
    }

    private static func systemValue(_ key: String, article: NativeArticleSummary) -> NativeBaseValue {
        switch key.lowercased() {
        case "title", "file.name": return .string(article.title)
        case "status", "note.status": return .string(article.status.rawValue)
        case "category", "note.category": return .string(article.category)
        case "tags", "tag", "note.tags": return .list(article.tags)
        case "wordcount", "note.wordcount": return .number(Double(article.wordCount))
        case "pageviews", "note.pageviews": return .number(Double(article.pageViews))
        case "updatedat", "file.mtime", "note.updatedat":
            return NativeBaseValue.parseDate(article.updatedAt).map(NativeBaseValue.date) ?? .string(article.updatedAt)
        case "publishedat", "note.publishedat":
            guard let publishedAt = article.publishedAt else { return .empty }
            return NativeBaseValue.parseDate(publishedAt).map(NativeBaseValue.date) ?? .string(publishedAt)
        case "sourcepath", "file.path": return .string(article.sourceRelativePath)
        default: return .empty
        }
    }

    private static func propertyValue(_ key: String, article: NativeArticleSummary) -> NativeBaseValue {
        guard let value = article.properties.first(where: {
            $0.key.caseInsensitiveCompare(key) == .orderedSame
        })?.value else { return .empty }
        switch value.kind {
        case .text: return .string(value.value)
        case .list, .tags: return .list(value.listValues)
        case .number: return Double(value.value).map(NativeBaseValue.number) ?? .empty
        case .date:
            return NativeBaseValue.parseDate(value.value).map(NativeBaseValue.date) ?? .string(value.value)
        case .checkbox: return .boolean(value.booleanValue)
        }
    }
}

private struct FormulaParser {
    private enum Token: Equatable {
        case number(Double)
        case string(String)
        case identifier(String)
        case symbol(String)
        case end
    }

    private var tokens: [Token]
    private var index = 0
    private let now: Date
    private let resolve: (String) -> NativeBaseValue
    private let property: (String) -> NativeBaseValue

    init(
        source: String,
        now: Date,
        resolve: @escaping (String) -> NativeBaseValue,
        property: @escaping (String) -> NativeBaseValue
    ) {
        tokens = Self.tokenize(source) + [.end]
        self.now = now
        self.resolve = resolve
        self.property = property
    }

    mutating func parse() -> NativeBaseValue { parseOr() }

    private mutating func parseOr() -> NativeBaseValue {
        var value = parseAnd()
        while consume("||") { value = .boolean(value.booleanValue || parseAnd().booleanValue) }
        return value
    }

    private mutating func parseAnd() -> NativeBaseValue {
        var value = parseComparison()
        while consume("&&") { value = .boolean(value.booleanValue && parseComparison().booleanValue) }
        return value
    }

    private mutating func parseComparison() -> NativeBaseValue {
        var value = parseAddition()
        while case let .symbol(operation) = current,
              ["==", "!=", ">", ">=", "<", "<="].contains(operation) {
            index += 1
            let rhs = parseAddition()
            value = .boolean(compare(value, rhs, operation: operation))
        }
        return value
    }

    private mutating func parseAddition() -> NativeBaseValue {
        var value = parseMultiplication()
        while case let .symbol(operation) = current, operation == "+" || operation == "-" {
            index += 1
            value = calculate(value, parseMultiplication(), operation: operation)
        }
        return value
    }

    private mutating func parseMultiplication() -> NativeBaseValue {
        var value = parseUnary()
        while case let .symbol(operation) = current, operation == "*" || operation == "/" {
            index += 1
            value = calculate(value, parseUnary(), operation: operation)
        }
        return value
    }

    private mutating func parseUnary() -> NativeBaseValue {
        if consume("!") { return .boolean(!parseUnary().booleanValue) }
        if consume("-") { return parseUnary().numberValue.map { .number(-$0) } ?? .empty }
        return parsePrimary()
    }

    private mutating func parsePrimary() -> NativeBaseValue {
        let token = current
        index += 1
        switch token {
        case let .number(value): return .number(value)
        case let .string(value): return .string(value)
        case let .identifier(name):
            if consume("(") {
                var arguments: [NativeBaseValue] = []
                if !consume(")") {
                    repeat { arguments.append(parseOr()) } while consume(",")
                    _ = consume(")")
                }
                return function(name, arguments: arguments)
            }
            switch name.lowercased() {
            case "true": return .boolean(true)
            case "false": return .boolean(false)
            case "null": return .empty
            default: return resolve(name)
            }
        case .symbol("("):
            let value = parseOr()
            _ = consume(")")
            return value
        default: return .empty
        }
    }

    private func function(_ name: String, arguments: [NativeBaseValue]) -> NativeBaseValue {
        switch name.lowercased() {
        case "today": return .date(Calendar.current.startOfDay(for: now))
        case "now": return .date(now)
        case "date": return arguments.first?.dateValue.map(NativeBaseValue.date) ?? .empty
        case "prop": return arguments.first.map { property($0.displayText) } ?? .empty
        case "daysbetween":
            guard arguments.count >= 2,
                  let start = arguments[0].dateValue,
                  let end = arguments[1].dateValue else { return .empty }
            return .number(Double(Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0))
        case "if":
            guard arguments.count >= 2 else { return .empty }
            return arguments[0].booleanValue ? arguments[1] : (arguments.count > 2 ? arguments[2] : .empty)
        case "round":
            guard let value = arguments.first?.numberValue else { return .empty }
            let places = Int(arguments.dropFirst().first?.numberValue ?? 0)
            let factor = pow(10, Double(max(0, places)))
            return .number((value * factor).rounded() / factor)
        case "abs": return arguments.first?.numberValue.map { .number(Swift.abs($0)) } ?? .empty
        case "length":
            guard let value = arguments.first else { return .number(0) }
            if case let .list(items) = value { return .number(Double(items.count)) }
            return .number(Double(value.displayText.count))
        case "lower": return .string(arguments.first?.displayText.lowercased() ?? "")
        case "upper": return .string(arguments.first?.displayText.uppercased() ?? "")
        case "formatdate":
            guard let date = arguments.first?.dateValue else { return .empty }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = arguments.dropFirst().first?.displayText ?? "yyyy-MM-dd"
            return .string(formatter.string(from: date))
        case "min": return arguments.compactMap(\.numberValue).min().map(NativeBaseValue.number) ?? .empty
        case "max": return arguments.compactMap(\.numberValue).max().map(NativeBaseValue.number) ?? .empty
        default: return .empty
        }
    }

    private func calculate(
        _ lhs: NativeBaseValue,
        _ rhs: NativeBaseValue,
        operation: String
    ) -> NativeBaseValue {
        if operation == "-", let leftDate = lhs.dateValue, let rightDate = rhs.dateValue {
            return .number(Double(Calendar.current.dateComponents([.day], from: rightDate, to: leftDate).day ?? 0))
        }
        if let date = lhs.dateValue, let days = rhs.numberValue, operation == "+" || operation == "-" {
            return Calendar.current.date(byAdding: .day, value: Int(operation == "+" ? days : -days), to: date)
                .map(NativeBaseValue.date) ?? .empty
        }
        if operation == "+", lhs.numberValue == nil || rhs.numberValue == nil {
            return .string(lhs.displayText + rhs.displayText)
        }
        guard let left = lhs.numberValue, let right = rhs.numberValue else { return .empty }
        switch operation {
        case "+": return .number(left + right)
        case "-": return .number(left - right)
        case "*": return .number(left * right)
        case "/": return right == 0 ? .empty : .number(left / right)
        default: return .empty
        }
    }

    private func compare(_ lhs: NativeBaseValue, _ rhs: NativeBaseValue, operation: String) -> Bool {
        let result: ComparisonResult
        if let left = lhs.numberValue, let right = rhs.numberValue {
            result = left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
        } else if let left = lhs.dateValue, let right = rhs.dateValue {
            result = left.compare(right)
        } else {
            result = lhs.displayText.localizedCaseInsensitiveCompare(rhs.displayText)
        }
        switch operation {
        case "==": return result == .orderedSame
        case "!=": return result != .orderedSame
        case ">": return result == .orderedDescending
        case ">=": return result != .orderedAscending
        case "<": return result == .orderedAscending
        case "<=": return result != .orderedDescending
        default: return false
        }
    }

    private var current: Token { tokens[min(index, tokens.count - 1)] }

    private mutating func consume(_ symbol: String) -> Bool {
        guard current == .symbol(symbol) else { return false }
        index += 1
        return true
    }

    private static func tokenize(_ source: String) -> [Token] {
        let characters = Array(source)
        var result: [Token] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace { index += 1; continue }
            if character.isNumber || (character == "." && index + 1 < characters.count && characters[index + 1].isNumber) {
                let start = index
                index += 1
                while index < characters.count, characters[index].isNumber || characters[index] == "." { index += 1 }
                if let value = Double(String(characters[start..<index])) { result.append(.number(value)) }
                continue
            }
            if character == "\"" || character == "'" {
                let quote = character
                index += 1
                var value = ""
                while index < characters.count, characters[index] != quote {
                    if characters[index] == "\\", index + 1 < characters.count { index += 1 }
                    value.append(characters[index])
                    index += 1
                }
                if index < characters.count { index += 1 }
                result.append(.string(value))
                continue
            }
            if character.isLetter || character == "_" {
                let start = index
                index += 1
                while index < characters.count,
                      characters[index].isLetter || characters[index].isNumber
                        || characters[index] == "_" || characters[index] == "." { index += 1 }
                result.append(.identifier(String(characters[start..<index])))
                continue
            }
            let pair = index + 1 < characters.count ? String(characters[index...index + 1]) : ""
            if ["==", "!=", ">=", "<=", "&&", "||"].contains(pair) {
                result.append(.symbol(pair))
                index += 2
            } else {
                result.append(.symbol(String(character)))
                index += 1
            }
        }
        return result
    }
}
