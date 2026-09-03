import SwiftUI

struct SmartCollectionBoardView: View {
    @ObservedObject var model: NativeAppModel
    let articles: [NativeArticleSummary]
    let groupBy: NativeArticleGroupField
    let onChangeGroupBy: (NativeArticleGroupField) -> Void

    private var effectiveGroupBy: NativeArticleGroupField {
        groupBy == .none ? .status : groupBy
    }

    private var lanes: [BoardLane] {
        var values: [String: [NativeArticleSummary]] = [:]
        for article in articles {
            values[effectiveGroupBy.label(for: article), default: []].append(article)
        }
        let labels: [String]
        if effectiveGroupBy == .status {
            labels = [NativeArticleStatus.draft.label, NativeArticleStatus.published.label]
                + values.keys.filter {
                    $0 != NativeArticleStatus.draft.label && $0 != NativeArticleStatus.published.label
                }.sorted()
        } else {
            labels = values.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        return labels.map { BoardLane(label: $0, articles: values[$0, default: []]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("按").foregroundStyle(.secondary)
                Menu {
                    ForEach([NativeArticleGroupField.status, .category, .tag], id: \.self) { field in
                        Button {
                            onChangeGroupBy(field)
                        } label: {
                            Label(
                                LocalizedStringKey(field.label),
                                systemImage: effectiveGroupBy == field ? "checkmark" : "rectangle.3.group"
                            )
                        }
                    }
                } label: {
                    Label(LocalizedStringKey(effectiveGroupBy.label), systemImage: "rectangle.3.group")
                }
                Text("分组；拖动卡片即可修改对应字段。")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 22)
            .padding(.top, 12)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(lanes) { lane in
                        BoardLaneColumn(
                            model: model,
                            allArticles: articles,
                            lane: lane,
                            groupBy: effectiveGroupBy
                        )
                    }
                }
                .padding(20)
            }
        }
    }

}

private struct BoardLane: Identifiable {
    let label: String
    let articles: [NativeArticleSummary]
    var id: String { label }
}

private struct BoardLaneColumn: View {
    @ObservedObject var model: NativeAppModel
    let allArticles: [NativeArticleSummary]
    let lane: BoardLane
    let groupBy: NativeArticleGroupField

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(lane.label).font(.headline)
                Text("\(lane.articles.count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Spacer()
                Button {
                    model.newArticle(inBoardGroup: lane.label, field: groupBy)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .disabled(model.isMarkdownSourceReadOnly)
                .help("在“\(lane.label)”中新建页面")
            }

            LazyVStack(spacing: 10) {
                ForEach(lane.articles) { article in
                    BoardArticleCard(model: model, article: article)
                        .draggable(article.slug)
                }
                if lane.articles.isEmpty {
                    Text("拖动页面到这里")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 72)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 272, alignment: .topLeading)
        .frame(minHeight: 320, alignment: .topLeading)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
        .dropDestination(for: String.self) { slugs, _ in handleDrop(slugs) }
    }

    private func handleDrop(_ slugs: [String]) -> Bool {
        let droppedArticles = allArticles.filter { slugs.contains($0.slug) }
        for article in droppedArticles {
            model.moveArticle(article, toGroup: lane.label, field: groupBy)
        }
        return !droppedArticles.isEmpty
    }
}

private struct BoardArticleCard: View {
    @ObservedObject var model: NativeAppModel
    let article: NativeArticleSummary

    var body: some View {
        Button { model.selectSlug(article.slug) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(article.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if !article.excerpt.isEmpty {
                    Text(article.excerpt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack {
                    Label(article.category, systemImage: "folder")
                    Spacer()
                    Text(article.updatedAt.nativeDateLabel)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.14)) }
        }
        .buttonStyle(.plain)
    }
}

struct SmartCollectionCalendarView: View {
    @ObservedObject var model: NativeAppModel
    let articles: [NativeArticleSummary]
    let collection: NativeSmartCollection?
    @AppStorage("articleLibraryCalendarDateProperty") private var allArticlesDatePropertyKey = ""
    @State private var displayedMonth = Calendar.current.date(
        from: Calendar.current.dateComponents([.year, .month], from: Date())
    ) ?? Date()

    private let calendar = Calendar.current

