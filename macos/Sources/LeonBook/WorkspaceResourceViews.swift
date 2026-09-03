import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NativeWorkspaceResourceSection: View {
    @ObservedObject var model: NativeAppModel
    @Binding var expandedFolderIDs: Set<String>
    @Binding var selectedResourceIDs: Set<String>

    var body: some View {
        Section {
            rootRow
            if model.workspaceResources.isEmpty {
                Text("还没有页面。可在根目录新建页面或文件夹。")
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
                Text("页面")
                Spacer(minLength: 4)
                Button {
                    model.newArticle(inFolder: "")
                } label: {
                    Image(systemName: "note.text.badge.plus")
                }
                .buttonStyle(.plain)
                .help("在根目录新建页面")
                .disabled(model.isMarkdownSourceReadOnly)

                Button {
                    model.promptToCreateWorkspaceFolder(parentPath: "")
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .help("在根目录新建文件夹")
                .disabled(model.isMarkdownSourceReadOnly)

                if !expandedFolderIDs.isEmpty {
                    Button {
                        expandedFolderIDs.removeAll()
                    } label: {
                        Image(systemName: "rectangle.compress.vertical")
                    }
                    .buttonStyle(.plain)
                    .help("折叠全部")
                }
            }
        }
    }

    private var rootRow: some View {
        Button {
            selectedResourceIDs.removeAll()
            model.showAllArticles()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "externaldrive.fill")
                    .foregroundStyle(.secondary)
                Text("全部页面")
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(model.articles.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarNavigationButtonStyle(
            isSelected: model.section == .articles
                && model.selectedSmartCollectionID == nil
                && model.selectedArticleFolderPath == nil
                && selectedResourceIDs.isEmpty
        ))
        .contextMenu {
            Button("新建页面") { model.newArticle(inFolder: "") }
                .disabled(model.isMarkdownSourceReadOnly)
            Button("新建文件夹…") { model.promptToCreateWorkspaceFolder(parentPath: "") }
                .disabled(model.isMarkdownSourceReadOnly)
        }
        .onDrop(of: [UTType.utf8PlainText.identifier], isTargeted: nil) { providers in
            acceptResourceDrop(providers, destinationFolder: "")
        }
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
}

private struct NativeWorkspaceResourceBranch: View {
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
                    Image(systemName: resource.children.isEmpty ? resource.systemImage : "doc.on.doc.fill")
                        .foregroundStyle(iconColor(resource))
                        .frame(width: 16)
                    Text(resource.articleTitle ?? resource.name)
                        .lineLimit(1)
                        .help(resource.relativePath)
                    Spacer(minLength: 4)
                    if resource.storage == .managedMedia {
                        Image(systemName: "link")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help("由 LeonBook 管理的文章附件")
                    } else if resource.canContainPages && resource.articleCount > 1 {
                        Text("\(resource.articleCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(rowBackground(resource), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)

            if hoveredResourceID == resource.id && resource.canContainPages {
                Button {
                    model.newArticle(inFolder: resource.pageContainerPath)
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("新建子页面")
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
            Button(LocalizedStringKey(resource.kind == .article ? "新建子页面" : "新建页面")) {
                model.newArticle(inFolder: resource.pageContainerPath)
            }
            .disabled(model.isMarkdownSourceReadOnly)
            Button("新建文件夹…") {
                model.promptToCreateWorkspaceFolder(parentPath: resource.pageContainerPath)
            }
            .disabled(model.isMarkdownSourceReadOnly)
            Divider()
            if resource.kind == .article {
                Button("打开") { select(resource, ignoresModifiers: true) }
                Divider()
            }
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
            return Color.accentColor.opacity(0.16)
        }
        if resource.articleSlug == model.selectedSlug {
            return Color.accentColor.opacity(0.08)
        }
        return .clear
    }

    private func iconColor(_ resource: NativeWorkspaceResourceNode) -> Color {
        switch resource.kind {
        case .folder:
            return .accentColor
        case .article:
            return resource.articleSlug == model.selectedSlug ? .accentColor : .primary
        case .attachment:
            return .secondary
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
