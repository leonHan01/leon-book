import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
struct QuoteCard: View {
    @ObservedObject var store:ChatStore
    let quote:MessageQuote
    let room:String
    let title:String
    var cancel:(()->Void)? = nil
    @State private var target:ChatSearchHit?
    var body:some View {
        HStack(spacing:9) {
            RoundedRectangle(cornerRadius:1).fill(Color.primary.opacity(0.35)).frame(width:2)
            Button {target=quote.anchor(room:room,title:title)} label:{
                VStack(alignment:.leading,spacing:4) {
                    Text(quote.sender).font(.system(size:12))
                    Text(quote.preview.isEmpty ? "[消息]" : quote.preview).font(.system(size:12)).lineLimit(2)
                }.frame(maxWidth:.infinity,alignment:.leading).multilineTextAlignment(.leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if let cancel {Button(action:cancel) {Image(systemName:"xmark").font(.system(size:12)).frame(width:32,height:32)}.buttonStyle(.plain).accessibilityLabel("取消引用")}
        }.padding(10).fixedSize(horizontal:false,vertical:true).background(Color.primary.opacity(0.045),in:RoundedRectangle(cornerRadius:6))
            .accessibilityIdentifier(cancel == nil ? "message_quote" : "quote_preview")
            .sheet(item:$target) {hit in ChatSearchView(store:store,room:room,title:title,initialHit:hit) {store.openQuotedRoom($0)}}
    }
}

@MainActor
struct FavoritesView: View {
    @ObservedObject var store:ChatStore
    @StateObject private var model:FavoriteBrowserState
    @State private var selected:FavoriteItem?
    @State private var source:ChatSearchHit?
    @State private var confirmRemoval=false
    @Environment(\.dismiss) private var dismiss
    let openRoom:(String)->Void
    init(store:ChatStore,openRoom:@escaping (String)->Void) {
        self.store=store;self.openRoom=openRoom
        _model=StateObject(wrappedValue:FavoriteBrowserState(fetch:store.favoritePage,remove:store.deleteFavorite))
    }
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Button {if selected != nil {selected=nil} else {dismiss()}} label:{Label(selected == nil ? "关闭" : "收藏",systemImage:"chevron.left")}
                Spacer();Text(selected == nil ? "我的收藏" : "收藏详情").font(.system(size:17,weight:.regular));Spacer()
                if selected != nil {Button("取消收藏") {confirmRemoval=true}.disabled(!model.removing.isEmpty)}
                else {Button("刷新") {model.reload()}.disabled(model.busy)}
            }.padding(16)
            Divider()
            ZStack {
                list.opacity(selected==nil ? 1 : 0).allowsHitTesting(selected==nil).accessibilityHidden(selected != nil)
                if let item=selected {detail(item).background(collectionBackground)}
            }
            if let error=model.error {Text(error).font(.callout).foregroundStyle(.primary).padding(10);Button("重试") {if let item=selected,model.failedRemoval==item.id {Task {if await model.delete(item) {selected=nil}}} else {model.retry()}}.padding(.bottom,10)}
        }
        .background(collectionBackground).tint(.primary)
        .task {model.reload()}
        .onChange(of:model.query) {_ in model.reload(debounce:true)}
        .onChange(of:store.searchConnectionID) {_ in selected=nil;source=nil;model.query="";model.reload();dismiss()}
        .onDisappear {model.stop()}
        .confirmationDialog("取消这条收藏？",isPresented:$confirmRemoval,titleVisibility:.visible) {
            Button("取消收藏",role:.destructive) {if let item=selected {Task {if await model.delete(item) {selected=nil}}}}
            Button("保留",role:.cancel) {}
        }
        .sheet(item:$source) {hit in
            ChatSearchView(store:store,room:hit.message.conversationId,title:hit.conversationName,initialHit:hit) {room in dismiss();openRoom(room)}
        }
        #if os(macOS)
        .frame(minWidth:660,idealWidth:760,minHeight:520,idealHeight:640)
        #endif
    }
    private var list:some View {
        VStack(spacing:0) {
            HStack {Image(systemName:"magnifyingglass");TextField("搜索收藏",text:$model.query).textFieldStyle(.plain);if !model.query.isEmpty {Button {model.query=""} label:{Image(systemName:"xmark.circle.fill")}.buttonStyle(.plain)}}
                .padding(12).background(Color.primary.opacity(0.045),in:RoundedRectangle(cornerRadius:8)).padding(14)
            ScrollView {
                LazyVStack(spacing:10) {
                    ForEach(model.items) {item in
                        Button {selected=item} label:{
                            VStack(alignment:.leading,spacing:10) {
                                HStack {Text(item.message.sender).font(.system(size:14));Spacer();Text(item.message.date.formatted(date:.numeric,time:.shortened)).font(.caption).foregroundStyle(.primary)}
                                if !item.message.text.isEmpty {Text(item.message.text).font(.system(size:15)).lineLimit(3).multilineTextAlignment(.leading)}
                                ForEach(item.message.documents ?? []){doc in Text("[文件] "+doc.name).font(.system(size:14))}
                                if let image=item.message.images?.first {CollectionImage(store:store,favorite:item.id,image:image.id).frame(maxHeight:120)}
                                Text("来自：\(item.conversationName)").font(.caption).foregroundStyle(.primary)
                            }.frame(maxWidth:.infinity,alignment:.leading).padding(15).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:9)).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("favorite_\(item.id)")
                            .contextMenu {Button("取消收藏",role:.destructive) {selected=item;confirmRemoval=true}}
                    }
                    if model.busy {ProgressView("正在读取收藏…").padding(24)}
                    else if model.items.isEmpty && model.error == nil {Text(model.query.isEmpty ? "暂无收藏\n长按聊天消息，选择“收藏”" : "未找到相关收藏").font(.callout).foregroundStyle(.primary).multilineTextAlignment(.center).padding(.top,70)}
                    if model.hasMore && !model.busy {Button("加载更多收藏") {model.more()}.padding(16)}
                }.padding(.horizontal,14).padding(.bottom,16)
            }
        }
    }
    private func detail(_ item:FavoriteItem) -> some View {
        ScrollView {
            VStack(alignment:.leading,spacing:15) {
                Text("\(item.message.sender) · \(item.message.date.formatted(date:.numeric,time:.shortened))").font(.caption).foregroundStyle(.primary)
                if let quote=item.message.quote {Text("引用 \(quote.sender)：\(quote.preview)").font(.callout).padding(10).background(Color.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:6))}
                if !item.message.text.isEmpty {CollectionText(text:item.message.text)}
                ForEach(item.message.documents ?? []){doc in DocumentCard(store:store,document:doc,favorite:item.id)}
                ForEach(item.message.images ?? []) {image in CollectionImage(store:store,favorite:item.id,image:image.id)}
                Text("来自：\(item.conversationName)").font(.caption).foregroundStyle(.primary)
                Button("查看原消息") {source=ChatSearchHit(message:item.message,conversationName:item.conversationName)}
            }.padding(18).frame(maxWidth:.infinity,alignment:.leading)
        }
    }
}

