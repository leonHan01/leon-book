import Foundation

enum ChatCommand: String, CaseIterable, Identifiable {
    case compact, context, clear
    case newRound = "new", exportRound = "export"
    var id: String { rawValue }
    var title: String {
        switch self { case .clear: return "清空当前会话记录"; case .compact: return "压缩上下文"; case .context: return "查看上下文"; case .newRound: return "结束本轮并开始新对话"; case .exportRound: return "导出到 LeonBook" }
    }
    var detail: String {
        switch self {
        case .clear: return "确认后永久删除当前会话消息、图片和上下文"
        case .compact: return "用 AI 整理较早对话，保留最近一轮原文"
        case .context: return "查看摘要、保留轮数和上下文设置"
        case .newRound: return "可先归档总结和原文，再开始完全新的上下文"
        case .exportRound: return "保存为文章草稿：总结在前，原始对话在后"
        }
    }
    var symbol: String {
        switch self { case .clear: return "trash"; case .compact: return "arrow.down.right.and.arrow.up.left"; case .context: return "brain"; case .newRound: return "plus.bubble"; case .exportRound: return "square.and.arrow.up" }
    }
    static func query(in text: String, selection: NSRange) -> String? {
        guard selection.length == 0, selection.location == (text as NSString).length,
              !text.contains("\n"), !text.contains("\r") else { return nil }
        let trimmed = text.drop(while: { $0.isWhitespace })
        guard trimmed.first == "/" else { return nil }
        let query = String(trimmed.dropFirst()).lowercased()
        guard !query.contains(where: { $0.isWhitespace || $0 == "/" }) else { return nil }
        return query
    }
    static func matching(_ query: String) -> [ChatCommand] {
        allCases.filter { query.isEmpty || $0.rawValue.hasPrefix(query.lowercased()) || $0.title.contains(query) || ($0 == .compact && "compress".hasPrefix(query.lowercased())) }
    }
    static func exact(_ text: String) -> ChatCommand? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value == "/compress" { return .compact }
        return allCases.first { value == "/" + $0.rawValue }
    }
    static func isAttempt(_ text: String) -> Bool {
        if query(in: text, selection: NSRange(location: (text as NSString).length, length: 0)) != nil { return true }
        let first = text.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        return exact(first) != nil
    }
}
