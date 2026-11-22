import SwiftUI

/// One connection and outbox across LeonBook windows and navigation changes.
@MainActor
final class LeonChatSession {
    static let shared = LeonChatSession()
    let store = ChatStore()
    private(set) var started = false
    private var routing = false
    private var appActive: Bool?
    private var lastKeyHostID: UUID?

    struct Host {
        let foreground: Bool
        let key: Bool
        let visible: Bool
        let root: String?
        let user: String?
        let open: () -> Void
    }
    private var hosts: [UUID: Host] = [:]

    private init() { store.requiresHostArchiveDestination = true }

    func update(_ id: UUID, host: Host) {
        hosts[id] = host
        if host.key && host.foreground { lastKeyHostID = id }
        if host.visible && !started {
            started = true
            Task { await store.start() }
        }
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

    private func bind() {
        guard started else { return }
        let foreground = hosts.values.contains { $0.foreground }
        if appActive != foreground {
            appActive = foreground
            store.setActive(foreground)
        }
        let front = frontHost
        // A window captures the destination before archive creation. Existing
        // unfinished archives retain their original root/user for safe retries.
        store.setArchiveDestination(root: front?.root, user: front?.user)
        ChatNotifications.shared.bind(api: store.notificationAPI, device: store.notificationDevice,
            room: front?.visible == true ? store.selectedConversationId : nil, foreground: foreground)
        openPendingNotification()
    }

    func openPendingNotification() {
        let notifications = ChatNotifications.shared
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
                guard notifications.route == route else { return }
                notifications.route = nil
                store.error = error.localizedDescription
            }
        }
    }
}

@MainActor
public struct LeonChatView: View {
    @ObservedObject private var store = LeonChatSession.shared.store

    public init() {}

    public var body: some View {
        ContentView(store: store)
            .frame(minWidth: 760, minHeight: 560)
            .accessibilityIdentifier("leon-chat-workspace")
    }
}

/// Lives on the window, so leaving Chat preserves drafts and notifications.
@MainActor
private struct LeonChatHost: ViewModifier {
    let isVisible: Bool
    let archiveRoot: String?
    let archiveUser: String?
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
            .onChange(of: archiveRoot) { _ in update() }
            .onChange(of: archiveUser) { _ in update() }
            .onChange(of: store.searchConnectionID) { _ in update() }
            .onChange(of: store.selectedConversationId) { _ in update() }
            .onChange(of: notifications.route) { _ in LeonChatSession.shared.openPendingNotification() }
            .onDisappear { LeonChatSession.shared.remove(id) }
    }

    private func update() {
        LeonChatSession.shared.update(id, host: .init(foreground: phase == .active,
            key: controlActiveState == .key, visible: isVisible, root: archiveRoot,
            user: archiveUser, open: openChat))
    }
}

@MainActor
public extension View {
    func leonChatHost(isVisible: Bool, archiveRoot: String?, archiveUser: String?,
                      openChat: @escaping () -> Void) -> some View {
        modifier(LeonChatHost(isVisible: isVisible, archiveRoot: archiveRoot,
            archiveUser: archiveUser, openChat: openChat))
    }
}
