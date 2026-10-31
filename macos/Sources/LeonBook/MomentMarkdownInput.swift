import AppKit

extension NSAttributedString.Key {
    static let momentHeadingLevel = Self("LeonMomentHeadingLevel")
    static let momentCode = Self("LeonMomentCode")
    static let momentHighlighted = Self("LeonMomentHighlighted")
    static let momentHighlightColor = Self("LeonMomentHighlightColor")
}

/// Input shortcuts operate only on the paragraph before the insertion point.
/// Persisted text remains plain text plus the same runs used by the toolbar.
@MainActor
enum MomentMarkdownInput {
    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,4}) "#)
    private static let inlineRules: [(String, NSRegularExpression)] = [
        ("bold", #"(?<![\\*])\*\*([^*\n]+)\*\*$"#),
        ("bold", #"(?<![\\_])__([^_\n]+)__$"#),
        ("italic", #"(?<![\\*])\*([^*\n]+)\*$"#),
        ("strike", #"(?<![\\~])~~([^~\n]+)~~$"#),
        ("highlight", #"(?<![\\=])==([^=\n]+)==$"#),
        ("code", #"(?<![\\`])`([^`\n]+)`$"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    nonisolated static func fontSize(for level: Int?) -> CGFloat {
        switch level {
        case 1: return 28
        case 2: return 24
        case 3: return 20
        case 4: return 18
        default: return 16
        }
    }

    @discardableResult
    static func convert(in textView: NSTextView) -> Bool {
        let caret = textView.selectedRange()
        guard caret.length == 0, caret.location > 0, !textView.hasMarkedText(),
              let storage = textView.textStorage, caret.location <= storage.length else { return false }
        let source = storage.string as NSString
        let paragraph = source.paragraphRange(for: NSRange(location: caret.location, length: 0))
        let prefixRange = NSRange(location: paragraph.location, length: caret.location - paragraph.location)
        let prefix = source.substring(with: prefixRange) as NSString
        guard prefix.length > 0 else { return false }
        if let match = heading.firstMatch(in: prefix as String, range: NSRange(location: 0, length: prefix.length)) {
            let level = match.range(at: 1).length
            let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: paragraph))
            replacement.deleteCharacters(in: match.range)
            let attributes: [NSAttributedString.Key: Any] = [
                .momentHeadingLevel: level,
                .font: NSFont.systemFont(ofSize: fontSize(for: level), weight: .bold),
            ]
            replacement.addAttributes(attributes, range: NSRange(location: 0, length: replacement.length))
            textView.insertText(replacement, replacementRange: paragraph)
            textView.setSelectedRange(NSRange(location: caret.location - match.range.length, length: 0))
            textView.typingAttributes.merge(attributes) { _, next in next }
            return true
        }
        guard storage.attribute(.momentCode, at: caret.location - 1, effectiveRange: nil) == nil else { return false }
        for (style, rule) in inlineRules {
            guard let match = rule.firstMatch(in: prefix as String, range: NSRange(location: 0, length: prefix.length)) else { continue }
            let inner = match.range(at: 1)
            let content = prefix.substring(with: inner)
            guard content == content.trimmingCharacters(in: .whitespaces) else { continue }
            let range = NSRange(location: paragraph.location + match.range.location, length: match.range.length)
            let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(
                from: NSRange(location: paragraph.location + inner.location, length: inner.length)
            ))
            let full = NSRange(location: 0, length: replacement.length)
            let baseline = storage.attributes(at: range.location, effectiveRange: nil)
            switch style {
            case "bold", "italic":
                replacement.enumerateAttribute(.font, in: full) { value, range, _ in
                    let font = value as? NSFont ?? .systemFont(ofSize: 16)
                    replacement.addAttribute(.font, value: NSFontManager.shared.convert(font,
                        toHaveTrait: style == "bold" ? .boldFontMask : .italicFontMask), range: range)
                }
            case "strike": replacement.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: full)
            case "highlight": replacement.addAttributes(MomentTextRuns.highlightAttributes, range: full)
            default:
                replacement.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular), .momentCode: true], range: full)
            }
            textView.insertText(replacement, replacementRange: range)
            textView.typingAttributes = baseline
            return true
        }
        return false
    }

    static func resetParagraphTyping(in textView: NSTextView) {
        if textView.typingAttributes[.momentHeadingLevel] != nil {
            textView.typingAttributes = MomentTextRuns.defaultAttributes
        }
    }
}
