import Foundation

extension LocalBlogStore {
    // MARK: - Moments

    public func listMoments() throws -> [NativeMoment] {
        try prepare()
        return try allMoments(includesHidden: false)
    }

    public func getMoment(id: String) throws -> NativeMoment {
        try prepare()
        guard let moment = try moment(withID: id), permitsContent(isPrivate: moment.isPrivate) else {
            throw NativeStoreError.notFound
        }
        return moment
    }

    public func listMomentPage(
        matching filter: NativeMomentFilter = .all,
        before cursor: NativeMomentCursor? = nil,
        limit: Int = 40
    ) throws -> NativeMomentPage {
        try prepare()
        let pageSize = min(max(limit, 1), 100)
        let batchSize = max(pageSize * 2, 64)
        var scanCursor = cursor
        var matches: [NativeMoment] = []

        while matches.count <= pageSize {
            let batch = try momentCandidates(
                matching: filter,
                before: scanCursor,
                limit: batchSize
            )
            guard !batch.isEmpty else { break }

            for moment in batch {
                if filter.matches(moment) {
                    matches.append(moment)
                    if matches.count > pageSize { break }
                }
                scanCursor = NativeMomentCursor(createdAt: moment.createdAt, id: moment.id)
            }

            if matches.count > pageSize || batch.count < batchSize { break }
        }

        let hasMore = matches.count > pageSize
        let page = Array(matches.prefix(pageSize))
        return NativeMomentPage(
            moments: page,
            nextCursor: hasMore ? page.last.map { NativeMomentCursor(createdAt: $0.createdAt, id: $0.id) } : nil
        )
    }

    public func countMoments(matching filter: NativeMomentFilter = .all) throws -> Int {
        try prepare()
        return try momentCandidateCount(matching: filter)
    }

    public func listMomentFacetRecords() throws -> [NativeMomentFacetRecord] {
        try prepare()
        var order: [String] = []
        var records: [String: (createdAt: String, tags: [String])] = [:]
        try db().query("""
        SELECT moment.id, moment.created_at, tag.tag
        FROM moments AS moment
        LEFT JOIN moment_tags AS tag ON tag.moment_id = moment.id
        WHERE moment.deleted_at IS NULL AND \(contentVisibility("moment.is_private"))
        ORDER BY moment.created_at DESC, moment.id DESC, tag.normalized_tag
        """) { row in
            guard let id = row.text(at: 0), let createdAt = row.text(at: 1) else {
                throw NativeStoreError.fileSystem(NativeLocalization.text("SQLite：微博筛选记录不完整"))
            }
            if records[id] == nil {
                order.append(id)
                records[id] = (createdAt, [])
            }
            if let tag = row.text(at: 2) {
                records[id]?.tags.append(tag)
            }
        }
        return order.compactMap { id in
            records[id].map { NativeMomentFacetRecord(createdAt: $0.createdAt, tags: $0.tags) }
        }
    }

    public func saveMoment(
        text: String,
        textRuns: [NativeMomentTextRun],
        images: [NativeMedia],
        isPrivate: Bool = false
    ) throws -> NativeMoment {
        try prepare()
        let normalizedInput = normalizedMomentText(text, textRuns: textRuns)
        let normalizedText = NativeMomentTag.content(
            from: normalizedInput.text,
            textRuns: normalizedInput.runs
        )
        let normalizedImages = Array(images
            .filter(isSupportedMomentMedia)
            .map(normalizeMedia)
            .prefix(9))
        guard !normalizedText.text.isEmpty || !normalizedImages.isEmpty else {
            throw NativeStoreError.invalidMoment
        }

        let latestCreatedAt = try latestMomentCreatedAt()
        let createdAt = nextTimestamp(after: latestCreatedAt)
        let id = "moment-\(Int(Date().timeIntervalSince1970 * 1_000))-\(UUID().uuidString.lowercased().prefix(8))"
        let saved = NativeMoment(
            createdAt: createdAt,
            id: id,
            images: normalizedImages,
            isFavorite: false,
            tags: normalizedText.tags,
            text: normalizedText.text,
            textRuns: normalizedText.runs,
            updatedAt: createdAt,
            isPrivate: isPrivate
        )

        try db().transaction {
            try insertMoment(saved, into: db())
            try recordActivityEvent(type: "moment_published", at: activityDate(from: createdAt) ?? Date())
        }
        do {
            try writeMomentSidecar(saved)
            try writeActivityEventsAfterMutation()
        } catch {
            markJSONBackupNeedsRebuild()
        }
        return saved
    }

