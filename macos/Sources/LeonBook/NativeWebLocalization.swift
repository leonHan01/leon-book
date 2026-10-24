import Foundation
import WebKit

enum NativeWebLocalization {
    static func install(on configuration: WKWebViewConfiguration, language: NativeAppLanguage) {
        guard let url = Bundle.leonBookResources.url(forResource: "WebLocalization", withExtension: "js"),
              let runtime = try? String(contentsOf: url, encoding: .utf8),
              let data = try? JSONSerialization.data(withJSONObject: payload(language)),
              let json = String(data: data, encoding: .utf8) else { return }
        configuration.userContentController.addUserScript(WKUserScript(
            source: runtime + "\nwindow.LeonL10n.setLanguage(" + json + ");",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
    }

    static func apply(_ language: NativeAppLanguage, to view: WKWebView) {
        view.callAsyncJavaScript(
            "window.LeonL10n.setLanguage(payload)",
            arguments: ["payload": payload(language)], in: nil, in: .page
        ) { _ in }
    }

    private static func payload(_ language: NativeAppLanguage) -> [String: Any] {
        ["language": language.rawValue, "strings": NativeLocalization.catalog(language: language)]
    }
}
