@testable import LeonChat
import AppKit

@main
struct ComposerChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ClientError.message(message) }
    }
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        editor.isRichText = false
        let window = NSWindow(contentRect: editor.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = editor
        try check(window.makeFirstResponder(editor), "Could not focus composer")
        var sent = 0
        editor.send = { sent += 1 }
        func enter(_ modifiers: NSEvent.ModifierFlags = [], key: UInt16 = 36, repeatKey: Bool = false) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: repeatKey, keyCode: key)!
            editor.keyDown(with: event)
        }
        editor.string = "你好"
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        enter()
        try check(sent == 1 && editor.string == "你好", "Enter did not send or inserted a newline")
        enter(.shift)
        try check(sent == 1 && editor.string == "你好\n", "Shift+Enter did not insert a newline")
        enter(.command)
        try check(sent == 2, "Command+Enter shortcut stopped working")
        enter(.numericPad, key: 76)
        try check(sent == 3, "Keypad Enter did not send")
        enter(repeatKey: true)
        try check(sent == 3, "Holding Enter sent repeatedly")

        let state = MentionEditorState()
        state.editor = editor; state.group = true; state.conversationId = "shared"
        state.eligible = [AgentInfo(id: "writer", name: "写作助手", handle: "writer", provider: "openai", model: "test", enabled: true, avatarId: nil)]
        editor.confirmMention = { state.command(#selector(NSResponder.insertNewline(_:))) }
        editor.string = "@w"; editor.setSelectedRange(NSRange(location: 2, length: 0))
        enter()
        try check(sent == 3 && editor.string == "@writer ", "Enter sent instead of confirming an @ candidate")
        enter()
        try check(sent == 4, "Enter did not send after completing the mention")

        editor.confirmMention = nil
        editor.string = ""
        editor.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try check(editor.hasMarkedText(), "Could not start input-method composition")
        enter()
        try check(sent == 4, "Enter sent while input method was composing")
        print("PASS: Enter sends, Shift+Enter adds a newline, Command/keypad Enter work, held keys do not resend")
        print("PASS: Enter confirms @ candidates first and does not send during input-method composition")
    }
}
