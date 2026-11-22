import Foundation
import Combine

enum SearchExcerpt {
    static func text(_ body: String, query: String) -> String {
        let flat = body.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        guard let match = flat.range(of: query, options: .caseInsensitive), !query.isEmpty else { return String(flat.prefix(120)) }
        let start = flat.index(match.lowerBound, offsetBy: -28, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(match.upperBound, offsetBy: 80, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }
}

/// Search owns its own cursors. Browsing history never alters the live chat or its draft.
@MainActor
final class ChatSearchState: ObservableObject {
    typealias Fetch = (String, String?, Int64?) async throws -> ChatSearchPage
    @Published var query = ""
    @Published private(set) var results: [ChatSearchHit] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var searched = false
    @Published private(set) var hasMore = false
    let room: String?
    private let fetch: Fetch
    private var before: Int64?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    init(room: String?, fetch: @escaping Fetch) { self.room = room; self.fetch = fetch }
    func changed(immediate: Bool = false) {
        stop(); results = []; before = nil; hasMore = false; searched = false; error = nil
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        guard q.utf16.count <= 100 else { error = "搜索词最多 100 字符"; return }
        busy = true; let stamp = generation
        task = Task {
            if !immediate { do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return } }
            await perform(q, stamp: stamp, append: false)
        }
    }
    func more() {
        guard !busy, hasMore, before != nil else { return }
        busy = true; error = nil; let q = query.trimmingCharacters(in: .whitespacesAndNewlines), stamp = generation
        task = Task { await perform(q, stamp: stamp, append: true) }
    }
    func retry() { if results.isEmpty { changed(immediate: true) } else { more() } }
    func stop() { task?.cancel(); task = nil; generation = UUID(); busy = false }
    private func perform(_ q: String, stamp: UUID, append: Bool) async {
        do {
            let page = try await fetch(q, room, append ? before : nil)
            guard generation == stamp, !Task.isCancelled else { return }
            let known = Set(results.map(\.id))
            results = append ? results + page.results.filter { !known.contains($0.id) } : page.results
            before = page.nextBefore; hasMore = page.hasMore && page.nextBefore != nil; searched = true; busy = false
        } catch {
            guard generation == stamp, !Task.isCancelled else { return }
            self.error = error.localizedDescription; busy = false
        }
    }
}

@MainActor
final class ChatSearchHistory: ObservableObject {
    typealias Fetch = (String, Int64, String) async throws -> ChatSearchContext
    @Published private(set) var messages: [Message] = []
    @Published private(set) var hasOlder = false
    @Published private(set) var hasNewer = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    let hit: ChatSearchHit
    private let fetch: Fetch
    private var revision: Int64?
    private var generation = UUID()
    init(hit: ChatSearchHit, fetch: @escaping Fetch) { self.hit = hit; self.fetch = fetch }
    func stop() { generation = UUID(); busy = false }
    func load(_ direction: String = "around") async {
        guard !busy, let room = hit.message.conversationId else { return }
        if direction == "around" { revision = nil; messages = []; hasOlder = false; hasNewer = false }
        busy = true; error = nil; let stamp = generation
        let anchor = direction == "before" ? messages.first?.id ?? hit.id : direction == "after" ? messages.last?.id ?? hit.id : hit.id
        do {
            let page = try await fetch(room, anchor, direction)
            guard stamp == generation, !Task.isCancelled else { return }
            if let revision, revision != page.historyRevision {
                messages = []; hasOlder = false; hasNewer = false; busy = false
                error = "聊天记录已变更，请返回重新搜索。"; return
            }
            revision = page.historyRevision
            if direction == "around" { messages = page.messages }
            else {
                let known = Set(messages.map(\.id)); messages += page.messages.filter { !known.contains($0.id) }; messages.sort { $0.id < $1.id }
            }
            if direction != "after" { hasOlder = page.hasOlder }
            if direction != "before" { hasNewer = page.hasNewer }
            busy = false
        } catch {
            guard stamp == generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription; busy = false
        }
    }
}
