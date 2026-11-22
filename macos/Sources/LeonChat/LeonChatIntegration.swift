import AppKit
import SwiftUI
import UserNotifications

/// One connection and outbox across LeonBook windows and navigation changes.
@MainActor
final class LeonChatSession {
    static let shared = LeonChatSession(store: ChatStore(), notifications: .shared)
    let store: ChatStore
    private let notifications: ChatNotifications?
    private(set) var started = false
    private var routing = false
    private var chatPollingActive: Bool?
    private var lastKeyHostID: UUID?

    struct Host {
        let foreground: Bool
        let key: Bool
        let visible: Bool
        let open: () -> Void
    }
    private var hosts: [UUID: Host] = [:]

    init(store: ChatStore, notifications: ChatNotifications? = nil) {
        self.store = store
        self.notifications = notifications
    }

    func startIfNeeded(forVisibleChat visible: Bool = false) {
        guard !started, visible || notifications?.enabled == true || notifications?.route != nil else { return }
        started = true
        updatePolling()
        Task {
            await store.start()
            bind()
        }
    }

    func update(_ id: UUID, host: Host) {
        hosts[id] = host
        if host.key && host.foreground { lastKeyHostID = id }
        startIfNeeded(forVisibleChat: host.visible)
        bind()
    }

    func remove(_ id: UUID) {
        hosts.removeValue(forKey: id)
        if lastKeyHostID == id { lastKeyHostID = nil }
        bind()
    }

    private var frontHost: Host? {
        hosts.values.first { $0.key && $0.foreground }
            ?? lastKeyHostID.flatMap { hosts[$0] }.flatMap { $0.foreground ? $0 : nil }
            ?? hosts.values.first { $0.foreground }
    }

    private func updatePolling() {
        let chatVisible = hosts.values.contains { $0.foreground && $0.visible }
        if chatPollingActive != chatVisible {
            chatPollingActive = chatVisible
            store.setActive(chatVisible)
        }
    }

    private func bind() {
        guard started else { return }
        updatePolling()
        let foreground = hosts.values.contains { $0.foreground }
        let front = frontHost
        notifications?.bind(api: store.notificationAPI, device: store.notificationDevice,
            room: front?.visible == true ? store.selectedConversationId : nil, foreground: foreground)
        openPendingNotification()
    }

    func openPendingNotification() {
        guard let notifications else { return }
        if notifications.route != nil { startIfNeeded() }
        guard !routing, let route = notifications.route, frontHost != nil,
              let api = store.notificationAPI else { return }
        routing = true
        Task {
            defer {
                routing = false
                // A second click or a connection change may arrive while the
                // first route is being authorized. Process the remaining route.
                if notifications.route != nil { openPendingNotification() }
            }
            do {
                let status = try await api.notificationStatus()
                guard store.searchConnectionID == ObjectIdentifier(api),
                      notifications.route == route else { return }
                guard status.userId == route.account else { notifications.route = nil; return }
                _ = try await store.searchHistory(room: route.room, message: route.message, direction: "around")
                guard store.searchConnectionID == ObjectIdentifier(api),
                      notifications.route == route, let host = frontHost else { return }
                notifications.route = nil
                store.selectConversation(route.room)
                host.open()
            } catch {
                guard notifications.route == route, store.searchConnectionID == ObjectIdentifier(api) else { return }
                notifications.route = nil
                store.error = error.localizedDescription
            }
        }
    }
}

@MainActor
public final class LeonChatApplicationDelegate: NSObject, NSApplicationDelegate {
    public func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = ChatNotifications.shared
        LeonChatSession.shared.startIfNeeded()
    }
}

public struct LeonChatActions {
    public let openSettings: () -> Void
    public let sync: () -> Void
}

private struct LeonChatActionsKey: FocusedValueKey {
    typealias Value = LeonChatActions
}

public extension FocusedValues {
    var leonChatActions: LeonChatActions? {
        get { self[LeonChatActionsKey.self] }
        set { self[LeonChatActionsKey.self] = newValue }
    }
}

@MainActor
public struct LeonChatView: View {
    @ObservedObject private var store = LeonChatSession.shared.store

    private let library: LeonBlogExporter.Destination?

    public init(archiveRoot: String?, archiveUser: String?) {
        library = archiveRoot.flatMap { root in
            archiveUser.map { LeonBlogExporter.Destination(root: root, user: $0) }
        }
    }

    public var body: some View {
        ContentView(store: store, archiveLibrary: library)
            .frame(minWidth: 760, minHeight: 560)
            .accessibilityIdentifier("leon-chat-workspace")
    }
}

/// Lives on the window, so leaving Chat preserves drafts and notifications.
@MainActor
private struct LeonChatHost: ViewModifier {
    let isVisible: Bool
    let openChat: () -> Void
    @State private var id = UUID()
    @Environment(\.scenePhase) private var phase
    @Environment(\.controlActiveState) private var controlActiveState
    @ObservedObject private var store = LeonChatSession.shared.store
    @ObservedObject private var notifications = ChatNotifications.shared

    func body(content: Content) -> some View {
        content
            .onAppear(perform: update)
            .onChange(of: phase) { _ in update() }
            .onChange(of: controlActiveState) { _ in update() }
            .onChange(of: isVisible) { _ in update() }
            .onChange(of: store.searchConnectionID) { _ in update() }
            .onChange(of: store.selectedConversationId) { _ in update() }
            .onChange(of: notifications.route) { _ in LeonChatSession.shared.openPendingNotification() }
            .onDisappear { LeonChatSession.shared.remove(id) }
    }

    private func update() {
        LeonChatSession.shared.update(id, host: .init(foreground: phase == .active,
            key: controlActiveState == .key, visible: isVisible, open: openChat))
    }
}

@MainActor
public extension View {
    func leonChatHost(isVisible: Bool, openChat: @escaping () -> Void) -> some View {
        modifier(LeonChatHost(isVisible: isVisible, openChat: openChat))
    }
}
