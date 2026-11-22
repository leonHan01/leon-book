import Foundation

/// Session-only reading position. An anchor survives rows above it changing height.
struct ConversationScrollPosition:Equatable {
    let offset:Double
    let messageID:Int64?
    let messageTop:Double
    static func cacheRange(ids:[Int64],anchor:Int64?,limit:Int=300)->Range<Int>{
        guard ids.count>limit else {return 0..<ids.count}
        guard let anchor,let index=ids.firstIndex(of:anchor) else {return ids.count-limit..<ids.count}
        let start=max(0,min(index-80,ids.count-limit));return start..<start+limit
    }
}
