import SwiftUI
import UniformTypeIdentifiers
import QuickLook

@MainActor
struct DocumentCard:View {
    @ObservedObject var store:ChatStore
    let document:DocumentAttachment
    var favorite:Int64?=nil
    var message:Message?=nil
    var onBranch: ((Message) -> Void)? = nil
    var remove:(()->Void)?=nil
    @State private var preview:URL?
    @State private var busy=false
    @State private var error:String?
    var body:some View {
        HStack(spacing:10){
            Image(systemName:"doc.text").font(.system(size:25,weight:.regular)).frame(width:34)
            Button {Task {await open()}} label:{VStack(alignment:.leading,spacing:5){Text(document.name).font(.system(size:14)).lineLimit(2);Text(document.detail).font(.system(size:11))}.frame(maxWidth:.infinity,alignment:.leading).multilineTextAlignment(.leading)}.buttonStyle(.plain).disabled(busy||remove != nil)
            if busy {ProgressView()}
            if let remove {Button(action:remove){Image(systemName:"xmark").font(.system(size:12)).frame(width:32,height:32)}.buttonStyle(.plain).accessibilityLabel("移除附件")}
        }.foregroundStyle(.primary).padding(12).background(Color.primary.opacity(0.045),in:RoundedRectangle(cornerRadius:7))
            .contextMenu {if let message {Button("引用"){store.quoteMessage(message)};Button("收藏"){Task {await store.favoriteMessage(message)}};if let onBranch { Button("从这里创建分支") { onBranch(message) } }}}
            .quickLookPreview($preview).alert("附件",isPresented:Binding(get:{error != nil},set:{if !$0 {error=nil}})){Button("确定",role:.cancel){}} message:{Text(error ?? "")}
            .onChange(of:store.searchConnectionID){_ in preview=nil;error=nil}
    }
    private func open() async {
        busy=true;defer {busy=false}
        do {
            let bytes=try await store.documentData(document.id,favorite:favorite)
            let folder=FileManager.default.temporaryDirectory.appendingPathComponent("LeonDocuments",isDirectory:true).appendingPathComponent(UUID().uuidString,isDirectory:true)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let name=URL(fileURLWithPath:document.name).lastPathComponent
            let file=folder.appendingPathComponent(name);try bytes.write(to:file,options:.atomic);preview=file
        }catch {self.error=error.localizedDescription}
    }
}

@MainActor
struct DocumentPickerButton:View {
    @ObservedObject var store:ChatStore
    @State private var choosing=false
    @State private var room=""
    @State private var connection:ObjectIdentifier?
    var body:some View {
        Button {room=store.documentRoom;connection=store.searchConnectionID;choosing=true} label:{
            #if os(macOS)
            Label("添加文件",systemImage:"paperclip").font(.system(size:13,weight:.regular)).foregroundStyle(.primary)
            #else
            MobileToolArtwork(title:"文件",symbol:.document)
            #endif
        }.buttonStyle(.plain).disabled(store.searchConnectionID==nil||store.importingDocuments)
            .accessibilityIdentifier("chat_tool_documents")
            .fileImporter(isPresented:$choosing,allowedContentTypes:[.item],allowsMultipleSelection:true){result in
                if case .success(let urls)=result {store.addDocuments(urls,room:room,connection:connection)}
            }
    }
}
@MainActor
struct DocumentDraftsView:View {
    @ObservedObject var store:ChatStore
    var body:some View {
        if store.importingDocuments {ProgressView("正在读取文档…").font(.system(size:12))}
        if !store.draftDocuments.isEmpty {ScrollView(.horizontal,showsIndicators:false){HStack(spacing:8){ForEach(store.draftDocuments){draft in DocumentCard(store:store,document:draft.attachment,remove:{store.removeDocument(draft.id)}).frame(width:260)}}}.frame(maxHeight:90)}
    }
}
