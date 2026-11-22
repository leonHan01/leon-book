import Foundation
import Combine

@MainActor
final class FavoriteBrowserState: ObservableObject {
    @Published var query = ""
    @Published private(set) var items: [FavoriteItem] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var hasMore = false
    @Published private(set) var removing = Set<Int64>()
    @Published private(set) var failedRemoval:Int64?
    private var before: Int64?
    private var generation = UUID()
    private var task: Task<Void,Never>?
    private let fetch: (String,Int64?) async throws -> FavoritePage
    private let remove: (Int64) async throws -> Void
    init(fetch: @escaping (String,Int64?) async throws -> FavoritePage, remove: @escaping (Int64) async throws -> Void) {self.fetch=fetch;self.remove=remove}
    func reload(debounce: Bool = false) {
        stop();items=[];before=nil;hasMore=false;error=nil;failedRemoval=nil
        let q=query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard q.utf16.count<=100 else {error="搜索词最多 100 字符";return}
        busy=true;let stamp=generation
        task=Task {
            if debounce {do {try await Task.sleep(nanoseconds:350_000_000)} catch {return}}
            await load(q,stamp:stamp,append:false)
        }
    }
    func more() {
        guard !busy,hasMore else {return};busy=true;error=nil;let stamp=generation,q=query.trimmingCharacters(in:.whitespacesAndNewlines)
        task=Task {await load(q,stamp:stamp,append:true)}
    }
    func retry(){if items.isEmpty || !hasMore {reload()} else {more()}}
    private func load(_ q:String,stamp:UUID,append:Bool) async {
        do {
            let page=try await fetch(q,append ? before : nil)
            guard stamp==generation,!Task.isCancelled else {return}
            let known=Set(items.map(\.id));items=append ? items+page.results.filter {!known.contains($0.id)} : page.results
            before=page.nextBefore;hasMore=page.hasMore && before != nil;busy=false
        } catch {guard stamp==generation,!Task.isCancelled else {return};self.error=error.localizedDescription;busy=false}
    }
    func delete(_ item:FavoriteItem) async -> Bool {
        guard !removing.contains(item.id) else {return false};let stamp=generation;removing.insert(item.id);failedRemoval=nil;error=nil
        defer {if stamp==generation {removing.remove(item.id)}}
        do {try await remove(item.id);guard stamp==generation else {return false};items.removeAll {$0.id==item.id};return true}
        catch {if stamp==generation {self.error=error.localizedDescription;failedRemoval=item.id};return false}
    }
    func stop(){task?.cancel();task=nil;generation=UUID();busy=false;removing=[]}
}

extension MessageQuote {
    func anchor(room:String,title:String) -> ChatSearchHit {
        let message=Message(id:id,clientMessageId:"",deviceId:"",sender:sender,platform:"",text:text,createdAt:0,conversationId:room,role:nil,agentId:nil,replyTo:nil,images:images)
        return ChatSearchHit(message:message,conversationName:title)
    }
}
