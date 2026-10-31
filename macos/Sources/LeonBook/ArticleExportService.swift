import Foundation
import UniformTypeIdentifiers

enum ArticleExportFormat: String, CaseIterable, Identifiable {
    case pdf, html, package
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pdf: return "PDF 文档"
        case .html: return "独立 HTML"
        case .package: return "文章包（HTML 与附件）"
        }
    }
    var description: String {
        switch self {
        case .pdf: return "A4 分页排版，保留正文、图片、表格与代码。"
        case .html: return "将图片与媒体内嵌到 HTML，单个文件即可离线阅读。"
        case .package: return "HTML 与原始附件一起打包为 ZIP，解压后打开 index.html。"
        }
    }
    func fileExtension(count: Int) -> String { count > 1 || self == .package ? "zip" : rawValue }
}

enum ArticleExportError: LocalizedError {
    case emptySelection, renderFailed, invalidDestination
    case missingAsset(String), oversizedHTML, downloadFailed(String), archiveFailed

    var errorDescription: String? {
        switch self {
        case .emptySelection: return NativeLocalization.text("请至少选择一篇文章。")
        case .renderFailed: return NativeLocalization.text("文章排版失败，请检查图片是否完整后重试。")
        case .invalidDestination: return NativeLocalization.text("请选择资料库以外的导出位置，避免覆盖原始文章或附件。")
        case .missingAsset(let name): return NativeLocalization.text("找不到文章附件：\(name)")
        case .oversizedHTML: return NativeLocalization.text("内嵌媒体超过 256 MB，请改用文章包导出。")
        case .downloadFailed(let name): return NativeLocalization.text("无法下载远程媒体：\(name)。请检查网络后重试。")
        case .archiveFailed: return NativeLocalization.text("无法创建文章压缩包。")
        }
    }
}

