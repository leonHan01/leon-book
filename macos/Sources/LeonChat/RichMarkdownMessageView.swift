import SwiftUI
import AppKit
import WebKit

enum RichMarkdown {
    // Basic text and math keep the lightweight native renderer. Extended syntax
    // uses the same bundled renderer as Android, including HTML tables/collapse.
    static func isRequired(_ source: String) -> Bool {
        source.range(of: #"(?m)```|~~~|!\[|<[/!A-Za-z]|\[\^|\[\[|\[![A-Za-z]+\]|==[^=\n]+==|\^[^\s^]+\^|(?:^|[^~])~[^~\s]+~(?:[^~]|$)|:[+\w-]+:|^\s*:\s+|[-+*]\s+\[[ xX]\]|\d+[.)]\s+\[[ xX]\]|\\(?:newcommand|renewcommand|def|tag|begin\{aligned)"#,
                     options: .regularExpression) != nil
    }

    static var runtimeURL: URL? {
        ChatResources.bundle.url(forResource: "MarkdownRuntime", withExtension: nil)
    }
}

struct RichMarkdownMessageView: View {
    let source: String
    let mine: Bool
    var onQuote:(()->Void)? = nil
    var onFavorite:(()->Void)? = nil
    var onBranch:(()->Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var layout = MarkdownLayoutState()

    var body: some View {
        Group {
            if layout.visible {
                NativeRichMarkdown(source: source, mine: mine,onQuote:onQuote,onFavorite:onFavorite,onBranch:onBranch, dark: colorScheme == .dark, height: $layout.height)
            } else {
                Color.clear
            }
        }.frame(maxWidth: .infinity).frame(height: layout.height)
            .onAppear { layout.visible = true }
            .onDisappear { layout.visible = false }
    }
}

private final class MarkdownLayoutState: ObservableObject {
    @Published var height: CGFloat = 48
    @Published var visible = false
}

private struct NativeRichMarkdown: NSViewRepresentable {
    let source: String
    let mine: Bool
    var onQuote:(()->Void)? = nil
    var onFavorite:(()->Void)? = nil
    var onBranch:(()->Void)? = nil
    let dark: Bool
    @Binding var height: CGFloat
    private static let dataStore = WKWebsiteDataStore.nonPersistent()

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MarkdownWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "leonMarkdown")
        let view = MarkdownWebView(frame: .zero, configuration: configuration)
        // AppKit WebKit otherwise paints an opaque white page behind transparent
        // HTML, hiding the outgoing bubble and dark appearance beneath it.
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        view.allowsLinkPreview = false
        view.navigationDelegate = context.coordinator
        view.rawSource = source;view.onQuote=onQuote;view.onFavorite=onFavorite;view.onBranch=onBranch
        context.coordinator.view = view
        if let runtime = RichMarkdown.runtimeURL {
            view.loadFileURL(runtime.appendingPathComponent("markdown.html"), allowingReadAccessTo: runtime)
        } else {
            // Keep content readable even if a damaged installation lost its resources.
            view.loadHTMLString("<pre>\(source.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;"))</pre>", baseURL: nil)
        }
        return view
    }

    func updateNSView(_ view: MarkdownWebView, context: Context) {
        context.coordinator.parent = self
        view.rawSource = source;view.onQuote=onQuote;view.onFavorite=onFavorite;view.onBranch=onBranch
        context.coordinator.render()
    }

    static func dismantleNSView(_ view: MarkdownWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "leonMarkdown")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: NativeRichMarkdown
        weak var view: MarkdownWebView?
        var ready = false
        private var lastPayload: String?
        init(_ parent: NativeRichMarkdown) { self.parent = parent }

        func render() {
            guard ready, let view,
                  let data = try? JSONSerialization.data(withJSONObject: ["source": parent.source, "mine": parent.mine, "dark": parent.dark, "platform": "mac"]),
                  let json = String(data: data, encoding: .utf8), json != lastPayload else { return }
            lastPayload = json
            view.evaluateJavaScript("void window.renderMessage(\(json))", completionHandler: nil)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let value = message.body as? String,
                  let data = value.data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { return }
            switch type {
            case "ready": ready = true; render()
            case "height":
                if let height = event["height"] as? Double, height.isFinite {
                    let value = CGFloat(min(200_000, max(24, height)))
                    if abs(value - parent.height) > 0.5 { parent.height = value }
                }
            case "copy":
                if let text = event["text"] as? String { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
            case "open":
                if let text = event["url"] as? String, let url = URL(string: text), MessageMarkdown.isAllowedLink(url) { NSWorkspace.shared.open(url) }
            case "anchor":
                if let y = event["y"] as? Double, y.isFinite, let view { view.scrollToMessageOffset(CGFloat(max(0, y))) }
            case "context":
                if let x = event["x"] as? Double, let y = event["y"] as? Double, x.isFinite, y.isFinite {
                    view?.showOriginalMenu(x: CGFloat(x), y: CGFloat(y))
                }
            case "notice":
                view?.toolTip = event["text"] as? String
                if let view {
                    NSAccessibility.post(element: view, notification: .announcementRequested,
                                         userInfo: [.announcement: event["text"] as? String ?? "", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                }
            default: break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; render() }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url,
               url.isFileURL, let runtime = RichMarkdown.runtimeURL,
               url.standardizedFileURL.path.hasPrefix(runtime.standardizedFileURL.path + "/") {
                decisionHandler(.allow)
            } else if navigationAction.request.url?.absoluteString == "about:blank" {
                decisionHandler(.allow)
            } else {
                if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url, MessageMarkdown.isAllowedLink(url) { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            }
        }
    }
}

private final class MarkdownWebView: WKWebView {
    var onQuote:(()->Void)?
    var onFavorite:(()->Void)?
    var onBranch:(()->Void)?
    var rawSource = ""
    override var isOpaque: Bool { false }
    override func scrollWheel(with event: NSEvent) {
        if let parent = enclosingScrollView { parent.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }
    }
    func scrollToMessageOffset(_ y: CGFloat) {
        scrollToVisible(NSRect(x: 0, y: y, width: 1, height: 28))
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        for item in menu.items where item.identifier?.rawValue == "leon-copy-markdown" { menu.removeItem(item) }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let item = NSMenuItem(title: "复制原文", action: #selector(copyOriginal), keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("leon-copy-markdown")
        item.target = self; menu.addItem(item)
        appendMessageActions(menu)
        return menu
    }
    func showOriginalMenu(x: CGFloat, y: CGFloat) {
        let menu = NSMenu()
        let item = NSMenuItem(title: "复制原文", action: #selector(copyOriginal), keyEquivalent: "")
        item.target = self; menu.addItem(item)
        appendMessageActions(menu)
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: isFlipped ? y : bounds.height - y), in: self)
    }
    private func appendMessageActions(_ menu:NSMenu) {
        if onQuote != nil {let item=NSMenuItem(title:"引用",action:#selector(quoteMessage),keyEquivalent:"");item.target=self;menu.addItem(item)}
        if onFavorite != nil {let item=NSMenuItem(title:"收藏",action:#selector(favoriteMessage),keyEquivalent:"");item.target=self;menu.addItem(item)}
        if onBranch != nil {let item=NSMenuItem(title:"从这里创建分支",action:#selector(branchMessage),keyEquivalent:"");item.target=self;menu.addItem(item)}
    }
    @objc private func quoteMessage(){onQuote?()}
    @objc private func favoriteMessage(){onFavorite?()}
    @objc private func branchMessage(){onBranch?()}
    @objc private func copyOriginal() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(rawSource, forType: .string) }
}
