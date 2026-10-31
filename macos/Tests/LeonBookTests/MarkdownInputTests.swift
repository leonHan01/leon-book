import AppKit
import SwiftUI
import WebKit
@testable import LeonBook

private struct MarkdownInputFailure: Error { let message: String }
private func markdownExpect(_ condition: Bool, _ message: String) throws {
    if !condition { throw MarkdownInputFailure(message: message) }
}

extension RichArticleTests {
    @MainActor
    func testMomentOrdinaryBackgroundDoesNotBecomeHighlight() throws {
        let text = "普通粘贴文字，不应该默认出现黄色背景。"
        for background in [NSColor.white, .clear, .textBackgroundColor] {
            var attributes = MomentTextRuns.defaultAttributes
            attributes[.backgroundColor] = background
            let runs = MomentTextRuns.runs(from: NSAttributedString(string: text, attributes: attributes))
            try markdownExpect(runs.allSatisfy { $0.highlighted != true }, "ordinary pasted background must not become yellow highlight")
            let restored = MomentTextRuns.attributedString(text: text, runs: runs)
            try markdownExpect(restored.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil,
                               "saving and reopening ordinary text must keep its background clear")
        }
    }

    @MainActor
    func testArticleMarkdownShortcuts() async throws {
        try await withWebEditor { view in
            _ = try await view.callAsyncJavaScript(#"""
            const root = document.getElementById('document');
            const expect = (value, message) => { if (!value) throw new Error(message); };
            let id = 0;
            const load = (html = '<p><br></p>') => {
              LeonArticle.load('<article data-leon-format="html-v1">' + html + '</article>', 'markdown-' + (++id), true, 18);
              root.focus(); const range = document.createRange(); range.selectNodeContents(root.firstElementChild); range.collapse(false);
              getSelection().removeAllRanges(); getSelection().addRange(range);
            };
            const type = text => {
              for (const data of text) {
                root.dispatchEvent(new InputEvent('beforeinput', {bubbles: true, cancelable: true, inputType: 'insertText', data}));
                document.execCommand('insertText', false, data);
              }
            };
            for (let level = 1; level <= 4; level++) {
              load(); type('#'.repeat(level) + ' 标题');
              expect(root.firstElementChild.tagName === 'H' + level && root.textContent === '标题', 'heading shortcut ' + level + ': ' + root.innerHTML);
              const body = LeonArticle.serialize(); load(body.replace(/^<article[^>]*>|<\/article>$/g, ''));
              expect(root.firstElementChild.tagName === 'H' + level, 'headings must survive save/reload');
              root.dispatchEvent(new InputEvent('beforeinput', {bubbles: true, cancelable: true, inputType: 'insertParagraph'}));
              type('正文'); expect(root.lastElementChild.tagName === 'P', 'Return exits heading');
            }
            for (const [source, tag] of [['**加粗**','strong'], ['__加粗__','strong'], ['*斜体*','em'], ['~~删除~~','s'], ['==高亮==','mark'], ['`代码`','code']]) {
              load(); type(source); expect(root.querySelector(tag)?.textContent === source.replace(/^[*_~=`]+|[*_~=`]+$/g, ''), 'inline ' + source);
              const body = LeonArticle.serialize();
              type('后续'); expect(!root.querySelector(tag).textContent.includes('后续'), 'immediate style leak: ' + source + root.innerHTML);
              LeonArticle.undo(-1);
              LeonArticle.undo(-1); expect(root.textContent === source, 'undo should restore literal markdown');
              LeonArticle.undo(1); expect(LeonArticle.serialize() === body, 'redo should restore rich text');
              type('后续'); expect(!root.querySelector(tag).textContent.includes('后续'), 'style should not leak after redo: ' + source + root.innerHTML);
            }
            for (const [source, selector] of [['- 列表','p[data-type=bullet]'], ['1. 编号','p[data-type=number]'], ['> 引用','blockquote'], ['- [ ] 待办','p[data-type=task][data-checked=false]']]) {
              load(); type(source); expect(root.querySelector(selector), 'block shortcut ' + source);
            }
            load(); type('```swift');
            root.dispatchEvent(new InputEvent('beforeinput', {bubbles: true, cancelable: true, inputType: 'insertParagraph'}));
            type('let a = 1'); expect(root.querySelector('pre[data-language=swift] code')?.textContent === 'let a = 1', 'fenced code shortcut');
            type(' **literal**'); expect(!root.querySelector('strong'), 'code must keep markdown literal');
            load(); type('\\**原文**'); expect(!root.querySelector('strong'), 'escaped syntax stays literal');
            load('<p>普通 # 文本</p>'); type(' '); expect(!root.querySelector('h1'), 'mid-paragraph hashes stay literal');
            load(); root.dispatchEvent(new CompositionEvent('compositionstart', {bubbles: true})); type('# 标题');
            expect(!root.querySelector('h1'), 'composition must not convert while IME is active');
            root.dispatchEvent(new CompositionEvent('compositionend', {bubbles: true}));
            expect(root.querySelector('h1')?.textContent === '标题', 'committed IME text may convert');
            load('<table><tr><td><p><br></p></td></tr></table>');
            getSelection().setPosition(root.querySelector('td p'), 0); type('## 单元格');
            expect(root.querySelector('td h2')?.textContent === '单元格', 'shortcuts work inside table cells');
            return true;
            """#, arguments: [:], in: nil, contentWorld: .page)
        }
    }

    @MainActor
    func testMomentMarkdownShortcuts() throws {
        _ = NSApplication.shared
        var text = "", runs: [NativeMomentTextRun] = []
        let controller = MomentRichTextController()
        let editor = MomentRichTextEditor(text: Binding(get: { text }, set: { text = $0 }),
            textRuns: Binding(get: { runs }, set: { runs = $0 }), controller: controller, onPasteImages: { _ in })
        let coordinator = editor.makeCoordinator()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSTextView(frame: window.contentView!.bounds)
        view.isRichText = true; view.allowsUndo = true; view.delegate = coordinator
        window.contentView = view; window.makeFirstResponder(view); controller.attach(to: view)
        defer { window.close() }
        func reset() {
            view.textStorage?.setAttributedString(NSAttributedString(string: ""))
            view.setSelectedRange(NSRange(location: 0, length: 0)); view.typingAttributes = MomentTextRuns.defaultAttributes
            view.undoManager?.removeAllActions(); text = ""; runs = []
        }
        func type(_ string: String) { for character in string { view.insertText(String(character), replacementRange: view.selectedRange()) } }
        for level in 1...4 {
            reset(); type(String(repeating: "#", count: level) + " 标题")
            try markdownExpect(text == "标题" && runs.first?.headingLevel == level, "native headings should convert and publish runs")
            let restored = MomentTextRuns.attributedString(text: text, runs: runs)
            try markdownExpect(MomentTextRuns.runs(from: restored) == runs, "native heading should round trip")
            type("\n正文")
            try markdownExpect(runs.last?.headingLevel == nil && runs.last?.bold == false, "Return should restore body style")
        }
        for source in ["**加粗**", "__加粗__", "*斜体*", "~~删除~~", "==高亮==", "`代码`"] {
            reset(); type(source)
            try markdownExpect(!text.contains(source.first!) && !runs.isEmpty, "native inline syntax should be removed: \(source)")
            try markdownExpect(MomentTextRuns.runs(from: MomentTextRuns.attributedString(text: text, runs: runs)) == runs,
                               "native inline styles should round trip: \(source)")
            let run = runs[0]
            try markdownExpect(run.bold || run.italic == true || run.strikethrough == true || run.highlighted == true || run.code == true,
                               "native inline style must be applied: \(source)")
            type("后续")
            try markdownExpect(runs.last?.bold == false && runs.last?.italic == nil && runs.last?.highlighted == nil && runs.last?.code == nil,
                               "native inline style should not leak")
        }
        reset(); type("#旅行 ")
        try markdownExpect(text == "#旅行 " && NativeMomentTag.extract(from: text) == ["旅行"], "hashtags stay compatible")
        reset(); type("\\**原文**")
        try markdownExpect(text == "\\**原文**", "escaped native syntax stays literal")
        reset(); view.setMarkedText("# 标题", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: 0, length: 0))
        try markdownExpect(view.string == "# 标题", "IME marked text stays literal")
        view.unmarkText()
        // Explicit undo group mirrors a native input event's automatic grouping.
        reset(); view.undoManager?.beginUndoGrouping(); type("**撤销**"); view.undoManager?.endUndoGrouping()
        view.undoManager?.undo()
        try markdownExpect(view.string.isEmpty, "native conversion must remain undoable")
        reset(); type("左右")
        for color in NativeMomentHighlightColor.allCases {
            view.selectAll(nil); controller.apply(highlight: color)
            try markdownExpect(text == "左右" && runs.allSatisfy { $0.resolvedHighlightColor == color },
                               "applying a pastel color should preserve the selected text")
            let restored = MomentTextRuns.attributedString(text: text, runs: runs)
            try markdownExpect(MomentTextRuns.runs(from: restored) == runs, "each highlight color must survive reopening")
            try markdownExpect((restored.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor)?.isEqual(color.nsColor) == true,
                               "editor should restore the chosen pastel color")
        }
        view.setSelectedRange(NSRange(location: 0, length: 1)); controller.apply(highlight: .green)
        view.setSelectedRange(NSRange(location: 1, length: 1)); controller.apply(highlight: .pink)
        try markdownExpect(runs.map(\.resolvedHighlightColor) == [.green, .pink], "adjacent colors must remain separate runs")
        view.selectAll(nil); controller.apply(highlight: nil)
        try markdownExpect(runs.allSatisfy { $0.resolvedHighlightColor == nil }, "cancel should clear every selected highlight color")
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0)); controller.apply(highlight: .blue)
        type("蓝")
        try markdownExpect(runs.last?.resolvedHighlightColor == .blue, "a color chosen at the caret should apply to newly typed text")
        controller.apply(highlight: nil); type("无")
        try markdownExpect(runs.last?.resolvedHighlightColor == nil, "cancel at the caret should restore plain typing")
        controller.apply(highlight: .yellow)
        reset(); type("高亮文字")
        view.selectAll(nil); controller.toggleHighlight()
        try markdownExpect(runs.allSatisfy { $0.highlighted == true }, "toolbar highlight should be saved")
        controller.toggleHighlight()
        try markdownExpect(runs.allSatisfy { $0.highlighted == nil }, "toolbar should remove highlight")
        controller.toggleHighlight()
        view.insertText("", replacementRange: NSRange(location: 0, length: view.string.utf16.count))
        type("普通新文字")
        try markdownExpect(runs.allSatisfy { $0.highlighted == nil }, "clearing a draft must reset inherited highlight")
    }
}
