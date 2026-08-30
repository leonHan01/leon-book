import Foundation

extension LocalBlogStore {
    public func search(
        _ rawQuery: String,
        restrictingTo forcedTypes: Set<NativeSearchDocumentType> = [],
        limit: Int = 60
    ) throws -> [NativeGlobalSearchResult] {
        try prepare()
        let query = NativeGlobalSearchQuery(rawQuery)
        let effectiveTypes: Set<NativeSearchDocumentType>
        if forcedTypes.isEmpty {
            effectiveTypes = query.types
        } else if query.types.isEmpty {
            effectiveTypes = forcedTypes
        } else {
            effectiveTypes = forcedTypes.intersection(query.types)
        }
        if !forcedTypes.isEmpty, !query.types.isEmpty, effectiveTypes.isEmpty { return [] }

        var predicates: [String] = []
        var values: [SQLiteValue] = []
        let indexedTerms = query.textTerms.filter { $0.count >= 3 }
        let shortTerms = query.textTerms.filter { $0.count < 3 }

        if !indexedTerms.isEmpty {
            let expression = indexedTerms
                .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
                .joined(separator: " AND ")
            predicates.append("content_search MATCH ?")
            values.append(.text(expression))
        }

        for term in shortTerms {
            if let token = shortSearchToken(for: term) {
                predicates.append("""
                EXISTS (
                    SELECT 1 FROM content_short_search AS short_index
                    WHERE short_index.document_type = content_search.document_type
                      AND short_index.document_id = content_search.document_id
                      AND content_short_search MATCH ?
                )
                """)
                values.append(.text("\"\(token.replacingOccurrences(of: "\"", with: "\"\""))\""))
            } else {
                predicates.append("""
                (instr(lower(title), lower(?)) > 0
                 OR instr(lower(aliases), lower(?)) > 0
                 OR instr(lower(body), lower(?)) > 0
                 OR instr(lower(excerpt), lower(?)) > 0
                 OR instr(lower(tags), lower(?)) > 0
                 OR instr(lower(category), lower(?)) > 0
                 OR instr(lower(properties), lower(?)) > 0)
                """)
                values.append(contentsOf: Array(repeating: .text(term), count: 7))
            }
        }

        for tag in query.tags {
            predicates.append("""
            ((document_type = 'article' AND EXISTS (
                SELECT 1 FROM article_tags AS tag_filter
                WHERE tag_filter.article_slug = document_id
                  AND tag_filter.normalized_tag = ?
            )) OR (document_type = 'moment' AND EXISTS (
                SELECT 1 FROM moment_tags AS tag_filter
                WHERE tag_filter.moment_id = document_id
                  AND tag_filter.normalized_tag = ?
            )))
            """)
            let normalizedTag = normalizedSearchIdentity(tag)
            values.append(.text(normalizedTag))
            values.append(.text(normalizedTag))
        }

        if !effectiveTypes.isEmpty {
            let orderedTypes = effectiveTypes.sorted { $0.rawValue < $1.rawValue }
            predicates.append("document_type IN (\(orderedTypes.map { _ in "?" }.joined(separator: ", ")))")
            values.append(contentsOf: orderedTypes.map { .text($0.rawValue) })
        }

        if let status = query.status {
            predicates.append("status = ?")
            values.append(.text(status.rawValue))
        }
        if let after = query.after {
            predicates.append("created_at >= ?")
            values.append(.text(NativeTimestamp.string(from: after)))
        }
        if let before = query.before {
            predicates.append("created_at < ?")
            values.append(.text(NativeTimestamp.string(from: before)))
        }
        for property in query.propertyFilters {
            predicates.append("""
            (document_type = 'article' AND EXISTS (
                SELECT 1
                FROM article_properties AS property_filter
                WHERE property_filter.article_slug = document_id
                  AND property_filter.normalized_key = ?
                  AND property_filter.normalized_value = ?
            ))
            """)
            values.append(.text(normalizedSearchIdentity(property.key)))
            values.append(.text(normalizedSearchIdentity(property.value)))
        }

        let whereClause = predicates.isEmpty ? "" : "WHERE \(predicates.joined(separator: " AND "))"
        let ordering = indexedTerms.isEmpty
            ? "updated_at DESC"
            : "bm25(content_search, 0.0, 0.0, 8.0, 7.0, 3.0, 4.0, 2.0, 2.0, 5.0, 0.0, 0.0, 0.0) ASC, updated_at DESC"
        values.append(.integer(min(max(limit, 1), 200)))

        var results: [NativeGlobalSearchResult] = []
        try db().query(
            """
            SELECT document_type, document_id, title,
                   snippet(content_search, -1, '⟦', '⟧', ' … ', 28),
                   substr(body, 1, 320), excerpt, tags, category, status, created_at, updated_at
            FROM content_search
            \(whereClause)
            ORDER BY \(ordering)
            LIMIT ?
            """,
            values: values
        ) { row in
            guard let typeValue = row.text(at: 0),
                  let documentType = NativeSearchDocumentType(rawValue: typeValue),
                  let documentID = row.text(at: 1),
                  let storedTitle = row.text(at: 2),
                  let body = row.text(at: 4),
                  let excerpt = row.text(at: 5),
                  let tagsJSON = row.text(at: 6),
                  let updatedAt = row.text(at: 10) else {
                throw NativeStoreError.fileSystem("SQLite：全文搜索结果不完整")
            }

            let highlighted = row.text(at: 3) ?? ""
            let fallback = excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? body : excerpt
            let snippet = compactSearchSnippet(
                highlighted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : highlighted
            )
            results.append(NativeGlobalSearchResult(
                documentType: documentType,
                documentID: documentID,
                title: storedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? (documentType == .moment ? "图片微博" : "未命名文章")
                    : storedTitle,
                snippet: snippet,
                tags: (try? decode(tagsJSON)) ?? [],
                category: row.text(at: 7).flatMap { $0.isEmpty ? nil : $0 },
                status: row.text(at: 8).flatMap(NativeArticleStatus.init(rawValue:)),
                timestamp: row.text(at: 9) ?? updatedAt
            ))
        }
        return results
    }

    /// Reads incrementally maintained raw wiki-link references and resolves them
    /// against current titles, slugs, paths, and aliases without loading bodies.
    public func articleRelations(for slug: String) throws -> NativeArticleRelations {
        try prepare()
        try Task.checkCancellation()
        let safeSlug = try requireSafeSegment(slug, label: "文章 slug")
        let summaries = try allArticleSummaries()
        try Task.checkCancellation()
        guard let article = summaries.first(where: { $0.slug == safeSlug }) else {
            throw NativeStoreError.notFound
        }

        let summariesBySlug = Dictionary(uniqueKeysWithValues: summaries.map { ($0.slug, $0) })
        let resolver = NativeArticleLinkIdentityIndex(summaries)
        let outgoing = try indexedOutgoingArticles(
            from: article.slug,
            summariesBySlug: summariesBySlug,
            resolver: resolver
        )
        let incoming = try indexedIncomingArticles(
            to: article,
            summariesBySlug: summariesBySlug,
            resolver: resolver
        )

        let unlinkedMentions = try mentionCandidates(
            containing: article.title,
            excluding: article.slug
        ).compactMap { candidate -> NativeArticleMention? in
            guard !Task.isCancelled else { return nil }
            guard let mention = unlinkedMention(of: article.title, in: candidate.body),
                  let summary = summariesBySlug[candidate.slug] else { return nil }
            return NativeArticleMention(article: summary, count: mention.count, snippet: mention.snippet)
        }
        .sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.article.updatedAt > $1.article.updatedAt
        }
        try Task.checkCancellation()

        return NativeArticleRelations(
            outgoing: outgoing,
            incoming: incoming,
            unlinkedMentions: unlinkedMentions
        )
    }

    private func unlinkedMention(of title: String, in body: String) -> (count: Int, snippet: String)? {
        let target = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard target.count >= 2 else { return nil }

        let markerSlug = "__leon_unlinked_mention__"
        let analysis = NativeArticleLink.linkingUnlinkedMentions(of: target, to: markerSlug, in: body)
        let markerPrefix = "[[\(markerSlug)|"
        guard analysis.count > 0,
              let prefixRange = analysis.body.range(of: markerPrefix),
              let closingRange = analysis.body.range(of: "]]", range: prefixRange.upperBound..<analysis.body.endIndex)
        else { return nil }
        let lower = analysis.body.index(
            prefixRange.lowerBound,
            offsetBy: -72,
            limitedBy: analysis.body.startIndex
        ) ?? analysis.body.startIndex
        let upper = analysis.body.index(
            closingRange.upperBound,
            offsetBy: 120,
            limitedBy: analysis.body.endIndex
        ) ?? analysis.body.endIndex
        let markedSnippet = String(analysis.body[lower..<upper])
        let markerExpression = try! NSRegularExpression(
            pattern: #"\[\[__leon_unlinked_mention__\|([^\]]+)\]\]"#
        )
        let cleanedSnippet = markerExpression.stringByReplacingMatches(
            in: markedSnippet,
            range: NSRange(markedSnippet.startIndex..., in: markedSnippet),
            withTemplate: "$1"
        )
        let compact = cleanedSnippet.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let prefix = lower == analysis.body.startIndex ? "" : "…"
        let suffix = upper == analysis.body.endIndex ? "" : "…"
        return (analysis.count, prefix + compact + suffix)
    }

    @discardableResult
    public func convertUnlinkedMention(
        sourceSlug: String,
        targetSlug: String,
        expectedUpdatedAt: String
    ) throws -> NativeArticle {
        try prepare()
        let safeSourceSlug = try requireSafeSegment(sourceSlug, label: "来源文章 slug")
        let safeTargetSlug = try requireSafeSegment(targetSlug, label: "目标文章 slug")
        guard let source = try storedArticle(withSlug: safeSourceSlug),
              let target = try storedArticle(withSlug: safeTargetSlug) else {
            throw NativeStoreError.notFound
        }
        guard source.updatedAt == expectedUpdatedAt else { throw NativeStoreError.conflict }
        let replacement = NativeArticleLink.linkingUnlinkedMentions(
            of: target.title,
            to: target.slug,
            in: source.body
        )
        guard replacement.count > 0 else {
            throw NativeStoreError.fileSystem("未找到可转换的未链接提及")
        }
        return try saveArticle(NativeSaveArticle(
            banner: source.banner,
            body: replacement.body,
            category: source.category,
            excerpt: source.excerpt,
            media: source.media,
            slug: source.slug,
            status: source.status,
            tags: source.tags,
            title: source.title,
            expectedUpdatedAt: source.updatedAt,
            properties: source.properties
        ))
    }

    public func articleGraph() throws -> NativeArticleGraph {
        try prepare()
        return try indexedArticleGraph(nodes: allArticleSummaries())
    }
}
