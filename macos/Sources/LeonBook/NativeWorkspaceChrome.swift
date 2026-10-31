import SwiftUI

/// Rounds the workspace's junction with the title bar and navigation rail.
struct NativeWorkspaceSurfaceShape: Shape {
    static let cornerRadius: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        let radius = min(Self.cornerRadius, min(rect.width, rect.height) / 2)
        return Path { path in
            path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + radius, y: rect.minY),
                control: CGPoint(x: rect.minX, y: rect.minY)
            )
            path.closeSubpath()
        }
    }
}

/// Global destinations stay available when the article sidebar is collapsed.
struct NativeWorkspaceRail: View {
    /// Space for the compact title bar, including when its toolbar is absent.
    static let titlebarClearance: CGFloat = 38

    @Environment(\.nativeAppPalette) private var appPalette

    @ObservedObject var model: NativeAppModel
    @ObservedObject var navigation: NativeNavigationState

    var body: some View {
        VStack(spacing: 10) {
            destination(.dashboard, title: "概览", icon: "house")
            destination(.moments, title: "微博", icon: "quote.bubble")
            destination(.articles, title: "全部文章", icon: "doc")
            destination(.canvas, title: "无限画布", icon: "square.dashed")
            destination(.photos, title: "相册", icon: "photo.on.rectangle")
            destination(.mediaLibrary, title: "影音库", icon: "play.rectangle")
            destination(.qAndA, title: "问答", icon: "questionmark.bubble")
            if model.isTodoModuleEnabled {
                destination(.todos, title: "待办", icon: "checklist")
            }

            if model.isKnowledgeGraphModuleEnabled {
                Divider().padding(.horizontal, 15).padding(.vertical, 4)
                destination(.graph, title: "关系图", icon: "point.3.connected.trianglepath.dotted")
            }

            Spacer(minLength: 24)

            destination(.trash, title: "回收站", icon: "trash")
            destination(.settings, title: "设置", icon: "gearshape")
        }
        .padding(.vertical, 14)
        .frame(width: 52)
        .background(appPalette.rail)
        .overlay(alignment: .trailing) {
            appPalette.border
                .frame(width: 1)
                .padding(.top, NativeWorkspaceSurfaceShape.cornerRadius)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("主导航")
    }

    private func destination(
        _ section: NativeSection,
        title: String,
        icon: String
    ) -> some View {
        let isSelected = navigation.section == section
            || (section == .articles && (navigation.section == .reader || navigation.section == .editor))
        return Button {
            switch section {
            case .articles: model.showAllArticles()
            case .todos: model.openTodos()
            default: model.section = section
            }
        } label: {
            NativeIcon.image(icon, size: NativeIcon.Size.toolbar)
                .symbolRenderingMode(.monochrome)
                .frame(width: 36, height: 36)
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(NativeChromeIconButtonStyle(isSelected: isSelected))
        .help(Text(LocalizedStringKey(title)))
        .accessibilityLabel(Text(LocalizedStringKey(title)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct NativeChromeIconButtonStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        NativeChromeIconButton(configuration: configuration, isSelected: isSelected)
    }
}

private struct NativeChromeIconButton: View {
    @Environment(\.nativeAppPalette) private var appPalette

    let configuration: ButtonStyle.Configuration
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(isSelected ? appPalette.accent : isHovered ? appPalette.textPrimary : appPalette.textSecondary)
            .background(
                isSelected ? appPalette.lightBlue : isHovered || configuration.isPressed ? appPalette.selection : .clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.65 : 1)
            .onHover { isHovered = isEnabled && $0 }
    }
}
