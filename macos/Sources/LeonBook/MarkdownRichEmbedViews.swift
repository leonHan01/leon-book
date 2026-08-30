import AVKit
import AppKit
import Foundation
import PDFKit
import SwiftUI
import WebKit

struct NativePDFEmbedView: View {
    let reference: String
    let title: String
    let store: LocalBlogStore
    let sourceRelativePath: String?

    @State private var fileURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(title.isEmpty ? "PDF" : title, systemImage: "doc.richtext")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if let fileURL {
                    Button {
                        NSWorkspace.shared.open(fileURL)
                    } label: {
                        Label("在预览中打开", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.secondary.opacity(0.08))

            if let fileURL {
                NativePDFKitView(fileURL: fileURL)
                    .frame(maxWidth: .infinity, minHeight: 520, maxHeight: 680)
            } else if let errorMessage {
                Label(errorMessage, systemImage: "doc.badge.ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                ProgressView("正在载入 PDF…")
                    .frame(maxWidth: .infinity, minHeight: 140)
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.22)) }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: "\(reference)|\(sourceRelativePath ?? "")") {
            fileURL = await store.mediaURL(
                for: reference,
                relativeToMarkdownSource: sourceRelativePath
            )
            errorMessage = fileURL == nil ? "找不到 PDF：\(reference)" : nil
        }
    }
}

private struct NativePDFKitView: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.document = PDFDocument(url: fileURL)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard view.document?.documentURL != fileURL else { return }
        view.document = PDFDocument(url: fileURL)
        view.autoScales = true
    }
}

struct NativeAudioEmbedView: View {
    let reference: String
    let title: String
    let store: LocalBlogStore
    let sourceRelativePath: String?

    @State private var player: AVPlayer?
    @State private var fileURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(title.isEmpty ? "音频" : title, systemImage: "waveform")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if let fileURL {
                    Button {
                        NSWorkspace.shared.open(fileURL)
                    } label: {
                        Label("打开文件", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            if let player {
                NativeAudioPlayerView(player: player)
                    .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 64)
            } else if let errorMessage {
                Label(errorMessage, systemImage: "speaker.slash")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            } else {
                ProgressView("正在载入音频…")
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)) }
        .task(id: "\(reference)|\(sourceRelativePath ?? "")") {
            player?.pause()
            player = nil
            fileURL = await store.mediaURL(
                for: reference,
                relativeToMarkdownSource: sourceRelativePath
            )
            guard let fileURL else {
                errorMessage = "找不到音频：\(reference)"
                return
            }
            errorMessage = nil
            player = AVPlayer(url: fileURL)
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

private struct NativeAudioPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = false
        view.allowsVideoFrameAnalysis = false
        view.updatesNowPlayingInfoCenter = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

struct MarkdownMathView: View {
    let source: String
    let display: Bool
    @State private var contentHeight: CGFloat = 44

    var body: some View {
        NativeScriptedMarkdownWebView(
            document: .math(source: source, display: display),
            onHeightChange: { contentHeight = $0 }
        )
        .frame(maxWidth: .infinity, minHeight: contentHeight, maxHeight: contentHeight)
        .accessibilityLabel(display ? "LaTeX 公式" : "含行内公式的段落")
    }
}

struct MarkdownMermaidView: View {
    let source: String
    @State private var contentHeight: CGFloat = 180

    var body: some View {
        NativeScriptedMarkdownWebView(
            document: .mermaid(source: source),
            onHeightChange: { contentHeight = $0 }
        )
        .frame(maxWidth: .infinity, minHeight: contentHeight, maxHeight: contentHeight)
        .background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.16)) }
        .accessibilityLabel("Mermaid 图表")
    }
}

private enum NativeScriptedMarkdownDocument: Equatable {
    case math(source: String, display: Bool)
    case mermaid(source: String)

