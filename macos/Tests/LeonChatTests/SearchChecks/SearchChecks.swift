import Foundation
@testable import LeonChat

private final class SearchTransport: URLProtocol, @unchecked Sendable {
    static var check: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, body) = try Self.check!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url:request.url!,statusCode:code,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private func require(_ value: Bool, _ message: String) throws { if !value { throw ClientError.message(message) } }
@main
struct SearchChecks {
    @MainActor static func main() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SearchTransport.self]
        let api = MessageAPI(base:URL(string:"https://search.invalid")!,token:"chat_fixture",configuration:config)
        SearchTransport.check = { request in
            try require(request.value(forHTTPHeaderField:"Authorization") == "Bearer chat_fixture","missing authorization")
            let q = Dictionary(uniqueKeysWithValues:URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!.map {($0.name,$0.value!)})
            try require(q == ["q":"中文 %_&+?#","conversationId":"thread:one","before":"15"],"search URL changed literal query or cursor")
            return (200,#"{"results":[],"hasMore":true,"nextBefore":9}"#)
        }
        let page = try await api.search(query:"中文 %_&+?#",room:"thread:one",before:15)
        try require(page.hasMore && page.nextBefore == 9,"lost search pagination")
        SearchTransport.check = {request in
            let q = Dictionary(uniqueKeysWithValues:URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!.map {($0.name,$0.value!)})
            try require(q == ["q":"中文"],"global search includes room or stale cursor")
            return (404,"{}")
        }
        do {_ = try await api.search(query:"中文",room:nil,before:nil);throw ClientError.message("old server accepted")}
        catch {try require(error.localizedDescription.contains("升级"),"old server lacks upgrade hint")}
        SearchTransport.check = {request in
            let q = Dictionary(uniqueKeysWithValues:URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!.map {($0.name,$0.value!)})
            try require(request.url!.path == "/api/device-messages/context" && q == ["conversationId":"thread:one","messageId":"25","direction":"after"],"context endpoint or anchor incorrect")
            return (200,#"{"messages":[],"hasOlder":true,"hasNewer":false,"historyRevision":8}"#)
        }
        let context = try await api.searchContext(room:"thread:one",message:25,direction:"after")
        try require(context.hasOlder && context.historyRevision == 8,"context metadata lost")
        let branchRoom=Conversation(id:"branch:result",name:"方案 B",kind:"direct",agentId:"agent",agentIds:["agent"])
        SearchTransport.check = {request in
            try require(request.httpMethod=="POST" && request.url!.path=="/api/conversations/dm:user:agent/branches","branch coordinates or method")
            try require(request.value(forHTTPHeaderField:"Authorization")=="Bearer chat_fixture","branch authentication")
            var bytes=request.httpBody ?? Data()
            if bytes.isEmpty,let input=request.httpBodyStream {input.open();defer {input.close()};var buffer=[UInt8](repeating:0,count:4096);while input.hasBytesAvailable {let n=input.read(&buffer,maxLength:buffer.count);if n<=0 {break};bytes.append(contentsOf:buffer.prefix(n))}}
            let body=try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
            try require(body.count==3 && body["messageId"] as? Int==7 && body["requestId"] as? String=="stable-request" && body["name"] as? String=="方案 B","branch trusted client history or lost retry ID")
            return (200,String(data:try JSONEncoder().encode(branchRoom),encoding:.utf8)!)
        }
        try require(try await api.branch(room:"dm:user:agent",message:7,name:"方案 B",requestId:"stable-request").id==branchRoom.id,"branch decode")
        SearchTransport.check={_ in (404,"{}")}
        do {_ = try await api.branch(room:"shared",message:7,name:"分支",requestId:"request");throw ClientError.message("old server accepted branch")}
        catch {try require(error.localizedDescription.contains("升级"),"missing branch upgrade feedback")}
        SearchTransport.check={_ in (404,#"{"message":"原消息不存在或已清空，请刷新后重试"}"#)}
        do {_ = try await api.branch(room:"shared",message:7,name:"分支",requestId:"request");throw ClientError.message("missing anchor accepted")}
        catch {try require(error.localizedDescription.contains("原消息不存在"),"missing branch point was incorrectly treated as an old server")}
        let message=Message(id:7,clientMessageId:"client",deviceId:"device",sender:"Alice",platform:"macos",text:"hello",createdAt:1000,conversationId:"shared",role:"user",agentId:nil,replyTo:nil)
        let favorite=FavoriteItem(id:12,message:message,conversationName:"设备群聊",savedAt:1000)
        SearchTransport.check = {request in
            try require(request.value(forHTTPHeaderField:"Authorization")=="Bearer chat_fixture","favorite auth")
            switch request.url!.path {
            case "/api/device-messages/7/favorite":return (200,String(data:try JSONEncoder().encode(favorite),encoding:.utf8)!)
            case "/api/device-messages/favorites":
                let q=Dictionary(uniqueKeysWithValues:URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!.map {($0.name,$0.value!)})
                try require(q==["q":"中文 %_&+","before":"20"],"favorite query encoding")
                return (200,String(data:try JSONEncoder().encode(FavoritePage(results:[favorite],hasMore:false,nextBefore:nil)),encoding:.utf8)!)
            case "/api/device-messages/favorites/12/remove":try require(request.httpMethod=="POST","remove method");return (200,#"{"removed":true}"#)
            case "/api/device-messages/features":return (404,"{}")
            default:throw ClientError.message("Unexpected collection request")
            }
        }
        try require(try await api.addFavorite(7).id==12,"favorite response")
        try require(try await api.favorites(query:"中文 %_&+",before:20).results.first?.id==12,"favorite page")
        try await api.removeFavorite(12)
        var outgoing=Outgoing(clientMessageId:"quote",deviceId:"device",sender:"Alice",platform:"macos",text:"reply",conversationId:"shared",quoteMessageId:7,quote:MessageQuote(message:message))
        do {_ = try await api.send(outgoing);throw ClientError.message("old server accepted quote")}
        catch {try require(error.localizedDescription.contains("升级"),"missing quote upgrade hint")}
        outgoing.quote=nil
        let body = String(repeating:"😀前文",count:100)+"target"+String(repeating:"后文",count:100)
        try require(SearchExcerpt.text(body,query:"TARGET").contains("target"),"distant keyword not present in excerpt")
        var release: CheckedContinuation<ChatSearchPage,Never>?
        let state = ChatSearchState(room:nil) {_,_,_ in await withCheckedContinuation {release = $0}}
        state.query = "query"; state.changed(immediate:true)
        while release == nil {await Task.yield()}
        state.query = ""; state.changed()
        release!.resume(returning:ChatSearchPage(results:[],hasMore:true,nextBefore:10))
        for _ in 0..<10 {await Task.yield()}
        try require(!state.hasMore && !state.searched && !state.busy,"late response revived a cancelled search")
        print("Mac search: authenticated HTTP, Unicode queries, global scope, pagination, context, upgrade and cancellation checks passed")
    }
}
