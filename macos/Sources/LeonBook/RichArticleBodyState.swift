import Foundation

/// The bridge stays synchronous from the editor's perspective. Session and
/// revision checks prevent a queued edit from replacing a newer document load.
struct RichArticleBodyState {
    let sessionID: String
    private(set) var body: String
    private(set) var revision = 0

    mutating func accept(_ payload: [String: Any]) -> String? {
        guard payload["sessionID"] as? String == sessionID,
              let nextRevision = payload["revision"] as? Int, nextRevision > revision else { return nil }
        let next: String
        if let complete = payload["body"] as? String {
            next = complete
        } else {
            guard payload["baseRevision"] as? Int == revision, nextRevision == revision + 1,
                  let patch = payload["patch"] as? [String: Any],
                  let offset = patch["offset"] as? Int, let length = patch["removedLength"] as? Int,
                  let baseLength = patch["baseLength"] as? Int, let text = patch["text"] as? String,
                  offset >= 0, length >= 0 else { return nil }
            let source = body as NSString
            guard baseLength == source.length, offset <= source.length, length <= source.length - offset,
                  Range(NSRange(location: offset, length: length), in: body) != nil else { return nil }
            next = source.replacingCharacters(in: NSRange(location: offset, length: length), with: text)
        }
        guard RichArticleDocument.isHTML(next) else { return nil }
        body = next; revision = nextRevision
        return next
    }
}
