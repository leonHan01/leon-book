import Foundation

struct ChatNotification:Codable,Identifiable,Equatable,Sendable {let id:Int64;let room:String;let title:String;let text:String}
struct NotificationPage:Codable,Sendable {let events:[ChatNotification];let nextAfter:Int64;let hasMore:Bool}
struct NotificationStatus:Codable,Sendable {let enabled:Bool;let apns:Bool;let vivo:Bool;let userId:String}
struct PushRegistration:Codable,Sendable {
    let deviceId:String;let platform:String;let provider:String;let token:String;let environment:String
    let enabled:Bool;let preview:Bool;let activeRoom:String?
}
protocol NotificationAPI:AnyObject,Sendable {
    func notificationStatus() async throws -> NotificationStatus
    func notifications(device:String,after:Int64?,preview:Bool) async throws -> NotificationPage
    func registerNotifications(_ registration:PushRegistration) async throws
    func removeNotifications(device:String) async throws
}
