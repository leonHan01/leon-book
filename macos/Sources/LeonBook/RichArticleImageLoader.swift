import Foundation

/// Serializes expensive image decoding across editors without occupying the UI
/// thread. Clipboard access stays on the main actor; only immutable data crosses.
actor RichArticleImageLoader {
    enum Source: Sendable {
        case clipboard([Data])
        case file(URL)
    }

    static let shared = RichArticleImageLoader()
    private let encode: @Sendable (Data) -> String?

    init(encode: @escaping @Sendable (Data) -> String? = { RichArticleClipboard.imageDataURL(from: $0) }) {
        self.encode = encode
    }

    func imageDataURL(from source: Source) throws -> String? {
        try Task.checkCancellation()
        return try autoreleasepool {
            let candidates: [Data]
            switch source {
            case .clipboard(let data): candidates = data
            case .file(let url): candidates = [try Data(contentsOf: url)]
            }
            for data in candidates {
                try Task.checkCancellation()
                let result = encode(data)
                try Task.checkCancellation()
                if let result { return result }
            }
            return nil
        }
    }
}