    var html: String {
        switch self {
        case let .math(source, display):
            let encoded = Self.javaScriptString(source)
            return """
            <!doctype html><html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' https://cdn.jsdelivr.net; style-src 'unsafe-inline' https://cdn.jsdelivr.net; font-src https://cdn.jsdelivr.net data:">
            <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
            <style>
            :root { color-scheme: light dark; }
            html, body { margin: 0; padding: 0; background: transparent; color: CanvasText; }
            body { font: 17px -apple-system, BlinkMacSystemFont, sans-serif; line-height: 1.55; overflow: hidden; }
            #content { padding: 6px 4px; overflow-wrap: anywhere; }
            .katex-display { margin: 0.35em 0; overflow-x: auto; overflow-y: hidden; }
            .fallback { white-space: pre-wrap; font-family: ui-monospace, monospace; color: GrayText; }
            </style></head><body><div id="content"></div>
            <script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
            <script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"></script>
            <script>
            const source = \(encoded), display = \(display ? "true" : "false");
            const root = document.getElementById('content');
            function notify() { requestAnimationFrame(() => window.webkit.messageHandlers.leonbookHeight.postMessage(Math.ceil(document.documentElement.scrollHeight))); }
            function render() {
              try {
                if (display) { katex.render(source, root, {displayMode:true, throwOnError:false, strict:'warn'}); }
                else { root.textContent = source; renderMathInElement(root, {delimiters:[{left:'$',right:'$',display:false},{left:'\\\\(',right:'\\\\)',display:false}], throwOnError:false, strict:'warn'}); }
              } catch (error) { root.className='fallback'; root.textContent=source; }
              notify();
            }
            window.addEventListener('load', render); setTimeout(() => { if (!root.textContent && !root.children.length) { root.className='fallback'; root.textContent=source; notify(); } }, 4000);
            </script></body></html>
            """
        case let .mermaid(source):
            let encoded = Self.javaScriptString(source)
            return """
            <!doctype html><html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' https://cdn.jsdelivr.net; style-src 'unsafe-inline'; img-src data:">
            <style>
            :root { color-scheme: light dark; }
            html, body { margin: 0; padding: 0; background: transparent; color: CanvasText; overflow: hidden; }
            #diagram { margin: 0; padding: 14px; display: flex; justify-content: center; overflow-x: auto; }
            #diagram svg { max-width: 100%; height: auto; }
            .fallback { white-space: pre-wrap; font: 13px ui-monospace, monospace; color: GrayText; justify-content: flex-start !important; }
            </style></head><body><pre id="diagram"></pre>
            <script src="https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.min.js"></script>
            <script>
            const source = \(encoded), root = document.getElementById('diagram'); root.textContent = source;
            function notify() { requestAnimationFrame(() => window.webkit.messageHandlers.leonbookHeight.postMessage(Math.ceil(document.documentElement.scrollHeight))); }
            async function render() {
              try { mermaid.initialize({startOnLoad:false, securityLevel:'strict', theme:matchMedia('(prefers-color-scheme: dark)').matches?'dark':'default'}); await mermaid.run({nodes:[root]}); }
              catch (error) { root.className='fallback'; root.textContent=source+'\\n\\n'+String(error); }
              notify();
            }
            window.addEventListener('load', render); setTimeout(() => { if (!root.querySelector('svg')) { root.className='fallback'; root.textContent=source; notify(); } }, 5000);
            </script></body></html>
            """
        }
    }

    private static func javaScriptString(_ source: String) -> String {
        guard let data = try? JSONEncoder().encode(source),
              var encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        encoded = encoded.replacingOccurrences(of: "</", with: "<\\/")
        return encoded
    }
}

private struct NativeScriptedMarkdownWebView: NSViewRepresentable {
    let document: NativeScriptedMarkdownDocument
    let onHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onHeightChange: onHeightChange)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.add(context.coordinator, name: "leonbookHeight")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.loadedDocument = document
        view.loadHTMLString(document.html, baseURL: nil)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onHeightChange = onHeightChange
        guard context.coordinator.loadedDocument != document else { return }
        context.coordinator.loadedDocument = document
        view.loadHTMLString(document.html, baseURL: nil)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "leonbookHeight")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var loadedDocument: NativeScriptedMarkdownDocument?
        var onHeightChange: (CGFloat) -> Void

        init(onHeightChange: @escaping (CGFloat) -> Void) {
            self.onHeightChange = onHeightChange
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "leonbookHeight",
                  let number = message.body as? NSNumber else { return }
            let height = min(max(CGFloat(truncating: number), 36), 900)
            DispatchQueue.main.async { self.onHeightChange(height) }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if navigationAction.navigationType == .linkActivated,
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            let scheme = url.scheme?.lowercased()
            decisionHandler(scheme == "about" || scheme == "https" ? .allow : .cancel)
        }
    }
}

