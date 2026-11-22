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
    let fontSize: CGFloat
    var onQuote: (() -> Void)?
    var onFavorite: (() -> Void)?
    var onBranch: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @State private var rowID = UUID()
    @State private var height: CGFloat = 48

    var body: some View {
        NativeRichMarkdown(key: MarkdownRenderKey(row: rowID, source: source, mine: mine,
                                                dark: colorScheme == .dark, fontSize: fontSize),
                           onQuote: onQuote, onFavorite: onFavorite, onBranch: onBranch, height: $height)
            .frame(maxWidth: .infinity).frame(height: height)
    }
}

private struct MarkdownRenderKey: Hashable {
    let row: UUID
    let source: String
    let mine: Bool
    let dark: Bool
    let fontSize: CGFloat
}

private final class MarkdownHeightKey: NSObject {
    let render: MarkdownRenderKey
    let width: Int

    init(render: MarkdownRenderKey, width: Int) {
        self.render = render
        self.width = width
    }

    override var hash: Int { var hasher = Hasher(); hasher.combine(render); hasher.combine(width); return hasher.finalize() }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? MarkdownHeightKey else { return false }
        return render == other.render && width == other.width
    }
}

@MainActor
private final class MarkdownWebPool {
    static let shared = MarkdownWebPool()
    private var idle: [MarkdownWebView] = []
    let heights = NSCache<MarkdownHeightKey, NSNumber>()

    private init() {
        heights.countLimit = 160
        heights.totalCostLimit = 2 * 1024 * 1024
    }

    func take(for key: MarkdownRenderKey) -> MarkdownWebView {
        if let index = idle.lastIndex(where: { $0.renderKey == key }) { return idle.remove(at: index) }
        return idle.popLast() ?? MarkdownWebView()
    }

    func recycle(_ view: MarkdownWebView) {
        view.onEvent = nil
        view.onQuote = nil
        view.onFavorite = nil
        view.onBranch = nil
        view.toolTip = nil
        view.removeFromSuperview()
        idle.append(view)
        if idle.count > 4 { idle.removeFirst() }
    }
}

private struct NativeRichMarkdown: NSViewRepresentable {
    let key: MarkdownRenderKey
    var onQuote: (() -> Void)?
    var onFavorite: (() -> Void)?
    var onBranch: (() -> Void)?
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MarkdownWebContainer {
        let container = MarkdownWebContainer()
        container.onViewportChange = { [weak coordinator = context.coordinator, weak container] in
            if let container { coordinator?.refresh(in: container) }
        }
        return container
    }

    func updateNSView(_ container: MarkdownWebContainer, context: Context) {
        context.coordinator.update(self)
        container.scheduleRefresh()
    }

    static func dismantleNSView(_ container: MarkdownWebContainer, coordinator: Coordinator) {
        container.onViewportChange = nil
        coordinator.releaseWebView()
    }

    @MainActor
    final class Coordinator {
        var parent: NativeRichMarkdown
        private weak var web: MarkdownWebView?
        private var measurement: MarkdownHeightKey?
        private var needsConfiguration = true

        init(_ parent: NativeRichMarkdown) { self.parent = parent }

        func update(_ parent: NativeRichMarkdown) {
            self.parent = parent
            needsConfiguration = true
        }

        func refresh(in container: MarkdownWebContainer) {
            guard container.isNearViewport else { releaseWebView(); return }
            let key = parent.key
            let width = Int(container.bounds.width.rounded())
            if web != nil, !needsConfiguration, measurement?.width == width { return }
            needsConfiguration = false
            if measurement?.render != key || measurement?.width != width {
                let measured = MarkdownHeightKey(render: key, width: width)
                measurement = measured
                if let height = MarkdownWebPool.shared.heights.object(forKey: measured) {
                    updateHeight(CGFloat(height.doubleValue))
                }
            }
            let view: MarkdownWebView
            if let web {
                view = web
            } else {
                view = MarkdownWebPool.shared.take(for: key)
                view.frame = container.bounds
                view.autoresizingMask = [.width, .height]
                container.addSubview(view)
                web = view
                view.onEvent = { [weak self] event in self?.receive(event) }
                if view.renderKey == key, view.measuredHeight?.width == width, let height = view.measuredHeight?.value {
                    updateHeight(CGFloat(min(200_000, max(24, height))))
                }
            }
            view.onQuote = parent.onQuote
            view.onFavorite = parent.onFavorite
            view.onBranch = parent.onBranch
            view.show(key)
        }

        func releaseWebView() {
            guard let web else { return }
            MarkdownWebPool.shared.recycle(web)
            self.web = nil
        }

        private func updateHeight(_ value: CGFloat) {
            if abs(value - parent.height) > 0.5 { parent.height = value }
        }

