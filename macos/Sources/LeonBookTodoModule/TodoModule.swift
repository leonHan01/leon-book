import Foundation
import LeonBookModuleKit

public enum TodoFirstPartyModule: FirstPartyModule {
    public static let id = FirstPartyModuleID(rawValue: "todo")
    public static let descriptor = FirstPartyModuleDescriptor(
        id: id, name: "待办", summary: "管理任务、优先级和截止日期，记录完成进度。", systemImage: "checklist",
        permissions: [.contentRead, .contentWrite],
        commands: [
            .init(id: "navigation.todos", title: "前往待办", detail: "查看和管理 TODO list", keywords: "todo task checklist 待办 任务", systemImage: "checklist", requiredPermissions: [.contentRead]),
            .init(id: "todo.new", title: "新建待办", detail: "快速添加一项待办任务", keywords: "todo task add 新建 待办", systemImage: "plus.circle", availability: .storageReadyAndIdle, requiredPermissions: [.contentWrite]),
        ],
        eventNames: ["todo.opened", "todo.created", "todo.updated", "todo.completed", "todo.reopened", "todo.deleted", "todo.restored"]
    )
}

public enum TodoPriority: Int, Codable, CaseIterable, Identifiable, Sendable {
    case low = 0, normal = 1, high = 2
    public var id: Int { rawValue }
    public var label: String {
        switch self { case .low: return "低优先级"; case .normal: return "普通优先级"; case .high: return "高优先级" }
    }
}

public enum TodoFilter: String, CaseIterable, Identifiable, Sendable {
    case open, today, overdue, all, completed
    public var id: String { rawValue }
    public var label: String {
        switch self { case .open: return "待完成"; case .today: return "今天"; case .overdue: return "已逾期"; case .all: return "全部"; case .completed: return "已完成" }
    }
}

public enum TodoError: LocalizedError {
    case invalidTitle, invalidNotes, invalidDueDay, conflict, notFound
    public var errorDescription: String? {
        switch self {
        case .invalidTitle: return "待办标题需要 1 到 200 个字符。"
        case .invalidNotes: return "待办备注最多 5000 个字符。"
        case .invalidDueDay: return "请选择有效的截止日期。"
        case .conflict: return "这项待办已在其他窗口中更新，请根据最新内容重新操作。"
        case .notFound: return "这项待办已不存在。"
        }
    }
}

public struct TodoDraft: Equatable, Sendable {
    public var title: String
    public var notes: String
    public var priority: TodoPriority
    public var dueDay: String?

    public init(title: String = "", notes: String = "", priority: TodoPriority = .normal, dueDay: String? = nil) {
        self.title = title; self.notes = notes; self.priority = priority; self.dueDay = dueDay
    }

    public func validated() throws -> Self {
        var result = self
        result.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        result.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...200).contains(result.title.count) else { throw TodoError.invalidTitle }
        guard result.notes.count <= 5_000 else { throw TodoError.invalidNotes }
        if let dueDay {
            guard TodoDay.isValid(dueDay) else { throw TodoError.invalidDueDay }
        }
        return result
    }
}

public struct TodoItem: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let notes: String
    public let priority: TodoPriority
    public let dueDay: String?
    public let completedAt: String?
    public let createdAt: String
    public let updatedAt: String
    public let revision: Int
    public let deletedAt: String?

    public init(id: String, title: String, notes: String = "", priority: TodoPriority = .normal, dueDay: String? = nil, completedAt: String? = nil, createdAt: String, updatedAt: String, revision: Int = 1, deletedAt: String? = nil) {
        self.id = id; self.title = title; self.notes = notes; self.priority = priority; self.dueDay = dueDay
        self.completedAt = completedAt; self.createdAt = createdAt; self.updatedAt = updatedAt; self.revision = revision; self.deletedAt = deletedAt
    }
    public var isCompleted: Bool { completedAt != nil }
    public var draft: TodoDraft { .init(title: title, notes: notes, priority: priority, dueDay: dueDay) }
    public func isOverdue(today: String) -> Bool { !isCompleted && dueDay.map { $0 < today } == true }
}

/// Due dates are Gregorian calendar days, rather than UTC instants. Changing
/// time zone must not move a task's chosen due date to the preceding day.
public enum TodoDay {
    private static func gregorian(_ calendar: Calendar) -> Calendar {
        var result = Calendar(identifier: .gregorian); result.timeZone = calendar.timeZone; return result
    }
    public static func string(from date: Date, calendar: Calendar = .current) -> String {
        let parts = gregorian(calendar).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    public static func date(from day: String, calendar: Calendar = .current) -> Date? {
        guard day.utf8.count == 10, day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...9999).contains(parts[0]) else { return nil }
        let calendar = gregorian(calendar)
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)), string(from: date, calendar: calendar) == day else { return nil }
        return date
    }
    public static func isValid(_ day: String) -> Bool {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return date(from: day, calendar: calendar) != nil
    }
}

public struct TodoListProjection: Sendable {
    public let items: [TodoItem]
    public let openCount: Int
    public let completedCount: Int
    public let todayCount: Int
    public let overdueCount: Int

    public init(items source: [TodoItem], filter: TodoFilter = .open, search: String = "", today: String = TodoDay.string(from: Date())) {
        let active = source.filter { $0.deletedAt == nil }
        openCount = active.filter { !$0.isCompleted }.count
        completedCount = active.count - openCount
        todayCount = active.filter { !$0.isCompleted && $0.dueDay == today }.count
        overdueCount = active.filter { $0.isOverdue(today: today) }.count
        let terms = Self.fold(search).split(whereSeparator: \.isWhitespace).map(String.init)
        items = active.filter { item in
            let matches: Bool
            switch filter {
            case .all: matches = true
            case .open: matches = !item.isCompleted
            case .completed: matches = item.isCompleted
            case .today: matches = !item.isCompleted && item.dueDay == today
            case .overdue: matches = item.isOverdue(today: today)
            }
            guard matches else { return false }
            let text = Self.fold(item.title + "\n" + item.notes)
            return terms.allSatisfy { text.contains($0) }
        }.sorted { left, right in
            if left.isCompleted != right.isCompleted { return !left.isCompleted }
            if left.isCompleted {
                if left.completedAt != right.completedAt { return (left.completedAt ?? "") > (right.completedAt ?? "") }
            } else {
                if left.dueDay != right.dueDay { return (left.dueDay ?? "9999-99-99") < (right.dueDay ?? "9999-99-99") }
                if left.priority != right.priority { return left.priority.rawValue > right.priority.rawValue }
            }
            if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
            return left.id < right.id
        }
    }
    private static func fold(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
}
