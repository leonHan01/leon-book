import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MomentRichTextController: ObservableObject {
    private weak var textView: NSTextView?

    func attach(to textView: NSTextView) {
        self.textView = textView
    }

    func toggleBold() {
        guard let textView else { return }
        let range = textView.selectedRange()

        guard range.length > 0 else {
            let current = textView.typingAttributes[.font] as? NSFont ?? .systemFont(ofSize: 16)
            let bold = current.fontDescriptor.symbolicTraits.contains(.bold)
            textView.typingAttributes[.font] = convertedFont(current, bold: !bold)
            return
        }

        guard let storage = textView.textStorage else { return }
        var selectionIsBold = true
        storage.enumerateAttribute(.font, in: range) { value, _, _ in
            let font = value as? NSFont ?? .systemFont(ofSize: 16)
            if !font.fontDescriptor.symbolicTraits.contains(.bold) {
                selectionIsBold = false
            }
        }
        var fontUpdates: [(NSRange, NSFont)] = []
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = value as? NSFont ?? .systemFont(ofSize: 16)
            fontUpdates.append((subrange, convertedFont(font, bold: !selectionIsBold)))
        }
        for (subrange, font) in fontUpdates {
            storage.addAttribute(.font, value: font, range: subrange)
        }
        textView.didChangeText()
    }

    func apply(color: NativeMomentTextColor?) {
        guard let textView else { return }
        let range = textView.selectedRange()
        let nsColor = color?.nsColor ?? .labelColor

        guard range.length > 0 else {
            textView.typingAttributes[.foregroundColor] = nsColor
            return
        }

        textView.textStorage?.addAttribute(.foregroundColor, value: nsColor, range: range)
        textView.didChangeText()
    }

    private func convertedFont(_ font: NSFont, bold: Bool) -> NSFont {
        let manager = NSFontManager.shared
        return bold
            ? manager.convert(font, toHaveTrait: .boldFontMask)
            : manager.convert(font, toNotHaveTrait: .boldFontMask)
    }
}

struct MomentRichTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var textRuns: [NativeMomentTextRun]
    let controller: MomentRichTextController
    let onPasteImages: ([NSImage]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        let textView = MomentTextView()
        textView.allowsUndo = true
        textView.autoresizingMask = [.width]
        textView.backgroundColor = .textBackgroundColor
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 16, weight: .regular)
        textView.isHorizontallyResizable = false
        textView.isRichText = true
        textView.isVerticallyResizable = true
        textView.importsGraphics = false
        textView.textColor = .labelColor
        textView.typingAttributes = MomentTextRuns.defaultAttributes
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 12
        textView.textContainer?.widthTracksTextView = true
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        textView.textStorage?.setAttributedString(MomentTextRuns.attributedString(text: text, runs: textRuns))
        textView.onPasteImages = { [weak coordinator = context.coordinator] images in
            coordinator?.parent.onPasteImages(images)
        }
        controller.attach(to: textView)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? MomentTextView else { return }
        controller.attach(to: textView)

        let currentRuns = MomentTextRuns.runs(from: textView.attributedString())
        guard textView.string != text || currentRuns != textRuns else { return }
        textView.textStorage?.setAttributedString(MomentTextRuns.attributedString(text: text, runs: textRuns))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MomentRichTextEditor

        init(parent: MomentRichTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.textRuns = MomentTextRuns.runs(from: textView.attributedString())
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            let replacementLength = ((replacementString ?? "") as NSString).length
            let currentLength = (textView.string as NSString).length
            return currentLength - affectedCharRange.length + replacementLength <= 500
        }
    }
}