    public func updateMoment(
        id: String,
        text: String,
        textRuns: [NativeMomentTextRun],
        images: [NativeMedia],
        expectedUpdatedAt: String? = nil,
        isPrivate: Bool? = nil
    ) throws -> NativeMoment {
        try prepare()
        let safeID = try requireSafeSegment(id, label: "微博 ID")
        let previous = try getMoment(id: safeID)

        if let expectedUpdatedAt, previous.updatedAt != expectedUpdatedAt { throw NativeStoreError.conflict }
        let normalizedInput = normalizedMomentText(text, textRuns: textRuns)
        let normalizedText = NativeMomentTag.content(
            from: normalizedInput.text,
            textRuns: normalizedInput.runs
        )
        let normalizedImages = Array(images
            .filter(isSupportedMomentMedia)
            .map(normalizeMedia)
            .prefix(9))
        guard !normalizedText.text.isEmpty || !normalizedImages.isEmpty else {
            throw NativeStoreError.invalidMoment
        }

        let updated = NativeMoment(
            commentCount: previous.commentCount,
            createdAt: previous.createdAt,
            id: previous.id,
            images: normalizedImages,
            isFavorite: previous.isFavorite,
            tags: normalizedText.tags,
            text: normalizedText.text,
            textRuns: normalizedText.runs,
            updatedAt: nextTimestamp(after: previous.updatedAt),
            isPrivate: isPrivate ?? previous.isPrivate
        )

        try db().transaction {
            if let expectedUpdatedAt, try moment(withID: safeID)?.updatedAt != expectedUpdatedAt { throw NativeStoreError.conflict }
            try insertMoment(updated, into: db())
            try recordActivityEvent(type: "moment_edited", at: activityDate(from: updated.updatedAt) ?? Date())
        }
        do {
            try writeMomentSidecar(updated)
            try writeActivityEventsAfterMutation()
        } catch {
            markJSONBackupNeedsRebuild()
        }
        try removeUnreferencedMomentImages(previous.images)
        return updated
    }

    public func setMomentFavorite(id: String, isFavorite: Bool) throws -> NativeMoment {
        try prepare()
        let safeID = try requireSafeSegment(id, label: "微博 ID")
        let previous = try getMoment(id: safeID)

        try db().execute(
            "UPDATE moments SET is_favorite = ? WHERE id = ?",
            values: [.integer(isFavorite ? 1 : 0), .text(safeID)]
        )
        let updated = NativeMoment(
            commentCount: previous.commentCount,
            createdAt: previous.createdAt,
            id: previous.id,
            images: previous.images,
            isFavorite: isFavorite,
            tags: previous.tags,
            text: previous.text,
            textRuns: previous.textRuns,
            updatedAt: previous.updatedAt,
            isPrivate: previous.isPrivate
        )
        do {
            try writeMomentSidecar(updated)
        } catch {
            markJSONBackupNeedsRebuild()
        }
        return updated
    }

    public func deleteMoment(id: String, expectedUpdatedAt: String? = nil) throws {
        try prepare()
        let safeID = try requireSafeSegment(id, label: "微博 ID")
        _ = try getMoment(id: safeID)

        let deletedAt = timestamp(from: Date())
        let expiresAt = timestamp(afterDays: Self.trashRetentionDays)
        try db().transaction {
            if let expectedUpdatedAt, try moment(withID: safeID)?.updatedAt != expectedUpdatedAt { throw NativeStoreError.conflict }
            try db().execute(
                "UPDATE moments SET deleted_at = ?, delete_expires_at = ? WHERE id = ?",
                values: [.text(deletedAt), .text(expiresAt), .text(safeID)]
            )
        }
        removeMomentSidecar(id: safeID)
        try writeTrashBackup()
    }

    func removeUnreferencedMomentImages(
        _ images: [NativeMedia],
        includingDeleted: Bool = true
    ) throws {
        try removeUnreferencedMediaFiles(images, includingDeleted: includingDeleted)
    }

