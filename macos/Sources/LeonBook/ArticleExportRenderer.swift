import AppKit
import CoreText
import PDFKit
import WebKit

/// A single, ephemeral WebKit instance per export, released when the job ends.
@MainActor
final class ArticleExportRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 960), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func normalize(body: String, links: [String: String], pdf: Bool) async throws -> (html: String, references: [(value: String, token: String)]) {
        try await load(ArticleExportDocument.page(title: "", content: ""))
        guard let scriptURL = Bundle.leonBookResources.url(forResource: "ArticleExport", withExtension: "js") else {
            throw ArticleExportError.renderFailed
        }
        let result = try await webView.callAsyncJavaScript(
            String(contentsOf: scriptURL, encoding: .utf8), arguments: ["body": body, "links": links, "pdf": pdf],
            in: nil, contentWorld: .page
        )
        guard let dictionary = result as? [String: Any], let html = dictionary["html"] as? String,
              let references = dictionary["references"] as? [[String: String]] else { throw ArticleExportError.renderFailed }
        return (html, references.compactMap { entry in
            guard let value = entry["value"], let token = entry["token"] else { return nil }
            return (value, token)
        })
    }

    func writePDF(html: String, to url: URL) async throws {
        try await load(html)
        // Use the same readable layout without invoking AppKit's synchronous
        // print loop, which can hang and prevents cancelling an export.
        _ = try await webView.evaluateJavaScript("""
        const style = document.createElement('style');
        style.textContent = 'body{width:720px;max-width:none;padding:0;font-size:16px;line-height:1.75}img{max-height:980px;object-fit:contain}figure{break-inside:avoid}';
        document.head.append(style);
        """)
        let ready = try await webView.callAsyncJavaScript("""
        await document.fonts.ready;
        return await Promise.race([
            Promise.all([...document.images].map(image => image.decode().then(() => true, () => false))).then(results => results.every(Boolean)),
            new Promise(resolve => setTimeout(() => resolve(false), 15000))
        ]);
        """, arguments: [:], in: nil, contentWorld: .page)
        guard ready as? Bool == true else { throw ArticleExportError.renderFailed }
        try Task.checkCancellation()
        let paper = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        let margin: CGFloat = 44, width: CGFloat = 720
        let scale = (paper.width - 2 * margin) / width
        let capacity = (paper.height - 2 * margin) / scale
        guard let layout = try await webView.callAsyncJavaScript("""
        const spans = [], height = document.body.getBoundingClientRect().height;
        function add(rect) { if (rect.height > 0 && rect.height <= capacity) spans.push([rect.top + scrollY, rect.bottom + scrollY]); }
        document.querySelectorAll('header,h1,h2,h3,h4,h5,h6,p,figure,tr,pre,aside,blockquote,li').forEach(node => add(node.getBoundingClientRect()));
        // Line boxes also protect paragraphs/code blocks taller than one page.
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        while (walker.nextNode()) {
            if (!walker.currentNode.textContent.trim()) continue;
            const range = document.createRange(); range.selectNodeContents(walker.currentNode);
            for (const rect of range.getClientRects()) add(rect);
        }
        const pages = []; let top = 0;
        while (top < height - 0.5) {
            let bottom = Math.min(height, top + capacity);
            if (bottom < height) {
                // Moving a boundary back cannot cross any earlier boundary.
                for (let pass = 0; pass <= spans.length; pass++) {
                    const crossing = spans.filter(([start,end]) => start < bottom - 0.25 && end > bottom + 0.25 && start > top + 0.5);
                    if (!crossing.length) break;
                    const next = Math.min(...crossing.map(span => span[0]));
                    if (next >= bottom) break;
                    bottom = next;
                }
            }
            if (bottom <= top + 0.5) bottom = Math.min(height, top + capacity);
            pages.push([top,bottom]); top = bottom;
        }
        return pages.length ? pages : [[0,1]];
        """, arguments: ["capacity": capacity], in: nil, contentWorld: .page) as? [[Double]],
              !layout.isEmpty else { throw ArticleExportError.renderFailed }
        var mediaBox = paper
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { throw ArticleExportError.renderFailed }
        defer { context.closePDF() }
        for (index, bounds) in layout.enumerated() {
            try Task.checkCancellation()
            let height = CGFloat(bounds[1] - bounds[0])
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(x: 0, y: bounds[0], width: width, height: height)
            let data = try await webView.pdf(configuration: configuration)
            guard let provider = CGDataProvider(data: data as CFData),
                  let source = CGPDFDocument(provider), let page = source.page(at: 1) else { throw ArticleExportError.renderFailed }
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor); context.fill(paper)
            context.saveGState()
            context.clip(to: CGRect(x: margin, y: paper.height - margin - height * scale, width: paper.width - 2 * margin, height: height * scale))
            context.translateBy(x: margin, y: paper.height - margin - height * scale)
            context.scaleBy(x: scale, y: scale)
            context.drawPDFPage(page)
            context.restoreGState()
            // CGContext draws PDF content but does not copy link annotations.
            if let sourcePage = PDFDocument(data: data)?.page(at: 0) {
                let contentRect = CGRect(x: margin, y: paper.height - margin - height * scale, width: paper.width - 2 * margin, height: height * scale)
                for annotation in sourcePage.annotations {
                    guard let link = annotation.url else { continue }
                    let rect = annotation.bounds
                    let mapped = CGRect(x: margin + rect.minX * scale, y: contentRect.minY + rect.minY * scale, width: rect.width * scale, height: rect.height * scale).intersection(contentRect)
                    if !mapped.isNull { context.setURL(link as CFURL, for: mapped) }
                }
            }
            let footer = CTLineCreateWithAttributedString(NSAttributedString(
                string: "\(index + 1) / \(layout.count)",
                attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.gray]
            ))
            context.textPosition = CGPoint(x: (paper.width - CGFloat(CTLineGetTypographicBounds(footer, nil, nil, nil))) / 2, y: 22)
            CTLineDraw(footer, context)
            context.endPDFPage()
        }
    }

    func close() {
        finish(.failure(CancellationError()))
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    private func load(_ html: String) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 25_000_000_000) } catch { return }
                    self?.finish(.failure(ArticleExportError.renderFailed))
                }
                webView.loadHTMLString(html, baseURL: nil)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.close() }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        timeout?.cancel(); timeout = nil
        let pending = continuation; continuation = nil
        pending?.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(ArticleExportError.renderFailed)) }
}
