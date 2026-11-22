import SwiftUI

struct SidebarFooter: View {
    let hasConnection: Bool
    let openFavorites: () -> Void
    let openUsage: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Divider()
            HStack(spacing: 4) {
                SidebarFooterButton(title: "收藏", symbol: "star", help: "查看收藏", action: openFavorites)
                    .disabled(!hasConnection)
                SidebarFooterButton(title: "用量", symbol: "chart.bar", help: "查看 Token 用量", action: openUsage)
                    .disabled(!hasConnection)
                SidebarFooterButton(title: "设置", symbol: "gearshape", help: "连接与通知设置", action: openSettings)
            }
        }
        .padding(.bottom, 12)
    }
}

private struct SidebarFooterButton: View {
    let title: String
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 15))
                Text(title).font(.system(size: 11))
            }
            .foregroundStyle(isEnabled ? Color.primary.opacity(0.8) : Color.secondary.opacity(0.5))
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(hovering && isEnabled ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