    func moment(withID id: String, includingDeleted: Bool = false) throws -> NativeMoment? {
        var result: NativeMoment?
        let whereClause = includingDeleted ? "id = ?" : "deleted_at IS NULL AND id = ?"
        try db().query(
            momentSelect + " WHERE \(whereClause)",
            values: [.text(id)]
        ) { row in
            result = try decodeMoment(row)
        }
        return result
    }

    func allMoments(includingDeleted: Bool = false, includesHidden: Bool = true) throws -> [NativeMoment] {
        var moments: [NativeMoment] = []
        let active = includingDeleted ? "1" : "deleted_at IS NULL"
        let whereClause = "WHERE \(active) AND \(includesHidden ? "1" : contentVisibility())"
        try db().query(momentSelect + " \(whereClause) ORDER BY created_at DESC, id DESC") { row in
            moments.append(try decodeMoment(row))
        }
        return moments
    }

    private func latestMomentCreatedAt() throws -> String? {
        try db().text("SELECT MAX(created_at) FROM moments WHERE deleted_at IS NULL")
    }

    private func momentCandidates(
        matching filter: NativeMomentFilter,
        before cursor: NativeMomentCursor?,
        limit: Int
    ) throws -> [NativeMoment] {
        let query = momentCandidateQuery(matching: filter, before: cursor)
        var moments: [NativeMoment] = []
        var values = query.values
        values.append(.integer(limit))
        try db().query(
            """
            \(momentSelect)
            WHERE \(query.whereClause)
            ORDER BY created_at DESC, id DESC
            LIMIT ?
            """,
            values: values
        ) { row in
            moments.append(try decodeMoment(row))
        }
        return moments
    }

    private func momentCandidateCount(matching filter: NativeMomentFilter) throws -> Int {
        let query = momentCandidateQuery(matching: filter, before: nil)
        return try db().integer(
            "SELECT COUNT(*) FROM moments WHERE \(query.whereClause)",
            values: query.values
        ) ?? 0
    }

    func momentCandidateQuery(
        matching filter: NativeMomentFilter,
        before cursor: NativeMomentCursor?
    ) -> (whereClause: String, values: [SQLiteValue]) {
        var predicates = ["deleted_at IS NULL", contentVisibility()]
        var values: [SQLiteValue] = []

        if filter.favoritesOnly {
            predicates.append("is_favorite = 1")
        }

        if let interval = momentDateInterval(for: filter.dateFilter) {
            predicates.append("created_at >= ?")
            values.append(.text(NativeTimestamp.string(from: interval.start)))
            predicates.append("created_at < ?")
            values.append(.text(NativeTimestamp.string(from: interval.end)))
        }

        if !filter.tags.isEmpty {
            let tagPredicates = filter.tags.map { _ in """
            EXISTS (
                SELECT 1 FROM moment_tags AS selected_moment_tag
                WHERE selected_moment_tag.moment_id = moments.id
                  AND selected_moment_tag.normalized_tag = ?
            )
            """ }
            predicates.append("(\(tagPredicates.joined(separator: " OR ")))")
            values.append(contentsOf: filter.tags.map { tag in
                .text(normalizedSearchIdentity(tag))
            })
        }

        if !filter.searchText.isEmpty {
            let search = momentSearchPredicate(filter.searchText)
            predicates.append(search.sql)
            values.append(contentsOf: search.values)
        }

        if let cursor {
            // A tuple comparison lets SQLite seek directly into the feed index.
            predicates.append("(created_at, id) < (?, ?)")
            values.append(.text(cursor.createdAt))
            values.append(.text(cursor.id))
        }

        return (predicates.joined(separator: " AND "), values)
    }

    private func momentSearchPredicate(
        _ rawQuery: String
    ) -> (sql: String, values: [SQLiteValue]) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if isDateLikeMomentSearch(query) {
            let year = "CAST(substr(created_at, 1, 4) AS INTEGER)"
            let month = "CAST(substr(created_at, 6, 2) AS INTEGER)"
            let day = "CAST(substr(created_at, 9, 2) AS INTEGER)"
            return (
                """
                (instr(lower(text), lower(?)) > 0
                 OR instr(lower(tags_json), lower(?)) > 0
                 OR instr(lower(created_at), lower(?)) > 0
                 OR instr(\(year) || '-' || \(month) || '-' || \(day), ?) > 0
                 OR instr(\(year) || '/' || \(month) || '/' || \(day), ?) > 0
                 OR instr(\(year) || '年' || \(month) || '月' || \(day) || '日', ?) > 0)
                """,
                Array(repeating: .text(query), count: 6)
            )
        }