private final class MomentTextView: NSTextView {
    var onPasteImages: (([NSImage]) -> Void)?

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types = super.readablePasteboardTypes
        for imageType in [.png, .tiff, .fileURL] as [NSPasteboard.PasteboardType] where !types.contains(imageType) {
            types.append(imageType)
        }
        return types
    }

    override func paste(_ sender: Any?) {
        if insertPastedImages(from: .general) { return }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if insertPastedImages(from: .general) { return }
        super.pasteAsPlainText(sender)
    }

    override func readSelection(
        from pasteboard: NSPasteboard,
        type: NSPasteboard.PasteboardType
    ) -> Bool {
        if insertPastedImages(from: pasteboard) { return true }
        return super.readSelection(from: pasteboard, type: type)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        images(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard insertPastedImages(from: sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }
        return true
    }

    @discardableResult
    private func insertPastedImages(from pasteboard: NSPasteboard) -> Bool {
        let pastedImages = images(from: pasteboard)
        guard !pastedImages.isEmpty, let onPasteImages else { return false }
        onPasteImages(pastedImages)
        return true
    }

    private func images(from pasteboard: NSPasteboard) -> [NSImage] {
        if let image = pasteboard
            .readObjects(forClasses: [NSImage.self])?
            .compactMap({ $0 as? NSImage })
            .first {
            return [image]
        }

        var images: [NSImage] = []
        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types {
                guard let uniformType = UTType(type.rawValue),
                      uniformType.conforms(to: .image),
                      let data = item.data(forType: type),
                      let image = NSImage(data: data) else { continue }
                images.append(image)
                break
            }
        }
        if !images.isEmpty { return images }

        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let image = NSImage(data: data) {
                images.append(image)
                break
            }
        }
        if !images.isEmpty { return images }

        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.compactMap(NSImage.init(contentsOf:))
    }
}

private enum MomentTextRuns {
    static let defaultAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 16, weight: .regular),
        .foregroundColor: NSColor.labelColor,
    ]

    static func attributedString(text: String, runs: [NativeMomentTextRun]) -> NSAttributedString {
        let resolvedRuns = runs.map(\.text).joined() == text && !runs.isEmpty
            ? runs
            : [NativeMomentTextRun(text: text, bold: false, color: nil)]
        let result = NSMutableAttributedString()
        for run in resolvedRuns where !run.text.isEmpty {
            var attributes = defaultAttributes
            attributes[.font] = NSFont.systemFont(ofSize: 16, weight: run.bold ? .bold : .regular)
            attributes[.foregroundColor] = run.color?.nsColor ?? NSColor.labelColor
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    static func runs(from attributedText: NSAttributedString) -> [NativeMomentTextRun] {
        guard attributedText.length > 0 else { return [] }
        var result: [NativeMomentTextRun] = []
        attributedText.enumerateAttributes(
            in: NSRange(location: 0, length: attributedText.length),
            options: []
        ) { attributes, range, _ in
            let text = attributedText.attributedSubstring(from: range).string
            let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: 16)
            let run = NativeMomentTextRun(
                text: text,
                bold: font.fontDescriptor.symbolicTraits.contains(.bold),
                color: NativeMomentTextColor.resolve(attributes[.foregroundColor] as? NSColor)
            )
            append(run, to: &result)
        }
        return result
    }

    private static func append(_ run: NativeMomentTextRun, to runs: inout [NativeMomentTextRun]) {
        guard !run.text.isEmpty else { return }
        guard let previous = runs.last,
              previous.bold == run.bold,
              previous.color == run.color else {
            runs.append(run)
            return
        }
        runs[runs.count - 1] = NativeMomentTextRun(
            text: previous.text + run.text,
            bold: run.bold,
            color: run.color
        )
    }
}

private extension NativeMomentTextColor {
    var nsColor: NSColor {
        switch self {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        }
    }

    static func resolve(_ color: NSColor?) -> NativeMomentTextColor? {
        guard let color,
              let source = color.usingColorSpace(.deviceRGB) else { return nil }
        return allCases.min { distance(from: source, to: $0.nsColor) < distance(from: source, to: $1.nsColor) }
            .flatMap { distance(from: source, to: $0.nsColor) < 0.02 ? $0 : nil }
    }

    private static func distance(from source: NSColor, to target: NSColor) -> CGFloat {
        guard let target = target.usingColorSpace(.deviceRGB) else { return .greatestFiniteMagnitude }
        let red = source.redComponent - target.redComponent
        let green = source.greenComponent - target.greenComponent
        let blue = source.blueComponent - target.blueComponent
        return red * red + green * green + blue * blue
    }
}
