import SwiftUI

struct NativeMediaLibrarySidebar: View {
    @ObservedObject var library: NativeMediaLibraryModel
    let onChange: () -> Void

    var body: some View {
        Section {
            row("全部影音", icon: "play.rectangle.on.rectangle", scope: .all, localized: true)
            row("默认分组", icon: "tray", scope: .defaultGroup, localized: true)
            ForEach(library.groups) { group in
                row(group.name, icon: "folder", scope: .group(group.id))
                    .contextMenu {
                        Button("重命名影音分组") { library.editGroup(group, onChange: onChange) }
                        Button("删除影音分组", role: .destructive) {
                            library.confirmDeleteGroup(group, onChange: onChange)
                        }
                    }
            }
            Button { library.editGroup(onChange: onChange) } label: {
                Label("新建影音分组", nativeIcon: "folder.badge.plus")
            }
            .buttonStyle(SidebarNavigationButtonStyle(isSelected: false))
            .disabled(library.isBusy)
        } header: {
            Text("影音目录")
        }
    }

    private func row(
        _ title: String, icon: String, scope: NativeMediaLibraryScope, localized: Bool = false
    ) -> some View {
        Button { library.scope = scope } label: {
            HStack {
                Label {
                    if localized { Text(LocalizedStringKey(title)) }
                    else { Text(title) }
                } icon: { NativeIcon.image(icon) }
                .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(library.items.filter { scope.contains($0) }.count)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarNavigationButtonStyle(isSelected: library.scope == scope))
        .accessibilityAddTraits(library.scope == scope ? .isSelected : [])
    }
}
