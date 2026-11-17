import AppKit
import SwiftUI
import WebKit
@testable import LeonBook

private struct BodyBridgeFailure: Error, CustomStringConvertible { let description: String }
private func bridgeExpect(_ value: Bool, _ message: String) throws {
    if !value { throw BodyBridgeFailure(description: message) }
}

@MainActor private final class BodyBridgeMessages: NSObject, WKScriptMessageHandler {
    let coordinator: RichArticleEditor.Coordinator
    var patches = 0
    var transmittedCharacters = 0
    init(_ coordinator: RichArticleEditor.Coordinator) { self.coordinator = coordinator }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let payload = message.body as? [String: Any], payload["type"] as? String == "change" {
            if let patch = payload["patch"] as? [String: Any] {
                patches += 1; transmittedCharacters += (patch["text"] as? String)?.utf16.count ?? 0
            } else { transmittedCharacters += (payload["body"] as? String)?.utf16.count ?? 0 }
        }
        coordinator.userContentController(controller, didReceive: message)
    }
}

final class RichArticleBodyBridgeTests {
    func testBodyPatchesValidateSessionRevisionAndUnicode() throws {
        let source = RichArticleDocument.opening + "<p>😀中文</p><p>后文</p></article>"
        var state = RichArticleBodyState(sessionID: "current", body: source)
        let range = (source as NSString).range(of: "<p>😀中文</p>")
        var payload: [String: Any] = ["sessionID": "current", "revision": 1, "baseRevision": 0,
            "patch": ["offset": range.location, "removedLength": range.length, "text": "<p>👩‍💻修改</p>", "baseLength": source.utf16.count]]
        let updated = state.accept(payload)
        try bridgeExpect(updated == source.replacingOccurrences(of: "<p>😀中文</p>", with: "<p>👩‍💻修改</p>"), "UTF-16 patches must preserve emoji and following text")
        try bridgeExpect(state.accept(payload) == nil, "duplicate patches must be ignored")
        payload["revision"] = 2
        try bridgeExpect(state.accept(payload) == nil, "wrong base revisions must not corrupt body")
        try bridgeExpect(state.accept(["sessionID": "old", "revision": 99, "body": source]) == nil, "stale documents must be ignored")
        try bridgeExpect(state.accept(["sessionID": "current", "revision": 3, "body": source]) == source, "full snapshots must recover a skipped revision")
        payload = ["sessionID": "current", "revision": 4, "baseRevision": 3,
            "patch": ["offset": Int.max, "removedLength": 1, "text": "", "baseLength": source.utf16.count]]
        try bridgeExpect(state.accept(payload) == nil && state.body == source, "invalid ranges must leave the last good body intact")
    }

    @MainActor
    func testIncrementalBridgeKeepsNativeBodyCurrentThroughUndoAndReload() async throws {
        _ = NSApplication.shared
        var html = RichArticleDocument.opening + (0..<600).map { "<p data-block-id=\"p\($0)\">正文😀\($0)</p>" }.joined() + "</article>"
        let coordinator = RichArticleEditor.Coordinator(parent: RichArticleEditor(html: Binding(get: { html }, set: { html = $0 }), documentID: "bridge-test"))
        let recorder = BodyBridgeMessages(coordinator)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        NativeWebLocalization.install(on: configuration, language: NativeLocalization.currentLanguage)
        configuration.userContentController.add(recorder, name: "richArticle")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 600), configuration: configuration)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; view.navigationDelegate = coordinator
        defer { RichArticleEditor.dismantleNSView(view, coordinator: coordinator); window.close() }
        view.loadHTMLString(RichArticleEditor.pageHTML, baseURL: nil)
        try await waitUntil { (try? await view.evaluateJavaScript("document.getElementById('document')?.contentEditable === 'true'")) as? Bool == true }
        _ = try await view.evaluateJavaScript("const root = document.getElementById('document'); root.focus(); getSelection().setPosition(root.children[300].firstChild, 2); for (let i = 0; i < 40; i++) document.execCommand('insertText', false, '新');")
        let expected = try await view.evaluateJavaScript("LeonArticle.serialize()") as! String
        try await waitUntil { html == expected }
        try bridgeExpect(recorder.patches >= 39 && recorder.transmittedCharacters < expected.utf16.count * 3, "typing must use small patches while updating the native binding")
        coordinator.parent.fontSize = 24; coordinator.synchronize(view)
        _ = try await view.evaluateJavaScript("document.execCommand('insertText', false, '末尾😀'); LeonArticle.undo(-1); LeonArticle.undo(1);")
        let afterUndo = try await view.evaluateJavaScript("LeonArticle.serialize()") as! String
        try await waitUntil { html == afterUndo }
        html = RichArticleDocument.opening + "<p data-block-id=\"replacement\">替换</p></article>"
        coordinator.synchronize(view)
        try await waitUntil { (try? await view.evaluateJavaScript("root.textContent")) as? String == "替换" }
        _ = try await view.evaluateJavaScript("root.focus(); getSelection().setPosition(root.firstElementChild.firstChild, 2); document.execCommand('insertText', false, '完成');")
        try await waitUntil { RichArticleDocument.plainText(html) == "替换完成" }
        print("Article bridge: \(recorder.patches) patches, native body verified through Unicode typing, undo, font update and reload")
    }

    @MainActor private func waitUntil(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<200 {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw BodyBridgeFailure(description: "native article bridge did not synchronize")
    }
}
