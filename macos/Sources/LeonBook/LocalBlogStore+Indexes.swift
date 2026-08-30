import Foundation

extension LocalBlogStore {
    func migrateLegacyDataIfNeeded() throws {
        let database = try db()
        guard try database.text("SELECT value FROM metadata WHERE key = 'legacy_migration_v1'") != "done" else { return }

        let articles = try loadLegacyArticles()
        let moments = try loadLegacyMoments()
        let events = try loadLegacyActivityEvents()
        let trash = try loadLegacyTrashBackup()

        try database.transaction {
            try importArticles(articles, into: database)
            try importMoments(moments, into: database)
            try importActivityEvents(events, into: database)
            try importTrashedArticles(trash.articles, into: database)
            try importTrashedMoments(trash.moments, into: database)
            try database.execute("INSERT OR REPLACE INTO metadata(key, value) VALUES('legacy_migration_v1', 'done')")
        }
    }

    /// One-time handoff from the former SQLite-primary layout. Existing database
    /// rows win exactly once; after this marker is written, Markdown wins.
    func migrateMarkdownSourcesIfNeeded() throws {
        let database = try db()
        guard try database.text(
            "SELECT value FROM metadata WHERE key = 'markdown_source_v1'"
        ) != "done" else { return }

        if markdownWorkspaceSource.mode.isMounted {
            try database.execute(
                "INSERT OR REPLACE INTO metadata(key, value) VALUES('markdown_source_v1', 'done')"
            )
            return
        }

        var migrated: [NativeArticle] = []
        for article in try allArticles() {
            let record = try MarkdownArticleSource.write(
                article,
                relativePath: article.sourceRelativePath,
                in: articlesURL
            )
            migrated.append(applyingSourceRecord(record, to: article))
        }
        try database.transaction {
            for article in migrated { try insertArticle(article, into: database) }
            try database.execute(
                "INSERT OR REPLACE INTO metadata(key, value) VALUES('markdown_source_v1', 'done')"
            )
        }
    }

    func migrateMomentTagsIfNeeded() throws {
        let database = try db()
        guard try database.text("SELECT value FROM metadata WHERE key = 'moment_tags_v1'") != "done" else {
            return
        }

        var legacyMoments: [(id: String, text: String)] = []
        try database.query("SELECT id, text FROM moments WHERE tags_json IS NULL") { row in
            guard let id = row.text(at: 0), let text = row.text(at: 1) else {
                throw NativeStoreError.fileSystem("SQLite：微博记录不完整")
            }
            legacyMoments.append((id, text))
        }

        try database.transaction {
            for moment in legacyMoments {
                try database.execute(
                    "UPDATE moments SET tags_json = ? WHERE id = ?",
                    values: [
                        .text(try jsonString(NativeMomentTag.extract(from: moment.text))),
                        .text(moment.id),
                    ]
                )
            }
            try database.execute("INSERT OR REPLACE INTO metadata(key, value) VALUES('moment_tags_v1', 'done')")
        }
    }

    func migrateArticleDerivedIndexesIfNeeded() throws {
        let database = try db()
        let version = try database.text(
            "SELECT value FROM metadata WHERE key = 'article_derived_indexes_v1'"
        )
        guard version != "links-mentions-v2" else { return }

        var documents: [(slug: String, body: String)] = []
        try database.query(
            "SELECT slug, body FROM articles WHERE deleted_at IS NULL ORDER BY slug"
        ) { row in
            guard let slug = row.text(at: 0), let body = row.text(at: 1) else {
                throw NativeStoreError.fileSystem("SQLite：文章派生索引迁移记录不完整")
            }
            documents.append((slug, body))
        }

        try database.transaction {
            try database.execute("DELETE FROM article_link_references")
            try database.execute("DELETE FROM article_mention_search")
            for document in documents {
                try insertArticleLinkReferences(
                    sourceSlug: document.slug,
                    body: document.body,
                    into: database
                )
                try database.execute(
                    "INSERT INTO article_mention_search(source_slug, body) VALUES(?, ?)",
                    values: [.text(document.slug), .text(document.body)]
                )
            }
            try database.execute("""
            INSERT OR REPLACE INTO metadata(key, value)
            VALUES('article_derived_indexes_v1', 'links-mentions-v2')
            """)
        }
    }

