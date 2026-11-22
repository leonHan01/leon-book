import SwiftUI
import UserNotifications
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct NotificationRoute:Equatable {let nonce=UUID();let account:String;let room:String;let message:Int64}

@MainActor
final class ChatNotifications:NSObject,ObservableObject,UNUserNotificationCenterDelegate {
    static let shared=ChatNotifications()
    @Published private(set) var enabled=ChatPreferences.defaults.bool(forKey:"chat.notifications.enabled")
    @Published var previews=ChatPreferences.defaults.bool(forKey:"chat.notifications.previews") {didSet {ChatPreferences.defaults.set(previews,forKey:"chat.notifications.previews");restart()}}
    @Published private(set) var status="通知尚未开启"
    @Published var route:NotificationRoute?
    private var api:(any NotificationAPI)?
    private var device="",account=""
    private var foreground=true,visibleRoom:String?
    private var task:Task<Void,Never>?
    private var generation=UUID()
    private var token=ChatPreferences.defaults.string(forKey:"chat.notifications.apns-token") ?? ""
    private var after:Int64?
    private var displayed=Set<Int64>()
    override init(){super.init()}
    func bind(api:(any NotificationAPI)?,device:String,room:String?,foreground:Bool){
        UNUserNotificationCenter.current().delegate=self
        let changed=self.api.map(ObjectIdentifier.init) != api.map(ObjectIdentifier.init)
        self.foreground=foreground;visibleRoom=room
        if changed {
            if let previous=self.api {Task {try? await previous.removeNotifications(device:self.device)}}
            task?.cancel();generation=UUID();after=nil;displayed=[];account=""
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        }
        self.api=api;self.device=device
        #if os(iOS)
        if !foreground {task?.cancel();task=nil;generation=UUID();if let api,enabled {Task {try? await api.registerNotifications(registration(active:nil))}};return}
        #endif
        if changed||task==nil {restart()}
    }
    func setEnabled(_ value:Bool) async {
        if value {
            do {let allowed=try await UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound,.badge]);guard allowed else {status="系统通知未授权，请在系统设置中允许 Leon 通知。";return}}
            catch {status="无法申请系统通知权限。";return}
        }
        enabled=value;ChatPreferences.defaults.set(value,forKey:"chat.notifications.enabled")
        if value {registerRemoteIfAvailable()}else {UNUserNotificationCenter.current().removeAllPendingNotificationRequests();UNUserNotificationCenter.current().removeAllDeliveredNotifications();if let api {try? await api.removeNotifications(device:device)}}
        restart()
    }
    func receivedToken(_ data:Data){token=data.map {String(format:"%02x",$0)}.joined();ChatPreferences.defaults.set(token,forKey:"chat.notifications.apns-token");restart()}
    func remoteFailed(){if enabled {status="系统通知已开启；APNs 尚未配置。"}}
    private var remoteEnabled:Bool {Bundle.main.object(forInfoDictionaryKey:"LeonRemotePushEnabled") as? Bool == true}
    private func registerRemoteIfAvailable(){
        guard remoteEnabled else {return}
        #if os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #else
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }
    private func registration(active:String?) -> PushRegistration {
        #if os(macOS)
        let platform="macos"
        #else
        let platform="ios"
        #endif
        return PushRegistration(deviceId:device,platform:platform,provider:remoteEnabled && !token.isEmpty ? "apns" : "local",token:remoteEnabled ? token : "",environment:Bundle.main.object(forInfoDictionaryKey:"LeonPushEnvironment") as? String ?? "development",enabled:enabled,preview:previews,activeRoom:active)
    }
    private func restart(){
        task?.cancel();task=nil;generation=UUID()
        guard enabled else {status="通知尚未开启";return}
        guard let api,!device.isEmpty else {status="请先连接服务器";return}
        #if os(iOS)
        guard foreground else {return}
        #endif
        let stamp=generation
        registerRemoteIfAvailable()
        task=Task {
            var checkedAt=Date.distantPast,remoteAvailable=false
            while !Task.isCancelled,stamp==generation {
                do {
                    let settings=await UNUserNotificationCenter.current().notificationSettings()
                    guard stamp==generation,!Task.isCancelled else {return}
                    guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {status="系统通知未授权，请在系统设置中允许。";try? await api.removeNotifications(device:device);task=nil;return}
                    if Date().timeIntervalSince(checkedAt)>30 {
                        let availability=try await api.notificationStatus();guard stamp==generation else {return}
                        account=availability.userId;remoteAvailable=availability.apns&&remoteEnabled && !token.isEmpty
                        try await api.registerNotifications(registration(active:foreground ? visibleRoom : nil));checkedAt=Date()
                        status=remoteAvailable ? "系统通知已开启；后台通道已配置" : "应用运行时通知已开启；后台推送待配置"
                    }
                    let page=try await api.notifications(device:device,after:after,preview:previews)
                    guard stamp==generation,!Task.isCancelled else {return}
                    for event in page.events {
                        if !(foreground && event.room==visibleRoom),!remoteAvailable {await present(event)}
                    }
                    after=page.nextAfter
                    if page.hasMore {continue}
                } catch {if stamp==generation {status=error.localizedDescription}}
                do {try await Task.sleep(nanoseconds:8_000_000_000)}catch {return}
            }
        }
    }
    private func present(_ event:ChatNotification) async {
        guard enabled,displayed.insert(event.id).inserted else {return}
        if displayed.count>1000 {displayed=[event.id]}
        let content=UNMutableNotificationContent();content.title=event.title;content.body=event.text;content.sound = .default;content.threadIdentifier=event.room
        content.userInfo=["accountId":account,"roomId":event.room,"messageId":event.id]
        let stamp=generation,identifier="leon.\(account).\(event.id)"
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:identifier,content:content,trigger:nil))
        if stamp != generation {UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers:[identifier]);UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers:[identifier])}
    }
    private func parsed(_ info:[AnyHashable:Any])->NotificationRoute? {
        guard let user=info["accountId"] as? String,let room=info["roomId"] as? String,!room.isEmpty,room.count<=80 else {return nil}
        let message=(info["messageId"] as? NSNumber)?.int64Value ?? Int64(info["messageId"] as? String ?? "") ?? 0
        return NotificationRoute(account:user,room:room,message:message)
    }
    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter,willPresent notification:UNNotification,withCompletionHandler completionHandler:@escaping (UNNotificationPresentationOptions)->Void){
        Task {@MainActor in
            guard self.enabled,let target=self.parsed(notification.request.content.userInfo),target.account==self.account,!(self.foreground&&target.room==self.visibleRoom) else {completionHandler([]);return}
            let local=notification.request.identifier.hasPrefix("leon.")
            if !local && !self.displayed.insert(target.message).inserted {completionHandler([]);return}
            completionHandler([.banner,.sound,.list])
        }
    }
    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter,didReceive response:UNNotificationResponse,withCompletionHandler completionHandler:@escaping ()->Void){
        Task {@MainActor in self.route=self.parsed(response.notification.request.content.userInfo);completionHandler()}
    }
}

