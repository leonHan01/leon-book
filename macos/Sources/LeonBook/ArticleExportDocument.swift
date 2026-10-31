import Foundation

enum ArticleExportDocument {
    static func body(_ article: NativeArticle, includeMetadata: Bool) -> String {
        let escape = RichArticleDocument.escape
        var html = "<header><h1>\(escape(article.title))</h1>"
        if includeMetadata {
            let metadata = [article.category, article.updatedAt.nativeDateLabel] + article.tags.map { "#" + $0 }
            html += "<p class=\"metadata\">\(escape(metadata.filter { !$0.isEmpty }.joined(separator: " · ")))</p>"
            if !article.excerpt.isEmpty { html += "<p class=\"excerpt\">\(escape(article.excerpt))</p>" }
        }
        html += "</header>"
        if let banner = article.banner { html += "<figure><img src=\"\(escape(banner.url))\" alt=\"\(escape(banner.alt))\"></figure>" }
        html += RichArticleDocument.convertingLegacyBody(article.body)
        let attachments = article.media.filter { !article.body.contains($0.url) && !article.body.contains(escape($0.url)) }
        if !attachments.isEmpty {
            html += "<section><h2>\(escape(NativeLocalization.text("附件")))</h2><ul>"
            for attachment in attachments {
                if attachment.isImage {
                    html += "<li><figure><img src=\"\(escape(attachment.url))\" alt=\"\(escape(attachment.name))\"><figcaption>\(escape(attachment.name))</figcaption></figure></li>"
                } else {
                    html += "<li><a href=\"\(escape(attachment.url))\">\(escape(attachment.name))</a></li>"
                }
            }
            html += "</ul></section>"
        }
        return html
    }

    static func page(title: String, content: String) -> String {
        """
        <!doctype html>
        <html lang="\(NativeLocalization.currentLanguage.rawValue)"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: 'self'; media-src data: 'self'; style-src 'unsafe-inline'; font-src 'none'; base-uri 'none'; form-action 'none'">
        <title>\(RichArticleDocument.escape(title))</title><style>
        :root{color-scheme:light}*{box-sizing:border-box}body{max-width:840px;margin:0 auto;padding:48px 36px;color:#252827;background:white;font:16px/1.8 -apple-system,BlinkMacSystemFont,'Helvetica Neue','PingFang SC',sans-serif;overflow-wrap:anywhere}
        header{margin-bottom:30px;padding-bottom:22px;border-bottom:1px solid #e0e5e2}h1{font-size:32px;line-height:1.35;margin:0 0 16px}h2{font-size:24px}h3{font-size:20px}h1,h2,h3,h4,h5,h6{break-after:avoid;line-height:1.4}p{margin:0 0 16px}.metadata,figcaption{color:#637067;font-size:12px}.excerpt{color:#556158;margin:12px 0 0}
        a{color:#187456;text-decoration:underline}img{display:block;max-width:100%;height:auto;margin:12px auto}figure{margin:18px 0;break-inside:avoid}figcaption{text-align:center;margin-top:7px}audio,video{display:block;max-width:100%;width:100%;margin:12px 0}video{max-height:560px}
        pre{padding:16px;background:#f4f6f5;border:1px solid #dce3df;border-radius:6px;white-space:pre-wrap;overflow-wrap:anywhere;tab-size:4;font-size:12px}code{font-family:ui-monospace,Menlo,monospace}p code,li code{background:#f1f4f2;padding:2px 4px;border-radius:3px}blockquote{margin:18px 0;padding:6px 18px;border-left:3px solid #39846a;color:#556158}aside{padding:16px 20px;background:#fff6db;border-left:3px solid #c9a644;border-radius:5px}
        table{border-collapse:collapse;table-layout:fixed;width:100%;margin:20px 0;font-size:14px}th,td{border:1px solid #d8dfda;padding:9px 12px;text-align:left;vertical-align:top}th{background:#f2f5f3}td p:last-child,th p:last-child{margin-bottom:0}thead{display:table-header-group}tr{break-inside:avoid}hr{border:0;border-top:1px solid #dce3df;margin:26px 0}
        [data-type=bullet]::before{content:'• ';color:#637067}[data-type=number]::before{content:attr(data-number) '. '}[data-type=task]::before{content:'☐ ';color:#39846a}[data-type=task][data-checked=true]::before{content:'☑ '}[data-type=task][data-checked=true]{text-decoration:line-through;color:#637067}mark{background:#ffecac}p,li{orphans:3;widows:3}
        @media print{body{max-width:none;padding:0;font-size:11pt;line-height:1.75}h1{font-size:25pt}h2{font-size:18pt}h3{font-size:14pt}img{max-height:620pt;object-fit:contain}pre{font-size:9pt}table{font-size:10pt}header{margin-bottom:22pt}audio,video{display:none}}
        @page{size:A4;margin:44pt}
        div[data-type=columns]{display:flex;align-items:stretch;gap:16px;margin:0 0 16px}div[data-type=column]{flex:0 1 auto;min-width:0;width:50%}div[data-type=column]>:last-child{margin-bottom:0}
        </style></head><body>\(content)</body></html>
        """
    }

    /// Keep filenames inside the staging directory, even for imported titles.
    static func filename(_ title: String, fallback: String) -> String {
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:?*\"<>|"))
        let value = title.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return String((value.isEmpty ? fallback : value).prefix(70))
    }

    static func relativeURL(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "#?"))) ?? path
    }
}
