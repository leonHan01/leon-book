import Foundation

/// Resolves indexed raw wiki-link targets without rescanning Markdown bodies.
/// Title and slug preserve the previous first-match behaviour; paths and aliases
/// only resolve when they identify exactly one article.
struct NativeArticleLinkIdentityIndex {
    private var titles: [String: NativeArticleSummary] = [:]
    private var slugs: [String: NativeArticleSummary] = [:]
    private var paths: [String: [NativeArticleSummary]] = [:]
    private var aliases: [String: [NativeArticleSummary]] = [:]

    init(_ articles: [NativeArticleSummary]) {
        for article in articles {
            let title = Self.folded(article.title)
            let slug = Self.folded(article.slug)
            if titles[title] == nil { titles[title] = article }
            if slugs[slug] == nil { slugs[slug] = article }
            let path = Self.normalizedPath(article.sourceRelativePath)
            paths[path, default: []].append(article)
            for alias in article.aliases {
                aliases[Self.folded(alias), default: []].append(article)
            }
        }
    }

    func resolve(_ rawReference: String) -> NativeArticleSummary? {
        let reference = NativeArticleLink.Reference(rawValue: rawReference).target
        guard !reference.isEmpty else { return nil }
        let identity = Self.folded(reference)
        if let title = titles[identity] { return title }
        if let slug = slugs[identity] { return slug }
        let pathMatches = paths[Self.normalizedPath(reference)] ?? []
        if pathMatches.count == 1 { return pathMatches[0] }
        let aliasMatches = aliases[identity] ?? []
        return aliasMatches.count == 1 ? aliasMatches[0] : nil
    }

    static func folded(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive], locale: .current)
    }

    static func normalizedPath(_ source: String) -> String {
        let normalized = source
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let withoutExtension = normalized.lowercased().hasSuffix(".md")
            ? String(normalized.dropLast(3))
            : normalized
        return folded(withoutExtension)
    }
}
