import Foundation

/// Standard Obsidian `.base` persistence. Markdown/YAML is authoritative;
/// SQLite only caches the parsed projection returned by this file.
enum NativeSmartCollectionFile {
    static func write(_ collection: NativeSmartCollection, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(try filename(for: collection.id))
        var normalized = collection
        normalized.synchronizeActiveView()

        var document: NativeBaseYAMLDocument
        if let source = normalized.sourceYAML,
           let parsed = try? NativeBaseYAMLDocument(source: source) {
            document = parsed
        } else {
            document = NativeBaseYAMLDocument()
        }
        guard case .mapping = document.root else {
            throw NativeStoreError.fileSystem("\(url.lastPathComponent) 的顶层 YAML 必须是对象")
        }

        document.root.set(normalized.filterNode.map(yamlFilter), forKey: "filters")
        document.root.set(formulasNode(normalized.formulas), forKey: "formulas")
        mergeProperties(of: normalized, into: &document.root)
        mergeViews(of: normalized, into: &document.root)

        do {
            try Data(document.rendered().utf8).write(to: url, options: .atomic)
            return url
        } catch {
            throw NativeStoreError.fileSystem("无法写入 \(url.lastPathComponent)：\(error.localizedDescription)")
        }
    }

    static func readAll(in directory: URL) throws -> [NativeSmartCollection] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.caseInsensitiveCompare("base") == .orderedSame }
        return try urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.map(read)
    }

    static func remove(id: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(try filename(for: id))
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) }
        catch {
            throw NativeStoreError.fileSystem("无法删除 \(url.lastPathComponent)：\(error.localizedDescription)")
        }
    }

    private static func read(_ url: URL) throws -> NativeSmartCollection {
        let source: String
        do { source = try String(contentsOf: url, encoding: .utf8) }
        catch {
            throw NativeStoreError.fileSystem("无法读取 \(url.lastPathComponent)：\(error.localizedDescription)")
        }

        let document: NativeBaseYAMLDocument
        do { document = try NativeBaseYAMLDocument(source: source) }
        catch {
            throw NativeStoreError.fileSystem("无法解析 \(url.lastPathComponent)：\(error.localizedDescription)")
        }
        guard case .mapping = document.root else {
            throw NativeStoreError.fileSystem("\(url.lastPathComponent) 的顶层 YAML 必须是对象")
        }

        let legacy = legacyCollection(from: document.root)
        let id = url.deletingPathExtension().lastPathComponent
        let attributes = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let createdAt = legacy?.createdAt
            ?? NativeTimestamp.string(from: attributes?.creationDate ?? Date())
        let updatedAt = NativeTimestamp.string(from: attributes?.contentModificationDate ?? Date())
        let propertyNames = propertyDisplayNames(from: document.root.value(forKey: "properties"))
        let formulas = parseFormulas(
            document.root.value(forKey: "formulas"),
            displayNames: propertyNames,
            legacy: legacy?.formulas ?? []
        )
        let filter = document.root.value(forKey: "filters").flatMap(parseFilter)
        let parsedViews = parseViews(
            document.root.value(forKey: "views"),
            baseID: id,
            displayNames: propertyNames,
            formulas: formulas,
            legacy: legacy
        )
        let views = parsedViews.isEmpty
            ? [NativeSmartCollectionView(
                id: "\(id)-view-1",
                name: legacy?.name ?? id,
                layout: legacy?.layout ?? .table,
                sorts: legacy?.sorts ?? [NativeArticleSortDescriptor()],
                groupBy: legacy?.groupBy ?? .none,
                columns: legacy?.columns ?? NativeSmartCollection.defaultColumns
            )]
            : parsedViews
        let first = views[0]
        let projection = filter?.legacyProjection
        return NativeSmartCollection(
            id: id,
            name: legacy?.name ?? first.name,
            matchMode: projection?.mode ?? legacy?.matchMode ?? .all,
            rules: projection?.rules ?? legacy?.rules ?? [],
            sorts: first.sorts,
            groupBy: first.groupBy,
            layout: first.layout,
            columns: first.columns,
            formulas: formulas,
            filter: filter,
            views: views,
            activeViewID: first.id,
            sourceYAML: source,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func legacyCollection(from root: NativeBaseYAMLValue) -> NativeSmartCollection? {
        guard let viewNodes = root.value(forKey: "views")?.items else { return nil }
        for node in viewNodes {
            guard let encoded = decodedScalar(node.value(forKey: "leonBookConfig")),
                  let data = Data(base64Encoded: encoded),
                  let collection = try? JSONDecoder().decode(NativeSmartCollection.self, from: data) else { continue }
            return collection
        }
        return nil
    }

    private static func parseViews(
        _ node: NativeBaseYAMLValue?,
        baseID: String,
        displayNames: [String: String],
        formulas: [NativeSmartCollectionFormula],
        legacy: NativeSmartCollection?
    ) -> [NativeSmartCollectionView] {
        guard let items = node?.items else { return [] }
        return items.enumerated().compactMap { index, node in
            guard node.pairs != nil else { return nil }
            let type = decodedScalar(node.value(forKey: "type")) ?? "table"
            let layout = NativeSmartCollectionLayout(rawValue: type) ?? .table
            let name = decodedScalar(node.value(forKey: "name")) ?? "视图 \(index + 1)"
            let filter = node.value(forKey: "filters").flatMap(parseFilter)
            let order = scalarList(node.value(forKey: "order"))
            let summaries = summaryMap(node.value(forKey: "summaries"))
            let widths = numberMap(
                node.value(forKey: "leonBookColumnWidths") ?? node.value(forKey: "columnSize")
            )
            let hidden = Set(scalarList(node.value(forKey: "leonBookHidden")).map(normalizedKey))
            let legacyColumns = index == 0 ? legacy?.columns ?? [] : []
            let propertyNames = order.isEmpty ? NativeSmartCollection.defaultColumns.map(\.basePropertyName) : order
            var columns = propertyNames.map { propertyName in
                var column = column(
                    for: propertyName,
                    title: displayNames[normalizedKey(propertyName)],
                    formulas: formulas,
                    legacy: legacyColumns
                )
                if let width = widths[normalizedKey(propertyName)] {
                    column.width = min(max(width, 80), 480)
                }
                column.isHidden = hidden.contains(normalizedKey(propertyName))
                column.summary = summaries[normalizedKey(propertyName)]
                return column
            }
            for hiddenName in scalarList(node.value(forKey: "leonBookHidden"))
                where !columns.contains(where: { normalizedKey($0.basePropertyName) == normalizedKey(hiddenName) }) {
                var hiddenColumn = column(
                    for: hiddenName,
                    title: displayNames[normalizedKey(hiddenName)],
                    formulas: formulas,
                    legacy: legacyColumns
                )
                hiddenColumn.isHidden = true
                columns.append(hiddenColumn)
            }
            let groupBy = parseGroup(node.value(forKey: "groupBy"))
            let sorts = parseSorts(node.value(forKey: "leonBookSorts"))
                ?? (index == 0 ? legacy?.sorts : nil)
                ?? [NativeArticleSortDescriptor(id: stableUUID("sort:\(baseID):\(index):default"))]
            let limit = decodedScalar(node.value(forKey: "limit")).flatMap(Int.init)
            return NativeSmartCollectionView(
                id: "\(baseID)-view-\(index + 1)",
                name: name,
                baseType: type,
                layout: layout,
                filter: filter,
                sorts: sorts,
                groupBy: groupBy,
                columns: columns,
                limit: limit
            )
        }
    }

    private static func parseFilter(_ node: NativeBaseYAMLValue) -> NativeSmartCollectionFilter? {
        switch node {
        case .scalar:
            guard let expression = decodedScalar(node), !expression.isEmpty, expression != "null" else { return nil }
            if case let .rule(parsedRule)? = NativeBaseFilterExpression.parse(expression) {
                var rule = parsedRule
                rule.id = stableUUID("rule:\(expression.lowercased())")
                return .rule(rule)
            }
            return .expression(expression)
        case let .sequence(items):
            return .and(items.compactMap(parseFilter))
        case let .mapping(pairs):
            guard let pair = pairs.first(where: {
                ["and", "or", "not"].contains($0.key.lowercased())
            }) else { return nil }
            let children: [NativeSmartCollectionFilter]
            if let items = pair.value.items { children = items.compactMap(parseFilter) }
            else if let child = parseFilter(pair.value) { children = [child] }
            else { children = [] }
            switch pair.key.lowercased() {
            case "or": return .or(children)
            case "not": return .not(children)
            default: return .and(children)
            }
        case .block:
            return nil
        }
    }

    private static func parseFormulas(
        _ node: NativeBaseYAMLValue?,
        displayNames: [String: String],
        legacy: [NativeSmartCollectionFormula]
    ) -> [NativeSmartCollectionFormula] {
        guard let pairs = node?.pairs else { return [] }
        return pairs.prefix(20).compactMap { pair in
            guard let expression = decodedScalar(pair.value) else { return nil }
            let existing = legacy.first(where: { $0.key.caseInsensitiveCompare(pair.key) == .orderedSame })
            return NativeSmartCollectionFormula(
                id: existing?.id ?? stableUUID("formula:\(pair.key.lowercased())"),
                key: pair.key,
                name: displayNames[normalizedKey("formula.\(pair.key)")] ?? existing?.name ?? pair.key,
                expression: expression
            )
        }
    }

    private static func propertyDisplayNames(from node: NativeBaseYAMLValue?) -> [String: String] {
        guard let pairs = node?.pairs else { return [:] }
        return Dictionary(uniqueKeysWithValues: pairs.compactMap { pair in
            guard let name = decodedScalar(pair.value.value(forKey: "displayName")) else { return nil }
            return (normalizedKey(pair.key), name)
        })
    }

    private static func summaryMap(_ node: NativeBaseYAMLValue?) -> [String: NativeSmartCollectionSummary] {
        guard let pairs = node?.pairs else { return [:] }
        return Dictionary(uniqueKeysWithValues: pairs.compactMap { pair in
            guard let value = decodedScalar(pair.value),
                  let summary = NativeSmartCollectionSummary.allCases.first(where: {
                      $0.baseName.caseInsensitiveCompare(value) == .orderedSame
                  }) else { return nil }
            return (normalizedKey(pair.key), summary)
        })
    }

    private static func numberMap(_ node: NativeBaseYAMLValue?) -> [String: Double] {
        guard let pairs = node?.pairs else { return [:] }
        return Dictionary(uniqueKeysWithValues: pairs.compactMap { pair in
            guard let value = decodedScalar(pair.value).flatMap(Double.init) else { return nil }
            return (normalizedKey(pair.key), value)
        })
    }

    private static func scalarList(_ node: NativeBaseYAMLValue?) -> [String] {
        if let items = node?.items { return items.compactMap(decodedScalar) }
        guard let scalar = decodedScalar(node), scalar.hasPrefix("["), scalar.hasSuffix("]") else { return [] }
        return splitArguments(String(scalar.dropFirst().dropLast())).map(decodeYAMLScalar)
    }

    private static func parseGroup(_ node: NativeBaseYAMLValue?) -> NativeArticleGroupField {
        guard let property = decodedScalar(node?.value(forKey: "property"))?.lowercased() else { return .none }
        switch property {
        case "note.status", "status": return .status
        case "note.category", "category": return .category
        case "note.tags", "tags", "file.tags": return .tag
        case "file.mtime": return .updatedMonth
        default: return .none
        }
    }

    private static func parseSorts(_ node: NativeBaseYAMLValue?) -> [NativeArticleSortDescriptor]? {
        guard let items = node?.items else { return nil }
        let sorts = items.enumerated().compactMap { index, item -> NativeArticleSortDescriptor? in
            guard let property = decodedScalar(item.value(forKey: "property")),
                  let field = sortField(for: property) else { return nil }
            let direction = decodedScalar(item.value(forKey: "direction")) ?? "DESC"
            return NativeArticleSortDescriptor(
                id: stableUUID("sort:\(index):\(property.lowercased()):\(direction.uppercased())"),
                field: field,
                ascending: direction.uppercased() == "ASC"
            )
        }
        return sorts.isEmpty ? nil : Array(sorts.prefix(3))
    }

    private static func sortField(for property: String) -> NativeArticleSortField? {
        switch property.lowercased() {
        case "file.mtime", "note.updatedat": return .updatedAt
        case "note.publishedat": return .publishedAt
        case "file.name", "note.title": return .title
        case "note.category", "category": return .category
        case "note.status", "status": return .status
        case "note.wordcount", "wordcount": return .wordCount
        case "note.pageviews", "pageviews": return .pageViews
        default: return nil
        }
    }

    private static func column(
        for propertyName: String,
        title: String?,
        formulas: [NativeSmartCollectionFormula],
        legacy: [NativeSmartCollectionColumn]
    ) -> NativeSmartCollectionColumn {
        if var existing = legacy.first(where: {
            normalizedKey($0.basePropertyName) == normalizedKey(propertyName)
        }) {
            if let title { existing.title = title }
            return existing
        }
        let normalized = propertyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: NativeSmartCollectionColumn
        switch normalized.lowercased() {
        case "file.name": result = .system(.title, width: 200)
        case "file.mtime": result = .system(.updatedAt)
        case "file.path": result = .system(.sourcePath, width: 220)
        default:
            if normalized.lowercased().hasPrefix("formula.") {
                let key = String(normalized.dropFirst("formula.".count))
                let formula = formulas.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })
                result = NativeSmartCollectionColumn(source: .formula, key: key, title: formula?.name ?? key)
            } else {
                let key = normalized.lowercased().hasPrefix("note.")
                    ? String(normalized.dropFirst("note.".count)) : normalized
                if let system = NativeSmartCollectionSystemField(rawValue: key) {
                    result = .system(system)
                } else {
                    result = NativeSmartCollectionColumn(source: .property, key: key, title: key)
                }
            }
        }
        var titled = result
        titled.id = stableUUID("column:\(normalizedKey(propertyName))")
        titled.basePropertyOverride = propertyName
        guard let title else { return titled }
        titled.title = title
        return titled
    }

    private static func mergeProperties(of collection: NativeSmartCollection, into root: inout NativeBaseYAMLValue) {
        var properties = root.value(forKey: "properties") ?? .mapping([])
        if properties.pairs == nil { properties = .mapping([]) }
        for column in collection.columns + collection.views.flatMap(\.columns) {
            var config = properties.value(forKey: column.basePropertyName) ?? .mapping([])
            if config.pairs == nil { config = .mapping([]) }
            config.set(.scalar(yamlString(column.displayTitle)), forKey: "displayName")
            properties.set(config, forKey: column.basePropertyName)
        }
        root.set(properties.pairs?.isEmpty == false ? properties : nil, forKey: "properties")
    }

    private static func mergeViews(of collection: NativeSmartCollection, into root: inout NativeBaseYAMLValue) {
        let views = collection.views.isEmpty
            ? [NativeSmartCollectionView(
                id: "\(collection.id)-view-1",
                name: collection.name,
                layout: collection.layout,
                sorts: collection.sorts,
                groupBy: collection.groupBy,
                columns: collection.columns
            )]
            : collection.views
        var existing = root.value(forKey: "views")?.items ?? []
        for (index, view) in views.enumerated() {
            var node = existing.indices.contains(index) ? existing[index] : .mapping([])
            if node.pairs == nil { node = .mapping([]) }
            node.set(.scalar(yamlString(view.baseType)), forKey: "type")
            node.set(.scalar(yamlString(view.name)), forKey: "name")
            node.set(view.limit.map { .scalar(String($0)) }, forKey: "limit")
            node.set(view.filter.map(yamlFilter), forKey: "filters")
            if let group = groupNode(view.groupBy) {
                node.set(group, forKey: "groupBy")
            } else if parseGroup(node.value(forKey: "groupBy")) != .none {
                node.set(nil, forKey: "groupBy")
            }
            node.set(.sequence(view.columns.filter { !$0.isHidden }.map {
                .scalar(yamlKey($0.basePropertyName))
            }), forKey: "order")
            var summaries = node.value(forKey: "summaries") ?? .mapping([])
            if summaries.pairs == nil { summaries = .mapping([]) }
            for column in view.columns {
                if let summary = column.summary {
                    summaries.set(.scalar(summary.baseName), forKey: column.basePropertyName)
                } else if let existingName = decodedScalar(summaries.value(forKey: column.basePropertyName)),
                          NativeSmartCollectionSummary.allCases.contains(where: {
                              $0.baseName.caseInsensitiveCompare(existingName) == .orderedSame
                          }) {
                    summaries.set(nil, forKey: column.basePropertyName)
                }
            }
            node.set(summaries.pairs?.isEmpty == false ? summaries : nil, forKey: "summaries")
            node.set(.mapping(view.columns.map {
                NativeBaseYAMLPair(key: $0.basePropertyName, value: .scalar(String(Int($0.width.rounded()))))
            }), forKey: "leonBookColumnWidths")
            let hidden = view.columns.filter(\.isHidden)
            node.set(hidden.isEmpty ? nil : .sequence(hidden.map {
                .scalar(yamlKey($0.basePropertyName))
            }), forKey: "leonBookHidden")
            node.set(sortNode(view.sorts), forKey: "leonBookSorts")
            node.set(nil, forKey: "leonBookConfig")
            if existing.indices.contains(index) { existing[index] = node }
            else { existing.append(node) }
        }
        root.set(.sequence(existing), forKey: "views")
    }

    private static func formulasNode(_ formulas: [NativeSmartCollectionFormula]) -> NativeBaseYAMLValue? {
        guard !formulas.isEmpty else { return nil }
        return .mapping(formulas.map {
            NativeBaseYAMLPair(key: $0.key, value: .scalar(yamlString($0.expression)))
        })
    }

    private static func yamlFilter(_ filter: NativeSmartCollectionFilter) -> NativeBaseYAMLValue {
        switch filter {
        case let .rule(rule): return .scalar(yamlString(filterExpression(for: rule)))
        case let .expression(expression): return .scalar(yamlString(expression))
        case let .and(children):
            return .mapping([NativeBaseYAMLPair(key: "and", value: .sequence(children.map(yamlFilter)))])
        case let .or(children):
            return .mapping([NativeBaseYAMLPair(key: "or", value: .sequence(children.map(yamlFilter)))])
        case let .not(children):
            return .mapping([NativeBaseYAMLPair(key: "not", value: .sequence(children.map(yamlFilter)))])
        }
    }

    private static func groupNode(_ field: NativeArticleGroupField) -> NativeBaseYAMLValue? {
        guard field != .none else { return nil }
        return .mapping([
            NativeBaseYAMLPair(key: "property", value: .scalar(groupProperty(field))),
            NativeBaseYAMLPair(key: "direction", value: .scalar("ASC")),
        ])
    }

    private static func sortNode(_ sorts: [NativeArticleSortDescriptor]) -> NativeBaseYAMLValue? {
        guard !sorts.isEmpty else { return nil }
        return .sequence(sorts.prefix(3).map { sort in
            .mapping([
                NativeBaseYAMLPair(key: "property", value: .scalar(sortProperty(sort.field))),
                NativeBaseYAMLPair(key: "direction", value: .scalar(sort.ascending ? "ASC" : "DESC")),
            ])
        })
    }

    private static func sortProperty(_ field: NativeArticleSortField) -> String {
        switch field {
        case .updatedAt: return "file.mtime"
        case .publishedAt: return "note.publishedAt"
        case .title: return "file.name"
        case .category: return "note.category"
        case .status: return "note.status"
        case .wordCount: return "note.wordCount"
        case .pageViews: return "note.pageViews"
        }
    }

    private static func filename(for id: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        guard !id.isEmpty, !id.hasPrefix("."), id.rangeOfCharacter(from: allowed.inverted) == nil else {
            throw NativeStoreError.fileSystem("智能集合 ID 无效")
        }
        return "\(id).base"
    }

    private static func filterExpression(for rule: NativeSmartCollectionRule) -> String {
        let field: String
        switch rule.field {
        case .title: field = "file.name"
        case .content: field = "note.excerpt"
        case .status: field = "note.status"
        case .category: field = "note.category"
        case .tag: field = "note.tags"
        case .property: field = propertyReference(rule.propertyKey)
        case .updatedAt: field = "file.mtime"
        case .publishedAt: field = "note.publishedAt"
        case .wordCount: field = "note.wordCount"
        case .pageViews: field = "note.pageViews"
        case .sourcePath: field = "file.path"
        }
        let value: String
        if rule.field.isNumber, Double(rule.value) != nil { value = rule.value }
        else if rule.field.isDate { value = "date(\(formulaString(rule.value)))" }
        else { value = formulaString(rule.value) }
        switch rule.comparison {
        case .contains: return "\(field).contains(\(value))"
        case .startsWith: return "\(field).startsWith(\(value))"
        case .equals: return "\(field) == \(value)"
        case .notEquals: return "\(field) != \(value)"
        case .before, .lessThan: return "\(field) < \(value)"
        case .after, .greaterThan: return "\(field) > \(value)"
        case .atMost: return "\(field) <= \(value)"
        case .atLeast: return "\(field) >= \(value)"
        case .isEmpty: return "\(field).isEmpty()"
        case .isNotEmpty: return "!\(field).isEmpty()"
        }
    }

    private static func groupProperty(_ field: NativeArticleGroupField) -> String {
        switch field {
        case .status: return "note.status"
        case .category: return "note.category"
        case .tag: return "note.tags"
        case .updatedMonth: return "file.mtime"
        case .none: return "file.name"
        }
    }

    private static func propertyReference(_ key: String) -> String {
        let usesDirectReference = NativeArticleProperties.isValidKey(key)
            && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return usesDirectReference ? "note.\(key)" : "note[\(formulaString(key))]"
    }

    private static func decodedScalar(_ node: NativeBaseYAMLValue?) -> String? {
        guard let token = node?.scalarToken else { return nil }
        return decodeYAMLScalar(token)
    }

    private static func formulaString(_ source: String) -> String {
        "\"" + source.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func yamlString(_ source: String) -> String {
        "'" + source.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func yamlKey(_ source: String) -> String {
        source.allSatisfy { $0.isLetter || $0.isNumber || "._-/".contains($0) }
            ? source : yamlString(source)
    }

    private static func decodeYAMLScalar(_ source: String) -> String {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2 else { return value }
        if value.first == "'", value.last == "'" {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if value.first == "\"", value.last == "\"" {
            return (try? JSONDecoder().decode(String.self, from: Data(value.utf8)))
                ?? String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func normalizedKey(_ source: String) -> String {
        source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func stableUUID(_ source: String) -> UUID {
        var high: UInt64 = 0xcbf29ce484222325
        var low: UInt64 = 0x84222325cbf29ce4
        for byte in source.utf8 {
            high = (high ^ UInt64(byte)) &* 0x100000001b3
            low = (low ^ UInt64(byte &+ 31)) &* 0x100000001b3
        }
        let hex = String(format: "%016llx%016llx", high, low)
        let value = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        return UUID(uuidString: value) ?? UUID()
    }

    private static func splitArguments(_ source: String) -> [String] {
        var result: [String] = []
        var start = source.startIndex
        var quoted: Character?
        var escaped = false
        for index in source.indices {
            let character = source[index]
            if escaped { escaped = false; continue }
            if character == "\\", quoted == "\"" { escaped = true; continue }
            if character == "'" || character == "\"" {
                if quoted == character { quoted = nil }
                else if quoted == nil { quoted = character }
            } else if character == ",", quoted == nil {
                result.append(String(source[start..<index]).trimmingCharacters(in: .whitespaces))
                start = source.index(after: index)
            }
        }
        result.append(String(source[start...]).trimmingCharacters(in: .whitespaces))
        return result.filter { !$0.isEmpty }
    }
}

private enum NativeBaseFilterExpression {
    static func parse(_ source: String) -> NativeSmartCollectionFilter? {
        let expression = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if let argument = functionArgument(expression, name: "file.hasTag") {
            return .rule(NativeSmartCollectionRule(field: .tag, comparison: .equals, value: literal(argument)))
        }
        if let argument = functionArgument(expression, name: "file.inFolder") {
            let folder = literal(argument).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return .rule(NativeSmartCollectionRule(
                field: .sourcePath,
                comparison: .startsWith,
                value: folder.isEmpty ? "" : folder + "/"
            ))
        }

        let negated = expression.hasPrefix("!")
        let unwrapped = negated ? String(expression.dropFirst()).trimmingCharacters(in: .whitespaces) : expression
        if unwrapped.hasSuffix(".isEmpty()") {
            let reference = String(unwrapped.dropLast(".isEmpty()".count))
            return rule(reference: reference, comparison: negated ? .isNotEmpty : .isEmpty, value: "")
        }
        for function in ["contains", "startsWith"] {
            let suffix = ".\(function)("
            guard let range = unwrapped.range(of: suffix), unwrapped.hasSuffix(")") else { continue }
            let reference = String(unwrapped[..<range.lowerBound])
            let argument = String(unwrapped[range.upperBound..<unwrapped.index(before: unwrapped.endIndex)])
            let comparison: NativeSmartCollectionOperator = function == "contains" ? .contains : .startsWith
            return rule(reference: reference, comparison: comparison, value: literal(argument))
        }

        for (token, comparison) in [
            (">=", NativeSmartCollectionOperator.atLeast),
            ("<=", .atMost),
            ("==", .equals),
            ("!=", .notEquals),
            (">", .greaterThan),
            ("<", .lessThan),
        ] {
            guard let range = operatorRange(token, in: expression) else { continue }
            let reference = String(expression[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(expression[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if reference == "file.ext" {
                let ext = literal(rawValue)
                return .rule(NativeSmartCollectionRule(
                    field: .sourcePath,
                    comparison: comparison == .notEquals ? .notEquals : .contains,
                    value: ".\(ext)"
                ))
            }
            return rule(reference: reference, comparison: comparison, value: literal(rawValue))
        }
        return nil
    }

    private static func rule(
        reference: String,
        comparison: NativeSmartCollectionOperator,
        value: String
    ) -> NativeSmartCollectionFilter? {
        let normalized = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized.lowercased()
        let field: NativeSmartCollectionField
        var propertyKey = ""
        switch lower {
        case "file.name", "note.title", "title": field = .title
        case "note.excerpt", "excerpt", "note.content", "content": field = .content
        case "note.status", "status": field = .status
        case "note.category", "category": field = .category
        case "note.tags", "file.tags", "tags": field = .tag
        case "file.mtime", "note.updatedat", "updatedat": field = .updatedAt
        case "note.publishedat", "publishedat": field = .publishedAt
        case "note.wordcount", "wordcount": field = .wordCount
        case "note.pageviews", "pageviews": field = .pageViews
        case "file.path", "file.folder": field = .sourcePath
        default:
            guard !lower.hasPrefix("formula.") else { return nil }
            field = .property
            if lower.hasPrefix("note[") || normalized.hasPrefix("[") {
                guard let open = normalized.firstIndex(of: "["), normalized.hasSuffix("]") else { return nil }
                propertyKey = literal(String(normalized[normalized.index(after: open)..<normalized.index(before: normalized.endIndex)]))
            } else if lower.hasPrefix("note.") {
                propertyKey = String(normalized.dropFirst("note.".count))
            } else {
                propertyKey = normalized
            }
        }
        var normalizedComparison = comparison
        if field.isDate {
            if comparison == .greaterThan { normalizedComparison = .after }
            if comparison == .lessThan { normalizedComparison = .before }
        }
        return .rule(NativeSmartCollectionRule(
            field: field,
            comparison: normalizedComparison,
            value: value,
            propertyKey: propertyKey
        ))
    }

    private static func functionArgument(_ source: String, name: String) -> String? {
        let prefix = name + "("
        guard source.hasPrefix(prefix), source.hasSuffix(")") else { return nil }
        return String(source.dropFirst(prefix.count).dropLast())
    }

    private static func operatorRange(_ token: String, in source: String) -> Range<String.Index>? {
        var quoted: Character?
        var escaped = false
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if escaped { escaped = false; index = source.index(after: index); continue }
            if character == "\\", quoted == "\"" { escaped = true; index = source.index(after: index); continue }
            if character == "'" || character == "\"" {
                if quoted == character { quoted = nil }
                else if quoted == nil { quoted = character }
            }
            if quoted == nil, source[index...].hasPrefix(token) {
                return index..<source.index(index, offsetBy: token.count)
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func literal(_ source: String) -> String {
        var value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("date("), value.hasSuffix(")") {
            value = String(value.dropFirst("date(".count).dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard value.count >= 2 else { return value }
        if value.first == "'", value.last == "'" {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if value.first == "\"", value.last == "\"" {
            return (try? JSONDecoder().decode(String.self, from: Data(value.utf8)))
                ?? String(value.dropFirst().dropLast())
        }
        return value
    }
}

private extension NativeSmartCollection {
    var filterNode: NativeSmartCollectionFilter? {
        if let filter {
            if filter.legacyProjection != nil,
               let edited = Self.legacyFilter(matchMode: matchMode, rules: rules) { return edited }
            return filter
        }
        return Self.legacyFilter(matchMode: matchMode, rules: rules)
    }
}
