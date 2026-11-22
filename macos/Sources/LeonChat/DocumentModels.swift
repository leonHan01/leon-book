import Foundation

struct DocumentAttachment: Codable,Identifiable,Equatable,Sendable {
    let id:String
    let name:String
    let mimeType:String
    let byteCount:Int
    let characterCount:Int
    let truncated:Bool
    var detail:String {ByteCountFormatter.string(fromByteCount:Int64(byteCount),countStyle:.file)+(characterCount>0 ? " · 已提取 \(characterCount) 字符" : "")+(truncated ? " · 长文已截取" : "")}
}
struct DraftDocument:Identifiable,Equatable,Sendable {
    let attachment:DocumentAttachment
    let data:Data
    var id:String {attachment.id}
    static let extensions=["pdf","txt","doc","docx","xls","xlsx","md","markdown","csv"]
    static func read(_ url:URL)throws -> DraftDocument {
        let allowed=url.startAccessingSecurityScopedResource();defer {if allowed {url.stopAccessingSecurityScopedResource()}}
        guard extensions.contains(url.pathExtension.lowercased()),url.lastPathComponent.utf16.count<=180 else {throw DocumentError(message:"支持 PDF、TXT、Word、Excel、Markdown 和 CSV 文件。")}
        let file=try FileHandle(forReadingFrom:url);defer {try? file.close()};var data=Data()
        while let part=try file.read(upToCount:65536),!part.isEmpty {guard data.count+part.count<=10*1024*1024 else {throw DocumentError(message:"每个文档不能超过 10 MB。")};data.append(part)}
        guard !data.isEmpty else {throw DocumentError(message:"不能发送空文件。")}
        return DraftDocument(attachment:DocumentAttachment(id:UUID().uuidString.lowercased(),name:url.lastPathComponent,mimeType:"application/octet-stream",byteCount:data.count,characterCount:0,truncated:false),data:data)
    }
}
struct DocumentError:LocalizedError {let message:String;var errorDescription:String? {message}}

enum DocumentFiles {
    static func file(_ id:String,scope:String)throws -> URL {
        guard UUID(uuidString:id) != nil,!scope.isEmpty else {throw DocumentError(message:"文档存储标识无效。")}
        let base=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
        let folder=base.appendingPathComponent("Leon/chat-documents").appendingPathComponent(scope)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);return folder.appendingPathComponent(id)
    }
    static func save(_ doc:DraftDocument,scope:String)throws {let url=try file(doc.id,scope:scope);try doc.data.write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)}
    static func read(_ id:String,scope:String)throws -> Data {try Data(contentsOf:file(id,scope:scope))}
    static func remove(_ ids:[String],scope:String){for id in ids {if let url=try? file(id,scope:scope){try? FileManager.default.removeItem(at:url)}}}
}
