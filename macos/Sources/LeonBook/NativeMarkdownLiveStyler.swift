import AppKit
import Foundation

enum NativeMarkdownLiveStyler {
    private static let inlineCode = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)
    private static let strongAsterisk = try! NSRegularExpression(pattern: #"\*\*([^*\n]+)\*\*"#)
    private static let strongUnderscore = try! NSRegularExpression(pattern: #"__([^_\n]+)__"#)
    private static let emphasis = try! NSRegularExpression(pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#)
    private static let wikiLink = try! NSRegularExpression(pattern: #"\[\[([^\[\]\n]+)\]\]"#)
    private static let markdownLink = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\(([^)\n]+)\)"#)
    private static let blockQuote = try! NSRegularExpression(pattern: #"(?m)^[ \t]*(>)[ \t]+(.+)$"#)
    private static let listMarker = try! NSRegularExpression(pattern: #"(?m)^[ \t]*([-+*]|\d+[.)])[ \t]+"#)
    private static let heading = try! NSRegularExpression(pattern: #"(?m)^(#{1,6})[ \t]+(.+)$"#)
    private static let fencedCode = try! NSRegularExpression(pattern: #"(?ms)^```[^\n]*\n.*?^```[ \t]*$"#)
    private static let markdownMarkers = try! NSRegularExpression(
        pattern: #"\*\*|__|(?<!\*)\*(?!\*)|`|\[\[|\]\]|\]\(|\)"#
    )

    static func apply(
        _ appearance: NativeBodyEditorAppearance,
        typography: NativeReadingTypography,
        to textView: NSTextView,
        editedRange: NSRange?
    ) {
        guard let storage = textView.textStorage else { return }
        let targetRange = stylingRange(in: storage.string, editedRange: editedRange)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = typography.lineSpacing
        paragraphStyle.paragraphSpacing = typography.paragraphSpacing
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: typography.bodyFont.nsFont(size: typography.fontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle,
        ]

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: targetRange)
        textView.typingAttributes = baseAttributes
        textView.insertionPointColor = .controlAccentColor

        guard appearance == .livePreview, storage.length > 0 else {
            storage.endEditing()
            return
        }

        let source = storage.string
        let markerAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        apply(inlineCode, group: 1, to: storage, source: source, range: targetRange, attributes: [
            .font: typography.codeFont.nsFont(size: max(11, typography.fontSize - 2)),
            .backgroundColor: NSColor.controlBackgroundColor,
        ])
        apply(strongAsterisk, group: 1, to: storage, source: source, range: targetRange, attributes: [
            .font: typography.bodyFont.nsFont(size: typography.fontSize, weight: .bold),
        ])
        apply(strongUnderscore, group: 1, to: storage, source: source, range: targetRange, attributes: [
            .font: typography.bodyFont.nsFont(size: typography.fontSize, weight: .bold),
        ])
        apply(emphasis, group: 1, to: storage, source: source, range: targetRange, attributes: [
            .font: NSFontManager.shared.convert(
                typography.bodyFont.nsFont(size: typography.fontSize),
                toHaveTrait: .italicFontMask
            ),
        ])
        apply(wikiLink, group: 1, to: storage, source: source, range: targetRange, attributes: [
            .foregroundColor: NSColor.controlAccentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        apply(markdownLink, group: 1, to: storage, source: source, range: targetRange, attributes: [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        apply(blockQuote, group: 0, to: storage, source: source, range: targetRange, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        apply(blockQuote, group: 1, to: storage, source: source, range: targetRange, attributes: [
            .foregroundColor: NSColor.controlAccentColor,
            .font: typography.bodyFont.nsFont(size: typography.fontSize, weight: .semibold),
        ])
        apply(listMarker, group: 1, to: storage, source: source, range: targetRange, attributes: [
            .foregroundColor: NSColor.controlAccentColor,
            .font: typography.bodyFont.nsFont(size: typography.fontSize, weight: .semibold),
        ])
        apply(fencedCode, group: 0, to: storage, source: source, range: targetRange, attributes: [
            .font: typography.codeFont.nsFont(size: max(11, typography.fontSize - 3)),
            .backgroundColor: NSColor.controlBackgroundColor,
        ])

        for match in heading.matches(in: source, range: targetRange) {
            guard match.numberOfRanges >= 3,
                  match.range(at: 0).location != NSNotFound,
                  match.range(at: 1).location != NSNotFound else { continue }
            let level = max(1, min(match.range(at: 1).length, 6))
            let scales: [CGFloat] = [1.78, 1.55, 1.34, 1.17, 1.06, 1]
            storage.addAttributes([
                .font: typography.bodyFont.nsFont(
                    size: max(13, typography.fontSize * scales[level - 1]),
                    weight: level <= 2 ? .bold : .semibold
                ),
            ], range: match.range(at: 0))
            storage.addAttributes(markerAttributes, range: match.range(at: 1))
        }

        apply(
            markdownMarkers,
            group: 0,
            to: storage,
            source: source,
            range: targetRange,
            attributes: markerAttributes
        )
        storage.endEditing()
    }

    static func stylingRange(in source: String, editedRange: NSRange?) -> NSRange {
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        guard let editedRange, fullRange.length > 0 else { return fullRange }

        let nsSource = source as NSString
        let location = min(max(0, editedRange.location), fullRange.length)
        let availableLength = max(0, fullRange.length - location)
        let clampedLength = min(max(0, editedRange.length), availableLength)
        let probeLocation = min(location, max(0, fullRange.length - 1))
        let probeLength = max(1, clampedLength)
        var result = nsSource.paragraphRange(for: NSRange(
            location: probeLocation,
            length: min(probeLength, fullRange.length - probeLocation)
        ))

        if result.location > 0 {
            result = NSUnionRange(
                result,
                nsSource.paragraphRange(for: NSRange(location: result.location - 1, length: 0))
            )
        }
        if NSMaxRange(result) < fullRange.length {
            result = NSUnionRange(
                result,
                nsSource.paragraphRange(for: NSRange(location: NSMaxRange(result), length: 0))
            )
        }

        let context = nsSource.substring(with: result)
        if context.contains("```") { return fullRange }
        if source.contains("```") {
            for match in fencedCode.matches(in: source, range: fullRange) {
                let containsEdit = location >= match.range.location && location <= NSMaxRange(match.range)
                if containsEdit || NSIntersectionRange(result, match.range).length > 0 {
                    result = NSUnionRange(result, match.range)
                }
            }
        }
        return NSIntersectionRange(result, fullRange)
    }

    private static func apply(
        _ expression: NSRegularExpression,
        group: Int,
        to storage: NSTextStorage,
        source: String,
        range: NSRange,
        attributes: [NSAttributedString.Key: Any]
    ) {
        for match in expression.matches(in: source, range: range) where match.numberOfRanges > group {
            let matchRange = match.range(at: group)
            guard matchRange.location != NSNotFound, matchRange.length > 0 else { continue }
            storage.addAttributes(attributes, range: matchRange)
        }
    }
}