private var collectionBackground:Color {
    #if os(macOS)
    Color(nsColor:.windowBackgroundColor)
    #else
    Color(uiColor:.systemBackground)
    #endif
}
private struct CollectionText:View {
    let text:String
    #if !os(macOS)
    @State private var height:CGFloat=44
    #endif
    var body:some View {
        #if os(macOS)
        MarkdownMessageView(text,mine:false)
        #else
        RichMessageView(source:text,mine:false,height:$height,resized:{},copied:{}).frame(height:height)
        #endif
    }
}
@MainActor
private struct CollectionImage:View {
    @ObservedObject var store:ChatStore
    let favorite:Int64
    let image:String
    @State private var bytes:Data?
    @State private var failed=false
    @State private var attempt=0
    var body:some View {
        Group {
            if let bytes {
                #if os(macOS)
                if let image=NSImage(data:bytes) {Image(nsImage:image).resizable().scaledToFit().frame(maxHeight:420)}
                #else
                if let image=UIImage(data:bytes) {Image(uiImage:image).resizable().scaledToFit().frame(maxHeight:420)}
                #endif
            } else if failed {Button("图片加载失败，点击重试") {attempt+=1}}
            else {ProgressView().frame(height:70)}
        }.task(id:attempt) {do {failed=false;bytes=try await store.favoriteImage(favorite,image:image)} catch {failed=true}}
    }
}

@MainActor
struct BranchConversationView:View {
    @ObservedObject var store:ChatStore
    let message:Message
    let sourceName:String
    let openRoom:(Conversation)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var name=""
    @State private var request=UUID().uuidString.lowercased()
    @State private var submittedName:String?
    @State private var attempt=0
    @State private var creating=false
    @State private var failure:String?
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("创建对话分支").font(.system(size:20,weight:.semibold))
            Text("复制到这条消息（含）为止的记录，在新会话中继续独立讨论。").font(.system(size:14))
            VStack(alignment:.leading,spacing:7) {
                Text(message.sender).font(.system(size:12)).foregroundStyle(.secondary)
                Text(MessageQuote(message:message).preview).font(.system(size:14)).lineLimit(4)
            }.frame(maxWidth:.infinity,alignment:.leading).padding(12).background(Color.primary.opacity(0.045),in:RoundedRectangle(cornerRadius:7))
            TextField("分支名称",text:$name).textFieldStyle(.roundedBorder).disabled(submittedName != nil).accessibilityIdentifier("branch_name")
            if store.conversations.first(where:{$0.id==store.selectedConversationId})?.kind == "group" {
                Text("群聊分支仅自己可见，保留原 Agent。需要共同讨论时可再邀请其他用户。").font(.system(size:12)).foregroundStyle(.secondary)
            }
            if creating {ProgressView("正在创建分支…")}
            if let failure {Text(failure).font(.system(size:13)).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)}
            HStack {
                Spacer()
                Button("取消",role:.cancel) {store.branchMessage=nil;dismiss()}.disabled(creating)
                Button(failure == nil ? "创建分支" : "重试创建") {
                    if submittedName == nil {submittedName=name.trimmingCharacters(in:.whitespacesAndNewlines)}
                    creating=true;failure=nil;attempt+=1
                }.disabled(creating || name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || name.utf16.count>60)
                    .accessibilityIdentifier("branch_create")
            }
        }.padding(24)
            #if os(macOS)
            .frame(width:440)
            #endif
            .interactiveDismissDisabled(creating)
            .onAppear {
                if name.isEmpty {
                    var title=sourceName
                    while title.utf16.count>50 {title.removeLast()}
                    name=title+" · 分支"
                }
            }
            .onChange(of:store.searchConnectionID) {_ in store.branchMessage=nil;dismiss()}
            .task(id:attempt) {
                guard attempt>0,let title=submittedName else {return}
                defer {creating=false}
                do {
                    let room=try await store.createBranch(message,name:title,requestId:request)
                    try Task.checkCancellation()
                    let stillAtSource=store.documentRoom == message.conversationId
                    store.branchMessage=nil;dismiss();if stillAtSource {openRoom(room)}
                } catch is CancellationError {} catch {failure=error.localizedDescription}
            }
    }
}
