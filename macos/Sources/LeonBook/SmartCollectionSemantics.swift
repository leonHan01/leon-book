import Foundation

/// Canonical smart-collection meaning shared by persistence and execution
/// adapters. Adapter-specific details, such as SQLite column names, stay local.
enum NativeSmartCollectionSemantics {
    static func baseReference(for field: NativeSmartCollectionField) -> String? {
        switch field {
        case .title: return "file.name"
        case .content: return "note.excerpt"
        case .status: return "note.status"
        case .category: return "note.category"
        case .tag: return "note.tags"
        case .property: return nil
        case .updatedAt: return "file.mtime"
        case .publishedAt: return "note.publishedAt"
        case .wordCount: return "note.wordCount"
        case .pageViews: return "note.pageViews"
        case .sourcePath: return "file.path"
        }
    }

    static func baseReference(for field: NativeArticleSortField) -> String {
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

    static func baseReference(for field: NativeArticleGroupField) -> String {
        switch field {
        case .status: return "note.status"
        case .category: return "note.category"
        case .tag: return "note.tags"
        case .updatedMonth: return "file.mtime"
        case .none: return "file.name"
        }
    }

    static func normalizedText(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    static func date(from source: String) -> Date? {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = NativeTimestamp.date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}
