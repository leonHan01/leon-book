import AppKit
import Foundation

struct EditorArticleLinkSuggestion: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let reference: String

    static func article(_ article: NativeArticleSummary) -> Self {
        Self(
            id: "article:\(article.slug)",
            title: article.title,
            detail: "\(article.category) · \(article.slug)",
            systemImage: "doc.text.fill",
            reference: article.title
        )
    }
}

struct EditorBlockLinkQuery: Equatable {
    let target: String
    let searchText: String

    init?(_ query: String) {
        guard let separator = query.range(of: "#^", options: .backwards) else { return nil }
        target = String(query[..<separator.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        searchText = String(query[separator.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class ArticleLinkAutocompleteController: ObservableObject {
    private weak var textView: NSTextView?
    @Published private(set) var activeLinkQuery: String?

    func attach(to textView: NSTextView) {
        self.textView = textView
    }

    func completeSuggestion(_ suggestion: EditorArticleLinkSuggestion) {
        guard let textView,
              !textView.hasMarkedText(),
              let context = linkContext(in: textView.string, selectedRange: textView.selectedRange()) else {
            return
        }

        let replacement = "[[\(suggestion.reference)]]"
        guard textView.shouldChangeText(in: context.range, replacementString: replacement) else { return }
        textView.textStorage?.replaceCharacters(in: context.range, with: replacement)
        let cursor = context.range.location + (replacement as NSString).length
        textView.setSelectedRange(NSRange(location: cursor, length: 0))
        textView.didChangeText()
        activeLinkQuery = nil
        textView.window?.makeFirstResponder(textView)
    }

    func dismissSuggestions() {
        if activeLinkQuery != nil { activeLinkQuery = nil }
    }

    func updateLinkQuery(from textView: NSTextView) {
        let query = textView.hasMarkedText() ? nil
            : linkContext(in: textView.string, selectedRange: textView.selectedRange())?.query
        if activeLinkQuery != query { activeLinkQuery = query }
    }

    func linkContext(in text: String, selectedRange: NSRange) -> (range: NSRange, query: String)? {
        guard selectedRange.length == 0, selectedRange.location >= 0 else { return nil }
        let source = text as NSString
        guard selectedRange.location <= source.length else { return nil }
        // Wiki-link queries cannot cross a newline. Search only this line and
        // avoid copying or scanning the document prefix on every caret move.
        let line = source.lineRange(for: NSRange(location: selectedRange.location, length: 0))
        let prefixRange = NSRange(location: line.location, length: selectedRange.location - line.location)
        let opening = source.range(of: "[[", options: .backwards, range: prefixRange)
        guard opening.location != NSNotFound else { return nil }

        let queryRange = NSRange(
            location: opening.location + opening.length,
            length: selectedRange.location - opening.location - opening.length
        )
        let query = source.substring(with: queryRange)
        guard !query.contains("["),
              !query.contains("]"),
              !query.contains(where: { $0.isNewline }) else {
            return nil
        }
        return (NSRange(location: opening.location, length: selectedRange.location - opening.location), query)
    }
}
