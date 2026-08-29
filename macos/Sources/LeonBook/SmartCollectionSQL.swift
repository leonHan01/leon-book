import Foundation

struct NativeSmartCollectionSQLQuery {
    let whereClause: String
    let orderClause: String
    let values: [SQLiteValue]
}

/// Compiles a saved Base into one parameterized SQLite query. The store only
/// decodes rows that survived filtering and sorting; article bodies never cross
/// the SQLite seam merely to evaluate a collection.
enum NativeSmartCollectionSQLCompiler {
    static func compile(
        _ collection: NativeSmartCollection,
        articleAlias: String = "a"
    ) -> NativeSmartCollectionSQLQuery {
        let compiledFilter = collection.effectiveFilter.map { compile($0, alias: articleAlias) }
        let rulePredicate = compiledFilter.map { " AND (\($0.sql))" } ?? ""
        let values = compiledFilter?.values ?? []
        let sorts = collection.sorts.isEmpty
            ? [NativeArticleSortDescriptor()]
            : Array(collection.sorts.prefix(3))
        let orderTerms = sorts.map { descriptor in
            "\(sortExpression(descriptor.field, alias: articleAlias)) \(descriptor.ascending ? "ASC" : "DESC")"
        } + ["\(articleAlias).slug ASC"]
        return NativeSmartCollectionSQLQuery(
            whereClause: "WHERE \(articleAlias).deleted_at IS NULL\(rulePredicate)",
            orderClause: "ORDER BY \(orderTerms.joined(separator: ", "))",
            values: values
        )
    }

    private struct CompiledRule {
        let sql: String
        let values: [SQLiteValue]
    }

    private static func compile(
        _ filter: NativeSmartCollectionFilter,
        alias: String
    ) -> CompiledRule {
        switch filter {
        case let .rule(rule):
            return compile(rule, alias: alias)
        case .expression:
            return CompiledRule(sql: "0", values: [])
        case let .and(children):
            return compile(children, joiner: " AND ", emptyValue: "1", alias: alias)
        case let .or(children):
            return compile(children, joiner: " OR ", emptyValue: "0", alias: alias)
        case let .not(children):
            let child = compile(children, joiner: " OR ", emptyValue: "0", alias: alias)
            return CompiledRule(sql: "NOT (\(child.sql))", values: child.values)
        }
    }

    private static func compile(
        _ children: [NativeSmartCollectionFilter],
        joiner: String,
        emptyValue: String,
        alias: String
    ) -> CompiledRule {
        guard !children.isEmpty else { return CompiledRule(sql: emptyValue, values: []) }
        let compiled = children.map { compile($0, alias: alias) }
        return CompiledRule(
            sql: compiled.map { "(\($0.sql))" }.joined(separator: joiner),
            values: compiled.flatMap(\.values)
        )
    }

    private static func compile(
        _ rule: NativeSmartCollectionRule,
        alias: String
    ) -> CompiledRule {
        switch rule.field {
        case .title:
            return textRule(rule, expressions: ["\(alias).title"])
        case .content:
            return textRule(rule, expressions: ["\(alias).body", "\(alias).excerpt"])
        case .status:
            return textRule(rule, expressions: ["\(alias).status"])
        case .category:
            return textRule(rule, expressions: ["\(alias).category"])
        case .tag:
            return candidateRule(
                rule,
                from: "json_each(\(alias).tags_json) AS candidate",
                candidate: "CAST(candidate.value AS TEXT)"
            )
        case .property:
            let source = """
            json_each(\(alias).properties_json) AS property,
            json_each(
                CASE
                    WHEN json_extract(property.value, '$.kind') IN ('list', 'tags')
                    THEN json_extract(property.value, '$.value')
                    ELSE json_array(COALESCE(json_extract(property.value, '$.value'), ''))
                END
            ) AS candidate
            """
            return candidateRule(
                rule,
                from: source,
                candidate: "CAST(candidate.value AS TEXT)",
                prefixPredicate: "lower(trim(CAST(property.key AS TEXT))) = lower(?)",
                prefixValues: [.text(rule.propertyKey.trimmingCharacters(in: .whitespacesAndNewlines))]
            )
        case .updatedAt:
            return dateRule(rule, expression: "\(alias).updated_at")
        case .publishedAt:
            return dateRule(rule, expression: "\(alias).published_at")
        case .wordCount:
            return numberRule(rule, expression: "\(alias).word_count")
        case .pageViews:
            return numberRule(rule, expression: "\(alias).page_views")
        case .sourcePath:
            return textRule(rule, expressions: ["\(alias).source_path"])
        }
    }

