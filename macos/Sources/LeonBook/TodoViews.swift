import SwiftUI
import LeonBookTodoModule

struct TodoListView: View {
    @Environment(\.nativeAppPalette) private var appPalette

    @ObservedObject var model: NativeAppModel
    @State private var composer: TodoComposerContext?
    @FocusState private var quickEntryFocused: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let today = TodoDay.string(from: context.date)
            let projection = TodoListProjection(items: model.todoSession.items, filter: model.todoSession.filter, search: model.todoSession.search, today: today)
            VStack(spacing: 0) {
                header(projection)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        summary(projection)
                        quickEntry
                        filters
                        list(projection, today: today)
                    }
                    .padding(24)
                    .frame(maxWidth: 1100)
                    .frame(maxWidth: .infinity)
                }
                if let deleted = model.todoSession.lastDeleted {
                    HStack(spacing: 10) {
                        NativeIcon.image("trash").foregroundStyle(.secondary)
                        Text(NativeLocalization.text("已删除：\(deleted.title)")).lineLimit(1)
                        Spacer()
                        Button("撤销删除") { Task { _ = await model.undoTodoDeletion() } }
                            .disabled(!model.canWriteTodos)
                        Button { model.todoSession.lastDeleted = nil } label: { NativeIcon.image("xmark") }
                            .buttonStyle(.plain).help("关闭")
                    }
                    .font(.callout).padding(14).background(appPalette.surface)
                }
            }
            .background(appPalette.canvas)
        }
        .sheet(item: $composer) { context in
            TodoEditorSheet(model: model, context: context)
        }
        .task(id: model.workspaceGeneration) {
            do { try await model.reloadTodos() }
            catch { model.errorMessage = error.localizedDescription }
            if composer == nil { quickEntryFocused = true }
        }
        .onChange(of: model.todoSession.focusRequest) { _ in quickEntryFocused = true }
        .onChange(of: model.workspaceGeneration) { _ in composer = nil }
    }

    private func header(_ projection: TodoListProjection) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("TODO LIST").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(appPalette.textSecondary)
                Text("待办").font(.system(size: 28, weight: .bold)).foregroundStyle(appPalette.deepBlue)
                Text("安排任务，记录每一次完成。") .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.todoSession.isLoading || model.isSavingTodo { ProgressView().controlSize(.small) }
            VStack(alignment: .trailing, spacing: 7) {
                Text(NativeLocalization.text("已完成 \(projection.completedCount) / \(projection.openCount + projection.completedCount)"))
                    .font(.caption).foregroundStyle(.secondary)
                ProgressView(value: Double(projection.completedCount), total: Double(max(1, projection.openCount + projection.completedCount)))
                    .frame(width: 140).tint(appPalette.blue)
            }
            Button {
                composer = TodoComposerContext(item: nil, draft: .init(title: model.todoSession.quickTitle), workspace: model.workspaceGeneration)
            } label: { Label("新建待办", nativeIcon: "plus") }
                .nativePrimaryButton().disabled(!model.canWriteTodos)
        }
        .padding(.horizontal, 26).padding(.vertical, 22)
        .background(appPalette.surface)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func summary(_ projection: TodoListProjection) -> some View {
        HStack(spacing: 12) {
            stat("待完成", count: projection.openCount, icon: "circle.dotted", color: appPalette.blue, filter: .open)
            stat("今天到期", count: projection.todayCount, icon: "calendar", color: appPalette.blue, filter: .today)
            stat("已逾期", count: projection.overdueCount, icon: "clock.badge.exclamationmark", color: .orange, filter: .overdue)
            stat("已完成", count: projection.completedCount, icon: "checkmark.circle", color: .green, filter: .completed)
        }
    }

    private func stat(_ title: String, count: Int, icon: String, color: Color, filter: TodoFilter) -> some View {
        Button { model.todoSession.filter = filter } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    NativeIcon.image(icon).foregroundStyle(color)
                    Spacer()
                    Text(LocalizedStringKey(title)).font(.caption).foregroundStyle(.secondary)
                }
                Text("\(count)").font(.system(size: 25, weight: .semibold)).foregroundStyle(appPalette.textPrimary)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(appPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.todoSession.filter == filter ? appPalette.blue.opacity(0.55) : appPalette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var quickEntry: some View {
        HStack(spacing: 12) {
            NativeIcon.image("plus.circle", size: 18).foregroundStyle(appPalette.blue)
            TextField("添加待办，按回车保存", text: $model.todoSession.quickTitle)
                .textFieldStyle(.plain).focused($quickEntryFocused)
                .onSubmit { addQuickTodo() }
            Button("添加") { addQuickTodo() }
                .nativePrimaryButton()
                .disabled(!model.canWriteTodos || model.todoSession.quickTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(14).background(appPalette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(quickEntryFocused ? appPalette.blue.opacity(0.65) : appPalette.border, lineWidth: 1))
    }

    private func addQuickTodo() {
        guard model.canWriteTodos else { return }
        Task {
            if await model.addQuickTodo() { quickEntryFocused = true }
        }
    }

    private var filters: some View {
        HStack(spacing: 18) {
            Picker("待办筛选", selection: $model.todoSession.filter) {
                ForEach(TodoFilter.allCases) { filter in Text(LocalizedStringKey(filter.label)).tag(filter) }
            }
            .pickerStyle(.segmented).frame(maxWidth: 440)
            Spacer(minLength: 10)
            HStack(spacing: 6) {
                NativeIcon.image("magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索待办或备注", text: $model.todoSession.search).textFieldStyle(.plain)
                if !model.todoSession.search.isEmpty {
                    Button { model.todoSession.search = "" } label: { NativeIcon.image("xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("清除搜索")
                }
            }
            .padding(8).frame(maxWidth: 250)
            .background(appPalette.surface, in: RoundedRectangle(cornerRadius: 7))
        }
    }

    @ViewBuilder
    private func list(_ projection: TodoListProjection, today: String) -> some View {
        if !model.todoSession.hasLoaded {
            VStack(spacing: 12) {
                if let error = model.todoSession.loadError {
                    NativeIcon.image("exclamationmark.circle", size: 32).foregroundStyle(.secondary)
                    Text(error).font(.callout).foregroundStyle(.secondary)
                    Button("重新加载") { Task { try? await model.reloadTodos() } }
                } else { ProgressView("正在加载待办…") }
            }.frame(maxWidth: .infinity).padding(55)
        } else if projection.items.isEmpty {
            VStack(spacing: 14) {
                NativeIcon.image("checklist", size: 32).foregroundStyle(appPalette.blue.opacity(0.65))
                Text(LocalizedStringKey(model.todoSession.items.isEmpty ? "开始第一项待办" : "没有匹配的待办")).font(.headline)
                Text(LocalizedStringKey(model.todoSession.items.isEmpty ? "在上方输入任务，按回车添加。" : "试试其他筛选条件或搜索关键词。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 65)
            .background(appPalette.surface, in: RoundedRectangle(cornerRadius: 12))
        } else {
            LazyVStack(spacing: 0) {
                ForEach(projection.items) { item in
                    TodoItemRow(item: item, today: today, isEnabled: model.canWriteTodos,
                        onToggle: { Task { _ = await model.toggleTodo(item) } },
                        onEdit: { composer = TodoComposerContext(item: item, draft: item.draft, workspace: model.workspaceGeneration) },
                        onDelete: { Task { _ = await model.deleteTodo(item) } })
                    if item.id != projection.items.last?.id { Divider().padding(.leading, 54) }
                }
            }
            .padding(6).background(appPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(appPalette.border.opacity(0.7), lineWidth: 1))
        }
    }
}

private struct TodoItemRow: View {
    @Environment(\.nativeAppPalette) private var appPalette

    let item: TodoItem
    let today: String
    let isEnabled: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 13) {
            Button(action: onToggle) {
                NativeIcon.image(item.isCompleted ? "checkmark.circle.fill" : "circle", size: 24)
                    .foregroundStyle(item.isCompleted ? appPalette.blue : appPalette.textSecondary.opacity(0.7))
            }
            .buttonStyle(.plain).disabled(!isEnabled)
            .accessibilityLabel(LocalizedStringKey(item.isCompleted ? "标记未完成" : "标记完成"))
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(.system(size: 14, weight: .medium))
                        .strikethrough(item.isCompleted).foregroundStyle(item.isCompleted ? appPalette.textSecondary : appPalette.textPrimary)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    if !item.notes.isEmpty { Text(item.notes).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
            .buttonStyle(.plain).disabled(!isEnabled)
            if let day = item.dueDay {
                Label(LocalizedStringKey(day == today ? "今天" : day), nativeIcon: "calendar", iconSize: 12)
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(item.isOverdue(today: today) ? Color.orange : appPalette.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(item.isOverdue(today: today) ? Color.orange.opacity(0.09) : appPalette.surfaceSecondary, in: Capsule())
            }
            NativeIcon.image("flag.fill", size: 12)
                .foregroundStyle(item.priority == .high ? Color.red.opacity(0.8) : item.priority == .normal ? appPalette.blue : appPalette.textSecondary.opacity(0.45))
                .help(LocalizedStringKey(item.priority.label)).accessibilityLabel(LocalizedStringKey(item.priority.label))
            Menu {
                Button("编辑待办", action: onEdit)
                Button(LocalizedStringKey(item.isCompleted ? "标记未完成" : "标记完成"), action: onToggle)
                Divider()
                Button("删除待办", role: .destructive, action: onDelete)
            } label: { NativeIcon.image("ellipsis") }
            .menuStyle(.borderlessButton).frame(width: 22).disabled(!isEnabled).help("待办操作")
        }
        .padding(.horizontal, 13).padding(.vertical, 15)
        .background(isHovered ? appPalette.lightBlue.opacity(0.55) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("编辑待办", action: onEdit).disabled(!isEnabled)
            Button("删除待办", role: .destructive, action: onDelete).disabled(!isEnabled)
        }
    }
}

private struct TodoComposerContext: Identifiable {
    let id = UUID()
    let item: TodoItem?
    let draft: TodoDraft
    let workspace: Int
}

private struct TodoEditorSheet: View {
    @Environment(\.nativeAppPalette) private var appPalette

    @ObservedObject var model: NativeAppModel
    let context: TodoComposerContext
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TodoDraft
    @State private var validationMessage: String?
    @FocusState private var titleFocused: Bool

    init(model: NativeAppModel, context: TodoComposerContext) {
        self.model = model; self.context = context; _draft = State(initialValue: context.draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(LocalizedStringKey(context.item == nil ? "新建待办" : "编辑待办")).font(.title2.weight(.semibold))
            TextField("要完成什么？", text: $draft.title).textFieldStyle(.roundedBorder).focused($titleFocused)
            HStack {
                Text("优先级").foregroundStyle(.secondary)
                Picker("优先级", selection: $draft.priority) {
                    ForEach(TodoPriority.allCases.reversed()) { priority in Text(LocalizedStringKey(priority.label)).tag(priority) }
                }.labelsHidden().frame(width: 155)
                Spacer()
                Toggle("设置截止日期", isOn: Binding(get: { draft.dueDay != nil }, set: { draft.dueDay = $0 ? TodoDay.string(from: Date()) : nil }))
                    .toggleStyle(.checkbox)
            }
            if draft.dueDay != nil {
                DatePicker("截止日期", selection: Binding(get: { draft.dueDay.flatMap { TodoDay.date(from: $0) } ?? Date() }, set: { draft.dueDay = TodoDay.string(from: $0) }), displayedComponents: .date)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("备注").font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $draft.notes).font(.body).padding(5)
                    .frame(height: 125).background(appPalette.surface)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(appPalette.border, lineWidth: 1))
            }
            if let validationMessage { Text(validationMessage).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if model.isSavingTodo { ProgressView().controlSize(.small) }
                Button("保存") { save() }.nativePrimaryButton().keyboardShortcut(.defaultAction)
                    .disabled(!model.canWriteTodos || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 520)
        .disabled(model.isSavingTodo)
        .onAppear { titleFocused = true }
    }

    private func save() {
        guard context.workspace == model.workspaceGeneration else { validationMessage = NativeLocalization.text("工作区已切换，请重新打开待办。"); return }
        do { _ = try draft.validated() } catch { validationMessage = error.localizedDescription; return }
        Task {
            if await model.saveTodoDraft(draft, editing: context.item) {
                if context.item == nil, model.todoSession.quickTitle == context.draft.title { model.todoSession.quickTitle = "" }
                dismiss()
            } else { validationMessage = model.errorMessage }
        }
    }
}
