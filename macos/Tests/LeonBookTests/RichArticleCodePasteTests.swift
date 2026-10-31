import WebKit
@testable import LeonBook

extension RichArticleTests {
    @MainActor
    func testMultilineCodePasteAndEditing() async throws {
        try await withWebEditor { view in
            _ = try await view.callAsyncJavaScript(#"""
            const root = document.getElementById('document');
            const text = 'messages = [{"role": "user", "content": task}]\nwhile True:\n    reply = llm.chat(messages)\n    if not reply.tool_calls:\n        return reply.text\n    for call in reply.tool_calls:\n        messages.append(run_tool(call))';
            const expect = (condition, message) => { if (!condition) throw new Error(message + ': ' + root.innerHTML); };
            LeonArticle.load('<article data-leon-format="html-v1"><pre data-language="text"><code><br></code></pre></article>', 'code-paste', true, 18);
            root.focus(); getSelection().setPosition(root.querySelector('code'), 0);
            const clipboard = new DataTransfer(); clipboard.setData('text/plain', text.replace(/\n/g, '\r\n'));
            root.dispatchEvent(new ClipboardEvent('paste', {bubbles: true, cancelable: true, clipboardData: clipboard}));
            expect(root.querySelectorAll('pre').length === 1 && root.querySelector('pre').textContent === text, 'paste must preserve lines and indentation in one block');
            expect(LeonArticle.serialize().includes('while True:\n    reply'), 'serialization must preserve newlines');
            root.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true, cancelable: true}));
            root.dispatchEvent(new KeyboardEvent('keydown', {key: 'Tab', bubbles: true, cancelable: true}));
            expect(root.querySelectorAll('pre').length === 1 && root.querySelector('pre').textContent === text + '\n    ', 'enter and tab must stay in the block');
            LeonArticle.undo(-1);
            expect(root.querySelectorAll('pre').length === 1 && root.querySelector('pre').textContent === text, 'undo must restore pasted code');
            const code = root.querySelector('code'); const node = code.firstChild;
            getSelection().setBaseAndExtent(node, 0, node, 8);
            const replacement = new DataTransfer(); replacement.setData('text/plain', 'new\nline');
            root.dispatchEvent(new ClipboardEvent('paste', {bubbles: true, cancelable: true, clipboardData: replacement}));
            expect(root.querySelector('pre').textContent === 'new\nline' + text.slice(8), 'paste must replace the selected code');
            return true;
            """#, arguments: [:], in: nil, contentWorld: .page)
        }
    }
}
