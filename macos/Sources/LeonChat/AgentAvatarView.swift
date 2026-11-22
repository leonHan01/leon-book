import SwiftUI
import AppKit

@MainActor
final class AvatarImage: ObservableObject {
    @Published var image: NSImage?
}

struct AgentAvatarView: View {
    @ObservedObject var store: ChatStore
    let avatarId: String
    var size: CGFloat = 36
    @StateObject private var loaded = AvatarImage()
    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let image = loaded.image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit().padding(2)
            } else {
                Image(systemName: "person.crop.square").font(.system(size: size * 0.5)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.23))
        .accessibilityLabel("Agent 头像")
        .task(id: store.avatarSessionKey + ":" + avatarId + (store.hasConnection ? ":configured" : ":unconfigured")) {
            loaded.image = nil
            guard store.hasConnection else { return }
            let data = await store.avatarData(avatarId)
            guard !Task.isCancelled else { return }
            loaded.image = data.flatMap(NSImage.init(data:))
        }
    }
}