@MainActor
struct NotificationSettingsView:View {
    @ObservedObject private var notifications=ChatNotifications.shared
    var body:some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 0) {
                Toggle(isOn: Binding(get: { notifications.enabled }, set: { value in
                    Task { await notifications.setEnabled(value) }
                })) {
                    Text("新消息通知").frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
                Divider().padding(.horizontal, 14)
                Toggle(isOn: $notifications.previews) {
                    Text("显示消息预览").frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(!notifications.enabled)
                .padding(14)
            }
            .toggleStyle(.switch)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            Text(notifications.status)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("通知说明") {
                Text("查看当前会话时不弹出提醒。应用退出后，只有后台推送可用时才能收到通知。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            .font(.callout)
        }
    }
}

@MainActor
struct NotificationHost:ViewModifier {
    @ObservedObject var store:ChatStore
    let visibleRoom:String?
    let openRoom:(String)->Void
    @ObservedObject private var notifications=ChatNotifications.shared
    @Environment(\.scenePhase) private var phase
    func body(content:Content)->some View {
        content.task {bind();openPending()}
            .onChange(of:store.searchConnectionID){_ in bind()}
            .onChange(of:visibleRoom){_ in bind()}
            .onChange(of:phase){_ in bind()}
            .onChange(of:notifications.route){_ in openPending()}
    }
    private func bind(){notifications.bind(api:store.notificationAPI,device:store.notificationDevice,room:visibleRoom,foreground:phase == .active)}
    private func openPending(){
        guard let route=notifications.route,store.notificationAPI != nil else {return}
        Task {
            do {
                guard let api=store.notificationAPI else {return};let status=try await api.notificationStatus()
                guard route.account==status.userId,store.searchConnectionID==ObjectIdentifier(api) else {notifications.route=nil;return}
                _ = try await store.searchHistory(room:route.room,message:route.message,direction:"around")
                guard store.searchConnectionID==ObjectIdentifier(api) else {return};notifications.route=nil;openRoom(route.room)
            }catch {notifications.route=nil;store.error=error.localizedDescription}
        }
    }
}

#if os(iOS)
@MainActor
final class PlatformPushDelegate:NSObject,UIApplicationDelegate {
    func application(_ application:UIApplication,didFinishLaunchingWithOptions launchOptions:[UIApplication.LaunchOptionsKey:Any]?=nil)->Bool {UNUserNotificationCenter.current().delegate=ChatNotifications.shared;return true}
    func application(_ application:UIApplication,didRegisterForRemoteNotificationsWithDeviceToken token:Data){ChatNotifications.shared.receivedToken(token)}
    func application(_ application:UIApplication,didFailToRegisterForRemoteNotificationsWithError error:Error){ChatNotifications.shared.remoteFailed()}
}
#endif
