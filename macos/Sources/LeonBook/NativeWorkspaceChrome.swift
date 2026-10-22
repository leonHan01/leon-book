import SwiftUI

/// Global destinations stay available when the article sidebar is collapsed.
struct NativeWorkspaceRail: View {
    @ObservedObject var model: NativeAppModel
    @ObservedObject var navigation: NativeNavigationState

    var body: some View {
        VStack(spacing: 10) {
            destination(.dashboard, title: "概览", icon: "house", selectedIcon: "house.fill")
            destination(.articles, title: "全部文章", icon: "doc.on.doc")
            destination(.moments, title: "微博", icon: "bubble.left.and.bubble.right")
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
        .background(NativeTheme.rail)
        .overlay(alignment: .trailing) {
            NativeTheme.border.frame(width: 1).allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("主导航")
    }

    private func destination(
        _ section: NativeSection,
        title: String,
        icon: String,
        selectedIcon: String? = nil
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
            Image(systemName: isSelected ? (selectedIcon ?? icon) : icon)
                .font(.system(size: 17, weight: .regular))
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
    let configuration: ButtonStyle.Configuration
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(isSelected || isHovered ? NativeTheme.textPrimary : NativeTheme.textSecondary)
            .background(
                isSelected || isHovered || configuration.isPressed ? NativeTheme.selection : .clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.65 : 1)
            .onHover { isHovered = $0 }
    }
}

struct NativeWorkspaceTitle: View {
    @ObservedObject var model: NativeAppModel
    @ObservedObject var navigation: NativeNavigationState

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "folder")
                .foregroundStyle(NativeTheme.textSecondary)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(NativeTheme.textPrimary)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch navigation.section {
        case .dashboard: NativeLocalization.string("概览")
        case .articles: model.articleListTitle
        case .reader: model.selectedArticle?.title ?? NativeLocalization.string("全部文章")
        case .editor: NativeLocalization.string("写作")
        case .graph: NativeLocalization.string("关系图")
        case .moments: NativeLocalization.string("微博")
        case .qAndA: NativeLocalization.string("问答")
        case .todos: NativeLocalization.string("待办")
        case .trash: NativeLocalization.string("回收站")
        case .settings: NativeLocalization.string("设置")
        }
    }
}
