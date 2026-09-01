import Foundation

enum NativeArticleDraftPrefill {
    @discardableResult
    static func applyBoardGroup(
        label: String,
        field: NativeArticleGroupField,
        to draft: inout NativeEditorDraft
    ) -> Bool {
        switch field {
        case .status:
            if label == NativeArticleStatus.published.label || label == NativeArticleStatus.published.rawValue {
                draft.status = .published
                return true
            }
            if label == NativeArticleStatus.draft.label || label == NativeArticleStatus.draft.rawValue {
                draft.status = .draft
                return true
            }
            return false
        case .category:
            draft.category = label == "未分类" ? "Notes" : label
            return true
        case .tag:
            if label == "无标签" {
                draft.tags = ""
            } else {
                draft.tags = label.trimmingCharacters(in: CharacterSet(charactersIn: "#＃"))
            }
            return true
        case .none, .updatedMonth:
            return false
        }
    }

    @discardableResult
    static func applyCalendarDate(
        _ value: String,
        propertyKey: String?,
        to draft: inout NativeEditorDraft
    ) -> Bool {
        guard let propertyKey else { return false }
        let key = propertyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NativeArticleProperties.isValidKey(key) else { return false }
        let date = NativeArticlePropertyValue.date(value)
        guard date.isValid else { return false }
        draft.properties[key] = date
        return true
    }
}
