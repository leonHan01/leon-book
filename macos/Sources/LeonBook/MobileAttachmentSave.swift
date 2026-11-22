import Foundation

struct MobileStagedAttachment: Decodable {
    let id: String?
    let path: String
    let name: String
    let kind: String
}

extension LocalBlogStore {
    private static let mobileImageSource = try! NSRegularExpression(
        pattern: #" src="/leonbook-inline/([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})""#
    )

    func saveMobileAttachments(
        method: String,
        parameters: AutomationParameters,
        files: [MobileStagedAttachment],
        inlineImages: Bool
    ) async throws -> AutomationValue {
        let isArticle = method.hasPrefix("articles.")
        let existingField = isArticle ? "media" : "images"
        guard (1...9).contains(files.count), parameters.values[existingField] == nil else {
            throw AutomationFailure("invalid_params", "Supply new staged files without replacing existing attachments")
        }
        var inlineBody: NSMutableString?
        var inlineSources: [(range: NSRange, index: Int)] = []
        if inlineImages {
            let body: String = try parameters.required("body")
            guard isArticle, try parameters.required("format", as: String.self) == "html" else {
                throw AutomationFailure("invalid_params", "Inline images require an HTML article")
            }
            let source = body as NSString
            for match in Self.mobileImageSource.matches(in: body, range: NSRange(location: 0, length: source.length)) {
                let id = source.substring(with: match.range(at: 1))
                guard let index = files.firstIndex(where: { $0.kind == "image" && $0.id == id }) else {
                    throw AutomationFailure("invalid_params", "Inline image is missing its upload")
                }
                inlineSources.append((match.range, index))
            }
            guard !inlineSources.isEmpty else { throw AutomationFailure("invalid_params", "Inline images are missing") }
            inlineBody = NSMutableString(string: body)
        }

        try prepare()
        let lease = try WorkspaceStorageLifecycle.beginAsyncWrite(in: rootURL)
        defer { withExtendedLifetime(lease) {} }
        let existing: [NativeMedia]
        switch method {
        case "articles.update":
            let article = try getArticle(slug: parameters.required("slug"))
            guard article.updatedAt == (try parameters.required("expectedUpdatedAt", as: String.self)) else { throw NativeStoreError.conflict }
            existing = article.media
        case "moments.update":
            let moment = try getMoment(id: parameters.required("id"))
            guard moment.updatedAt == (try parameters.required("expectedUpdatedAt", as: String.self)) else { throw NativeStoreError.conflict }
            existing = moment.images
        default:
            existing = []
        }
        guard isArticle || existing.count + files.count <= 9 else {
            throw AutomationFailure("attachment_limit", "A post supports up to 9 attachments")
        }

        var totalBytes = 0
        let sources = try files.map { file -> URL in
            guard file.path.hasPrefix("/"), !file.name.isEmpty, file.name.utf8.count <= 250,
                  ["image", "audio", "video", "file"].contains(file.kind) else {
                throw AutomationFailure("invalid_params", "Invalid staged attachment")
            }
            let url = URL(fileURLWithPath: file.path)
            let ext = url.pathExtension.lowercased()
            if !isArticle {
                let image = file.kind == "image" && ["jpg", "jpeg", "png", "gif", "webp", "avif", "heic", "heif"].contains(ext)
                let audio = file.kind == "audio" && ext == "mp3"
                let video = file.kind == "video" && ext == "mp4"
                guard image || audio || video else {
                    throw AutomationFailure("invalid_params", "Posts accept images, MP3 and MP4")
                }
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink == false, let size = values.fileSize,
                  (1...(32 * 1024 * 1024)).contains(size) else {
                throw AutomationFailure("message_too_large", "Invalid attachment size")
            }
            totalBytes += size
            guard totalBytes <= 64 * 1024 * 1024 else {
                throw AutomationFailure("message_too_large", "Attachments exceed 64 MiB")
            }
            return url
        }

        var added: [NativeMedia] = []
        do {
            for (file, url) in zip(files, sources) {
                let item = try await uploadMedia(fileURL: url, kind: file.kind, slug: isArticle ? "inbox" : "moments")
                added.append(NativeMedia(kind: item.kind, name: file.name, size: item.size, url: item.url))
            }
            var values = parameters.values
            values[existingField] = try .encoded(existing + added)
            if let inlineBody {
                for (range, index) in inlineSources.reversed() {
                    inlineBody.replaceCharacters(in: range, with: " src=\"\(added[index].url)\"")
                }
                values["body"] = .string(inlineBody as String)
            }
            let save = AutomationParameters(values: values)
            if isArticle {
                return try .encoded(automationSaveArticle(method: method, parameters: save))
            }
            if method == "moments.update" {
                return try automationMutateMoment(method: method, parameters: save)
            }
            return try .encoded(saveMoment(text: save.string("text"), textRuns: save.optional("textRuns") ?? [], images: existing + added))
        } catch {
            // A failed version check may race a desktop edit after staging.
            // The store only removes imported files that have no references.
            try? discardUnreferencedMedia(added)
            throw error
        }
    }
}
