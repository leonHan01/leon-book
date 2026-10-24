import Foundation

/// The authoritative article body is semantic HTML. Markdown is only consumed
/// by the one-way importer below; editing and saving never reconstruct Markdown.
enum RichArticleDocument {
    static let opening = "<article data-leon-format=\"html-v1\">"
    static let empty = opening + "<p><br></p></article>"

    static func isHTML(_ body: String) -> Bool {
        body.hasPrefix(opening) || body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(opening)
    }

    private static let contentSegments = try! NSRegularExpression(
        pattern: #"(?is)<(script|style)\b[^>]*>.*?</\1>|<[^>]*>|([^<]+)|(<)"#
    )
    private static let entityExpression = try! NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|[a-z]+);"#)

    static func hasContent(_ body: String) -> Bool {
        guard isHTML(body) else { return !body.isEmpty }
        let source = body as NSString
        var found = false
        // Dirty-state checks run during editing. Stop at the first visible text
        // segment instead of allocating/decoding a plain-text copy of the article.
        contentSegments.enumerateMatches(in: body, range: NSRange(location: 0, length: source.length)) { match, _, stop in
            guard let match else { return }
            if match.range(at: 3).location != NSNotFound { found = true }
            else if match.range(at: 2).location != NSNotFound {
                let segment = source.substring(with: match.range(at: 2))
                let text = segment.contains("&") ? decodeEntities(segment) : segment
                found = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if found { stop.pointee = true }
        }
        return found || ["<img ", "<pre", "<aside", "<table", "<hr"].contains(where: body.contains)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func plainText(_ source: String) -> String {
        guard isHTML(source) else { return source }
        let text = source
            .replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)<br\s*/?>|</(?:p|h[1-6]|pre|aside|blockquote|li|tr|figure|figcaption)>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        return decodeEntities(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let entities = ["lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "amp": "&"]
        let source = text as NSString
        var cursor = 0, pieces: [String] = []
        // Regex ranges are UTF-16. Append source spans once; converting each
        // range to a Swift String index and mutating backwards was quadratic.
        entityExpression.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, _ in
            guard let match else { return }
            if match.range.location > cursor { pieces.append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))) }
            let name = source.substring(with: match.range(at: 1))
            let decoded: String?
            if name.hasPrefix("#x") {
                decoded = UInt32(name.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init).map(String.init)
            } else if name.hasPrefix("#") {
                decoded = UInt32(name.dropFirst()).flatMap(UnicodeScalar.init).map(String.init)
            } else { decoded = entities[name] }
            pieces.append(decoded ?? source.substring(with: match.range))
            cursor = NSMaxRange(match.range)
        }
        guard cursor > 0 else { return text }
        if cursor < source.length { pieces.append(source.substring(from: cursor)) }
        return pieces.joined()
    }

    static func convertingLegacyBody(_ source: String) -> String {
        guard !isHTML(source) else { return source }
        guard !source.isEmpty else { return empty }
        let blocks = NativeBlockEditorDocument.parse(source).map { block -> String in
            let raw = NativeBlockEditorDocument.removingBlockID(from: block.markdown)
            let text = NativeBlockEditorDocument.converting(raw, to: .paragraph)
            let id = NativeBlockEditorDocument.blockID(in: block.markdown) ?? block.id.uuidString.lowercased()
            let attributes = " data-block-id=\"\(escape(id))\" data-depth=\"\(block.depth)\""
            let content = inlineHTML(text).replacingOccurrences(of: "\n", with: "<br>")
            switch block.kind {
            case .heading1: return "<h1\(attributes)>\(content)</h1>"
            case .heading2: return "<h2\(attributes)>\(content)</h2>"
            case .heading3: return "<h3\(attributes)>\(content)</h3>"
            case .code:
                let language = raw.components(separatedBy: "\n").first.map { String($0.dropFirst(3)) } ?? ""
                return "<pre\(attributes) data-language=\"\(escape(language))\"><code>\(escape(text))</code></pre>"
            case .callout: return "<aside\(attributes) data-type=\"callout\">\(content)</aside>"
            case .quote: return "<blockquote\(attributes)>\(content)</blockquote>"
            case .bulletedList: return "<p\(attributes) data-type=\"bullet\">\(content)</p>"
            case .numberedList: return "<p\(attributes) data-type=\"number\">\(content)</p>"
            case .task:
                return "<p\(attributes) data-type=\"task\" data-checked=\"\(NativeBlockEditorDocument.isCompletedTask(raw))\">\(content)</p>"
            case .divider: return "<hr\(attributes)>"
            case .math: return "<pre\(attributes) data-language=\"latex\"><code>\(escape(text))</code></pre>"
            case .table:
                let rows = raw.components(separatedBy: "\n").enumerated().compactMap { index, line -> String? in
                    if index == 1 { return nil }
                    var cells = line.trimmingCharacters(in: .whitespaces)
                    if cells.hasPrefix("|") { cells.removeFirst() }
                    if cells.hasSuffix("|") { cells.removeLast() }
                    let tag = index == 0 ? "th" : "td"
                    return "<tr>" + cells.components(separatedBy: "|").map {
                        "<\(tag)>\(inlineHTML($0.trimmingCharacters(in: .whitespaces)))</\(tag)>"
                    }.joined() + "</tr>"
                }
                return "<table\(attributes)><tbody>\(rows.joined())</tbody></table>"
            case .paragraph: return "<p\(attributes)>\(content.isEmpty ? "<br>" : content)</p>"
            }
        }
        return opening + blocks.joined() + "</article>"
    }

    static func imageURLs(in body: String) -> [String] {
        mediaURLs(in: body, tag: "img")
    }

    static func audioURLs(in body: String) -> [String] {
        mediaURLs(in: body, tag: "audio")
    }

    private static func mediaURLs(in body: String, tag: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: "(?i)<\(tag)\\b[^>]*\\bsrc=\"([^\"]+)\"")
        return expression.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap { match in
            Range(match.range(at: 1), in: body).map { String(body[$0]).replacingOccurrences(of: "&amp;", with: "&") }
        }
    }

    static func appending(_ addition: String, to body: String) -> String {
        let original = convertingLegacyBody(body)
        let added = convertingLegacyBody(addition)
        return String(original.dropLast("</article>".count))
            + String(added.dropFirst(opening.count).dropLast("</article>".count)) + "</article>"
    }

    static func linkReferences(in body: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"(?i)<a\b[^>]*href="([^"]+)""#)
        return expression.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: body),
                  let url = URLComponents(string: String(body[range]).replacingOccurrences(of: "&amp;", with: "&")),
                  url.scheme == "leonbook" else { return nil }
            return url.queryItems?.first(where: { $0.name == "slug" })?.value
        }
    }

    private static func inlineHTML(_ text: String) -> String {
        let image = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)\s]+)\)"#)
        if let match = image.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text), let alt = Range(match.range(at: 1), in: text),
           let url = Range(match.range(at: 2), in: text) {
            return inlineHTML(String(text[..<range.lowerBound]))
                + "<img src=\"\(escape(String(text[url])))\" alt=\"\(escape(String(text[alt])))\">"
                + inlineHTML(String(text[range.upperBound...]))
        }
        let wiki = try! NSRegularExpression(pattern: #"!?\[\[([^\[\]]+)\]\]"#)
        if let match = wiki.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text), let reference = Range(match.range(at: 1), in: text) {
            let parts = text[reference].components(separatedBy: "|")
            let target = parts[0]
            var link = URLComponents(); link.scheme = "leonbook"; link.host = "open"
            link.queryItems = [URLQueryItem(name: "slug", value: target)]
            return inlineHTML(String(text[..<range.lowerBound]))
                + "<a href=\"\(escape(link.string ?? ""))\">\(escape(parts.last ?? target))</a>"
                + inlineHTML(String(text[range.upperBound...]))
        }
        // Foundation's inline parser is used once during import, never for the
        // document produced by the rich text editor.
        guard let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return escape(text)
        }
        return parsed.runs.map { run in
            var html = escape(String(parsed[run.range].characters))
            let intent = run.inlinePresentationIntent
            if intent?.contains(.code) == true { html = "<code>\(html)</code>" }
            if intent?.contains(.stronglyEmphasized) == true { html = "<strong>\(html)</strong>" }
            if intent?.contains(.emphasized) == true { html = "<em>\(html)</em>" }
            if intent?.contains(.strikethrough) == true { html = "<s>\(html)</s>" }
            if let link = run.link { html = "<a href=\"\(escape(link.absoluteString))\">\(html)</a>" }
            return html
        }.joined()
    }

    static func outline(in body: String) -> [MarkdownOutlineItem] {
        guard isHTML(body) else { return MarkdownOutline.items(in: body) }
        let expression = try! NSRegularExpression(pattern: #"(?is)<h([1-4])\b[^>]*>(.*?)</h\1>"#)
        return expression.matches(in: body, range: NSRange(body.startIndex..., in: body)).enumerated().compactMap { index, match in
            guard let levelRange = Range(match.range(at: 1), in: body),
                  let textRange = Range(match.range(at: 2), in: body) else { return nil }
            return MarkdownOutlineItem(
                id: MarkdownOutline.anchorID(for: index),
                level: Int(body[levelRange]) ?? 1,
                title: plainText(opening + "<p>" + body[textRange] + "</p></article>")
            )
        }
    }
}

