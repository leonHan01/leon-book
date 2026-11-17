import AppKit
import SwiftUI
@testable import LeonBook

private struct MomentEditorPerformanceFailure: Error, CustomStringConvertible {
    let description: String
}

private func momentEditorExpect(_ condition: Bool, _ message: String) throws {
    if !condition { throw MomentEditorPerformanceFailure(description: message) }
}

private final class MomentRunExportProbe: NSTextView {
    var attributedStringReads = 0

    override func attributedString() -> NSAttributedString {
        attributedStringReads += 1
        return super.attributedString()
    }
}

private final class MomentImageDataProvider: NSObject, NSPasteboardItemDataProvider {
    var reads = 0
    let data: Data

    init(data: Data) { self.data = data }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        reads += 1
        item.setData(data, forType: type)
    }
}

@MainActor
final class MomentEditorPerformanceTests {
    func testTypingEchoSkipsRunExportAndPreservesComposition() throws {
        _ = NSApplication.shared
        var text = String(repeating: "正文", count: 2_400)
        var runs = (0..<48).map { index in
            NativeMomentTextRun(text: String(repeating: "正文", count: 50),
                                bold: index.isMultiple(of: 2), color: index.isMultiple(of: 3) ? .red : nil)
        }
        let controller = MomentRichTextController()
        let editor = MomentRichTextEditor(
            text: Binding(get: { text }, set: { text = $0 }),
            textRuns: Binding(get: { runs }, set: { runs = $0 }),
            controller: controller, onPasteImages: { _ in }
        )
        let coordinator = editor.makeCoordinator()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = MomentRunExportProbe(frame: window.contentView!.bounds)
        view.isRichText = true
        view.allowsUndo = true
        view.delegate = coordinator
        window.contentView = view
        window.makeFirstResponder(view)
        controller.attach(to: view)
        coordinator.synchronizeText(in: view)
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))

        for character in "连续输入十二个普通文字啊" {
            let before = view.attributedStringReads
            view.insertText(String(character), replacementRange: view.selectedRange())
            let afterNativeEdit = view.attributedStringReads
            try momentEditorExpect(afterNativeEdit > before, "native text changes must export their rich text")
            let selection = view.selectedRange()
            for _ in 0..<10 { coordinator.synchronizeText(in: view) }
            try momentEditorExpect(view.attributedStringReads == afterNativeEdit && view.selectedRange() == selection,
                                   "binding echoes must not re-export runs or replace the native selection")
        }

        view.setSelectedRange(NSRange(location: 0, length: 2))
        controller.toggleBold()
        let styledReads = view.attributedStringReads
        coordinator.synchronizeText(in: view)
        try momentEditorExpect(view.attributedStringReads == styledReads && runs.first?.bold == false,
                               "toolbar formatting must publish once and survive a binding echo")

        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0), replacementRange: view.selectedRange())
        let markedRange = view.markedRange(), composingReads = view.attributedStringReads
        coordinator.synchronizeText(in: view)
        try momentEditorExpect(view.hasMarkedText() && view.markedRange() == markedRange
            && view.attributedStringReads == composingReads,
            "an IME binding echo must preserve marked text without another run export")
        text = "外部草稿"
        runs = [.init(text: text, bold: false, color: .blue)]
        coordinator.synchronizeText(in: view)
        try momentEditorExpect(view.string == text && !view.hasMarkedText()
            && MomentTextRuns.runs(from: view.textStorage!) == runs,
            "switching drafts during composition must apply external text and styles and end the old composition")
        runs = [.init(text: text, bold: true, color: .red, highlighted: true)]
        coordinator.synchronizeText(in: view)
        try momentEditorExpect(MomentTextRuns.runs(from: view.textStorage!) == runs,
                               "style-only changes with identical text must still synchronize")
        text = ""; runs = []
        coordinator.synchronizeText(in: view)
        try momentEditorExpect(view.string.isEmpty, "clearing the external draft must clear native text")
    }

    func testDragHoverDoesNotReadImagePayloads() throws {
        _ = NSApplication.shared
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        memset(bitmap.bitmapData!, 127, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let provider = MomentImageDataProvider(data: bitmap.representation(using: .png, properties: [:])!)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.png])
        pasteboard.writeObjects([item])
        let view = MomentTextView()
        for _ in 0..<120 {
            try momentEditorExpect(view.dragOperation(for: pasteboard) == .copy, "image drag must be accepted")
        }
        try momentEditorExpect(provider.reads == 0, "hover must inspect advertised types without requesting image data")
        var pastedImages = 0
        view.onPasteImages = { pastedImages += $0.count }
        try momentEditorExpect(view.readSelection(from: pasteboard, type: .png) && pastedImages == 1 && provider.reads > 0,
                               "the real paste/drop reader must still load a valid image when requested")

        pasteboard.clearContents()
        let pdfProvider = MomentImageDataProvider(data: Data("PDF payload must remain unread during hover".utf8))
        let pdfItem = NSPasteboardItem()
        pdfItem.setDataProvider(pdfProvider, forTypes: [.pdf])
        pasteboard.writeObjects([pdfItem])
        for _ in 0..<120 {
            try momentEditorExpect(view.dragOperation(for: pasteboard) == .copy,
                                   "NSImage-readable PDF data must remain an accepted image drag")
        }
        try momentEditorExpect(pdfProvider.reads == 0, "PDF hover must not request the advertised payload")
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/nonexistent/moment-test.PDF") as NSURL])
        try momentEditorExpect(view.dragOperation(for: pasteboard) == .copy,
                               "PDF file URLs must retain NSImage compatibility without reading the file")

        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/nonexistent/moment-test.JPG") as NSURL])
        try momentEditorExpect(view.dragOperation(for: pasteboard) == .copy,
                               "hover must classify image URLs without opening files")
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/nonexistent/extensionless-image") as NSURL])
        try momentEditorExpect(view.dragOperation(for: pasteboard) == .copy,
                               "extensionless images must defer content validation until drop")
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/nonexistent/image.unknownmomentformat") as NSURL])
        try momentEditorExpect(view.dragOperation(for: pasteboard) == .copy,
                               "unknown file extensions must defer content validation until drop")
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/nonexistent/moment-test.txt") as NSURL])
        try momentEditorExpect(view.dragOperation(for: pasteboard).isEmpty, "unsupported files must be rejected")
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/nonexistent/moment-test.MP4") as NSURL])
        try momentEditorExpect(view.dragOperation(for: pasteboard).isEmpty, "video drops must respect the editor capability")
        view.acceptsVideoDrops = true
        try momentEditorExpect(view.dragOperation(for: pasteboard) == .copy,
                               "capability changes must invalidate cached drag acceptance")
        pasteboard.clearContents()
        pasteboard.setString("普通文字", forType: .string)
        try momentEditorExpect(view.dragOperation(for: pasteboard).isEmpty,
                               "a changed pasteboard must not reuse the preceding image/video decision")
    }
}