    func migrateSearchAccelerationIndexesIfNeeded() throws {
        let database = try db()
        let version = try database.text(
            "SELECT value FROM metadata WHERE key = 'search_acceleration_v1'"
        )
        guard version != "normalized-short-v3" else { return }

        let articles = try allArticles()
        let moments = try allMoments()
        var questions: [(id: String, title: String, body: String, tags: [String])] = []
        try database.query("SELECT id, title, body, tags_json FROM questions") { row in
            guard let id = row.text(at: 0),
                  let title = row.text(at: 1),
                  let body = row.text(at: 2),
                  let tagsJSON = row.text(at: 3) else { return }
            let tags: [String] = (try? decode(tagsJSON)) ?? []
            questions.append((id, title, body, tags))
        }
        try database.transaction {
            try database.execute("DELETE FROM article_tags")
            try database.execute("DELETE FROM article_properties")
            try database.execute("DELETE FROM moment_tags")
            try database.execute("DELETE FROM content_short_search")
            for article in articles {
                try replaceArticleFilterIndexes(article, isActive: true, in: database)
                try replaceShortSearchDocument(
                    type: "article",
                    id: article.slug,
                    source: articleSearchSource(article),
                    isActive: true,
                    in: database
                )
            }
            for moment in moments {
                try replaceMomentFilterIndexes(moment, isActive: true, in: database)
                try replaceShortSearchDocument(
                    type: "moment",
                    id: moment.id,
                    source: [moment.text, moment.tags.joined(separator: " "), moment.createdAt],
                    isActive: true,
                    in: database
                )
            }
            for question in questions {
                try replaceShortSearchDocument(
                    type: "question",
                    id: question.id,
                    source: [question.title, question.body, question.tags.joined(separator: " ")],
                    isActive: true,
                    in: database
                )
            }
            try database.execute("""
            INSERT OR REPLACE INTO metadata(key, value)
            VALUES('search_acceleration_v1', 'normalized-short-v3')
            """)
        }
    }

    func migrateMediaReferencesIfNeeded() throws {
        let database = try db()
        guard try database.text(
            "SELECT value FROM metadata WHERE key = 'media_references_v1'"
        ) != "done" else { return }

        var owners: [(type: String, id: String, urls: [String])] = []
        try database.query("SELECT slug, body, banner_json, media_json FROM articles") { row in
            guard let slug = row.text(at: 0),
                  let body = row.text(at: 1),
                  let mediaJSON = row.text(at: 3) else { return }
            let media: [NativeMedia] = (try? decode(mediaJSON)) ?? []
            let banner: NativeBanner? = row.text(at: 2).flatMap { try? decode($0) }
            owners.append((
                "article",
                slug,
                media.map(\.url) + (banner.map { [$0.url] } ?? []) + embeddedMediaURLs(in: body)
            ))
        }
        try database.query("SELECT id, images_json FROM moments") { row in
            guard let id = row.text(at: 0), let imagesJSON = row.text(at: 1) else { return }
            let images: [NativeMedia] = (try? decode(imagesJSON)) ?? []
            owners.append(("moment", id, images.map(\.url)))
        }
        try database.query("SELECT id, body, images_json FROM question_answers") { row in
            guard let id = row.text(at: 0),
                  let body = row.text(at: 1),
                  let imagesJSON = row.text(at: 2) else { return }
            let images: [NativeMedia] = (try? decode(imagesJSON)) ?? []
            owners.append(("answer", id, images.map(\.url) + embeddedMediaURLs(in: body)))
        }

        try database.transaction {
            try database.execute("DELETE FROM media_references")
            for owner in owners {
                try replaceMediaReferences(
                    ownerType: owner.type,
                    ownerID: owner.id,
                    urls: owner.urls,
                    in: database
                )
            }
            try database.execute("""
            INSERT OR REPLACE INTO metadata(key, value)
            VALUES('media_references_v1', 'done')
            """)
        }
    }

    func replaceMediaReferences(
        ownerType: String,
        ownerID: String,
        urls: [String],
        in database: SQLiteDatabase
    ) throws {
        try database.execute(
            "DELETE FROM media_references WHERE owner_type = ? AND owner_id = ?",
            values: [.text(ownerType), .text(ownerID)]
        )
        let normalizedURLs = Set(urls.map(normalizeMediaURL).filter { $0.hasPrefix("/media/") })
        for url in normalizedURLs {
            try database.execute("""
            INSERT INTO media_references(owner_type, owner_id, normalized_url)
            VALUES(?, ?, ?)
            """, values: [.text(ownerType), .text(ownerID), .text(url)])
        }
    }

