import AppKit
import PDFKit
import Network
@testable import LeonBook

private struct ExportTestFailure: Error, CustomStringConvertible { let description: String }
private func exportExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw ExportTestFailure(description: message) }
}

final class ArticleExportTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("leon-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func save(_ store: LocalBlogStore, slug: String, title: String = "导出测试", body: String, media: [NativeMedia] = []) async throws {
        _ = try await store.saveArticle(NativeSaveArticle(
            banner: nil, body: body, category: "测试分类", excerpt: "文章摘要", media: media,
            slug: slug, status: .published, tags: ["测试"], title: title, expectedUpdatedAt: nil
        ))
    }

    private func image(at url: URL) throws -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let color = NSColor(deviceRed: 0.2, green: 0.6, blue: 0.4, alpha: 1)
        for y in 0..<100 { for x in 0..<300 { bitmap.setColor(color, atX: x, y: y) } }
        let data = bitmap.representation(using: .png, properties: [:])!
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return data
    }

    @MainActor
    func testStandaloneHTMLIsOfflineAndSanitized() async throws {
        _ = NSApplication.shared
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("workspace"), store = LocalBlogStore(rootURL: root)
        try await save(store, slug: "single", body: RichArticleDocument.empty)
        let png = try image(at: root.appendingPathComponent("media/single/图片 & 一.png"))
        let attachment = root.appendingPathComponent("media/single/附件.txt")
        try Data("original attachment".utf8).write(to: attachment)
        let original = try await store.getArticle(slug: "single")
        _ = try await store.saveArticle(NativeSaveArticle(
            banner: nil,
            body: RichArticleDocument.opening + "<h2>正文标题</h2><p style=\"color:#123456;background-image:url(https://invalid.test/track)\" onclick=\"alert(1)\">中文 &amp; English</p><img src=\"/media/single/图片 &amp; 一.png\"><table><tr><th>表头</th></tr><tr><td>内容</td></tr></table><script>alert(1)</script><iframe src=\"https://example.com/page\" title=\"来源网页\"></iframe></article>",
            category: original.category, excerpt: original.excerpt,
            media: [NativeMedia(kind: "file", name: "附件.txt", size: 19, url: "/media/single/附件.txt")],
            slug: "single", status: .published, tags: ["测试"], title: "标题 <安全>", expectedUpdatedAt: original.updatedAt
        ))
        let output = dir.appendingPathComponent("article.html")
        try Data("old export".utf8).write(to: output)
        try await ArticleExportService.export(slugs: ["single"], store: store, format: .html, includeMetadata: true, destination: output)
        let html = try String(contentsOf: output)
        try exportExpect(html.contains("标题 &lt;安全&gt;"), "escape article title")
        try exportExpect(html.contains("data:image/png;base64," + png.base64EncodedString()), "inline the exact image bytes")
        try exportExpect(html.contains("data:text/plain;base64,"), "inline file attachments")
        try exportExpect(html.contains("download=") && html.contains("来源网页") && html.contains("<table>"), "keep download links, embeds as links, and tables")
        try exportExpect(!html.contains("onclick") && !html.contains("<script") && !html.contains("<iframe") && !html.contains("background-image"), "strip active content and network CSS")
        try exportExpect(!html.contains("/media/single/") && !html.contains(root.path) && !html.contains("leon-export-asset:"), "no workspace dependencies or unresolved tokens")
        let renderer = ArticleExportRenderer()
        defer { renderer.close() }
        let normalized = try await renderer.normalize(body: html, links: [:], pdf: false)
        try exportExpect(normalized.references.isEmpty, "standalone output must not need external media")
    }

    @MainActor
    func testBatchPackagePreservesAttachmentsAndLinks() async throws {
        _ = NSApplication.shared
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("workspace"), store = LocalBlogStore(rootURL: root)
        try await save(store, slug: "first", title: "../index # 1", body: RichArticleDocument.empty)
        let png = try image(at: root.appendingPathComponent("media/first/picture.png"))
        try await save(store, slug: "second", title: "../index # 1", body: RichArticleDocument.opening + "<img src=\"/media/first/picture.png\"><a href=\"leonbook://open?slug=first\">第一篇</a></article>")
        let output = dir.appendingPathComponent("batch.zip")
        var counts: [Int] = []
        try await ArticleExportService.export(slugs: ["first", "second", "first"], store: store, format: .package, includeMetadata: false, destination: output) { count, _ in counts.append(count) }
        try exportExpect(counts.last == 2, "deduplicate selection and report completion")
        let expanded = dir.appendingPathComponent("expanded")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", output.path, expanded.path]
        try process.run(); process.waitUntilExit()
        try exportExpect(process.terminationStatus == 0, "ZIP must be readable")
        let content = expanded.appendingPathComponent("LeonBook Articles")
        let index = try String(contentsOf: content.appendingPathComponent("index.html"))
        let files = try FileManager.default.contentsOfDirectory(at: content, includingPropertiesForKeys: nil).filter { $0.pathExtension == "html" && $0.lastPathComponent != "index.html" }
        try exportExpect(files.count == 2 && Set(files.map(\.lastPathComponent)).count == 2, "duplicate and traversal-like titles need distinct safe filenames")
        for file in files { try exportExpect(index.contains(ArticleExportDocument.relativeURL(file.lastPathComponent)), "index must link every article with URL-safe paths") }
        let second = try files.map { try String(contentsOf: $0) }.first { $0.contains("第一篇") }!
        try exportExpect(!second.contains("leonbook://") && !second.contains("文章摘要"), "rewrite cross-article links and honor metadata toggle")
        let assets = try FileManager.default.contentsOfDirectory(at: content.appendingPathComponent("assets"), includingPropertiesForKeys: nil)
        try exportExpect(assets.count == 1 && (try Data(contentsOf: assets[0])) == png, "package contains original image bytes")
        try exportExpect(second.contains("assets/"), "package HTML uses relative asset paths")
        let htmlBatch = dir.appendingPathComponent("batch-html.zip")
        try await ArticleExportService.export(slugs: ["first", "second"], store: store, format: .html, includeMetadata: false, destination: htmlBatch)
        try exportExpect(FileManager.default.fileExists(atPath: htmlBatch.path), "batch standalone HTML must also produce ZIP")
    }

    @MainActor
    func testPDFHasA4PagesAndCompleteContent() async throws {
        _ = NSApplication.shared
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("workspace"), store = LocalBlogStore(rootURL: root)
        try await save(store, slug: "pdf", body: RichArticleDocument.empty)
        _ = try image(at: root.appendingPathComponent("media/pdf/picture.png"))
        let paragraphs = (1...42).map { "<p>第 \($0) 段：这是用于验证中文长文分页的段落。Mixed English text, punctuation &amp; readable typography.</p>" }.joined()
        let body = RichArticleDocument.opening + "<h2>中文排版与图片</h2><img src=\"/media/pdf/picture.png\"><table><thead><tr><th>项目</th><th>说明</th></tr></thead><tbody><tr><td>表格</td><td>正确换行</td></tr></tbody></table><pre><code>let exported = true\nprint(exported)</code></pre>" + paragraphs + "<p>EXPORT-END 完整结束</p></article>"
        let article = try await store.getArticle(slug: "pdf")
        _ = try await store.saveArticle(NativeSaveArticle(banner: nil, body: body, category: "测试", excerpt: "验证多页 PDF", media: [], slug: "pdf", status: .published, tags: ["导出"], title: "LeonBook 导出排版验证", expectedUpdatedAt: article.updatedAt))
        let output = dir.appendingPathComponent("article.pdf")
        try await ArticleExportService.export(slugs: ["pdf"], store: store, format: .pdf, includeMetadata: true, destination: output)
        guard let pdf = PDFDocument(url: output) else { throw ExportTestFailure(description: "PDF must open") }
        try exportExpect(pdf.pageCount >= 2, "long articles must paginate instead of using one giant page")
        let text = pdf.string ?? ""
        if let path = ProcessInfo.processInfo.environment["LEON_BOOK_EXPORT_QA_DIR"] {
            let qa = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: qa, withIntermediateDirectories: true)
            try text.write(to: qa.appendingPathComponent("text.txt"), atomically: true, encoding: .utf8)
        }
        try exportExpect(text.components(separatedBy: "typography.").count - 1 == 42, "every paragraph must be complete across page boundaries")
        try exportExpect(text.contains("EXPORT-END") && text.contains("LeonBook") && text.contains("exported = true"), "PDF must include first and last content and code")
        for index in 0..<pdf.pageCount {
            let bounds = pdf.page(at: index)!.bounds(for: .mediaBox)
            try exportExpect(abs(bounds.width - 595.28) < 2 && abs(bounds.height - 841.89) < 2, "every page must be A4")
        }
        if let path = ProcessInfo.processInfo.environment["LEON_BOOK_EXPORT_QA_DIR"] {
            let qa = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: qa, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: output, to: qa.appendingPathComponent("article-export.pdf"))
            try text.write(to: qa.appendingPathComponent("text.txt"), atomically: true, encoding: .utf8)
        }
    }

    @MainActor
    func testFailureCancellationAndSourceProtection() async throws {
        _ = NSApplication.shared
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("workspace"), store = LocalBlogStore(rootURL: root)
        try await save(store, slug: "missing", body: RichArticleDocument.opening + "<img src=\"/media/missing/lost.png\"></article>")
        let output = dir.appendingPathComponent("article.html"), sentinel = Data("previous export".utf8)
        try sentinel.write(to: output)
        do {
            try await ArticleExportService.export(slugs: ["missing"], store: store, format: .html, includeMetadata: true, destination: output)
            throw ExportTestFailure(description: "missing attachments must fail")
        } catch ArticleExportError.missingAsset { }
        try exportExpect(try Data(contentsOf: output) == sentinel, "failure must leave previous export intact")
        let article = try await store.getArticle(slug: "missing")
        let source = root.appendingPathComponent("articles").appendingPathComponent(article.sourceRelativePath)
        let original = try Data(contentsOf: source)
        do {
            try await ArticleExportService.export(slugs: ["missing"], store: store, format: .html, includeMetadata: true, destination: source)
            throw ExportTestFailure(description: "cannot overwrite a library article")
        } catch ArticleExportError.invalidDestination { }
        try exportExpect(try Data(contentsOf: source) == original, "original article must be unchanged")
        let media = root.appendingPathComponent("media/missing")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: media.appendingPathComponent("lost.png"), withDestinationURL: output)
        do {
            try await ArticleExportService.export(slugs: ["missing"], store: store, format: .package, includeMetadata: true, destination: dir.appendingPathComponent("escape.zip"))
            throw ExportTestFailure(description: "symlink must not expose files outside workspace")
        } catch ArticleExportError.missingAsset { }
        let cancelled = Task {
            try await ArticleExportService.export(slugs: ["missing"], store: store, format: .html, includeMetadata: true, destination: output)
        }
        cancelled.cancel()
        do { try await cancelled.value; throw ExportTestFailure(description: "cancelled job must fail") } catch is CancellationError { }
        try exportExpect(try Data(contentsOf: output) == sentinel, "cancellation must preserve destination")
    }

    @MainActor
    func testRemoteImagesAndBatchPDF() async throws {
        _ = NSApplication.shared
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let png = try image(at: dir.appendingPathComponent("fixture.png"))
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { _, _, _, _ in
                let headers = Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(png.count)\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: headers + png, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
            }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        for _ in 0..<100 { if (listener.port?.rawValue ?? 0) > 0 { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        guard let port = listener.port, port.rawValue > 0 else { throw ExportTestFailure(description: "local fixture server must start") }
        let store = LocalBlogStore(rootURL: dir.appendingPathComponent("workspace"))
        try await save(store, slug: "remote", body: RichArticleDocument.opening + "<p>REMOTE-IMAGE</p><img src=\"http://127.0.0.1:\(port.rawValue)/image\"><a href=\"https://example.com\">Web link</a></article>")
        try await save(store, slug: "legacy", body: "## Legacy heading\n\nLegacy article body.")
        let html = dir.appendingPathComponent("remote.html")
        try await ArticleExportService.export(slugs: ["remote"], store: store, format: .html, includeMetadata: true, destination: html)
        try exportExpect(try String(contentsOf: html).contains("data:image/png;base64," + png.base64EncodedString()), "extensionless remote images must use the response MIME type")
        let archive = dir.appendingPathComponent("pdfs.zip")
        try await ArticleExportService.export(slugs: ["remote", "legacy"], store: store, format: .pdf, includeMetadata: false, destination: archive)
        let expanded = dir.appendingPathComponent("expanded")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, expanded.path]
        try process.run(); process.waitUntilExit()
        let files = try FileManager.default.contentsOfDirectory(at: expanded.appendingPathComponent("LeonBook Articles"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "pdf" }
        try exportExpect(files.count == 2, "batch PDF must contain two distinct PDFs even with duplicate titles")
        let documents = files.compactMap { PDFDocument(url: $0) }
        try exportExpect(documents.count == 2 && documents.allSatisfy { $0.pageCount > 0 }, "every exported PDF must be readable")
        try exportExpect(documents.contains { ($0.string ?? "").contains("Legacy heading") }, "legacy Markdown must remain readable on export")
    }
}
