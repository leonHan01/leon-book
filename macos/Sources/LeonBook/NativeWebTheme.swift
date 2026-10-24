import WebKit

/// Updates presentation only; the document, selection and undo history stay in the same web view.
@MainActor
enum NativeWebTheme {
    static func apply(_ palette: NativeAppPalette, to webView: WKWebView) {
        webView.callAsyncJavaScript(#"""
            const mapping = {
              '--accent':'accent', '--native-button':'button', '--accent-soft':'accentSoft',
              '--native-canvas':'canvas', '--bg':'canvas', '--surface':'surface', '--card':'surface',
              '--soft':'soft', '--line':'border', '--border':'border', '--grid':'border',
              '--text':'text', '--muted':'muted', '--block-hover':'accentSoft'
            };
            for (const element of [document.documentElement, document.body]) {
              if (!element) continue;
              for (const [variable, key] of Object.entries(mapping)) element.style.setProperty(variable, colors[key]);
              element.style.setProperty('--native-scheme', dark ? 'dark' : 'light');
            }
            document.documentElement.style.colorScheme = dark ? 'dark' : 'light';
            let style = document.getElementById('leon-native-theme');
            if (!style) {
              style = document.createElement('style'); style.id = 'leon-native-theme'; document.head.appendChild(style);
            }
            style.textContent = `
              body:not(.readonly) { background:var(--native-canvas); color-scheme:var(--native-scheme); }
              .primary { background:var(--native-button); color:white; }
              #marquee { background:color-mix(in srgb,var(--accent) 10%,transparent); }
              #commands, #selection-toolbar, #selection-colors, #selection-headings {
                background:var(--surface); color:var(--text); border-color:var(--line);
              }
              #commands .command-header, #commands .command-footer, #commands .icon { border-color:var(--line); }
              #commands .command-footer, #commands .icon { background:var(--soft); color:var(--muted); }
              #commands button:hover, #commands button:focus-visible, #commands button[aria-selected=true],
              #selection-toolbar button:hover, #selection-toolbar button[aria-pressed=true],
              #selection-toolbar button[aria-expanded=true] { background:var(--accent-soft); color:var(--accent); box-shadow:none; }
              #commands button[aria-selected=true] .icon { background:var(--surface); border-color:var(--line); color:var(--accent); }
            `;
            return true;
            """#, arguments: ["colors": palette.webColors, "dark": palette.isDark], in: nil, in: .page) { _ in }
    }
}