    func embeddedMediaURLs(in source: String) -> [String] {
        var result: [String] = []
        var remainder = source[source.startIndex...]
        let terminators = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "<>\"')]}`")
        )
        while let prefix = remainder.range(of: "/media/") {
            let suffix = remainder[prefix.lowerBound...]
            let scalarEnd = suffix.unicodeScalars.firstIndex { terminators.contains($0) }
            let end = scalarEnd.flatMap { String.Index($0, within: suffix) } ?? suffix.endIndex
            let candidate = String(suffix[..<end])
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            if !candidate.isEmpty { result.append(candidate) }
            guard end < suffix.endIndex else { break }
            remainder = suffix[suffix.index(after: end)...]
        }
        return result
    }

    func replaceMomentFilterIndexes(
        _ moment: NativeMoment,
        isActive: Bool,
        in database: SQLiteDatabase
    ) throws {
        try database.execute(
            "DELETE FROM moment_tags WHERE moment_id = ?",
            values: [.text(moment.id)]
        )
        guard isActive else { return }
        for tag in moment.tags {
            let normalized = normalizedSearchIdentity(tag)
            guard !normalized.isEmpty else { continue }
            try database.execute("""
            INSERT OR IGNORE INTO moment_tags(moment_id, tag, normalized_tag)
            VALUES(?, ?, ?)
            """, values: [.text(moment.id), .text(tag), .text(normalized)])
        }
    }

    func replaceArticleFilterIndexes(
        _ article: NativeArticle,
        isActive: Bool,
        in database: SQLiteDatabase
    ) throws {
        try database.execute(
            "DELETE FROM article_tags WHERE article_slug = ?",
            values: [.text(article.slug)]
        )
        try database.execute(
            "DELETE FROM article_properties WHERE article_slug = ?",
            values: [.text(article.slug)]
        )
        guard isActive else { return }

        for tag in article.tags {
            let normalized = normalizedSearchIdentity(tag)
            guard !normalized.isEmpty else { continue }
            try database.execute("""
            INSERT OR IGNORE INTO article_tags(article_slug, tag, normalized_tag)
            VALUES(?, ?, ?)
            """, values: [.text(article.slug), .text(tag), .text(normalized)])
        }
        for (key, property) in article.properties {
            let normalizedKey = normalizedSearchIdentity(key)
            guard !normalizedKey.isEmpty else { continue }
            for value in property.searchValues {
                let normalizedValue = normalizedSearchIdentity(value)
                try database.execute("""
                INSERT OR IGNORE INTO article_properties(
                    article_slug, property_key, normalized_key, value, normalized_value, kind
                ) VALUES(?, ?, ?, ?, ?, ?)
                """, values: [
                    .text(article.slug), .text(key), .text(normalizedKey),
                    .text(value), .text(normalizedValue), .text(property.kind.rawValue),
                ])
            }
        }
    }

    func articleSearchSource(_ article: NativeArticle) -> [String] {
        [
            article.title,
            NativeArticleAlias.values(from: article.properties).joined(separator: " "),
            article.body,
            article.excerpt,
            article.tags.joined(separator: " "),
            article.category,
            article.properties.map { "\($0.key) \($0.value.searchText)" }.joined(separator: " "),
        ]
    }

    func replaceShortSearchDocument(
        type: String,
        id: String,
        source: [String],
        isActive: Bool,
        in database: SQLiteDatabase
    ) throws {
        try database.execute("""
        DELETE FROM content_short_search
        WHERE document_type = ? AND document_id = ?
        """, values: [.text(type), .text(id)])
        guard isActive else { return }
        let terms = shortSearchTerms(source)
        guard !terms.isEmpty else { return }
        try database.execute("""
        INSERT INTO content_short_search(document_type, document_id, terms)
        VALUES(?, ?, ?)
        """, values: [.text(type), .text(id), .text(terms)])
    }

    private func shortSearchTerms(_ source: [String]) -> String {
        let normalized = normalizedSearchIdentity(source.joined(separator: " "))
        var terms = Set<String>()
        var run: [Character] = []

        func flush() {
            guard !run.isEmpty else { return }
            for index in run.indices {
                terms.insert(String(run[index]))
                let next = run.index(after: index)
                if next < run.endIndex {
                    terms.insert(String([run[index], run[next]]))
                }
            }
            run.removeAll(keepingCapacity: true)
        }

        for character in normalized {
            if character.isLetter || character.isNumber {
                run.append(character)
            } else {
                flush()
            }
        }
        flush()
        return terms.sorted().joined(separator: " ")
    }

    func normalizedSearchIdentity(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    func shortSearchToken(for rawValue: String) -> String? {
        let characters = normalizedSearchIdentity(rawValue).filter { $0.isLetter || $0.isNumber }
        guard (1...2).contains(characters.count) else { return nil }
        return String(characters)
    }

}