    private var datePropertyKey: String? {
        if let collection { return collection.calendarDatePropertyKey }
        let value = allArticlesDatePropertyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private var availableDatePropertyKeys: [String] {
        var keys: [String] = []
        func append(_ key: String) {
            guard !key.isEmpty,
                  !keys.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) else { return }
            keys.append(key)
        }
        collection?.columns
            .filter { $0.source == .property && $0.propertyKind == .date }
            .forEach { append($0.key) }
        for article in articles {
            for (key, value) in article.properties where value.kind == .date { append(key) }
        }
        if let datePropertyKey { append(datePropertyKey) }
        return keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var unscheduledArticles: [NativeArticleSummary] {
        guard datePropertyKey != nil else { return [] }
        return articles.filter { articleDate(for: $0) == nil }
    }

    private var monthTitle: String {
        displayedMonth.formatted(.dateTime.year().month(.wide))
    }

    private var days: [CalendarDay] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth),
              let gridStart = calendar.dateInterval(of: .weekOfMonth, for: monthInterval.start)?.start else {
            return []
        }
        return (0..<42).compactMap { offset -> CalendarDay? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: gridStart) else { return nil }
            let dayArticles = articles.filter {
                guard let articleDate = articleDate(for: $0) else { return false }
                return calendar.isDate(articleDate, inSameDayAs: date)
            }
            return CalendarDay(
                date: date,
                isInDisplayedMonth: calendar.isDate(date, equalTo: displayedMonth, toGranularity: .month),
                articles: dayArticles
            )
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                    Button("今天") {
                        displayedMonth = calendar.date(
                            from: calendar.dateComponents([.year, .month], from: Date())
                        ) ?? Date()
                    }
                    Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                    Text(monthTitle).font(.title3.weight(.semibold))
                    Spacer()
                    Menu {
                        Button {
                            setDateProperty(nil)
                        } label: {
                            Label("更新时间", systemImage: datePropertyKey == nil ? "checkmark" : "clock")
                        }
                        if !availableDatePropertyKeys.isEmpty { Divider() }
                        ForEach(availableDatePropertyKeys, id: \.self) { key in
                            Button {
                                setDateProperty(key)
                            } label: {
                                Label(key, systemImage: datePropertyKey == key ? "checkmark" : "calendar")
                            }
                        }
                    } label: {
                        Label {
                            if let datePropertyKey {
                                Text(datePropertyKey)
                            } else {
                                Text("更新时间")
                            }
                        } icon: {
                            Image(systemName: "calendar.badge.clock")
                        }
                    }
                    .help("选择日历使用的日期属性")
                }

                if datePropertyKey != nil {
                    HStack(spacing: 8) {
                        Label("未排期 \(unscheduledArticles.count)", systemImage: "tray")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal) {
                            HStack(spacing: 6) {
                                if unscheduledArticles.isEmpty {
                                    Text("拖到这里可清除日期")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                ForEach(unscheduledArticles) { article in
                                    Button(article.title) { model.selectSlug(article.slug) }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .draggable(article.slug)
                                }
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                    .dropDestination(for: String.self) { slugs, _ in
                        guard let datePropertyKey else { return false }
                        let dropped = articles.filter { slugs.contains($0.slug) }
                        for article in dropped {
                            model.updateArticleProperty(
                                article: article,
                                key: datePropertyKey,
                                kind: .date,
                                text: ""
                            )
                        }
                        return !dropped.isEmpty
                    }
                    .help("把日历卡片拖到这里可清除日期")
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 8) {
                    ForEach(calendar.veryShortWeekdaySymbols, id: \.self) { weekday in
                        Text(weekday)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }

                    ForEach(days) { day in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(day.date.formatted(.dateTime.day()))
                                    .font(.caption.weight(calendar.isDateInToday(day.date) ? .bold : .regular))
                                    .foregroundStyle(day.isInDisplayedMonth ? .primary : .tertiary)
                                Spacer()
                                Button {
                                    model.newArticle(
                                        onCalendarDate: dateString(for: day.date),
                                        propertyKey: datePropertyKey
                                    )
                                } label: {
                                    Image(systemName: "plus")
                                }
                                .buttonStyle(.plain)
                                .disabled(model.isMarkdownSourceReadOnly)
                                .help("在这一天新建页面")
                            }
                            ForEach(day.articles.prefix(4)) { article in
                                Button(article.title) { model.selectSlug(article.slug) }
                                    .buttonStyle(.plain)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                                    .draggable(article.slug)
                            }
                            if day.articles.count > 4 {
                                Text("另有 \(day.articles.count - 4) 篇")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(7)
                        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                        .background(
                            day.isInDisplayedMonth ? Color(nsColor: .controlBackgroundColor) : Color.secondary.opacity(0.025),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.12)) }
                        .dropDestination(for: String.self) { slugs, _ in
                            guard let datePropertyKey else { return false }
                            let value = dateString(for: day.date)
                            for slug in slugs {
                                guard let article = articles.first(where: { $0.slug == slug }) else { continue }
                                model.updateArticleProperty(
                                    article: article,
                                    key: datePropertyKey,
                                    kind: .date,
                                    text: value
                                )
                            }
                            return !slugs.isEmpty
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func articleDate(for article: NativeArticleSummary) -> Date? {
        if let datePropertyKey {
            guard let value = article.properties.first(where: {
                $0.key.caseInsensitiveCompare(datePropertyKey) == .orderedSame
            })?.value.value else { return nil }
            return NativeTimestamp.date(from: value)
        }
        return NativeTimestamp.date(from: article.updatedAt)
    }

    private func setDateProperty(_ key: String?) {
        if collection == nil {
            allArticlesDatePropertyKey = key ?? ""
        } else {
            model.setSmartCollectionCalendarDateProperty(key)
        }
    }

    private func shiftMonth(_ amount: Int) {
        displayedMonth = calendar.date(byAdding: .month, value: amount, to: displayedMonth) ?? displayedMonth
    }

    private func dateString(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

private struct CalendarDay: Identifiable {
    let date: Date
    let isInDisplayedMonth: Bool
    let articles: [NativeArticleSummary]
    var id: Date { date }
}
