import Foundation

/// Extracts readable article content without executing scripts in the saved page.
enum NativeHTMLArticleImporter {
    struct Image {
        let token: String
        let data: Data
        let fileExtension: String
    }
    struct Document {
        let title: String
        let body: String
        let images: [Image]
    }

    static func parse(_ html: String, fileURL: URL) throws -> Document {
        // Saved pages can lack a usable charset declaration. The file is read as
        // UTF-8, so make that encoding explicit to Foundation's HTML parser.
        // HTML tidy strips leading spaces from Slate's nested text spans, even
        // inside code lines. Protect them while parsing, then restore the exact
        // text as it is emitted. A per-import marker avoids collisions.
        let spaceMarker = "LEONBOOKSPACE\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let tabMarker = "LEONBOOKTAB\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let textSpans = try NSRegularExpression(pattern: #"(?is)<span\b[^>]*\bdata-slate-string\s*=\s*["']true["'][^>]*>([^<]*)</span\s*>"#)
        let protected = NSMutableString(string: html)
        for match in textSpans.matches(in: html, range: NSRange(location: 0, length: (html as NSString).length)).reversed() {
            let range = match.range(at: 1)
            let value = protected.substring(with: range)
                .replacingOccurrences(of: " ", with: spaceMarker)
                .replacingOccurrences(of: "\t", with: tabMarker)
            protected.replaceCharacters(in: range, with: value)
        }
        func restore(_ value: String) -> String {
            value.replacingOccurrences(of: spaceMarker, with: " ").replacingOccurrences(of: tabMarker, with: "\t")
        }
        let document = try XMLDocument(xmlString: "<meta charset=\"UTF-8\">" + (protected as String), options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        let slate = try document.nodes(forXPath: "//*[@data-slate-editor='true']").first
        let article = try document.nodes(forXPath: "//article").first
        let main = try document.nodes(forXPath: "//main").first
        let pageBody = try document.nodes(forXPath: "//body").first
        guard let content = slate ?? article ?? main ?? pageBody else {
            throw NativeStoreError.fileSystem("HTML 中没有可导入的正文。")
        }
        let heading = try document.nodes(forXPath: "//h1").first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (heading?.isEmpty == false ? heading! : fileURL.deletingPathExtension().lastPathComponent)
        var images: [Image] = []
        func escaped(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func render(_ node: XMLNode) throws -> String {
            guard let element = node as? XMLElement else {
                return node.kind == .text ? escaped(restore(node.stringValue ?? "")) : ""
            }
            let tag = (element.name ?? "").lowercased()
            let type = element.attribute(forName: "data-slate-type")?.stringValue ?? ""
            if ["script", "style", "noscript", "nav", "footer", "iframe", "button", "form"].contains(tag) { return "" }
            if tag == "img" {
                guard let src = element.attribute(forName: "src")?.stringValue, !src.isEmpty else { return "" }
                var outputURL = src
                if src.hasPrefix("data:image/"), let comma = src.firstIndex(of: ",") {
                    let header = String(src[..<comma]); let encoded = String(src[src.index(after: comma)...])
                    guard header.contains(";base64"), let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), !data.isEmpty else {
                        throw NativeStoreError.fileSystem("无法解码 HTML 中的图片。")
                    }
                    let ext = header.dropFirst("data:image/".count).split(separator: ";").first.map(String.init) ?? "png"
                    guard ["png", "jpeg", "jpg", "gif", "webp", "tiff", "svg+xml", "heic"].contains(ext.lowercased()) else { throw NativeStoreError.fileSystem("不支持的嵌入图片格式：\(ext)") }
                    let token = "leonbook-import-\(UUID().uuidString)"
                    images.append(Image(token: token, data: data, fileExtension: ext == "svg+xml" ? "svg" : ext))
                    outputURL = token
                } else if !src.hasPrefix("https://") && !src.hasPrefix("http://") {
                    guard !src.hasPrefix("/"), let path = src.removingPercentEncoding, !path.contains("..") else { throw NativeStoreError.fileSystem("不支持的图片路径：\(src)") }
                    let imageURL = fileURL.deletingLastPathComponent().appendingPathComponent(path)
                    guard let data = try? Data(contentsOf: imageURL), !data.isEmpty else { throw NativeStoreError.fileSystem("无法读取图片：\(src)") }
                    let token = "leonbook-import-\(UUID().uuidString)"
                    images.append(Image(token: token, data: data, fileExtension: imageURL.pathExtension))
                    outputURL = token
                }
                return "<img src=\"\(escaped(outputURL))\" alt=\"\(escaped(element.attribute(forName: "alt")?.stringValue ?? ""))\">"
            }
            if type == "pre" {
                let lines = try element.nodes(forXPath: ".//*[@data-slate-type='code-line']").map {
                    restore(($0.stringValue ?? "").trimmingCharacters(in: .newlines))
                }
                return "<pre><code>\(escaped(lines.joined(separator: "\n")))</code></pre>"
            }
            let children = try (element.children ?? []).map(render).joined()
            let semantic: String?
            switch type {
            case "paragraph": semantic = "p"
            case "list": semantic = "ul"
            case "list-line": semantic = "li"
            case "bold": semantic = "strong"
            case "code": semantic = "code"
            default: semantic = nil
            }
            let outputTag = semantic ?? tag
            if outputTag == "br" || outputTag == "hr" { return "<\(outputTag)>" }
            if outputTag == "a", let href = element.attribute(forName: "href")?.stringValue,
               let url = URL(string: href), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                return "<a href=\"\(escaped(href))\">\(children)</a>"
            }
            if ["p", "h1", "h2", "h3", "h4", "pre", "code", "blockquote", "ul", "ol", "li", "strong", "b", "em", "i", "u", "s", "table", "thead", "tbody", "tr", "td", "th", "figure", "figcaption"].contains(outputTag) {
                return "<\(outputTag)>\(children)</\(outputTag)>"
            }
            return children
        }
        let body = try (content.children ?? []).map(render).joined()
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeStoreError.fileSystem("HTML 正文为空。") }
        return Document(title: title, body: "<article data-leon-format=\"html-v1\">\(body)</article>", images: images)
    }
}
