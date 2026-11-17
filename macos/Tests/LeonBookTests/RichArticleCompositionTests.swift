import AppKit
import WebKit
@testable import LeonBook

extension RichArticleTests {
    @MainActor
    func testRichArticleCellNormalizationPreservesBackwardSelection() async throws {
        try await withWebEditor { view in
            _ = try await view.callAsyncJavaScript(#"""
            const root = document.getElementById('document');
            for (const tag of ['td', 'th']) {
              LeonArticle.load(`<article data-leon-format="html-v1"><table><tr><${tag}>Initial</${tag}></tr></table></article>`, 'selection-' + tag, true, 18);
              const cell = root.querySelector(tag);
              cell.innerHTML = '<span>abc</span><strong>def</strong><span>ghi</span>';
              const text = cell.firstChild.firstChild, selection = getSelection();
              root.focus(); selection.setBaseAndExtent(cell, 3, text, 1);
              const selected = selection.toString();
              root.dispatchEvent(new InputEvent('input', { inputType: 'insertText', bubbles: true }));
              if (cell.children.length !== 1 || selection.toString() !== selected || selection.focusNode !== text || selection.focusOffset !== 1 || selection.anchorNode !== cell.firstElementChild || selection.anchorOffset !== 3) {
                throw new Error('normalization must retain backward selection with a cell boundary');
              }
            }
            return true;
            """#, arguments: [:], in: nil, contentWorld: .page)
        }
    }

    @MainActor
    func testRichArticleIMECommitPreservesTableCaret() async throws {
        try await withWebEditor { view in
            _ = try await view.evaluateJavaScript(#"""
            (() => {
              LeonArticle.load('<article data-leon-format="html-v1"><table><tr><td><p><br></p></td><td>Neighbor</td></tr></table></article>', 'ime-table', true, 18);
              const root = document.getElementById('document');
              root.focus(); getSelection().setPosition(root.querySelector('td p'), 0);
              return true;
            })()
            """#)
            view.window?.makeFirstResponder(view)
            guard let input = view.window?.firstResponder as? NSTextInputClient else {
                throw NSError(domain: "RichArticleCompositionTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "editor must expose its native input client"])
            }
            let insertion = NSRange(location: NSNotFound, length: 0)
            input.setMarkedText("huoqu", selectedRange: NSRange(location: 5, length: 0), replacementRange: insertion)
            try await Task.sleep(nanoseconds: 50_000_000)
            input.insertText("获取", replacementRange: insertion)
            try await Task.sleep(nanoseconds: 50_000_000)
            _ = try await view.callAsyncJavaScript(#"""
            const cell = document.querySelector('td'), selection = getSelection();
            if (cell.children.length !== 1 || cell.textContent !== '获取' || !cell.firstElementChild.contains(selection.anchorNode)) {
              throw new Error('IME commit must retain the caret inside the table paragraph');
            }
            return true;
            """#, arguments: [:], in: nil, contentWorld: .page)
            input.insertText("token", replacementRange: insertion)
            try await Task.sleep(nanoseconds: 50_000_000)
            _ = try await view.callAsyncJavaScript(#"""
            const cell = document.querySelector('td');
            if (cell.children.length !== 1 || cell.firstElementChild.textContent !== '获取token' || cell.nextElementSibling.textContent !== 'Neighbor') {
              throw new Error('typing English after Chinese must stay in the same table paragraph');
            }
            return true;
            """#, arguments: [:], in: nil, contentWorld: .page)
            input.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0), replacementRange: insertion)
            try await Task.sleep(nanoseconds: 50_000_000)
            input.insertText("中文", replacementRange: insertion)
            try await Task.sleep(nanoseconds: 50_000_000)
            input.insertText("again", replacementRange: insertion)
            try await Task.sleep(nanoseconds: 50_000_000)
            _ = try await view.callAsyncJavaScript(#"""
            const cell = document.querySelector('td'), selection = getSelection();
            if (cell.children.length !== 1 || cell.textContent !== '获取token中文again' || !cell.firstElementChild.contains(selection.anchorNode)) {
              throw new Error('repeated language switches must preserve the paragraph and caret');
            }
            const enter = new InputEvent('beforeinput', { inputType: 'insertParagraph', bubbles: true, cancelable: true });
            cell.dispatchEvent(enter);
            if (!enter.defaultPrevented || cell.children.length !== 2 || cell.firstElementChild.textContent !== '获取token中文again' || cell.lastElementChild.textContent !== '') {
              throw new Error('an intentional Enter must still create a new paragraph in the cell');
            }
            return true;
            """#, arguments: [:], in: nil, contentWorld: .page)
        }
    }
}