/// File IO and packaging run outside the main actor. Only WebKit layout uses it.
enum ArticleExportService {
    static func export(
        slugs: [String], store: LocalBlogStore, format: ArticleExportFormat,
        includeMetadata: Bool, destination: URL,
        progress: @escaping @MainActor (Int, String) -> Void = { _, _ in }
    ) async throws {
        var seen = Set<String>()
        let uniqueSlugs = slugs.filter { seen.insert($0).inserted }
        guard !uniqueSlugs.isEmpty else { throw ArticleExportError.emptySelection }
        let root = store.rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let articlesRoot = try await store.markdownSourceDirectoryURL().standardizedFileURL.resolvingSymlinksInPath()
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard !isInside(target, root: root), !isInside(target, root: articlesRoot) else { throw ArticleExportError.invalidDestination }
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("leon-article-export-\(UUID().uuidString)", isDirectory: true)
        let content = scratch.appendingPathComponent("LeonBook Articles", isDirectory: true)
        try fm.createDirectory(at: content, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let renderer = await ArticleExportRenderer()
        do {
            var articles: [NativeArticle] = []
            for slug in uniqueSlugs { try Task.checkCancellation(); articles.append(try await store.getArticle(slug: slug)) }
            var filenames: [String: String] = [:], usedNames = Set<String>()
            for article in articles {
                let base = ArticleExportDocument.filename(article.title, fallback: "Article")
                var name = base, suffix = 2
                while usedNames.contains(name.lowercased()) || name.lowercased() == "index" {
                    name = "\(base)-\(suffix)"; suffix += 1
                }
                usedNames.insert(name.lowercased())
                filenames[article.slug] = name + (format == .pdf ? ".pdf" : ".html")
            }
            var cachedAssets: [String: String] = [:]
            var embeddedBytes = 0
            for (index, article) in articles.enumerated() {
                try Task.checkCancellation()
                await progress(index, article.title)
                let normalized = try await renderer.normalize(
                    body: ArticleExportDocument.body(article, includeMetadata: includeMetadata),
                    links: articles.count > 1 ? filenames.mapValues(ArticleExportDocument.relativeURL) : [:], pdf: format == .pdf
                )
                var html = normalized.html
                for reference in normalized.references {
                    try Task.checkCancellation()
                    let replacement = try await resolveAsset(
                        reference.value, article: article, store: store, root: root, articlesRoot: articlesRoot,
                        directory: content, packaged: format == .package, cache: &cachedAssets, embeddedBytes: &embeddedBytes
                    )
                    // A terminating quote avoids replacing asset:1 inside asset:10.
                    html = html.replacingOccurrences(of: reference.token + "\"", with: RichArticleDocument.escape(replacement) + "\"")
                }
                let page = ArticleExportDocument.page(title: article.title, content: html)
                let output = content.appendingPathComponent(filenames[article.slug]!)
                if format == .pdf { try await renderer.writePDF(html: page, to: output) }
                else { try Data(page.utf8).write(to: output, options: .atomic) }
                await progress(index + 1, article.title)
            }
            let output: URL
            if format == .package || articles.count > 1 {
                let escape = RichArticleDocument.escape
                let links = articles.map { article in
                    "<li><a href=\"\(escape(ArticleExportDocument.relativeURL(filenames[article.slug]!)))\">\(escape(article.title))</a></li>"
                }.joined()
                let index = ArticleExportDocument.page(title: "LeonBook", content: "<header><h1>LeonBook</h1></header><ul>\(links)</ul>")
                try Data(index.utf8).write(to: content.appendingPathComponent("index.html"), options: .atomic)
                output = scratch.appendingPathComponent("articles.zip")
                try archive(directory: content, to: output)
            } else { output = content.appendingPathComponent(filenames[articles[0].slug]!) }
            try Task.checkCancellation()
            try publish(output, to: destination)
            await renderer.close()
        } catch {
            await renderer.close()
            throw error
        }
    }

    private static func resolveAsset(
        _ reference: String, article: NativeArticle, store: LocalBlogStore,
        root: URL, articlesRoot: URL, directory: URL, packaged: Bool,
        cache: inout [String: String], embeddedBytes: inout Int
    ) async throws -> String {
        let source: URL
        let remote = URL(string: reference).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        var temporaryDownload: URL?
        var mimeType: String?
        var assetName = remote?.lastPathComponent ?? ""
        defer { if let temporaryDownload { try? FileManager.default.removeItem(at: temporaryDownload) } }
        let key: String
        if let remote {
            key = remote.absoluteString
            if let cached = cache[key] { return cached }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 60
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            do {
                let (url, response) = try await session.download(from: remote)
                temporaryDownload = url
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                    throw ArticleExportError.downloadFailed(remote.lastPathComponent)
                }
                mimeType = response.mimeType
                if URL(fileURLWithPath: assetName).pathExtension.isEmpty {
                    assetName = response.suggestedFilename ?? ("media." + (mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension } ?? "bin"))
                }
                source = url
            } catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation(); throw ArticleExportError.downloadFailed(remote.lastPathComponent) }
        } else {
            let decoded = (reference.removingPercentEncoding ?? reference).replacingOccurrences(of: "\\", with: "/")
            let resolved: URL
            if decoded.hasPrefix("/media/") || decoded.hasPrefix("media/") {
                resolved = root.appendingPathComponent(decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded)
            } else if decoded.hasPrefix("/") {
                resolved = articlesRoot.appendingPathComponent(String(decoded.dropFirst()))
            } else {
                resolved = articlesRoot.appendingPathComponent(article.sourceRelativePath).deletingLastPathComponent().appendingPathComponent(decoded)
            }
            source = resolved.standardizedFileURL.resolvingSymlinksInPath()
            // Resolve symlinks before checking containment; never export arbitrary local files.
            guard isInside(source, root: root.appendingPathComponent("media")) || isInside(source, root: articlesRoot) else {
                throw ArticleExportError.missingAsset(reference)
            }
            key = source.path
        }
        return try materialize(source, key: key, originalName: remote == nil ? source.lastPathComponent : assetName, mimeType: mimeType, directory: directory, packaged: packaged, cache: &cache, embeddedBytes: &embeddedBytes)
    }

    private static func materialize(
        _ source: URL, key: String, originalName: String, mimeType: String? = nil, directory: URL, packaged: Bool,
        cache: inout [String: String], embeddedBytes: inout Int
    ) throws -> String {
        if let cached = cache[key] { return cached }
        guard let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { throw ArticleExportError.missingAsset(originalName) }
        let replacement: String
        if packaged {
            let assets = directory.appendingPathComponent("assets", isDirectory: true)
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            let originalURL = URL(fileURLWithPath: originalName)
            let ext = String(originalURL.pathExtension.prefix(12))
            let safeName = ArticleExportDocument.filename(originalURL.deletingPathExtension().lastPathComponent, fallback: "attachment") + (ext.isEmpty ? "" : "." + ArticleExportDocument.filename(ext, fallback: "bin"))
            let name = "\(cache.count + 1)-\(safeName)"
            try FileManager.default.copyItem(at: source, to: assets.appendingPathComponent(name))
            replacement = "assets/" + ArticleExportDocument.relativeURL(name)
        } else {
            embeddedBytes += values.fileSize ?? 0
            guard embeddedBytes <= 256 * 1024 * 1024 else { throw ArticleExportError.oversizedHTML }
            let ext = URL(fileURLWithPath: originalName).pathExtension
            let mime = mimeType ?? UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
            replacement = "data:\(mime);base64," + (try Data(contentsOf: source)).base64EncodedString()
        }
        cache[key] = replacement
        return replacement
    }

    private static func isInside(_ file: URL, root: URL) -> Bool {
        file.path == root.path || file.path.hasPrefix(root.path + "/")
    }

    private static func archive(directory: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", "--norsrc", directory.path, destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        while finished.wait(timeout: .now() + 0.1) == .timedOut {
            if Task.isCancelled {
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
                throw CancellationError()
            }
        }
        guard process.terminationStatus == 0 else { throw ArticleExportError.archiveFailed }
    }

    /// Stage on the destination volume so cancellation/failure leaves the old export intact.
    private static func publish(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".leon-export-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        try Task.checkCancellation()
        if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: staging) }
        else { try fm.moveItem(at: staging, to: destination) }
    }
}