    private static func textRule(
        _ rule: NativeSmartCollectionRule,
        expressions: [String]
    ) -> CompiledRule {
        let expected = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = expressions.map { "lower(trim(COALESCE(\($0), '')))" }
        switch rule.comparison {
        case .contains:
            return CompiledRule(
                sql: "(" + normalized.map { "instr(\($0), lower(?)) > 0" }.joined(separator: " OR ") + ")",
                values: Array(repeating: .text(expected.lowercased()), count: normalized.count)
            )
        case .equals:
            return CompiledRule(
                sql: "(" + normalized.map { "\($0) = lower(?)" }.joined(separator: " OR ") + ")",
                values: Array(repeating: .text(expected.lowercased()), count: normalized.count)
            )
        case .notEquals:
            return CompiledRule(
                sql: "(" + normalized.map { "\($0) <> lower(?)" }.joined(separator: " AND ") + ")",
                values: Array(repeating: .text(expected.lowercased()), count: normalized.count)
            )
        case .startsWith:
            return CompiledRule(
                sql: "(" + normalized.map { "substr(\($0), 1, length(?)) = lower(?)" }.joined(separator: " OR ") + ")",
                values: normalized.flatMap { _ in [.text(expected.lowercased()), .text(expected.lowercased())] }
            )
        case .isEmpty:
            return CompiledRule(sql: "(" + normalized.map { "\($0) = ''" }.joined(separator: " AND ") + ")", values: [])
        case .isNotEmpty:
            return CompiledRule(sql: "(" + normalized.map { "\($0) <> ''" }.joined(separator: " OR ") + ")", values: [])
        case .before, .after, .lessThan, .greaterThan, .atMost, .atLeast:
            return CompiledRule(sql: "0", values: [])
        }
    }

    private static func candidateRule(
        _ rule: NativeSmartCollectionRule,
        from source: String,
        candidate: String,
        prefixPredicate: String? = nil,
        prefixValues: [SQLiteValue] = []
    ) -> CompiledRule {
        let expected = rule.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedCandidate = "lower(trim(COALESCE(\(candidate), '')))"
        let prefix = prefixPredicate.map { "\($0) AND " } ?? ""
        let exists: (String) -> String = { predicate in
            "EXISTS (SELECT 1 FROM \(source) WHERE \(prefix)\(predicate))"
        }
        switch rule.comparison {
        case .contains:
            return CompiledRule(
                sql: exists("instr(\(normalizedCandidate), lower(?)) > 0"),
                values: prefixValues + [.text(expected)]
            )
        case .equals:
            return CompiledRule(
                sql: exists("\(normalizedCandidate) = lower(?)"),
                values: prefixValues + [.text(expected)]
            )
        case .notEquals:
            return CompiledRule(
                sql: "NOT " + exists("\(normalizedCandidate) = lower(?)"),
                values: prefixValues + [.text(expected)]
            )
        case .startsWith:
            return CompiledRule(
                sql: exists("substr(\(normalizedCandidate), 1, length(?)) = lower(?)"),
                values: prefixValues + [.text(expected), .text(expected)]
            )
        case .isEmpty:
            return CompiledRule(
                sql: "NOT " + exists("\(normalizedCandidate) <> ''"),
                values: prefixValues
            )
        case .isNotEmpty:
            return CompiledRule(sql: exists("\(normalizedCandidate) <> ''"), values: prefixValues)
        case .before, .after, .lessThan, .greaterThan, .atMost, .atLeast:
            return CompiledRule(sql: "0", values: [])
        }
    }

    private static func dateRule(
        _ rule: NativeSmartCollectionRule,
        expression: String
    ) -> CompiledRule {
        switch rule.comparison {
        case .isEmpty:
            return CompiledRule(sql: "trim(COALESCE(\(expression), '')) = ''", values: [])
        case .isNotEmpty:
            return CompiledRule(sql: "trim(COALESCE(\(expression), '')) <> ''", values: [])
        case .before, .after, .atMost, .atLeast:
            guard let timestamp = normalizedTimestamp(rule.value) else {
                return CompiledRule(sql: "0", values: [])
            }
            return CompiledRule(
                sql: "julianday(\(expression)) \(dateOperation(rule.comparison)) julianday(?)",
                values: [.text(timestamp)]
            )
        case .contains, .equals, .notEquals, .lessThan, .greaterThan, .startsWith:
            return CompiledRule(sql: "0", values: [])
        }
    }

    private static func numberRule(
        _ rule: NativeSmartCollectionRule,
        expression: String
    ) -> CompiledRule {
        guard let value = Double(rule.value.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite else {
            return CompiledRule(sql: "0", values: [])
        }
        let operation: String
        switch rule.comparison {
        case .equals: operation = "="
        case .notEquals: operation = "<>"
        case .lessThan: operation = "<"
        case .greaterThan: operation = ">"
        case .atMost: operation = "<="
        case .atLeast: operation = ">="
        default: return CompiledRule(sql: "0", values: [])
        }
        return CompiledRule(sql: "CAST(\(expression) AS REAL) \(operation) ?", values: [.text(String(value))])
    }

    private static func dateOperation(_ comparison: NativeSmartCollectionOperator) -> String {
        switch comparison {
        case .after, .atLeast: return ">="
        case .before: return "<"
        case .atMost: return "<="
        default: return "="
        }
    }

    private static func sortExpression(
        _ field: NativeArticleSortField,
        alias: String
    ) -> String {
        switch field {
        case .updatedAt: return "\(alias).updated_at"
        case .publishedAt: return "COALESCE(\(alias).published_at, '')"
        case .title: return "\(alias).title COLLATE NOCASE"
        case .category: return "\(alias).category COLLATE NOCASE"
        case .status: return "\(alias).status"
        case .wordCount: return "\(alias).word_count"
        case .pageViews: return "\(alias).page_views"
        }
    }

    private static func normalizedTimestamp(_ source: String) -> String? {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = NativeTimestamp.date(from: value) {
            return NativeTimestamp.string(from: date)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value).map(NativeTimestamp.string(from:))
    }
}
