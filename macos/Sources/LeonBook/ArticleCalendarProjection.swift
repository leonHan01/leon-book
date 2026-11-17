import Foundation

/// A value snapshot keeps calendar grouping independent of unrelated model
/// publications and of the month currently shown by the view.
struct NativeArticleCalendarSnapshot: Equatable, @unchecked Sendable {
    let articles: [NativeArticleSummary]
    let datePropertyKey: String?
    let calendar: Calendar
}

struct NativeArticleCalendarDay: Identifiable {
    let date: Date
    let isInDisplayedMonth: Bool
    let articles: [NativeArticleSummary]
    var id: Date { date }
}

struct NativeArticleCalendarProjection: @unchecked Sendable {
    private var articlesByDay: [Date: [NativeArticleSummary]] = [:]
    private(set) var unscheduledArticles: [NativeArticleSummary] = []
    private(set) var availableDatePropertyKeys: [String] = []

    init() {}

    init(snapshot: NativeArticleCalendarSnapshot) {
        var keysByIdentity: [String: String] = [:]
        func rememberKey(_ key: String) {
            guard !key.isEmpty else { return }
            let identity = key.folding(options: [.caseInsensitive], locale: .current)
            if keysByIdentity[identity] == nil { keysByIdentity[identity] = key }
        }
        for (index, article) in snapshot.articles.enumerated() {
            if index.isMultiple(of: 256), Task.isCancelled { return }
            for (key, value) in article.properties where value.kind == .date { rememberKey(key) }
            let date: Date?
            if let key = snapshot.datePropertyKey {
                date = article.properties.first {
                    $0.key.caseInsensitiveCompare(key) == .orderedSame
                }.flatMap { Self.propertyDate($0.value.value, timeZone: snapshot.calendar.timeZone) }
            } else {
                date = NativeTimestamp.date(from: article.updatedAt)
            }
            if let date {
                articlesByDay[snapshot.calendar.startOfDay(for: date), default: []].append(article)
            } else if snapshot.datePropertyKey != nil {
                unscheduledArticles.append(article)
            }
        }
        if let key = snapshot.datePropertyKey { rememberKey(key) }
        availableDatePropertyKeys = keysByIdentity.values.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    func days(in month: Date, calendar: Calendar) -> [NativeArticleCalendarDay] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: month),
              let start = calendar.dateInterval(of: .weekOfMonth, for: monthInterval.start)?.start else {
            return []
        }
        return (0..<42).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return NativeArticleCalendarDay(
                date: date,
                isInDisplayedMonth: calendar.isDate(date, equalTo: month, toGranularity: .month),
                articles: articlesByDay[calendar.startOfDay(for: date), default: []]
            )
        }
    }

    /// Properties are Gregorian civil dates, not UTC timestamps. Constructing
    /// them in the displayed time zone avoids shifting cards to the prior day.
    static func propertyDate(_ value: String, timeZone: TimeZone) -> Date? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard components.year == year, components.month == month, components.day == day else { return nil }
        return date
    }

    static func propertyDateString(for date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
