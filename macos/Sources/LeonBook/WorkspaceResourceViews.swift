import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NativeWorkspaceResourceSection: View {
    @Environment(\.nativeAppPalette) private var appPalette

    @ObservedObject var model: NativeAppModel
    @Binding var expandedFolderIDs: Set<String>
    @Binding var selectedResourceIDs: Set<String>

    var body: some View {
        Section {
            if model.workspaceResources.isEmpty {
                Text("还没有文章。请新建目录，或在“未分类”目录中开始写作。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                NativeWorkspaceResourceBranch(
                    model: model,
                    resources: model.workspaceResources,
                    expandedFolderIDs: $expandedFolderIDs,
                    selectedResourceIDs: $selectedResourceIDs
                )
            }
        } header: {
            HStack(spacing: 8) {
                Text("文章目录")
                Spacer(minLength: 4)
                Button {
                    model.newArticle(inFolder: "")
                } label: {
                    NativeIcon.image("plus", size: 12)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .foregroundStyle(appPalette.textSecondary)
                .accessibilityLabel("新文章")
                .help("在“未分类”目录新建文章")
                .disabled(model.isMarkdownSourceReadOnly)

                Button {
                    model.promptToCreateWorkspaceFolder(parentPath: "")
                } label: {
                    NativeIcon.image("folder", size: 12)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .foregroundStyle(appPalette.textSecondary)
                .accessibilityLabel("新建文件夹…")
                .help("在根目录新建文件夹")
                .disabled(model.isMarkdownSourceReadOnly)

                if !expandedFolderIDs.isEmpty {
                    Button {
                        expandedFolderIDs.removeAll()
                    } label: {
                        NativeIcon.image("chevron.up", size: 12)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(appPalette.textSecondary)
                    .accessibilityLabel("折叠全部")
                    .help("折叠全部")
                }
            }
        }
    }

}

private struct NativeWorkspaceResourceBranch: View {
    @Environment(\.nativeAppPalette) private var appPalette

    @ObservedObject var model: NativeAppModel
    let resources: [NativeWorkspaceResourceNode]
    @Binding var expandedFolderIDs: Set<String>
    @Binding var selectedResourceIDs: Set<String>
    @State private var hoveredResourceID: String?

    var body: some View {
        ForEach(resources) { resource in
            if resource.canContainPages && !resource.children.isEmpty {
                DisclosureGroup(
                    isExpanded: expansionBinding(for: resource.id),
                    content: {
                        NativeWorkspaceResourceBranch(
                            model: model,
                            resources: resource.children,
                            expandedFolderIDs: $expandedFolderIDs,
                            selectedResourceIDs: $selectedResourceIDs
                        )
                    },
                    label: {
                        resourceRow(resource)
                    }
                )
                .id(resource.id)
                .onDrop(of: [UTType.utf8PlainText.identifier], isTargeted: nil) { providers in
                    acceptResourceDrop(providers, destinationFolder: resource.pageContainerPath)
                }
            } else {
                resourceRow(resource)
                    .id(resource.id)
                    .onDrop(of: [UTType.utf8PlainText.identifier], isTargeted: nil) { providers in
                        guard resource.canContainPages else { return false }
                        return acceptResourceDrop(providers, destinationFolder: resource.pageContainerPath)
                    }
            }
        }
    }

    private func resourceRow(_ resource: NativeWorkspaceResourceNode) -> some View {
        HStack(spacing: 3) {
            Button {
                select(resource)
            } label: {
                HStack(spacing: 7) {
                    NativeIcon.image(sidebarIcon(for: resource), size: 14)
                        .foregroundStyle(iconColor(resource))
                        .frame(width: 16)
                    Text(resource.articleTitle ?? resource.name)
                        .lineLimit(1)
                        .help(resource.relativePath)
                    Spacer(minLength: 4)
                    if resource.storage == .managedMedia {
                        NativeIcon.image("link", size: 12)
                            .foregroundStyle(.tertiary)
                            .help("由 LeonBook 管理的文章附件")
                    } else if resource.canContainPages && resource.articleCount > 1 {
                        Text("\(resource.articleCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(rowBackground(resource), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)

            if hoveredResourceID == resource.id && resource.canContainPages {
                Button {
                    model.newArticle(inFolder: resource.pageContainerPath)
                } label: {
                    NativeIcon.image("plus", size: 12)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("在此目录新建文章")
                .disabled(model.isMarkdownSourceReadOnly)
            }
        }
        .onHover { hovering in
            if hovering { hoveredResourceID = resource.id }
            else if hoveredResourceID == resource.id { hoveredResourceID = nil }
        }
        .contextMenu { resourceContextMenu(resource) }
        .onDrag {
            let ids = selectedResourceIDs.contains(resource.id)
                ? Array(selectedResourceIDs)
                : [resource.id]
            return NSItemProvider(
                object: NativeWorkspaceResourceDragPayload.encode(ids) as NSString
            )
        }
    }

    @ViewBuilder
    private func resourceContextMenu(_ resource: NativeWorkspaceResourceNode) -> some View {
        let resources = contextualResources(for: resource)

        if resource.canContainPages {
            Button("新建文章") {
                model.newArticle(inFolder: resource.pageContainerPath)
            }
            .disabled(model.isMarkdownSourceReadOnly)
            Button("新建文件夹…") {
                model.promptToCreateWorkspaceFolder(parentPath: resource.pageContainerPath)
            }
            .disabled(model.isMarkdownSourceReadOnly
                || NativeArticleDirectoryPolicy.depth(of: resource.pageContainerPath) >= NativeArticleDirectoryPolicy.maximumDepth)
            Divider()
        } else if resource.kind == .article {
            Button("打开") { select(resource, ignoresModifiers: true) }
            Divider()
        } else {
            Button("打开附件") { model.openWorkspaceAttachment(resource) }
            Divider()
        }

        if resources.count == 1, resource.canMutateSource {
            Button("重命名…") { model.promptToRenameWorkspaceResource(resource) }
        }
        if resources.contains(where: { $0.canMutateSource }) {
            Button(LocalizedStringKey(resources.count > 1 ? "移动所选项目…" : "移动…")) {
                model.promptToMoveWorkspaceResources(resources)
            }
        }
        Button("在 Finder 中显示") { model.revealWorkspaceResourceInFinder(resource) }
            .disabled(resource.absolutePath.isEmpty)
        if resources.contains(where: { $0.canMutateSource }) {
            Divider()
            Button(LocalizedStringKey(resources.count > 1 ? "将所选项目移到废纸篓" : "移到废纸篓"), role: .destructive) {
                model.promptToTrashWorkspaceResources(resources)
            }
        }
    }

    private func select(
        _ resource: NativeWorkspaceResourceNode,
        ignoresModifiers: Bool = false
    ) {
        let modifiers = ignoresModifiers
            ? []
            : NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            if selectedResourceIDs.contains(resource.id) {
                selectedResourceIDs.remove(resource.id)
            } else {
                selectedResourceIDs.insert(resource.id)
            }
            return
        }

        selectedResourceIDs = [resource.id]
        switch resource.kind {
        case .folder:
            if expandedFolderIDs.contains(resource.id) {
                expandedFolderIDs.remove(resource.id)
            } else {
                expandedFolderIDs.insert(resource.id)
            }
            model.showArticleFolder(resource.pageContainerPath)
        case .article:
            if let slug = resource.articleSlug { model.selectSlug(slug) }
        case .attachment:
            model.openWorkspaceAttachment(resource)
        }
    }

    private func contextualResources(
        for resource: NativeWorkspaceResourceNode
    ) -> [NativeWorkspaceResourceNode] {
        guard selectedResourceIDs.contains(resource.id), selectedResourceIDs.count > 1 else {
            return [resource]
        }
        return model.workspaceResources(ids: selectedResourceIDs)
    }

    private func expansionBinding(for resourceID: String) -> Binding<Bool> {
        Binding(
            get: { expandedFolderIDs.contains(resourceID) },
            set: { isExpanded in
                if isExpanded {
                    expandedFolderIDs.insert(resourceID)
                } else {
                    expandedFolderIDs.remove(resourceID)
                }
            }
        )
    }

    private func acceptResourceDrop(
        _ providers: [NSItemProvider],
        destinationFolder: String
    ) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier)
        }) else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let payload = object as? String,
                  let ids = NativeWorkspaceResourceDragPayload.decode(payload) else { return }
            DispatchQueue.main.async {
                let resources = model.workspaceResources(ids: Set(ids))
                model.moveWorkspaceResources(resources, toFolder: destinationFolder)
            }
        }
        return true
    }

    private func rowBackground(_ resource: NativeWorkspaceResourceNode) -> Color {
        if selectedResourceIDs.contains(resource.id) {
            return appPalette.selection
        }
        if resource.articleSlug == model.selectedSlug {
            return appPalette.selection
        }
        return hoveredResourceID == resource.id ? appPalette.surfaceSecondary : .clear
    }

    private func iconColor(_ resource: NativeWorkspaceResourceNode) -> Color {
        switch resource.kind {
        case .folder:
            return appPalette.textSecondary
        case .article:
            return resource.articleSlug == model.selectedSlug ? appPalette.deepBlue : appPalette.textPrimary
        case .attachment:
            return .secondary
        }
    }

    private func sidebarIcon(for resource: NativeWorkspaceResourceNode) -> String {
        switch resource.kind {
        case .folder: return "folder"
        case .article: return "doc"
        case .attachment: return resource.systemImage
        }
    }
}

private enum NativeWorkspaceResourceDragPayload {
    private static let prefix = "leonbook-workspace-resource:"

    static func encode(_ ids: [String]) -> String {
        guard let data = try? JSONEncoder().encode(ids) else { return prefix }
        return prefix + data.base64EncodedString()
    }

    static func decode(_ payload: String) -> [String]? {
        guard payload.hasPrefix(prefix),
              let data = Data(base64Encoded: String(payload.dropFirst(prefix.count))) else {
            return nil
        }
        return try? JSONDecoder().decode([String].self, from: data)
    }
}
