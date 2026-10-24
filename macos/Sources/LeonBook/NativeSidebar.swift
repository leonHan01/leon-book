import SwiftUI

struct NativeSidebar: View {
    @Environment(\.nativeAppPalette) private var appPalette

    @ObservedObject var model: NativeAppModel
    @ObservedObject var navigation: NativeNavigationState
    @Binding var isPresentingNewUser: Bool
    @State private var expandedWorkspaceFolderIDs = Set<String>()
    @State private var selectedWorkspaceResourceIDs = Set<String>()

    var body: some View {
        VStack(spacing: 0) {
            NativeWorkspaceHeader(model: model, isPresentingNewUser: $isPresentingNewUser)

            ScrollViewReader { proxy in
                List {
                    if navigation.section == .mediaLibrary {
                        let library = model.mediaLibrary
                        NativeMediaLibrarySidebar(library: library) {
                            guard model.store === library.store else { return }
                            model.scheduleBackup()
                        }
                    } else if navigation.section.showsArticleDirectory {
                        articleSections
                    }
                }
                .listStyle(.sidebar)
                .font(.system(size: 13))
                .labelStyle(NativeSidebarLabelStyle())
                .scrollContentBackground(.hidden)
                .onAppear { revealSelectedArticle(model.selectedSlug, proxy: proxy) }
                .onChange(of: navigation.section) { _ in revealSelectedArticle(model.selectedSlug, proxy: proxy) }
                .onChange(of: model.selectedSlug) { revealSelectedArticle($0, proxy: proxy) }
                .onChange(of: model.workspaceResources) { _ in
                    let liveIDs = Set(model.workspaceResourceItems.map(\.id))
                    selectedWorkspaceResourceIDs.formIntersection(liveIDs)
                    revealSelectedArticle(model.selectedSlug, proxy: proxy)
                }
            }

            workspaceStatus
        }
        .frame(minWidth: 210)
        .symbolRenderingMode(.monochrome)
        .background(appPalette.sidebar)
    }

    @ViewBuilder
    private var articleSections: some View {
        if !model.bookmarks.isEmpty {
            Section(NativeLocalization.text("收藏")) {
                ForEach(model.bookmarks) { bookmark in
                    Button { model.openBookmark(bookmark) } label: {
                        Label(bookmark.title, nativeIcon: bookmark.target.systemImage)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SidebarNavigationButtonStyle(isSelected: false))
                    .contextMenu {
                        Button("移除收藏", role: .destructive) { model.deleteBookmark(bookmark) }
                    }
                }
            }
        }

        NativeWorkspaceResourceSection(
            model: model,
            expandedFolderIDs: $expandedWorkspaceFolderIDs,
            selectedResourceIDs: $selectedWorkspaceResourceIDs
        )
    }

    private var workspaceStatus: some View {
        HStack(spacing: 10) {
            Text(String(model.currentUser.name.prefix(1)).uppercased())
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .background(appPalette.selection, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.currentUser.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(LocalizedStringKey(model.storageReady ? "本地文件已连接" : "正在读取本地文件"))
                    .font(.system(size: 10))
                    .foregroundStyle(appPalette.textSecondary)
            }
            Spacer(minLength: 4)
            if model.isLoading || model.isSwitchingWorkspace {
                ProgressView().controlSize(.small)
            } else {
                NativeIcon.image(model.storageReady ? "checkmark.circle" : "externaldrive.badge.exclamationmark", size: 14)
                    .foregroundStyle(appPalette.textSecondary)
            }
        }
        .padding(16)
        .overlay(alignment: .top) {
            appPalette.border.frame(height: 1).padding(.horizontal, 16)
        }
    }

    private func revealSelectedArticle(_ slug: String?, proxy: ScrollViewProxy) {
        guard navigation.section.showsArticleDirectory else { return }
        guard let slug, let resourceID = model.workspaceResourceID(articleSlug: slug) else { return }
        expandedWorkspaceFolderIDs.formUnion(model.workspaceResourceAncestorIDs(resourceID: resourceID))
        selectedWorkspaceResourceIDs = [resourceID]
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(resourceID, anchor: .center)
            }
        }
    }
}

/// Workspace switching and search remain available on pages without a sidebar.
struct NativeWorkspaceHeader: View {
    @Environment(\.nativeAppPalette) private var appPalette

    @ObservedObject var model: NativeAppModel
    @Binding var isPresentingNewUser: Bool
    var showsWorkspaceStatus = false

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(model.users) { user in
                    Button { model.selectUser(user) } label: {
                        Label(user.name, nativeIcon: user.id == model.currentUser.id ? "checkmark" : "person")
                    }
                    .disabled(user.id == model.currentUser.id)
                }
                Divider()
                Button("新建用户…") { isPresentingNewUser = true }
            } label: {
                HStack(spacing: 6) {
                    Text("leon-book")
                        .font(.system(size: 17, weight: .semibold))
                    NativeIcon.image("chevron.down", size: 12)
                        .foregroundStyle(appPalette.textSecondary)
                }
                .padding(.vertical, 6)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("切换工作空间")
            .disabled(
                model.isLoading || model.isSwitchingWorkspace || model.isSaving
                    || model.isPublishingMoment || model.isPublishingQuestion
                    || model.isPublishingQuestionAnswer || model.isSavingTodo
            )

            if showsWorkspaceStatus {
                Text(model.currentUser.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(appPalette.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if showsWorkspaceStatus {
                if model.isLoading || model.isSwitchingWorkspace {
                    ProgressView().controlSize(.small)
                } else {
                    Label(
                        LocalizedStringKey(model.storageReady ? "本地文件已连接" : "正在读取本地文件"),
                        nativeIcon: model.storageReady ? "checkmark.circle" : "externaldrive.badge.exclamationmark", iconSize: 12
                    )
                    .font(.caption)
                    .foregroundStyle(appPalette.textSecondary)
                }
            }

            Button { model.executeCommand(.globalSearch) } label: {
                NativeIcon.image("magnifyingglass", size: 14)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(NativeChromeIconButtonStyle())
            .help("搜索")
            .accessibilityLabel("搜索")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

private struct NativeSidebarLabelStyle: LabelStyle {
    @Environment(\.nativeAppPalette) private var appPalette

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(appPalette.textSecondary)
                .frame(width: 16)
            configuration.title
        }
    }
}
