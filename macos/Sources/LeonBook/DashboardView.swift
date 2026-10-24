import SwiftUI

struct DashboardView: View {
    @Environment(\.nativeAppPalette) private var appPalette

    @ObservedObject var model: NativeAppModel
    @ObservedObject private var editing: NativeDashboardEditingState
    @StateObject private var dragPreviews: NativeDashboardDragPreviewRegistry
    @State private var showsModulePicker = false
    @State private var selectedModule: NativeDashboardModule?
    @State private var activeDrag: NativeDashboardModuleDrag?
    @State private var dropTargetID: UUID?
    @State private var resizeSession: NativeDashboardResizeSession?

    init(model: NativeAppModel, dragPreviews: NativeDashboardDragPreviewRegistry? = nil) {
        self.model = model
        _editing = ObservedObject(wrappedValue: model.dashboardEditing)
        _dragPreviews = StateObject(wrappedValue: dragPreviews ?? NativeDashboardDragPreviewRegistry())
    }

    private var document: NativeDashboardDocument { editing.draft ?? model.dashboard }
    private var isEditing: Bool { editing.draft != nil }

    var body: some View {
        GeometryReader { geometry in
            let horizontalPadding: CGFloat = geometry.size.width < 820 ? 28 : 44
            let gridWidth = min(1_080, max(1, geometry.size.width - horizontalPadding * 2))
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    if let error = model.dashboardLoadError {
                        Label(error, nativeIcon: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                        Button("重新加载首页") { Task { await model.reloadDashboard() } }
                    } else if !model.isDashboardLoaded {
                        ProgressView("正在加载首页…").frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        if isEditing {
                            Label("拖动标题栏排序，拖动边缘调整宽高；宽度按列、高度按 24 点对齐。", nativeIcon: "hand.draw", iconSize: 14)
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        moduleGrid(width: gridWidth)
                        if document.modules.isEmpty {
                            VStack(spacing: 14) {
                                NativeIcon.image("square.grid.2x2", size: 32)
                                Text("把首页布置成你喜欢的样子").font(.headline)
                                Text("从文字、图片、音乐或一份待办清单开始。")
                                    .foregroundStyle(.secondary)
                                Button("添加第一个模块") { beginAdding() }
                                    .nativePrimaryButton().disabled(!model.canEditDashboard)
                            }
                            .frame(maxWidth: .infinity, minHeight: 280)
                        }
                    }
                }
                .disabled(model.isSavingDashboard)
                .frame(maxWidth: 1_080, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .background(appPalette.canvas)
        .sheet(isPresented: $showsModulePicker) {
            DashboardModulePicker { kind in
                editing.draft?.modules.append(NativeDashboardModule(kind: kind))
                showsModulePicker = false
            }
        }
        .sheet(item: $selectedModule) { module in
            DashboardModuleEditor(model: model, module: module) { editing.update($0) }
        }
        .task(id: model.storageReady) { await model.reloadDashboard() }
        .onChange(of: activeDrag?.sessionID) { sessionID in
            if sessionID == nil { dragPreviews.clear() }
        }
        .onChange(of: isEditing) { _ in clearDrag() }
        .onChange(of: model.canEditDashboard) { canEdit in if !canEdit { clearDrag() } }
        .onDisappear { clearDrag() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Label("概览", nativeIcon: "house", iconSize: 12)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if isEditing {
                    Button("取消") {
                        editing.draft = nil
                        Task { await model.reloadDashboard() }
                    }
                    .disabled(model.isSavingDashboard)
                    Button {
                        guard let draft = editing.draft else { return }
                        Task { if await model.saveDashboard(draft) { editing.draft = nil } }
                    } label: {
                        Label(model.isSavingDashboard ? "正在保存…" : "保存首页", nativeIcon: "checkmark")
                    }
                    .nativePrimaryButton().disabled(!model.canEditDashboard)
                } else {
                    Button {
                        editing.draft = model.dashboard
                    } label: { Label("编辑首页", nativeIcon: "slider.horizontal.3") }
                    .disabled(!model.canEditDashboard)
                }
                Button { beginAdding() } label: { Label("添加模块", nativeIcon: "plus") }
                    .disabled(!model.canEditDashboard || document.modules.count >= 100)
            }
            if isEditing {
                TextField("你的本地写作空间", text: Binding(
                    get: { editing.draft?.title ?? "" },
                    set: { editing.draft?.title = $0 }
                ))
                .font(.system(size: 28, weight: .semibold)).textFieldStyle(.plain)
                TextField("添加一句首页介绍…", text: Binding(
                    get: { editing.draft?.subtitle ?? "" },
                    set: { editing.draft?.subtitle = $0 }
                ))
                .font(.callout).textFieldStyle(.plain).foregroundStyle(.secondary)
            } else {
                Text(document.title.isEmpty ? NativeLocalization.string("你的本地写作空间", language: NativeLocalization.currentLanguage) : document.title)
                    .font(.system(size: 28, weight: .semibold))
                if !document.subtitle.isEmpty {
                    Text(document.subtitle).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    private func moduleGrid(width: CGFloat) -> some View {
        let metrics = NativeDashboardGridMetrics(width: width)
        return NativeDashboardGridLayout {
            ForEach(document.modules) { module in
                moduleCard(module, metrics: metrics)
                    .layoutValue(key: NativeDashboardColumnSpanKey.self, value: module.preferredColumnSpan)
                    .layoutValue(key: NativeDashboardHeightRowsKey.self, value: module.heightRows)
            }
        }
        .background { if resizeSession != nil { NativeDashboardGridGuides() } }
    }

    private func moduleCard(_ module: NativeDashboardModule, metrics: NativeDashboardGridMetrics) -> some View {
        let width = metrics.cardWidth(columns: module.preferredColumnSpan)
        let height = module.heightRows.map { CGFloat($0) * NativeDashboardGridMetrics.rowHeight }
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                if isEditing {
                    moduleHeading(module)
                        .contentShape(Rectangle())
                        .help("拖动标题栏调整模块顺序")
                        .accessibilityIdentifier("dashboard-drag-\(module.id)")
                        .onDrag {
                            resizeSession = nil
                            dragPreviews.prepare(for: module.id)
                            let drag = NativeDashboardModuleDrag(moduleID: module.id)
                            activeDrag = drag
                            dropTargetID = nil
                            return drag.itemProvider()
                        } preview: {
                            NativeDashboardModuleDragPreview(
                                module: module, previews: dragPreviews
                            )
                        }
                } else {
                    moduleHeading(module)
                }
                if isEditing { moduleControls(module, compact: width < 400) }
            }
            .frame(height: 36)
            if let height {
                ScrollView {
                    moduleContent(module, width: width, contentHeight: max(1, height - (isEditing ? 108 : 92)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                moduleContent(module, width: width, contentHeight: nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, isEditing ? 36 : 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(height: height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .background(appPalette.surface, in: RoundedRectangle(cornerRadius: 16))
        .background {
            NativeDashboardDragPreviewAnchor(moduleID: module.id, registry: dragPreviews)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(dropTargetID == module.id || resizeSession?.original.id == module.id ? appPalette.accent :
                                (isEditing ? appPalette.accent.opacity(0.35) : appPalette.border),
                              lineWidth: dropTargetID == module.id || resizeSession?.original.id == module.id ? 2 : 1)
                .allowsHitTesting(false)
        }
        .overlay {
            if isEditing && model.canEditDashboard {
                NativeDashboardResizeHandles(moduleID: module.id, canResizeWidth: metrics.minimumColumns < NativeDashboardGridMetrics.columns,
                    onBegin: { axis, size in
                        guard model.canEditDashboard, isEditing else { return false }
                        clearDrag()
                        resizeSession = NativeDashboardResizeSession(original: module, axis: axis, size: size, metrics: metrics)
                        return true
                    }, onChange: { translation in
                        guard model.canEditDashboard, let session = resizeSession,
                              session.original.id == module.id else { return }
                        let resized = session.module(at: translation)
                        if document.modules.first(where: { $0.id == module.id }) != resized {
                            editing.resizeModule(resized)
                        }
                    }, onEnd: { cancelled in
                        if cancelled, model.canEditDashboard, let session = resizeSession {
                            editing.resizeModule(session.original)
                        }
                        resizeSession = nil
                    })
            }
        }
        .overlay(alignment: .topTrailing) {
            if resizeSession?.original.id == module.id {
                GeometryReader { geometry in
                    Text(NativeLocalization.text("\(metrics.columns(for: module.preferredColumnSpan))/12 列 · \(Int(geometry.size.height)) 点"))
                        .font(.caption.monospacedDigit()).padding(.horizontal, 10).padding(.vertical, 5)
                        .foregroundStyle(.white).background(appPalette.accent, in: Capsule())
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 12).offset(y: -14)
                }
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if dropTargetID == module.id {
                Text("松开以调整位置").font(.caption.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .foregroundStyle(.white).background(appPalette.accent, in: Capsule())
                    .offset(y: 9).allowsHitTesting(false)
            }
        }
        .onDrop(of: [NativeDashboardModuleDrag.contentType], delegate: NativeDashboardModuleDropDelegate(
            model: model, targetID: module.id, activeDrag: $activeDrag, dropTargetID: $dropTargetID
        ))
    }

    private func moduleContent(_ module: NativeDashboardModule, width: CGFloat, contentHeight: CGFloat?) -> some View {
        DashboardModuleContent(model: model, module: module, isEditing: isEditing,
                               availableWidth: width - 40, contentHeight: contentHeight) {
            selectedModule = module
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func moduleHeading(_ module: NativeDashboardModule) -> some View {
        HStack(spacing: 8) {
            if isEditing {
                NativeIcon.image("line.3.horizontal")
                    .foregroundStyle(.secondary).frame(width: 28, height: 32)
                    .background(appPalette.canvas, in: RoundedRectangle(cornerRadius: 6))
            }
            Label(module.displayTitle, nativeIcon: module.kind.symbol, iconSize: 14)
                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 6)
        }
        .frame(maxWidth: .infinity, minHeight: isEditing ? 36 : 18, alignment: .leading)
    }

    private func clearDrag() {
        resizeSession = nil
        activeDrag = nil
        dropTargetID = nil
        dragPreviews.clear()
    }

    private func moduleControls(_ module: NativeDashboardModule, compact: Bool) -> some View {
        HStack(spacing: 5) {
            if !compact {
                Button { editing.draft?.move(module.id, by: -1) } label: { NativeIcon.image("arrow.up") }
                    .help("上移模块").accessibilityLabel("上移模块")
                    .disabled(document.modules.first?.id == module.id)
                Button { editing.draft?.move(module.id, by: 1) } label: { NativeIcon.image("arrow.down") }
                    .help("下移模块").accessibilityLabel("下移模块")
                    .disabled(document.modules.last?.id == module.id)
            }
            Button { selectedModule = module } label: { NativeIcon.image("pencil") }
                .help("编辑模块").accessibilityLabel("编辑模块")
            Menu {
                if compact {
                    Button("上移模块") { editing.draft?.move(module.id, by: -1) }
                        .disabled(document.modules.first?.id == module.id)
                    Button("下移模块") { editing.draft?.move(module.id, by: 1) }
                        .disabled(document.modules.last?.id == module.id)
                    Divider()
                }
                Menu("模块宽度") {
                    ForEach(Array(NativeDashboardGridMetrics.columnRange), id: \.self) { columns in
                        Button {
                            var updated = module
                            updated.setColumnSpan(columns)
                            editing.update(updated)
                        } label: {
                            Label { Text(NativeLocalization.text("\(columns)/12 列")) } icon: {
                                NativeIcon.image(module.preferredColumnSpan == columns ? "checkmark" : "rectangle")
                            }
                        }
                    }
                }
                Button("高度随内容") {
                    var updated = module
                    updated.heightRows = nil
                    editing.update(updated)
                }
                Divider()
                Button("复制模块") {
                    var copy = module
                    copy.id = UUID()
                    if let index = editing.draft?.modules.firstIndex(where: { $0.id == module.id }) {
                        editing.draft?.modules.insert(copy, at: index + 1)
                    }
                }.disabled(document.modules.count >= 100)
                Button("移除模块", role: .destructive) {
                    editing.draft?.modules.removeAll { $0.id == module.id }
                }
            } label: { NativeIcon.image("ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("模块选项").accessibilityLabel("模块选项")
        }
        .buttonStyle(.borderless)
        .disabled(model.isSavingDashboard)
    }

    private func beginAdding() {
        if editing.draft == nil { editing.draft = model.dashboard }
        showsModulePicker = true
    }
}

private struct DashboardModulePicker: View {
    @Environment(\.nativeAppPalette) private var appPalette

    let onSelect: (NativeDashboardModuleKind) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("添加模块").font(.title2.weight(.semibold))
                    Text("自由组合，让首页成为你的日常工作台。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(NativeDashboardModuleKind.allCases) { kind in
                    Button { onSelect(kind) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            NativeIcon.image(kind.symbol, size: 18).foregroundStyle(appPalette.accent)
                                .frame(width: 34, height: 36)
                                .background(appPalette.lightBlue, in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(LocalizedStringKey(kind.title)).font(.headline)
                                Text(LocalizedStringKey(kind.subtitle))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14).frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                        .background(appPalette.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(28).frame(width: 650)
        .nativeAppTheme()
    }
}
