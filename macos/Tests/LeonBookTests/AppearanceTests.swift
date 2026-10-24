import AppKit
import SwiftUI
import WebKit
@testable import LeonBook

private struct AppearanceFailure: Error, CustomStringConvertible { let description: String }
private func appearanceExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw AppearanceFailure(description: message) }
}

private struct AppearanceEditorHost: View {
    let preferences: NativeAppearancePreferences
    @State private var document = RichArticleDocument.opening + "<p>保留编辑中的文字与光标。</p></article>"
    var body: some View {
        RichArticleEditor(html: $document, documentID: "theme-test").nativeAppTheme(preferences: preferences)
    }
}

final class AppearanceTests {
    @MainActor
    func testPreferencesPersistAndRecoverUnknownValues() throws {
        let suite = "leonbook.appearance.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = NativeAppearancePreferences(defaults: defaults)
        try appearanceExpect(preferences.theme == .classic && preferences.appearance == .system, "new installs should keep the white workspace and system appearance")
        for theme in NativeColorTheme.allCases {
            preferences.theme = theme
            preferences.appearance = .dark
            let reopened = NativeAppearancePreferences(defaults: defaults)
            try appearanceExpect(reopened.theme == theme && reopened.appearance == .dark, "theme and appearance must survive reopening")
            try appearanceExpect(reopened.palette(system: .light).isDark, "explicit appearance must override the system")
        }
        preferences.appearance = .system
        try appearanceExpect(!preferences.palette(system: .light).isDark && preferences.palette(system: .dark).isDark, "system mode must follow appearance changes")
        defaults.set("future-theme", forKey: NativeAppearancePreferences.themeKey)
        defaults.set("future-appearance", forKey: NativeAppearancePreferences.appearanceKey)
        let recovered = NativeAppearancePreferences(defaults: defaults)
        try appearanceExpect(recovered.theme == .classic && recovered.appearance == .system, "unknown stored settings must fall back safely")
    }

    func testPaletteTextAndButtonsRemainReadable() throws {
        func luminance(_ hex: UInt32) -> Double {
            let channels = [Double((hex >> 16) & 255), Double((hex >> 8) & 255), Double(hex & 255)].map { value -> Double in
                let s = value / 255
                return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }
        func contrast(_ a: UInt32, _ b: UInt32) -> Double {
            let x = luminance(a), y = luminance(b)
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        for theme in NativeColorTheme.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let palette = NativeAppPalette(theme: theme, colorScheme: scheme)
                try appearanceExpect(contrast(palette.hex(.text), palette.hex(.canvas)) >= 7, "body text must remain readable in \(theme)/\(scheme)")
                try appearanceExpect(contrast(0xFFFFFF, palette.hex(.button)) >= 4.5, "small white button labels need sufficient contrast in \(theme)/\(scheme)")
                try appearanceExpect(contrast(palette.hex(.accent), palette.hex(.canvas)) >= 3, "outline icons need visible contrast in \(theme)/\(scheme)")
            }
        }
    }

    @MainActor
    func testLiveThemeSwitchPreservesEditorSelectionAndUndo() async throws {
        _ = NSApplication.shared
        let suite = "leonbook.appearance.editor.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = NativeAppearancePreferences(defaults: defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AppearanceEditorHost(preferences: preferences))
        window.contentView = host
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var editor: WKWebView?
        for _ in 0..<200 {
            host.layoutSubtreeIfNeeded()
            editor = descendants(host).compactMap { $0 as? WKWebView }.first
            if let editor, (try? await editor.evaluateJavaScript("!!window.LeonArticle && document.getElementById('document').textContent.includes('光标')")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard let editor else { throw AppearanceFailure(description: "editor did not initialize") }
        _ = try await editor.evaluateJavaScript("""
            const root = document.getElementById('document'); root.focus();
            const range = document.createRange(); range.setStart(root.firstChild.firstChild, 0); range.setEnd(root.firstChild.firstChild, 4);
            getSelection().removeAllRanges(); getSelection().addRange(range); document.execCommand('bold');
            window.themeDocument = LeonArticle.serialize(); window.themeSelection = getSelection().toString();
            """)
        for theme in NativeColorTheme.allCases {
            preferences.theme = theme
            preferences.appearance = .dark
            let palette = preferences.palette(system: .light)
            var applied = false
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                let accent = try? await editor.evaluateJavaScript("document.documentElement.style.getPropertyValue('--accent')")
                if accent as? String == palette.webColors["accent"] { applied = true; break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            try appearanceExpect(applied, "theme must reach the existing editor immediately")
            try appearanceExpect(descendants(host).compactMap { $0 as? WKWebView }.first === editor, "theme must not recreate the editor")
            let retained = try await editor.evaluateJavaScript("LeonArticle.serialize() === themeDocument && getSelection().toString() === themeSelection")
            try appearanceExpect(retained as? Bool == true, "theme must retain draft content and selection")
        }
        let undone = try await editor.evaluateJavaScript("document.execCommand('undo'); !/<(b|strong)>/.test(LeonArticle.serialize())")
        try appearanceExpect(undone as? Bool == true, "theme changes must retain the editing undo stack")
    }
}
