import SwiftUI

struct NativeSidebar: View {
    @ObservedObject var model: NativeAppModel
    @ObservedObject var navigation: NativeNavigationState
    @Binding var isPresentingNewUser: Bool
    @State private var smartCollectionEditorRequest: SmartCollectionEditorRequest?
    @State private var expandedWorkspaceFolderIDs = Set<String>()
    @State private var selectedWorkspaceResourceIDs = Set<String>()

    var body: some View {
        VStack(spacing: 0) {
            header
            quickActions

            ScrollViewReader { proxy in
                List {
                    if !model.bookmarks.isEmpty {
                        Section("收藏") {
                            ForEach(model.bookmarks) { bookmark in
                                Button { model.openBookmark(bookmark) } label: {
                                    Label(bookmark.title, systemImage: bookmark.target.systemImage)
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

                    Section("智能集合") {
                        ForEach(model.smartCollections) { collection in
                            Button { model.showSmartCollection(collection) } label: {
                                Label(collection.name, systemImage: "rectangle.stack")
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(SidebarNavigationButtonStyle(
                                isSelected: navigation.section == .articles
                                    && model.selectedSmartCollectionID == collection.id
                            ))
                            .contextMenu {
                                Button("编辑") {
                                    smartCollectionEditorRequest = SmartCollectionEditorRequest(collection: collection)
                                }
                                Button("删除", role: .destructive) {
                                    Task { await model.deleteSmartCollection(collection) }
                                }
                            }
                        }
                        Button {
                            smartCollectionEditorRequest = SmartCollectionEditorRequest(collection: nil)
                        } label: {
                            Label("新建智能集合…", systemImage: "plus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(SidebarNavigationButtonStyle(isSelected: false))
                    }
                }
                .listStyle(.sidebar)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .onAppear { revealSelectedArticle(model.selectedSlug, proxy: proxy) }
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
        .background(NativeTheme.sidebar)
        .sheet(item: $smartCollectionEditorRequest) { request in
            SmartCollectionEditorSheet(model: model, collection: request.collection)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(model.users) { user in
                    Button { model.selectUser(user) } label: {
                        Label(user.name, systemImage: user.id == model.currentUser.id ? "checkmark" : "person")
                    }
                    .disabled(user.id == model.currentUser.id)
                }
                Divider()
                Button("新建用户…") { isPresentingNewUser = true }
            } label: {
                HStack(spacing: 6) {
                    Text("leon-book")
                        .font(.system(size: 17, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(NativeTheme.textSecondary)
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

            Spacer(minLength: 0)

            Button { model.executeCommand(.globalSearch) } label: {
                Image(systemName: "magnifyingglass").frame(width: 28, height: 28)
            }
            .buttonStyle(NativeChromeIconButtonStyle())
            .help("搜索")
            .accessibilityLabel("搜索")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var quickActions: some View {
        VStack(spacing: 3) {
            Button { model.executeCommand(.canvas) } label: {
                Label("无限画布", systemImage: "rectangle.3.group")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(SidebarNavigationButtonStyle(isSelected: navigation.section == .canvas))

            Button { model.executeCommand(.newArticle) } label: {
                Label("新文章", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(SidebarNavigationButtonStyle(isSelected: navigation.section == .editor))

            Button { model.executeCommand(.quickOpen) } label: {
                Label("快速打开", systemImage: "doc.text.magnifyingglass")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(SidebarNavigationButtonStyle(isSelected: false))
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var workspaceStatus: some View {
        HStack(spacing: 10) {
            Text(String(model.currentUser.name.prefix(1)).uppercased())
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .background(NativeTheme.selection, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.currentUser.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(LocalizedStringKey(model.storageReady ? "本地文件已连接" : "正在读取本地文件"))
                    .font(.system(size: 10))
                    .foregroundStyle(NativeTheme.textSecondary)
            }
            Spacer(minLength: 4)
            if model.isLoading || model.isSwitchingWorkspace {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: model.storageReady ? "checkmark.circle" : "externaldrive.badge.exclamationmark")
                    .foregroundStyle(NativeTheme.textSecondary)
                    .font(.system(size: 13))
            }
        }
        .padding(16)
        .overlay(alignment: .top) {
            NativeTheme.border.frame(height: 1).padding(.horizontal, 16)
        }
    }

    private func revealSelectedArticle(_ slug: String?, proxy: ScrollViewProxy) {
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
