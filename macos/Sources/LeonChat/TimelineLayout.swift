import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct TimelineLayout:Equatable {
    var viewport:CGFloat?
    var content:CGFloat?
    var bottom:CGFloat?
    var messages:[Int64:CGRect]=[:]
    var nearBottom:Bool {guard let viewport,let bottom else {return false};return bottom>=0 && bottom<=viewport+48}
    func resized(from old:Self)->Bool {viewport != old.viewport || content != old.content}
}
struct TimelineLayoutKey:PreferenceKey {
    static let defaultValue=TimelineLayout()
    static func reduce(value:inout TimelineLayout,nextValue:()->TimelineLayout){
        let next=nextValue();value.viewport=next.viewport ?? value.viewport;value.content=next.content ?? value.content;value.bottom=next.bottom ?? value.bottom
        value.messages.merge(next.messages,uniquingKeysWith:{$1})
    }
}
extension View {
    func timelineViewport()->some View {coordinateSpace(name:"conversation-viewport").background(GeometryReader {proxy in Color.clear.preference(key:TimelineLayoutKey.self,value:TimelineLayout(viewport:proxy.size.height))})}
    func timelineContent()->some View {background(GeometryReader {proxy in Color.clear.preference(key:TimelineLayoutKey.self,value:TimelineLayout(content:proxy.size.height))})}
    func timelineBottom()->some View {background(GeometryReader {proxy in Color.clear.preference(key:TimelineLayoutKey.self,value:TimelineLayout(bottom:proxy.frame(in:.named("conversation-viewport")).maxY))})}
    func timelineMessage(_ id:Int64)->some View {background(GeometryReader {proxy in Color.clear.preference(key:TimelineLayoutKey.self,value:TimelineLayout(messages:[id:proxy.frame(in:.named("conversation-viewport"))]))})}
}

@MainActor
final class TimelineScrollHandle {
    var read:(()->CGFloat?)?
    var write:((CGFloat)->Void)?
    var nearBottom:(()->Bool)?
    var isScrolling:(()->Bool)?
    var changed:(()->Void)?
    var connected:(()->Void)?
    var began:(()->Void)?
    var ended:(()->Void)?
    var offset:CGFloat? {read?()}
}