/// Metadata lives in the HTML head; body markup stays directly readable by a
/// browser. No YAML, Markdown fences, or Obsidian markers are written.
enum RichArticleFile {
    struct Metadata: Codable {
        let title: String
        let slug: String
        let category: String
        let excerpt: String
        let banner: NativeBanner?
        let media: [NativeMedia]
        let status: NativeArticleStatus
        let tags: [String]
        let updatedAt: String
        let publishedAt: String?
        let properties: [String: NativeArticlePropertyValue]
    }

    static func render(_ article: NativeArticle) throws -> String {
        let metadata = Metadata(
            title: article.title, slug: article.slug, category: article.category,
            excerpt: article.excerpt, banner: article.banner, media: article.media,
            status: article.status, tags: article.tags, updatedAt: article.updatedAt,
            publishedAt: article.publishedAt, properties: article.properties
        )
        let encoded = try JSONEncoder().encode(metadata).base64EncodedString()
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="leon-article" content="\(encoded)"><title>\(RichArticleDocument.escape(article.title))</title>
        <style>
        body{max-width:860px;margin:auto;padding:40px 24px;color:#252827;font:18px/1.75 system-ui,sans-serif;overflow-wrap:anywhere}
        article>p,article>aside,article>blockquote,article>pre{margin:0 0 16px}pre{padding:18px;background:#f4f6f4;border:1px solid #e4e8e5;border-radius:8px;white-space:pre-wrap;tab-size:4}code{font-family:ui-monospace,Menlo,monospace}
        aside{padding:14px 18px;background:#fff6d8;border-left:4px solid #d3a229;border-radius:6px}blockquote{border-left:3px solid #328568;padding:6px 16px;color:#68746c}img{display:block;max-width:100%;height:auto}mark{background:#f2ce5e70}
        figure{margin:0 0 14px}figcaption{margin-top:5px;color:#848a86;font:12px/1.6 -apple-system,sans-serif;text-align:center}figcaption:empty{display:none}audio{display:block;width:100%;max-width:100%}
        table{border-collapse:collapse;table-layout:fixed;width:100%;overflow-wrap:anywhere}th,td{border:1px solid #ddd;padding:8px 12px;vertical-align:top}[data-type=bullet]::before{content:'• ';}[data-type=number]::before{content:attr(data-number) '. ';}[data-type=task]::before{content:'☐ ';}[data-checked=true]::before{content:'☑ ';}[data-checked=true]{text-decoration:line-through}
        </style></head>
        <body>\(article.body)</body></html>
        """
    }

    static func read(_ source: String, relativePath: String, modifiedAt: String) throws -> MarkdownArticleSourceRecord {
        let expression = try NSRegularExpression(pattern: #"<meta name="leon-article" content="([A-Za-z0-9+/=]+)">"#)
        guard let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source),
              let data = Data(base64Encoded: String(source[range])),
              let start = source.range(of: RichArticleDocument.opening),
              let end = source.range(of: "</article>", options: .backwards), start.lowerBound < end.upperBound else {
            throw NativeStoreError.fileSystem(NativeLocalization.text("HTML 文章格式无效：\(relativePath)"))
        }
        let metadata = try JSONDecoder().decode(Metadata.self, from: data)
        return MarkdownArticleSourceRecord(
            relativePath: relativePath, contentHash: MarkdownArticleSource.hash(Data(source.utf8)),
            modifiedAt: modifiedAt, declaredUpdatedAt: metadata.updatedAt, slug: metadata.slug,
            title: metadata.title, body: String(source[start.lowerBound..<end.upperBound]),
            category: metadata.category, excerpt: metadata.excerpt, banner: metadata.banner,
            media: metadata.media, status: metadata.status, tags: metadata.tags,
            publishedAt: metadata.publishedAt, properties: try NativeArticleProperties.validated(metadata.properties)
        )
    }
}
