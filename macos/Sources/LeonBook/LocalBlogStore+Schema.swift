import Foundation

extension LocalBlogStore {
    func createSchema(in database: SQLiteDatabase) throws {
        try database.execute("""
        CREATE TABLE IF NOT EXISTS metadata (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS articles (
            slug TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL,
            body TEXT NOT NULL,
            category TEXT NOT NULL,
            excerpt TEXT NOT NULL,
            banner_json TEXT,
            media_json TEXT NOT NULL,
            status TEXT NOT NULL,
            tags_json TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            published_at TEXT,
            word_count INTEGER NOT NULL,
            page_views INTEGER NOT NULL DEFAULT 0,
            deleted_at TEXT,
            delete_expires_at TEXT,
            properties_json TEXT NOT NULL DEFAULT '{}',
            source_relative_path TEXT,
            source_content_hash TEXT,
            source_imported_at TEXT
        );
        CREATE INDEX IF NOT EXISTS articles_updated_at_idx ON articles(updated_at DESC);
        CREATE INDEX IF NOT EXISTS articles_active_status_updated_idx
            ON articles(status, updated_at DESC) WHERE deleted_at IS NULL;
        CREATE INDEX IF NOT EXISTS articles_active_category_updated_idx
            ON articles(category, updated_at DESC) WHERE deleted_at IS NULL;
        CREATE TABLE IF NOT EXISTS article_tags (
            article_slug TEXT NOT NULL,
            tag TEXT NOT NULL,
            normalized_tag TEXT NOT NULL,
            PRIMARY KEY(article_slug, normalized_tag),
            FOREIGN KEY(article_slug) REFERENCES articles(slug) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS article_tags_search_idx
            ON article_tags(normalized_tag, article_slug);
        CREATE TABLE IF NOT EXISTS article_properties (
            article_slug TEXT NOT NULL,
            property_key TEXT NOT NULL,
            normalized_key TEXT NOT NULL,
            value TEXT NOT NULL,
            normalized_value TEXT NOT NULL,
            kind TEXT NOT NULL,
            PRIMARY KEY(article_slug, normalized_key, normalized_value),
            FOREIGN KEY(article_slug) REFERENCES articles(slug) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS article_properties_search_idx
            ON article_properties(normalized_key, normalized_value, article_slug);
        CREATE TABLE IF NOT EXISTS article_revisions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sync_id TEXT,
            draft_key TEXT NOT NULL,
            article_slug TEXT,
            reason TEXT NOT NULL,
            snapshot_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS article_revisions_article_idx
            ON article_revisions(article_slug, updated_at DESC);
        CREATE INDEX IF NOT EXISTS article_revisions_draft_idx
            ON article_revisions(draft_key, updated_at DESC);
        CREATE TABLE IF NOT EXISTS article_comments (
            id TEXT PRIMARY KEY NOT NULL,
            article_slug TEXT NOT NULL,
            parent_id TEXT,
            author_name TEXT NOT NULL,
            text TEXT NOT NULL,
            quoted_text TEXT,
            anchor_id TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(article_slug) REFERENCES articles(slug) ON DELETE CASCADE,
            FOREIGN KEY(parent_id) REFERENCES article_comments(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS article_comments_article_idx
            ON article_comments(article_slug, created_at, id);
        CREATE INDEX IF NOT EXISTS article_comments_parent_idx
            ON article_comments(parent_id, created_at, id);
        CREATE TABLE IF NOT EXISTS article_link_references (
            source_slug TEXT NOT NULL,
            target_reference TEXT NOT NULL,
            target_identity TEXT NOT NULL,
            target_path TEXT NOT NULL,
            position INTEGER NOT NULL,
            PRIMARY KEY(source_slug, target_reference),
            FOREIGN KEY(source_slug) REFERENCES articles(slug) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS article_link_references_source_idx
            ON article_link_references(source_slug, position);
        CREATE TABLE IF NOT EXISTS smart_collections (
            id TEXT PRIMARY KEY NOT NULL,
            config_json TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS smart_collections_updated_idx
            ON smart_collections(updated_at DESC);
        CREATE TABLE IF NOT EXISTS bookmarks (
            id TEXT PRIMARY KEY NOT NULL,
            bookmark_json TEXT NOT NULL,
            position INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS bookmarks_position_idx
            ON bookmarks(position, created_at);
        CREATE TABLE IF NOT EXISTS portable_sidecar_tombstones (
            kind TEXT NOT NULL,
            record_id TEXT NOT NULL,
            deleted_at TEXT NOT NULL,
            PRIMARY KEY(kind, record_id)
        );
        CREATE TABLE IF NOT EXISTS moments (
            id TEXT PRIMARY KEY NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            text TEXT NOT NULL,
            text_runs_json TEXT NOT NULL,
            images_json TEXT NOT NULL,
            tags_json TEXT NOT NULL,
            is_favorite INTEGER NOT NULL DEFAULT 0,
            deleted_at TEXT,
            delete_expires_at TEXT
        );
        CREATE INDEX IF NOT EXISTS moments_created_at_idx ON moments(created_at DESC);
        CREATE INDEX IF NOT EXISTS moments_feed_active_idx ON moments(created_at DESC, id DESC)
            WHERE deleted_at IS NULL;
        CREATE TABLE IF NOT EXISTS moment_tags (
            moment_id TEXT NOT NULL,
            tag TEXT NOT NULL,
            normalized_tag TEXT NOT NULL,
            PRIMARY KEY(moment_id, normalized_tag),
            FOREIGN KEY(moment_id) REFERENCES moments(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS moment_tags_search_idx
            ON moment_tags(normalized_tag, moment_id);
        CREATE TABLE IF NOT EXISTS questions (
            id TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL,
            body TEXT NOT NULL,
            tags_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS questions_updated_at_idx
            ON questions(updated_at DESC, id DESC);
        CREATE TABLE IF NOT EXISTS question_tags (
            question_id TEXT NOT NULL,
            tag TEXT NOT NULL,
            normalized_tag TEXT NOT NULL,
            PRIMARY KEY(question_id, normalized_tag),
            FOREIGN KEY(question_id) REFERENCES questions(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS question_tags_search_idx
            ON question_tags(normalized_tag, question_id);
        CREATE TABLE IF NOT EXISTS question_answers (
            id TEXT PRIMARY KEY NOT NULL,
            question_id TEXT NOT NULL,
            body TEXT NOT NULL,
            images_json TEXT NOT NULL DEFAULT '[]',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(question_id) REFERENCES questions(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS question_answers_question_idx
            ON question_answers(question_id, created_at, id);
        CREATE TABLE IF NOT EXISTS media_references (
            owner_type TEXT NOT NULL,
            owner_id TEXT NOT NULL,
            normalized_url TEXT NOT NULL,
            PRIMARY KEY(owner_type, owner_id, normalized_url)
        );
        CREATE INDEX IF NOT EXISTS media_references_url_idx
            ON media_references(normalized_url, owner_type, owner_id);
        CREATE TABLE IF NOT EXISTS activity_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            type TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS activity_created_at_idx ON activity_events(created_at);
        """)
        try ensureColumn("deleted_at", in: "articles", database: database)
        try ensureColumn("delete_expires_at", in: "articles", database: database)
        try ensureColumn("page_views", in: "articles", database: database, definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn("properties_json", in: "articles", database: database, definition: "TEXT NOT NULL DEFAULT '{}'")
        try ensureColumn("source_relative_path", in: "articles", database: database)
        try ensureColumn("source_content_hash", in: "articles", database: database)
        try ensureColumn("source_imported_at", in: "articles", database: database)
        try ensureColumn("sync_id", in: "article_revisions", database: database)
        try ensureColumn(
            "target_identity",
            in: "article_link_references",
            database: database,
            definition: "TEXT NOT NULL DEFAULT ''"
        )
        try ensureColumn(
            "target_path",
            in: "article_link_references",
            database: database,
            definition: "TEXT NOT NULL DEFAULT ''"
        )
        try ensureColumn("deleted_at", in: "moments", database: database)
        try ensureColumn("delete_expires_at", in: "moments", database: database)
        try ensureColumn("tags_json", in: "moments", database: database)
        try ensureColumn("is_favorite", in: "moments", database: database, definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(
            "images_json",
            in: "question_answers",
            database: database,
            definition: "TEXT NOT NULL DEFAULT '[]'"
        )
        try database.execute("""
        CREATE INDEX IF NOT EXISTS articles_trash_expiry_idx ON articles(delete_expires_at);
        CREATE UNIQUE INDEX IF NOT EXISTS articles_source_path_idx
            ON articles(source_relative_path) WHERE source_relative_path IS NOT NULL;
        CREATE UNIQUE INDEX IF NOT EXISTS article_revisions_sync_idx
            ON article_revisions(sync_id) WHERE sync_id IS NOT NULL;
        CREATE INDEX IF NOT EXISTS article_link_references_identity_idx
            ON article_link_references(target_identity, source_slug);
        CREATE INDEX IF NOT EXISTS article_link_references_path_idx
            ON article_link_references(target_path, source_slug);
        CREATE INDEX IF NOT EXISTS moments_trash_expiry_idx ON moments(delete_expires_at);

        DROP TRIGGER IF EXISTS media_references_articles_delete;
        DROP TRIGGER IF EXISTS media_references_moments_delete;
        DROP TRIGGER IF EXISTS media_references_answers_delete;
        CREATE TRIGGER media_references_articles_delete AFTER DELETE ON articles BEGIN
            DELETE FROM media_references WHERE owner_type = 'article' AND owner_id = old.slug;
        END;
        CREATE TRIGGER media_references_moments_delete AFTER DELETE ON moments BEGIN
            DELETE FROM media_references WHERE owner_type = 'moment' AND owner_id = old.id;
        END;
        CREATE TRIGGER media_references_answers_delete AFTER DELETE ON question_answers BEGIN
            DELETE FROM media_references WHERE owner_type = 'answer' AND owner_id = old.id;
        END;
        """)
        var revisionsMissingSyncID: [Int] = []
        try database.query("SELECT id FROM article_revisions WHERE sync_id IS NULL") { row in
            if let id = row.integer(at: 0) { revisionsMissingSyncID.append(id) }
        }
        for id in revisionsMissingSyncID {
            try database.execute(
                "UPDATE article_revisions SET sync_id = ? WHERE id = ?",
                values: [.text(UUID().uuidString.lowercased()), .integer(id)]
            )
        }
        try createSearchSchema(in: database)
        try createShortSearchSchema(in: database)
        try createQuestionSearchSchema(in: database)
        try createArticleMentionSchema(in: database)
    }

    func createQuestionSearchSchema(in database: SQLiteDatabase) throws {
        try database.execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS question_search USING fts5(
            question_id UNINDEXED,
            title,
            body,
            tags,
            tokenize = 'trigram'
        );

        DROP TRIGGER IF EXISTS question_search_insert;
        DROP TRIGGER IF EXISTS question_search_update;
        DROP TRIGGER IF EXISTS question_search_delete;

        CREATE TRIGGER question_search_insert AFTER INSERT ON questions BEGIN
            DELETE FROM question_search WHERE question_id = new.id;
            INSERT INTO question_search(question_id, title, body, tags)
            VALUES(new.id, new.title, new.body, new.tags_json);
        END;
        CREATE TRIGGER question_search_update
        AFTER UPDATE OF id, title, body, tags_json ON questions BEGIN
            DELETE FROM question_search WHERE question_id = old.id;
            INSERT INTO question_search(question_id, title, body, tags)
            VALUES(new.id, new.title, new.body, new.tags_json);
        END;
        CREATE TRIGGER question_search_delete AFTER DELETE ON questions BEGIN
            DELETE FROM question_search WHERE question_id = old.id;
        END;
        """)

        let questionCount = try database.integer("SELECT COUNT(*) FROM questions") ?? 0
        let indexedCount = try database.integer("SELECT COUNT(*) FROM question_search") ?? 0
        guard questionCount != indexedCount else { return }
        try database.transaction {
            try database.execute("DELETE FROM question_search")
            try database.execute("""
            INSERT INTO question_search(question_id, title, body, tags)
            SELECT id, title, body, tags_json FROM questions
            """)
        }
    }

    func createShortSearchSchema(in database: SQLiteDatabase) throws {
        try database.execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS content_short_search USING fts5(
            document_type UNINDEXED,
            document_id UNINDEXED,
            terms,
            tokenize = 'unicode61 remove_diacritics 2'
        );

        DROP TRIGGER IF EXISTS content_short_search_articles_update;
        DROP TRIGGER IF EXISTS content_short_search_articles_delete;
        DROP TRIGGER IF EXISTS content_short_search_moments_update;
        DROP TRIGGER IF EXISTS content_short_search_moments_delete;

        CREATE TRIGGER content_short_search_articles_update
        AFTER UPDATE OF slug, deleted_at ON articles
        WHEN old.slug <> new.slug OR old.deleted_at IS NOT new.deleted_at BEGIN
            DELETE FROM content_short_search
            WHERE document_type = 'article' AND document_id = old.slug;
        END;
        CREATE TRIGGER content_short_search_articles_delete
        AFTER DELETE ON articles BEGIN
            DELETE FROM content_short_search
            WHERE document_type = 'article' AND document_id = old.slug;
        END;
        CREATE TRIGGER content_short_search_moments_update
        AFTER UPDATE OF id, deleted_at ON moments
        WHEN old.id <> new.id OR old.deleted_at IS NOT new.deleted_at BEGIN
            DELETE FROM content_short_search
            WHERE document_type = 'moment' AND document_id = old.id;
        END;
        CREATE TRIGGER content_short_search_moments_delete
        AFTER DELETE ON moments BEGIN
            DELETE FROM content_short_search
            WHERE document_type = 'moment' AND document_id = old.id;
        END;
        """)
    }

    func createArticleMentionSchema(in database: SQLiteDatabase) throws {
        try database.execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS article_mention_search USING fts5(
            source_slug UNINDEXED,
            body,
            tokenize = 'trigram'
        );

        DROP TRIGGER IF EXISTS article_mention_search_insert;
        DROP TRIGGER IF EXISTS article_mention_search_update;
        DROP TRIGGER IF EXISTS article_mention_search_delete;

        CREATE TRIGGER article_mention_search_insert
        AFTER INSERT ON articles WHEN new.deleted_at IS NULL BEGIN
            DELETE FROM article_mention_search WHERE source_slug = new.slug;
            INSERT INTO article_mention_search(source_slug, body) VALUES(new.slug, new.body);
        END;
        CREATE TRIGGER article_mention_search_update
        AFTER UPDATE OF slug, body, deleted_at ON articles
        WHEN old.slug <> new.slug
          OR old.body <> new.body
          OR old.deleted_at IS NOT new.deleted_at BEGIN
            DELETE FROM article_mention_search WHERE source_slug = old.slug;
            INSERT INTO article_mention_search(source_slug, body)
            SELECT new.slug, new.body WHERE new.deleted_at IS NULL;
        END;
        CREATE TRIGGER article_mention_search_delete
        AFTER DELETE ON articles BEGIN
            DELETE FROM article_mention_search WHERE source_slug = old.slug;
        END;
        """)
    }

    func createSearchSchema(in database: SQLiteDatabase) throws {
        var existingSearchColumns = Set<String>()
        try database.query("PRAGMA table_info(content_search)") { row in
            if let name = row.text(at: 1) { existingSearchColumns.insert(name) }
        }
        if !existingSearchColumns.isEmpty,
           (!existingSearchColumns.contains("aliases") || !existingSearchColumns.contains("properties")) {
            try database.execute("""
            DROP TRIGGER IF EXISTS content_search_articles_insert;
            DROP TRIGGER IF EXISTS content_search_articles_update;
            DROP TRIGGER IF EXISTS content_search_articles_delete;
            DROP TRIGGER IF EXISTS content_search_moments_insert;
            DROP TRIGGER IF EXISTS content_search_moments_update;
            DROP TRIGGER IF EXISTS content_search_moments_delete;
            DROP TABLE content_search;
            """)
        }
        try database.execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS content_search USING fts5(
            document_type UNINDEXED,
            document_id UNINDEXED,
            title,
            aliases,
            body,
            excerpt,
            tags,
            category,
            properties,
            status UNINDEXED,
            created_at UNINDEXED,
            updated_at UNINDEXED,
            tokenize = 'trigram'
        );

        DROP TRIGGER IF EXISTS content_search_articles_insert;
        DROP TRIGGER IF EXISTS content_search_articles_update;
        DROP TRIGGER IF EXISTS content_search_articles_delete;
        DROP TRIGGER IF EXISTS content_search_moments_insert;
        DROP TRIGGER IF EXISTS content_search_moments_update;
        DROP TRIGGER IF EXISTS content_search_moments_delete;

        CREATE TRIGGER content_search_articles_insert
        AFTER INSERT ON articles WHEN new.deleted_at IS NULL BEGIN
            DELETE FROM content_search
            WHERE document_type = 'article' AND document_id = new.slug;
            INSERT INTO content_search(
                document_type, document_id, title, aliases, body, excerpt, tags,
                category, properties, status, created_at, updated_at
            ) VALUES (
                'article', new.slug, new.title,
                COALESCE(
                    json_extract(new.properties_json, '$.aliases.value'),
                    json_extract(new.properties_json, '$.alias.value'),
                    json_extract(new.properties_json, '$.aliases'),
                    json_extract(new.properties_json, '$.alias'),
                    ''
                ),
                new.body, new.excerpt,
                new.tags_json, new.category,
                COALESCE((
                    SELECT group_concat(
                        indexed_property.key || ': ' || CASE indexed_property.type
                            WHEN 'object' THEN COALESCE(json_extract(indexed_property.value, '$.value'), '')
                            ELSE CAST(indexed_property.value AS TEXT)
                        END,
                        ' '
                    )
                    FROM json_each(new.properties_json) AS indexed_property
                ), ''),
                new.status,
                COALESCE(new.published_at, new.updated_at), new.updated_at
            );
        END;
        CREATE TRIGGER content_search_articles_update
        AFTER UPDATE OF slug, title, body, category, excerpt, tags_json, status, properties_json,
                        updated_at, published_at, deleted_at ON articles BEGIN
            DELETE FROM content_search
            WHERE document_type = 'article' AND document_id = old.slug;
            INSERT INTO content_search(
                document_type, document_id, title, aliases, body, excerpt, tags,
                category, properties, status, created_at, updated_at
            )
            SELECT 'article', new.slug, new.title,
                   COALESCE(
                       json_extract(new.properties_json, '$.aliases.value'),
                       json_extract(new.properties_json, '$.alias.value'),
                       json_extract(new.properties_json, '$.aliases'),
                       json_extract(new.properties_json, '$.alias'),
                       ''
                   ),
                   new.body, new.excerpt,
                   new.tags_json, new.category,
                   COALESCE((
                       SELECT group_concat(
                           indexed_property.key || ': ' || CASE indexed_property.type
                               WHEN 'object' THEN COALESCE(json_extract(indexed_property.value, '$.value'), '')
                               ELSE CAST(indexed_property.value AS TEXT)
                           END,
                           ' '
                       )
                       FROM json_each(new.properties_json) AS indexed_property
                   ), ''),
                   new.status,
                   COALESCE(new.published_at, new.updated_at), new.updated_at
            WHERE new.deleted_at IS NULL;
        END;
        CREATE TRIGGER content_search_articles_delete
        AFTER DELETE ON articles BEGIN
            DELETE FROM content_search
            WHERE document_type = 'article' AND document_id = old.slug;
        END;

        CREATE TRIGGER content_search_moments_insert
        AFTER INSERT ON moments WHEN new.deleted_at IS NULL BEGIN
            DELETE FROM content_search
            WHERE document_type = 'moment' AND document_id = new.id;
            INSERT INTO content_search(
                document_type, document_id, title, aliases, body, excerpt, tags,
                category, properties, status, created_at, updated_at
            ) VALUES (
                'moment', new.id,
                CASE WHEN trim(new.text) = '' THEN '媒体微博'
                     ELSE substr(replace(replace(new.text, char(10), ' '), char(13), ' '), 1, 80) END,
                '', new.text, '', COALESCE(new.tags_json, '[]'), '', '{}', '',
                new.created_at, new.updated_at
            );
        END;
        CREATE TRIGGER content_search_moments_update
        AFTER UPDATE OF id, created_at, updated_at, text, tags_json, deleted_at ON moments BEGIN
            DELETE FROM content_search
            WHERE document_type = 'moment' AND document_id = old.id;
            INSERT INTO content_search(
                document_type, document_id, title, aliases, body, excerpt, tags,
                category, properties, status, created_at, updated_at
            )
            SELECT 'moment', new.id,
                   CASE WHEN trim(new.text) = '' THEN '媒体微博'
                        ELSE substr(replace(replace(new.text, char(10), ' '), char(13), ' '), 1, 80) END,
                   '', new.text, '', COALESCE(new.tags_json, '[]'), '', '{}', '',
                   new.created_at, new.updated_at
            WHERE new.deleted_at IS NULL;
        END;
        CREATE TRIGGER content_search_moments_delete
        AFTER DELETE ON moments BEGIN
            DELETE FROM content_search
            WHERE document_type = 'moment' AND document_id = old.id;
        END;
        """)

        let activeCount = try database.integer("""
        SELECT (SELECT COUNT(*) FROM articles WHERE deleted_at IS NULL)
             + (SELECT COUNT(*) FROM moments WHERE deleted_at IS NULL)
        """) ?? 0
        let indexedCount = try database.integer("SELECT COUNT(*) FROM content_search") ?? 0
        let version = try database.text(
            "SELECT value FROM metadata WHERE key = 'content_search_v2'"
        )
        guard version != "properties-v4" || activeCount != indexedCount else { return }

        try database.transaction {
            try database.execute("DELETE FROM content_search")
            try database.execute("""
            INSERT INTO content_search(
                document_type, document_id, title, aliases, body, excerpt, tags,
                category, properties, status, created_at, updated_at
            )
            SELECT 'article', slug, title,
                   COALESCE(
                       json_extract(properties_json, '$.aliases.value'),
                       json_extract(properties_json, '$.alias.value'),
                       json_extract(properties_json, '$.aliases'),
                       json_extract(properties_json, '$.alias'),
                       ''
                   ),
                   body, excerpt, tags_json,
                   category,
                   COALESCE((
                       SELECT group_concat(
                           indexed_property.key || ': ' || CASE indexed_property.type
                               WHEN 'object' THEN COALESCE(json_extract(indexed_property.value, '$.value'), '')
                               ELSE CAST(indexed_property.value AS TEXT)
                           END,
                           ' '
                       )
                       FROM json_each(articles.properties_json) AS indexed_property
                   ), ''),
                   status, COALESCE(published_at, updated_at), updated_at
            FROM articles WHERE deleted_at IS NULL;

            INSERT INTO content_search(
                document_type, document_id, title, aliases, body, excerpt, tags,
                category, properties, status, created_at, updated_at
            )
            SELECT 'moment', id,
                   CASE WHEN trim(text) = '' THEN '媒体微博'
                        ELSE substr(replace(replace(text, char(10), ' '), char(13), ' '), 1, 80) END,
                   '', text, '', COALESCE(tags_json, '[]'), '', '{}', '', created_at, updated_at
            FROM moments WHERE deleted_at IS NULL;

            INSERT OR REPLACE INTO metadata(key, value)
            VALUES('content_search_v2', 'properties-v4');
            """)
        }
    }

    func ensureColumn(
        _ column: String,
        in table: String,
        database: SQLiteDatabase,
        definition: String = "TEXT"
    ) throws {
        var exists = false
        try database.query("PRAGMA table_info(\(table))") { row in
            if row.text(at: 1) == column { exists = true }
        }
        if !exists {
            try database.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
        }
    }

}