/// Keeps native offsets without replacing SwiftUI's scroll delegate.
#if os(macOS)
private struct TimelineNativeScroll: NSViewRepresentable {
    let handle:TimelineScrollHandle
    func makeNSView(context:Context)->Observer {Observer(handle:handle)}
    func updateNSView(_ view:Observer,context:Context){view.connect()}
    final class Observer:NSView {
        let handle:TimelineScrollHandle
        private weak var scroll:NSScrollView?
        private var observers:[NSObjectProtocol]=[]
        init(handle:TimelineScrollHandle){self.handle=handle;super.init(frame:.zero)}
        required init?(coder:NSCoder){fatalError("init(coder:) unavailable")}
        override func viewDidMoveToWindow(){super.viewDidMoveToWindow();DispatchQueue.main.async {[weak self] in self?.connect()}}
        func connect(){
            guard let parent=enclosingScrollView,parent !== scroll else {return}
            observers.forEach(NotificationCenter.default.removeObserver);observers=[];scroll=parent
            let clip=parent.contentView;clip.postsBoundsChangedNotifications=true
            handle.read={[weak parent] in parent?.window == nil ? nil : parent?.contentView.bounds.minY}
            handle.write={[weak parent] value in
                guard let parent,let document=parent.documentView else {return}
                let clip=parent.contentView,y=min(max(0,value),max(0,document.bounds.height-clip.bounds.height))
                clip.scroll(to:NSPoint(x:clip.bounds.minX,y:y));parent.reflectScrolledClipView(clip)
            }
            handle.nearBottom={[weak parent] in guard let parent,let document=parent.documentView else {return false};return document.bounds.height-parent.contentView.bounds.maxY<48}
            observers.append(NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:clip,queue:.main){[weak self] _ in self?.handle.changed?()})
            observers.append(NotificationCenter.default.addObserver(forName:NSScrollView.willStartLiveScrollNotification,object:parent,queue:.main){[weak self] _ in self?.handle.began?()})
            observers.append(NotificationCenter.default.addObserver(forName:NSScrollView.didEndLiveScrollNotification,object:parent,queue:.main){[weak self] _ in self?.handle.ended?()})
            handle.connected?()
        }
        deinit {observers.forEach(NotificationCenter.default.removeObserver)}
    }
}
#else
private struct TimelineNativeScroll:UIViewRepresentable {
    let handle:TimelineScrollHandle
    func makeUIView(context:Context)->Observer {Observer(handle:handle)}
    func updateUIView(_ view:Observer,context:Context){view.connect()}
    final class Observer:UIView {
        let handle:TimelineScrollHandle
        private weak var scroll:UIScrollView?
        private var observation:NSKeyValueObservation?
        init(handle:TimelineScrollHandle){self.handle=handle;super.init(frame:.zero);isUserInteractionEnabled=false}
        required init?(coder:NSCoder){fatalError("init(coder:) unavailable")}
        override func didMoveToWindow(){super.didMoveToWindow();DispatchQueue.main.async {[weak self] in self?.connect()}}
        func connect(){
            var ancestor=superview
            while let view=ancestor,!(view is UIScrollView){ancestor=view.superview}
            guard let parent=ancestor as? UIScrollView,parent !== scroll else {return};scroll=parent
            handle.read={[weak parent] in parent?.window == nil ? nil : parent?.contentOffset.y}
            handle.write={[weak parent] value in
                guard let parent else {return};let minY = -parent.adjustedContentInset.top,maxY=max(minY,parent.contentSize.height-parent.bounds.height+parent.adjustedContentInset.bottom)
                parent.setContentOffset(CGPoint(x:parent.contentOffset.x,y:min(max(minY,value),maxY)),animated:false)
            }
            handle.nearBottom={[weak parent] in guard let parent else {return false};return parent.contentSize.height-parent.bounds.height+parent.adjustedContentInset.bottom-parent.contentOffset.y<48}
            handle.isScrolling={[weak parent] in guard let parent else {return false};return parent.isDragging || parent.isDecelerating || parent.isTracking}
            observation=parent.observe(\.contentOffset,options:[.new]){[weak self] _,_ in Task {@MainActor in self?.handle.changed?()}}
            parent.panGestureRecognizer.addTarget(self,action:#selector(panChanged))
            handle.connected?()
        }
        @objc private func panChanged(){guard let state=scroll?.panGestureRecognizer.state else {return};if state == .began {handle.began?()};if state == .ended || state == .cancelled {handle.ended?()}}
    }
}
#endif

@MainActor
final class ConversationViewport:ObservableObject {
    let handle=TimelineScrollHandle()
    private(set) var room=""
    private var entry=UUID()
    private(set) var proxy:ScrollViewProxy?
    private var anchor:(Int64)->AnyHashable={AnyHashable($0)}
    private var save:((ConversationScrollPosition)->Void)?
    private var layout=TimelineLayout(),layoutOffset:CGFloat=0
    private var rows:[Int64]=[],pending=Set<String>()
    private var lastNativeOffset:CGFloat?
    private var loaded=false,active=false,initial=true,following=true,interacting=false,anchorRequested=false
    private var restoring:ConversationScrollPosition?,lastSaved:ConversationScrollPosition?
    init(){
        handle.changed={[weak self] in self?.nativeMoved()}
        handle.connected={[weak self] in self?.applyPosition()}
        handle.began={[weak self] in self?.pause()}
        handle.ended={[weak self] in guard let self else {return};self.interacting=false;self.following=self.handle.nearBottom?() ?? false;self.remember()}
    }
    func enter(room:String,position:ConversationScrollPosition?,rows:[Int64],pending:[String],loaded:Bool,proxy:ScrollViewProxy,anchor:@escaping (Int64)->AnyHashable,save:@escaping (ConversationScrollPosition)->Void){
        self.entry=UUID();self.room=room;self.proxy=proxy;self.anchor=anchor;self.save=save;self.rows=rows;self.pending=Set(pending);self.loaded=loaded
        active=true;initial=position==nil;following=position==nil;interacting=false;restoring=position;lastSaved=position;anchorRequested=false;layout=TimelineLayout()
        applyPosition()
    }
    func leave(room:String){if self.room==room {remember()};active=false;entry=UUID();proxy=nil}
    func pause(){initial=false;restoring=nil;interacting=true;following=false}
    func loadOlder(){pause();interacting=false}
    func receivedRows(room:String,rows:[Int64],pending:[String],loaded:Bool){
        guard active,self.room==room else {return}
        if !self.rows.isEmpty && rows.isEmpty {lastSaved=nil;restoring=nil;initial=true;following=true}
        self.rows=rows;self.pending=Set(pending);self.loaded=loaded;applyPosition()
    }
    func pendingChanged(_ ids:[String]){
        if !Set(ids).subtracting(pending).isEmpty {following=true;initial=false;restoring=nil}
        pending=Set(ids);applyPosition()
    }
    func loadedChanged(_ loaded:Bool){self.loaded=loaded;applyPosition()}
    func geometryChanged(_ value:TimelineLayout,loaded:Bool){
        guard active else {return}
        layout=value;layoutOffset=handle.offset ?? 0;self.loaded=loaded
        if interacting || handle.isScrolling?() == true {remember();return}
        if restoring != nil || initial || following {applyPosition();return}
        if let previous=lastSaved {
            if let id=previous.messageID,rows.contains(id),value.messages[id].map({abs(Double($0.minY)-previous.messageTop)>0.5}) ?? true {
                restoring=previous;anchorRequested=false;applyPosition();return
            }
            if previous.messageID == nil {remember()}
        }else {remember()}
    }
    func resized(){applyPosition()}
    private func applyPosition(){
        guard active,!interacting,handle.isScrolling?() != true,let proxy else {return};let stamp=entry
        if initial,loaded,layout.nearBottom,handle.nearBottom?() == true,(rows.last.map {layout.messages[$0] != nil} ?? true),handle.offset != nil {initial=false;following=true;remember();return}
        if let position=restoring {
            guard loaded,let current=handle.offset else {return}
            if let id=position.messageID,rows.contains(id){
                guard let rect=layout.messages[id] else {
                    if !anchorRequested {anchorRequested=true;DispatchQueue.main.async {[weak self] in guard let self,self.active,self.entry==stamp,self.restoring != nil else {return};self.anchorRequested=false;proxy.scrollTo(self.anchor(id),anchor:.top)}}
                    return
                }
                let top=rect.minY-(current-layoutOffset),wanted=current+top-CGFloat(position.messageTop)
                handle.write?(wanted)
                let actual=handle.offset ?? wanted
                lastSaved=ConversationScrollPosition(offset:Double(actual),messageID:id,messageTop:position.messageTop)
                if abs(wanted-actual)>1 {return}
            }else{
                handle.write?(CGFloat(position.offset));lastSaved=snapshot()
            }
            restoring=nil;initial=false;following=false
            if let lastSaved {save?(lastSaved)}
            return
        }
        if initial || following {
            // Once the tail is laid out, use its native extent; LazyVStack's
            // estimated scroll target can still be short of the actual bottom.
            if layout.bottom != nil,(rows.last.map {layout.messages[$0] != nil} ?? true),handle.offset != nil {
                handle.write?(.greatestFiniteMagnitude)
                if loaded {initial=false};remember();return
            }
            DispatchQueue.main.async {[weak self] in guard let self,self.active,self.entry==stamp,!self.interacting,self.handle.isScrolling?() != true,self.initial||self.following else {return};proxy.scrollTo("bottom",anchor:.bottom)}
        }
    }
    private func nativeMoved(){
        guard let offset=handle.offset else {return};let changed=lastNativeOffset.map {abs($0-offset)>0.1} ?? true;lastNativeOffset=offset
        guard active,!initial,restoring==nil,changed,interacting || handle.isScrolling?() == true else {return}
        if !interacting {following=handle.nearBottom?() ?? false};remember()
    }
    var currentPosition:ConversationScrollPosition? {snapshot()}
    private func snapshot()->ConversationScrollPosition? {
        guard let offset=handle.offset else {return nil};let delta=offset-layoutOffset,viewport=layout.viewport ?? 0
        let visible=layout.messages.map {($0.key,$0.value.offsetBy(dx:0,dy:-delta))}.filter {$0.1.maxY>0 && $0.1.minY<viewport}.min {$0.1.minY<$1.1.minY}
        return ConversationScrollPosition(offset:Double(offset),messageID:visible?.0,messageTop:Double(visible?.1.minY ?? 0))
    }
    private func remember(){guard active,!initial,restoring==nil,let position=snapshot() else {return};lastSaved=position;save?(position)}
}
extension View {
    @MainActor func trackConversationScroll(_ viewport:ConversationViewport)->some View {background(TimelineNativeScroll(handle:viewport.handle))}
}