        private func receive(_ event: [String: Any]) {
            guard let web else { return }
            switch event["type"] as? String {
            case "height":
                if let height = event["height"] as? Double, height.isFinite, let measurement {
                    let value = min(200_000, max(24, height))
                    MarkdownWebPool.shared.heights.setObject(NSNumber(value: value), forKey: measurement,
                        cost: max(1, measurement.render.source.utf8.count))
                    updateHeight(CGFloat(value))
                }
            case "copy":
                if let text = event["text"] as? String { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
            case "open":
                if let text = event["url"] as? String, let url = URL(string: text), MessageMarkdown.isAllowedLink(url) { NSWorkspace.shared.open(url) }
            case "anchor":
                if let y = event["y"] as? Double, y.isFinite { web.scrollToMessageOffset(CGFloat(max(0, y))) }
            case "context":
                if let x = event["x"] as? Double, let y = event["y"] as? Double, x.isFinite, y.isFinite { web.showOriginalMenu(x: CGFloat(x), y: CGFloat(y)) }
            case "notice":
                web.toolTip = event["text"] as? String
                NSAccessibility.post(element: web, notification: .announcementRequested,
                                     userInfo: [.announcement: event["text"] as? String ?? "", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            default: break
            }
        }
    }
}

private final class MarkdownWebContainer: NSView {
    var onViewportChange: (() -> Void)?
    private var viewport: MarkdownWebViewport?
    private var scheduled = false

    var isNearViewport: Bool {
        guard window != nil, !bounds.isEmpty else { return false }
        guard let clip = viewport?.clip else { return !visibleRect.isEmpty }
        return bounds.intersects(convert(clip.bounds, from: clip).insetBy(dx: 0, dy: -96))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeViewport()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeViewport()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleRefresh()
    }

    private func observeViewport() {
        let current = window == nil ? nil : enclosingScrollView?.contentView
        if viewport?.clip !== current || (current == nil && viewport != nil) {
            viewport?.containers.remove(self)
            viewport = current.map(MarkdownWebViewport.forClip)
            viewport?.containers.add(self)
        }
        scheduleRefresh()
    }

    func scheduleRefresh() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.onViewportChange?()
        }
    }

}

@MainActor
private final class MarkdownWebViewport {
    private static let viewports = NSMapTable<NSClipView, MarkdownWebViewport>.weakToWeakObjects()
    let containers = NSHashTable<MarkdownWebContainer>.weakObjects()
    private(set) weak var clip: NSClipView?
    private var observer: NSObjectProtocol?
    private var scheduled = false

    static func forClip(_ clip: NSClipView) -> MarkdownWebViewport {
        if let viewport = viewports.object(forKey: clip) { return viewport }
        let viewport = MarkdownWebViewport(clip)
        viewports.setObject(viewport, forKey: clip)
        return viewport
    }

    private init(_ clip: NSClipView) {
        self.clip = clip
        clip.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
    }

    private func scheduleRefresh() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            let views = self.containers.allObjects
            // Return offscreen views before visible rows borrow from the pool.
            for view in views where !view.isNearViewport { view.onViewportChange?() }
            for view in views where view.isNearViewport { view.onViewportChange?() }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

@MainActor
private final class MarkdownScriptHandler: NSObject, WKScriptMessageHandler {
    weak var web: MarkdownWebView?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let event = message.body as? [String: Any] else { return }
        web?.receive(event)
    }
}

private final class MarkdownWebView: WKWebView, WKNavigationDelegate {
    private static let dataStore = WKWebsiteDataStore.nonPersistent()
    private(set) var renderKey: MarkdownRenderKey?
    private(set) var measuredHeight: (width: Int, value: Double)?
    private var ready = false
    private var token = UUID()
    private var sentToken: UUID?
    private var resetContent = false
    var onEvent: (([String: Any]) -> Void)?
    var onQuote: (() -> Void)?
    var onFavorite: (() -> Void)?
    var onBranch: (() -> Void)?
    var rawSource: String { renderKey?.source ?? "" }

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let handler = MarkdownScriptHandler()
        let controller = configuration.userContentController
        controller.add(handler, name: "leonMarkdownHost")
        controller.addUserScript(WKUserScript(source: """
            window.addEventListener("leon-markdown-event", function(event) {
                window.webkit.messageHandlers.leonMarkdownHost.postMessage(
                    Object.assign({}, event.detail, { token: window.leonMarkdownToken || "" }));
            });
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        super.init(frame: .zero, configuration: configuration)
        handler.web = self
        setValue(false, forKey: "drawsBackground")
        underPageBackgroundColor = .clear
        allowsLinkPreview = false
        navigationDelegate = self
        if let runtime = RichMarkdown.runtimeURL {
            loadFileURL(runtime.appendingPathComponent("markdown.html"), allowingReadAccessTo: runtime)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func show(_ key: MarkdownRenderKey) {
        if key != renderKey {
            resetContent = renderKey?.row != key.row
            renderKey = key
            measuredHeight = nil
            token = UUID()
            isHidden = true
            if RichMarkdown.runtimeURL == nil {
                let escaped = key.source.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                loadHTMLString("<pre style='font-size: \(key.fontSize - 1)px'>\(escaped)</pre>", baseURL: nil)
                isHidden = false
                return
            }
        }
        guard ready, sentToken != token else { return }
        let current = token
        sentToken = current
        callAsyncJavaScript("""
            window.leonMarkdownToken = version;
            document.body.style.setProperty("--leon-chat-body-font-size", `${size}px`);
            if (reset) {
                window.getSelection()?.removeAllRanges();
                void window.renderMessage(Object.assign({}, input, { source: "" }));
            }
            void window.renderMessage(input);
            """, arguments: [
                "input": ["source": key.source, "mine": key.mine, "dark": key.dark, "platform": "mac"],
                "version": current.uuidString, "reset": resetContent, "size": key.fontSize
            ], in: nil, in: .page) { [weak self] _ in
                guard let self, self.token == current else { return }
                self.isHidden = false
            }
    }

    func receive(_ event: [String: Any]) {
        if event["type"] as? String == "ready" {
            ready = true
            if let renderKey { show(renderKey) }
        } else if event["token"] as? String == token.uuidString {
            if event["type"] as? String == "height", let height = event["height"] as? Double, height.isFinite {
                measuredHeight = (Int(bounds.width.rounded()), height)
            }
            onEvent?(event)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        sentToken = nil
        reload()
    }

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
