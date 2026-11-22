import Foundation

enum MentionCompletion {
    struct Token: Equatable {
        let range: NSRange
        let query: String
    }
    static func token(in text: String, selection: NSRange) -> Token? {
        let value = text as NSString
        guard selection.length == 0, selection.location >= 0, selection.location <= value.length else { return nil }
        let prefix = value.substring(to: selection.location)
        let pattern = #"(?:^|[^A-Za-z0-9_])([@＠][\p{L}\p{N}\p{M}_-]{0,64})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) else { return nil }
        let start = match.range(at: 1).location
        let query = (prefix as NSString).substring(with: NSRange(location: start + 1, length: selection.location - start - 1))
        let tail = value.substring(from: selection.location)
        let suffix = try? NSRegularExpression(pattern: #"^[\p{L}\p{N}\p{M}_-]*"#)
        let trailing = suffix?.firstMatch(in: tail, range: NSRange(location: 0, length: (tail as NSString).length))?.range.length ?? 0
        return Token(range: NSRange(location: start, length: selection.location - start + trailing), query: query)
    }
    static func matches(name: String, handle: String, query: String) -> Bool {
        query.isEmpty || name.lowercased().contains(query.lowercased()) || handle.lowercased().contains(query.lowercased())
    }
    static func replacing(_ token: Token, in text: String, with handle: String) -> (text: String, caret: Int, insertion: String) {
        let value = text as NSString
        let suffix = value.substring(from: NSMaxRange(token.range))
        let space = suffix.first?.isWhitespace == true ? "" : " "
        let prefix = value.substring(to: token.range.location)
        let boundary = prefix.range(of: #"[\p{L}\p{N}_]$"#, options: .regularExpression) != nil ? " " : ""
        let insert = boundary + "@\(handle)" + space
        let existingSpace = suffix.first?.isWhitespace == true ? String(suffix.first!).utf16.count : 0
        return (value.replacingCharacters(in: token.range, with: insert), token.range.location + (insert as NSString).length + existingSpace, insert)
    }
}