        if query.count >= 3 {
            let expression = "\"\(query.replacingOccurrences(of: "\"", with: "\"\""))\""
            return (
                """
                id IN (
                    SELECT document_id
                    FROM content_search
                    WHERE content_search MATCH ? AND document_type = 'moment'
                )
                """,
                [.text(expression)]
            )
        }

        if let token = shortSearchToken(for: query) {
            return (
                """
                id IN (
                    SELECT document_id
                    FROM content_short_search
                    WHERE content_short_search MATCH ? AND document_type = 'moment'
                )
                """,
                [.text("\"\(token.replacingOccurrences(of: "\"", with: "\"\""))\"")]
            )
        }

        return ("instr(lower(created_at), lower(?)) > 0", [.text(query)])
    }

    private func isDateLikeMomentSearch(_ query: String) -> Bool {
        !query.isEmpty && query.allSatisfy { character in
            character.isNumber || "-/年月日".contains(character)
        }
    }

    private func momentDateInterval(for filter: NativeMomentDateFilter) -> DateInterval? {
        let calendar = Calendar.current
        let now = Date()
        switch filter {
        case .all:
            return nil
        case .today:
            guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
                return nil
            }
            return DateInterval(start: calendar.startOfDay(for: now), end: end)
        case .thisWeek:
            return calendar.dateInterval(of: .weekOfYear, for: now)
        case let .month(year, month):
            guard let start = calendar.date(from: DateComponents(year: year, month: month)),
                  let end = calendar.date(byAdding: .month, value: 1, to: start) else {
                return nil
            }
            return DateInterval(start: start, end: end)
        case let .year(year):
            guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let end = calendar.date(byAdding: .year, value: 1, to: start) else {
                return nil
            }
            return DateInterval(start: start, end: end)
        }
    }

    func insertMoment(
        _ moment: NativeMoment,
        deletedAt: String? = nil,
        deleteExpiresAt: String? = nil,
        into database: SQLiteDatabase
    ) throws {
        try database.execute("""
        INSERT INTO moments(id, created_at, updated_at, text, text_runs_json, images_json, tags_json, is_favorite, deleted_at, delete_expires_at, is_private)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            created_at = excluded.created_at,
            updated_at = excluded.updated_at,
            text = excluded.text,
            text_runs_json = excluded.text_runs_json,
            images_json = excluded.images_json,
            tags_json = excluded.tags_json,
            is_favorite = excluded.is_favorite,
            deleted_at = excluded.deleted_at,
            delete_expires_at = excluded.delete_expires_at,
            is_private = excluded.is_private
        """, values: [
            .text(moment.id),
            .text(moment.createdAt),
            .text(moment.updatedAt),
            .text(moment.text),
            .text(try jsonString(moment.textRuns)),
            .text(try jsonString(moment.images)),
            .text(try jsonString(moment.tags)),
            .integer(moment.isFavorite ? 1 : 0),
            deletedAt.map(SQLiteValue.text) ?? .null,
            deleteExpiresAt.map(SQLiteValue.text) ?? .null,
            .integer(moment.isPrivate ? 1 : 0),
        ])
        try replaceShortSearchDocument(
            type: "moment",
            id: moment.id,
            source: [moment.text, moment.tags.joined(separator: " "), moment.createdAt],
            isActive: deletedAt == nil,
            in: database
        )
        try replaceMomentFilterIndexes(moment, isActive: deletedAt == nil, in: database)
        try replaceMediaReferences(
            ownerType: "moment",
            ownerID: moment.id,
            urls: moment.images.map(\.url),
            in: database
        )
    }

    func decodeMoment(_ row: SQLiteRow) throws -> NativeMoment {
        guard let id = row.text(at: 0),
              let createdAt = row.text(at: 1),
              let updatedAt = row.text(at: 2),
              let text = row.text(at: 3),
              let textRunsJSON = row.text(at: 4),
              let imagesJSON = row.text(at: 5) else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("SQLite：动态记录不完整"))
        }
        let tags: [String]
        if let tagsJSON = row.text(at: 6) {
            tags = try decode(tagsJSON)
        } else {
            tags = NativeMomentTag.extract(from: text)
        }
        let isFavorite = row.integer(at: 7) == 1
        return NativeMoment(
            commentCount: row.integer(at: 10) ?? 0,
            createdAt: createdAt,
            id: id,
            images: try decode(imagesJSON),
            isFavorite: isFavorite,
            tags: tags,
            text: text,
            textRuns: try decode(textRunsJSON),
            updatedAt: updatedAt,
            isPrivate: row.integer(at: 11) == 1
        )
    }

    func rebuildMomentsIndex() throws {
        let moments = try allMoments()
        for moment in moments {
            try writeMomentSidecar(moment)
        }
        try Data().write(to: momentSidecarsMarkerURL, options: .atomic)
        try writeJSON(moments, to: momentsIndexURL)
    }

    func writeMomentSidecar(_ moment: NativeMoment) throws {
        let safeID = try requireSafeSegment(moment.id, label: "微博 ID")
        try writeJSON(moment, to: momentsURL.appendingPathComponent("\(safeID).json"))
        if !FileManager.default.fileExists(atPath: momentSidecarsMarkerURL.path) {
            try Data().write(to: momentSidecarsMarkerURL, options: .atomic)
        }
    }

    func removeMomentSidecar(id: String) {
        guard let safeID = try? requireSafeSegment(id, label: "微博 ID") else { return }
        try? FileManager.default.removeItem(at: momentsURL.appendingPathComponent("\(safeID).json"))
    }

    func readMoment(at url: URL) throws -> NativeMoment {
        do {
            return try JSONDecoder().decode(NativeMoment.self, from: Data(contentsOf: url))
        } catch {
            throw NativeStoreError.fileSystem(NativeLocalization.text("无法读取 \(url.lastPathComponent)：\(error.localizedDescription)"))
        }
    }

    private func isSupportedMomentMedia(_ media: NativeMedia) -> Bool {
        guard !media.url.isEmpty else { return false }
        if media.isImage { return true }
        if media.isAudio {
            return (media.url as NSString).pathExtension.caseInsensitiveCompare("mp3") == .orderedSame
        }
        return media.isVideo
            && (media.url as NSString).pathExtension.caseInsensitiveCompare("mp4") == .orderedSame
    }

    private func normalizedMomentText(
        _ text: String,
        textRuns: [NativeMomentTextRun]
    ) -> (text: String, runs: [NativeMomentTextRun]) {
        let characters = Array(text)
        let leadingWhitespace = characters.prefix { $0.isWhitespace }.count
        let trailingWhitespace = characters.reversed().prefix { $0.isWhitespace }.count
        let availableCount = max(0, characters.count - leadingWhitespace - trailingWhitespace)
        let retainedCount = min(NativeMoment.maximumTextLength, availableCount)
        let normalizedText = String(characters.dropFirst(leadingWhitespace).prefix(retainedCount))

        guard !normalizedText.isEmpty, textRuns.map(\.text).joined() == text else {
            return normalizedText.isEmpty ? ("", []) : (normalizedText, [
                NativeMomentTextRun(text: normalizedText, bold: false, color: nil),
            ])
        }

        var position = 0
        var remaining = retainedCount
        var normalizedRuns: [NativeMomentTextRun] = []
        for run in textRuns where remaining > 0 {
            let runCharacters = Array(run.text)
            let runStart = position
            let runEnd = position + runCharacters.count
            position = runEnd

            let selectionStart = max(leadingWhitespace, runStart)
            let selectionEnd = min(leadingWhitespace + retainedCount, runEnd)
            guard selectionStart < selectionEnd else { continue }

            let startOffset = selectionStart - runStart
            let length = selectionEnd - selectionStart
            let segment = String(runCharacters.dropFirst(startOffset).prefix(length))
            appendMomentTextRun(
                run.replacingText(segment),
                to: &normalizedRuns
            )
            remaining -= length
        }

        return normalizedRuns.map(\.text).joined() == normalizedText
            ? (normalizedText, normalizedRuns)
            : (normalizedText, [NativeMomentTextRun(text: normalizedText, bold: false, color: nil)])
    }

    private func appendMomentTextRun(_ run: NativeMomentTextRun, to runs: inout [NativeMomentTextRun]) {
        guard !run.text.isEmpty else { return }
        guard let previous = runs.last,
              previous.hasSameStyle(as: run) else {
            runs.append(run)
            return
        }
        runs[runs.count - 1] = run.replacingText(previous.text + run.text)
    }
}
