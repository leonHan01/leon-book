import Foundation
import LeonBookTodoModule

struct EmailContent: Identifiable {
    let id = UUID()
    var subject: String
    var body: String
    var media: [NativeMedia] = []
    var sourceRelativePath: String? = nil

    static func moment(_ moment: NativeMoment) -> Self {
        .init(subject: NativeLocalization.text("微博") + " · " + moment.createdAt.nativeDateLabel,
              body: ([moment.createdAt.nativeDateLabel, moment.displayContent.text] + tagLine(moment.tags)).joined(separator: "\n\n"), media: moment.images)
    }

    static func todos(_ items: [TodoItem]) -> Self {
        let blocks = items.map { item in
            var lines = ["\(item.isCompleted ? "☑" : "☐") \(item.title)",
                         NativeLocalization.string(item.priority.label, language: NativeLocalization.currentLanguage)]
            if let due = item.dueDay { lines.append(NativeLocalization.text("截止日期") + ": " + due) }
            if let completed = item.completedAt { lines.append(NativeLocalization.text("已完成") + ": " + completed.nativeDateLabel) }
            if !item.notes.isEmpty { lines.append(item.notes) }
            return lines.joined(separator: "\n")
        }
        let subject = items.count == 1 ? NativeLocalization.text("待办") + " · " + items[0].title : NativeLocalization.text("待办清单")
        return .init(subject: subject, body: blocks.joined(separator: "\n\n"))
    }

    static func article(_ article: NativeArticle) -> Self {
        var media = article.media
        if let banner = article.banner { media.append(.init(kind: "image", name: banner.name, size: banner.size, url: banner.url)) }
        let html = RichArticleDocument.convertingLegacyBody(article.body)
        let references = RichArticleDocument.imageURLs(in: html) + RichArticleDocument.audioURLs(in: html) + RichArticleDocument.videoURLs(in: html)
        for path in references where !media.contains(where: { $0.url == path }) {
            media.append(.init(kind: "file", name: URL(string: path)?.lastPathComponent ?? "attachment", size: 0, url: path))
        }
        let metadata = ([article.category, article.updatedAt.nativeDateLabel] + tagLine(article.tags)).filter { !$0.isEmpty }.joined(separator: " · ")
        return .init(subject: article.title, body: [article.title, metadata, RichArticleDocument.plainText(html)].joined(separator: "\n\n"), media: media, sourceRelativePath: article.sourceRelativePath)
    }

    static func question(_ question: NativeQuestion, answers: [NativeQuestionAnswer]) -> Self {
        let blocks = answers.enumerated().map { index, answer in
            NativeLocalization.text("回答 \(index + 1)") + " · " + answer.createdAt.nativeDateLabel + "\n" + RichArticleDocument.plainText(RichArticleDocument.convertingLegacyBody(answer.body))
        }
        return .init(subject: question.title,
                     body: ([question.title, question.body] + tagLine(question.tags) + blocks).joined(separator: "\n\n"),
                     media: answers.flatMap(\.images))
    }

    private static func tagLine(_ tags: [String]) -> [String] { tags.isEmpty ? [] : [tags.map { "#" + $0 }.joined(separator: " ")] }

    var localMedia: [NativeMedia] {
        var seen = Set<String>()
        return media.filter { !Self.isRemote($0.url) && seen.insert($0.url).inserted }
    }
    var editableBody: String {
        let links = Array(Set(media.filter { Self.isRemote($0.url) }.map(\.url))).sorted()
        return links.isEmpty ? body : body + "\n\n" + NativeLocalization.text("媒体链接") + "\n" + links.joined(separator: "\n")
    }
    private static func isRemote(_ path: String) -> Bool { ["http", "https"].contains(URL(string: path)?.scheme?.lowercased() ?? "") }

    func attachments(store: LocalBlogStore) async throws -> [EmailAttachment] {
        var attachments: [EmailAttachment] = [], size = 0
        let root = store.rootURL.resolvingSymlinksInPath()
        let articlesRoot = await store.articlesURL.resolvingSymlinksInPath()
        for media in localMedia {
            guard let url = await store.mediaURL(for: media.url, relativeToMarkdownSource: sourceRelativePath) else { throw EmailError.missingAttachment(media.name) }
            let resolved = url.resolvingSymlinksInPath()
            // Do not attach symlink targets outside the workspace or mounted article root.
            guard [root, articlesRoot].contains(where: { resolved.path.hasPrefix($0.path + "/") }) else { throw EmailError.missingAttachment(media.name) }
            do {
                let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else { throw EmailError.missingAttachment(media.name) }
                guard size + (values.fileSize ?? 0) <= EmailMIME.maximumBytes else { throw EmailError.oversized }
                let handle = try FileHandle(forReadingFrom: resolved)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: EmailMIME.maximumBytes - size + 1) ?? Data()
                size += data.count
                guard size <= EmailMIME.maximumBytes else { throw EmailError.oversized }
                attachments.append(.init(name: media.name, data: data))
            } catch let error as EmailError { throw error }
            catch { throw EmailError.missingAttachment(media.name) }
        }
        return attachments
    }
}
