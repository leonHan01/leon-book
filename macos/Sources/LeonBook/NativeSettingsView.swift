import AppKit
import LeonBookBackupModule
import SwiftUI

public struct NativeSettingsView: View {
    @ObservedObject var model: NativeAppModel
    @ObservedObject var readingPreferences: NativeReadingPreferences
    @Environment(\.colorScheme) private var systemColorScheme

    public init(model: NativeAppModel) {
        self.model = model
        readingPreferences = NativeReadingPreferences()
    }

    init(model: NativeAppModel, readingPreferences: NativeReadingPreferences) {
        self.model = model
        self.readingPreferences = readingPreferences
    }

    public var body: some View {
        Form {
            Section("用户与工作空间") {
                LabeledContent("当前用户") { Text(model.currentUser.name) }
                LabeledContent("用户数量") { Text("\(model.users.count) 位") }
                Text("用户之间的数据完全隔离；切换用户不会共享文章、草稿、媒体或创作活动。")
                    .foregroundStyle(.secondary)
            }

            Section("本地文件") {
                LabeledContent("状态") {
                    Label(model.storageReady ? "已连接" : "未连接", systemImage: model.storageReady ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(model.storageReady ? .green : .red)
                }
                LabeledContent("存储方式") { Text("SQLite + 本地文件") }
                LabeledContent("数据目录") { Text(model.dataDirectoryPath).textSelection(.enabled) }
            }

            Section("数据") {
                Text("文章 Markdown/YAML 和媒体文件是权威数据源；SQLite 保存文章索引及评论、版本、收藏等结构化数据。所有内容均保存在本机，不会启动 Node.js、监听端口或上传到云端。")
                    .foregroundStyle(.secondary)
                Button("在 Finder 中打开项目目录") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: model.dataDirectoryPath)
                }
                Button("重新加载文章") { model.executeCommand(.reload) }
            }

            Section("阅读与编辑排版") {
                Picker("正文字体", selection: $readingPreferences.profile.bodyFont) {
                    ForEach(NativeReadingFontFamily.allCases) { font in
                        Text(font.title).tag(font)
                    }
                }
                Picker("代码字体", selection: $readingPreferences.profile.codeFont) {
                    ForEach(NativeCodeFontFamily.allCases) { font in
                        Text(font.title).tag(font)
                    }
                }
                Picker("阅读主题", selection: $readingPreferences.profile.theme) {
                    ForEach(NativeReadingTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }

                typographySlider(
                    title: "正文宽度",
                    value: $readingPreferences.profile.readingWidth,
                    range: 520...1_400,
                    step: 20,
                    suffix: "pt"
                )
                typographySlider(
                    title: "正文字号",
                    value: $readingPreferences.profile.fontSize,
                    range: 13...30,
                    step: 1,
                    suffix: "pt"
                )
                typographySlider(
                    title: "行距",
                    value: $readingPreferences.profile.lineSpacing,
                    range: 0...18,
                    step: 1,
                    suffix: "pt"
                )
                typographySlider(
                    title: "段距",
                    value: $readingPreferences.profile.paragraphSpacing,
                    range: 4...36,
                    step: 1,
                    suffix: "pt"
                )

                VStack(alignment: .leading, spacing: readingPreferences.typography.paragraphSpacing) {
                    Text("排版预览")
                        .font(readingPreferences.profile.bodyFont.swiftUIFont(
                            size: readingPreferences.typography.fontSize,
                            weight: .semibold
                        ))
                    Text("文字应当让内容呼吸，也让长时间阅读保持舒适。")
                        .font(readingPreferences.profile.bodyFont.swiftUIFont(
                            size: readingPreferences.typography.fontSize
                        ))
                        .lineSpacing(readingPreferences.typography.lineSpacing)
                    Text("let markdown = true")
                        .font(readingPreferences.profile.codeFont.swiftUIFont(
                            size: max(11, readingPreferences.typography.fontSize - 2)
                        ))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(
                    readingPreferences.profile.theme.background(system: systemColorScheme),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .environment(
                    \.colorScheme,
                    readingPreferences.profile.theme.colorScheme(system: systemColorScheme)
                )

                Button("恢复默认排版") { readingPreferences.reset() }
            }

            Section("命令与快捷键") {
                NativeCommandSettingsPanel(model: model)
            }

            Section("第一方模块") {
                ForEach(model.firstPartyModules) { module in
                    Toggle(isOn: Binding(
                        get: { model.isFirstPartyModuleEnabled(module.id) },
                        set: { model.setFirstPartyModuleEnabled($0, moduleID: module.id) }
                    )) {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(module.name)
                                Text(module.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: module.systemImage)
                        }
                    }
                    Text("权限：\(model.firstPartyPermissionLabels(module))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let event = model.latestFirstPartyModuleEvent,
                   let module = model.firstPartyModules.first(where: { $0.id == event.moduleID }) {
                    LabeledContent("最近事件") {
                        Text("\(module.name) · \(event.name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("停用后，该模块拥有的命令会从命令面板消失，直接入口也会经过同一权限门禁。模块状态保存在本机。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Markdown 工作区 / Obsidian Vault") {
                Picker("使用方式", selection: $model.selectedMarkdownWorkspaceMode) {
                    ForEach(NativeMarkdownWorkspaceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.isScanningObsidianVault || model.isImportingObsidianVault)

                Text(model.selectedMarkdownWorkspaceMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("当前模式") {
                    Text(model.activeMarkdownWorkspaceMode.title)
                        .foregroundStyle(model.isMarkdownSourceReadOnly ? .orange : .secondary)
                }
                LabeledContent("Markdown 目录") {
                    Text(model.markdownSourceDirectoryPath)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                LabeledContent("状态") {
                    HStack(spacing: 8) {
                        if model.isScanningObsidianVault || model.isImportingObsidianVault {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.obsidianImportStatus)
                    }
                }

                if let preview = model.obsidianImportPreview {
                    LabeledContent("Vault") {
                        Text(preview.vaultURL.path)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 18) {
                        Label(
                            model.selectedMarkdownWorkspaceMode == .copyImport
                                ? "\(preview.importableCount) 篇可复制"
                                : "\(preview.notes.count) 篇 Markdown",
                            systemImage: model.selectedMarkdownWorkspaceMode == .copyImport
                                ? "doc.badge.plus"
                                : "folder"
                        )
                        if model.selectedMarkdownWorkspaceMode == .copyImport {
                            Label("\(preview.attachmentCount) 个附件", systemImage: "paperclip")
                        }
                        if model.selectedMarkdownWorkspaceMode == .copyImport, preview.conflictCount > 0 {
                            Label("\(preview.conflictCount) 篇冲突跳过", systemImage: "shield.lefthalf.filled")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)

                    if !preview.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(Array(preview.notes.prefix(8))) { note in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: note.canImport ? "checkmark.circle" : "exclamationmark.shield")
                                        .foregroundStyle(note.canImport ? .green : .orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(note.title).lineLimit(1)
                                        Text(
                                            model.selectedMarkdownWorkspaceMode == .copyImport
                                                ? note.conflictReason ?? "\(note.relativePath) → \(note.slug)"
                                                : note.relativePath
                                        )
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                            if preview.notes.count > 8 {
                                Text("另有 \(preview.notes.count - 8) 篇…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    if !preview.warnings.isEmpty {
                        DisclosureGroup("扫描提示（\(preview.warnings.count)）") {
                            ForEach(Array(preview.warnings.prefix(8).enumerated()), id: \.offset) { _, warning in
                                Text(warning)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack {
                        Button(markdownSourceConfirmationTitle(preview)) {
                            model.confirmObsidianImport()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            (model.selectedMarkdownWorkspaceMode == .copyImport && preview.importableCount == 0)
                                || model.isImportingObsidianVault
                        )
                        Button("取消") { model.cancelObsidianImport() }
                            .disabled(model.isImportingObsidianVault)
                    }
                } else {
                    Button("选择并扫描 Markdown 文件夹…") {
                        model.chooseObsidianVault()
                    }
                    .disabled(model.isScanningObsidianVault || model.isImportingObsidianVault || !model.storageReady)
                }

                Text("挂载模式会持续监听普通文件夹或 Obsidian Vault 中的 Markdown；SQLite、评论、版本、布局和应用媒体仍保存在 LeonBook 工作区。只读挂载不会改写原目录；直接编辑会原子写回。工作区备份只包含 LeonBook 内部数据，不复制外部挂载目录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("备份") {
                LabeledContent("备份目录") {
                    Text(model.backupDirectoryPath.isEmpty ? "未设置" : model.backupDirectoryPath)
                        .textSelection(.enabled)
                }
                LabeledContent("状态") {
                    HStack(spacing: 8) {
                        if model.isBackingUp { ProgressView().controlSize(.small) }
                        Text(model.backupStatus)
                    }
                }
                if !model.lastBackupPath.isEmpty {
                    LabeledContent("最新快照") {
                        Text(model.lastBackupPath).textSelection(.enabled)
                    }
                }

                if !model.backupDirectoryPath.isEmpty {
                    DisclosureGroup("自动备份与保留策略") {
                        VStack(alignment: .leading, spacing: 12) {
                            Stepper(
                                value: Binding(
                                    get: { model.backupAutomaticIntervalHours },
                                    set: { model.updateBackupPolicy(automaticIntervalHours: $0) }
                                ),
                                in: 1...24
                            ) {
                                LabeledContent("最短自动备份间隔") {
                                    Text("\(model.backupAutomaticIntervalHours) 小时")
                                }
                            }
                            Stepper(
                                value: Binding(
                                    get: { model.backupRetentionDays },
                                    set: { model.updateBackupPolicy(retentionDays: $0) }
                                ),
                                in: 7...365,
                                step: 7
                            ) {
                                LabeledContent("最长保留时间") {
                                    Text("\(model.backupRetentionDays) 天")
                                }
                            }
                            Stepper(
                                value: Binding(
                                    get: { model.backupMaximumSnapshotCount },
                                    set: { model.updateBackupPolicy(maximumSnapshotCount: $0) }
                                ),
                                in: 10...200,
                                step: 5
                            ) {
                                LabeledContent("最多快照") {
                                    Text("\(model.backupMaximumSnapshotCount) 个")
                                }
                            }
                            Stepper(
                                value: Binding(
                                    get: { model.backupMinimumFreeSpaceGB },
                                    set: { model.updateBackupPolicy(minimumFreeSpaceGB: $0) }
                                ),
                                in: 1...100
                            ) {
                                LabeledContent("备份后最低剩余空间") {
                                    Text("\(model.backupMinimumFreeSpaceGB) GB")
                                }
                            }
                        }
                        .padding(.top, 8)
                    }

                    if let estimate = model.backupStorageEstimate {
                        LabeledContent("数据规模") {
                            Text(backupByteLabel(estimate.sourceSizeBytes))
                        }
                        LabeledContent("下次预计新增") {
                            Text(backupByteLabel(estimate.estimatedAdditionalBytes))
                        }
                        if let available = estimate.availableBytes {
                            LabeledContent("备份盘可用") {
                                Text(backupByteLabel(available))
                            }
                            let remaining = max(0, available - estimate.estimatedAdditionalBytes)
                            LabeledContent("预计备份后剩余") {
                                Text(backupByteLabel(remaining))
                                    .foregroundStyle(
                                        remaining < model.backupPolicy.minimumFreeSpaceBytes ? .red : .primary
                                    )
                            }
                        }
                        if estimate.reusableFileCount > 0 {
                            Text("下次快照预计复用 \(estimate.reusableFileCount) 个未变化文件。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack {
                    Button(model.backupDirectoryPath.isEmpty ? "设置备份路径" : "更改备份路径") {
                        model.chooseBackupDirectory()
                    }
                    .disabled(model.isRestoringBackup)
                    if !model.backupDirectoryPath.isEmpty {
                        Button("立即备份") { model.backupNow() }
                            .disabled(model.isBackingUp || model.isRestoringBackup || !model.storageReady)
                        Button("打开目录") { model.openBackupDirectory() }
                        Button("刷新快照") { model.refreshBackupOverviewNow() }
                            .disabled(model.isBackingUp || model.isRestoringBackup)
                        Button("清除路径") { model.clearBackupDirectory() }
                            .disabled(model.isBackingUp || model.isRestoringBackup)
                    }
                }

                if !model.backupSnapshots.isEmpty {
                    DisclosureGroup("快照浏览（\(model.backupSnapshots.count)）") {
                        VStack(spacing: 8) {
                            ForEach(Array(model.backupSnapshots.prefix(12))) { snapshot in
                                BackupSnapshotRow(model: model, snapshot: snapshot)
                                if snapshot.id != model.backupSnapshots.prefix(12).last?.id {
                                    Divider()
                                }
                            }
                            if model.backupSnapshots.count > 12 {
                                Text("其余 \(model.backupSnapshots.count - 12) 个快照可在备份目录中查看。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 8)
                    }
                    LabeledContent("校验状态") {
                        HStack(spacing: 8) {
                            if model.isValidatingBackup { ProgressView().controlSize(.small) }
                            Text(model.backupValidationStatus)
                        }
                    }
                }

                Text("自动备份会合并短时间内的连续变更；未变化文件从上一快照复用，APFS 同卷时优先使用写时复制。超过保留天数或数量的旧快照会自动清理，备份前会预留最低剩余空间。整库恢复前会先校验所选快照，并为当前数据额外创建安全快照。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("备份不会上传云端。建议选择另一块磁盘，并为磁盘启用 FileVault 或其他加密。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("这是完全原生的 SwiftUI 应用，不依赖 Safari、Chrome、WKWebView、Node.js 或本地 HTTP 服务。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 720)
        .padding(24)
        .task { readingPreferences.prepare(for: model.currentUser.id) }
        .onChange(of: model.currentUser.id) { readingPreferences.prepare(for: $0) }
    }

    private func typographySlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        suffix: String
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range, step: step)
                    .frame(width: 240)
                Text("\(Int(value.wrappedValue.rounded())) \(suffix)")
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }

    private func markdownSourceConfirmationTitle(_ preview: NativeObsidianImportPreview) -> String {
        switch model.selectedMarkdownWorkspaceMode {
        case .copyImport: return "确认复制 \(preview.importableCount) 篇"
        case .readOnlyMount: return "只读挂载此文件夹"
        case .directEdit: return "直接编辑此文件夹"
        }
    }
}

private struct NativeCommandSettingsPanel: View {
    @ObservedObject var model: NativeAppModel
    @ObservedObject private var preferences: NativeCommandPreferences
    @State private var query = ""

    init(model: NativeAppModel) {
        self.model = model
        _preferences = ObservedObject(wrappedValue: model.commandPreferences)
    }

    private var definitions: [NativeCommandDefinition] {
        let context = model.commandContext
        let ranking = preferences.ranking
        let palette = model.commandRegistry.matches(
            query,
            on: .palette,
            context: context,
            ranking: ranking,
            includingUnavailable: true
        ).map(\.definition)
        let slash = model.commandRegistry.matches(
            query,
            on: .editorSlash,
            context: context,
            ranking: ranking,
            includingUnavailable: true
        ).map(\.definition)
        var seen = Set<NativeCommandID>()
        return (palette + slash).filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("筛选命令", text: $query)
                .textFieldStyle(.roundedBorder)

            Text("快捷键由统一命令注册表驱动，修改后菜单和命令面板会同步更新。点击快捷键开始录制；Delete 移除，Esc 取消。")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(definitions) { definition in
                NativeCommandShortcutRow(
                    definition: definition,
                    preferences: preferences,
                    registry: model.commandRegistry
                )
                if definition.id != definitions.last?.id { Divider() }
            }

            HStack {
                Text("共 \(definitions.count) 个命令")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("恢复全部默认设置") { preferences.resetAll() }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct NativeCommandShortcutRow: View {
    let definition: NativeCommandDefinition
    @ObservedObject var preferences: NativeCommandPreferences
    let registry: NativeCommandRegistry
    @State private var conflictMessage: String?

    private var shortcut: NativeCommandShortcut? {
        preferences.shortcut(for: definition)
    }

    private var isCustomized: Bool {
        preferences.state.customShortcuts[definition.id.rawValue] != nil
            || preferences.state.disabledDefaultShortcuts.contains(definition.id.rawValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: definition.systemImage)
                    .frame(width: 22)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(definition.title).font(.callout.weight(.medium))
                    Text(definition.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if definition.surfaces.contains(.palette) {
                    Button {
                        preferences.togglePinned(definition.id)
                    } label: {
                        Image(systemName: preferences.isPinned(definition.id) ? "pin.fill" : "pin")
                    }
                    .buttonStyle(.borderless)
                    .help(preferences.isPinned(definition.id) ? "取消固定命令" : "固定到命令面板顶部")
                }
                NativeShortcutRecorder(shortcut: shortcut) { captured in
                    conflictMessage = nil
                    if let conflict = preferences.setShortcut(captured, for: definition.id),
                       let conflictDefinition = registry.definition(for: conflict) {
                        conflictMessage = "与“\(conflictDefinition.title)”冲突，未保存。"
                    }
                }
                if isCustomized {
                    Button("默认") {
                        preferences.resetShortcut(for: definition.id)
                        conflictMessage = nil
                    }
                    .controlSize(.small)
                }
            }
            if let conflictMessage {
                Label(conflictMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 32)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct NativeShortcutRecorder: View {
    let shortcut: NativeCommandShortcut?
    let onCapture: (NativeCommandShortcut?) -> Void
    @State private var isRecording = false

    var body: some View {
        Button {
            isRecording = true
        } label: {
            Text(isRecording ? "请按快捷键…" : (shortcut?.displayLabel ?? "未设置"))
                .font(.caption.monospaced())
                .frame(minWidth: 82)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .background(
            NativeShortcutCaptureView(
                isRecording: isRecording,
                onCapture: {
                    isRecording = false
                    onCapture($0)
                },
                onCancel: { isRecording = false }
            )
        )
    }
}

private struct NativeShortcutCaptureView: NSViewRepresentable {
    let isRecording: Bool
    let onCapture: (NativeCommandShortcut?) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NativeShortcutCaptureNSView {
        let view = NativeShortcutCaptureNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: NativeShortcutCaptureNSView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel
        nsView.isRecording = isRecording
        guard isRecording else { return }
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView, nsView.isRecording else { return }
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

private final class NativeShortcutCaptureNSView: NSView {
    var isRecording = false
    var onCapture: ((NativeCommandShortcut?) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            onCapture?(nil)
            return
        }
        guard let key = event.charactersIgnoringModifiers?.lowercased().first,
              !key.isWhitespace,
              !key.isNewline else {
            NSSound.beep()
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers = Set<NativeCommandShortcut.Modifier>()
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        guard !modifiers.isEmpty else {
            NSSound.beep()
            return
        }
        onCapture?(NativeCommandShortcut(key: String(key), modifiers: modifiers))
    }
}

private struct BackupSnapshotRow: View {
    @ObservedObject var model: NativeAppModel
    let snapshot: NativeBackupSnapshot

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: snapshot.isManifestReadable ? "externaldrive.fill.badge.checkmark" : "externaldrive.badge.exclamationmark")
                .foregroundStyle(snapshot.isManifestReadable ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout.weight(.medium))
                HStack(spacing: 8) {
                    Text(snapshot.url.lastPathComponent)
                    if snapshot.logicalSizeBytes > 0 {
                        Text("· \(backupByteLabel(snapshot.logicalSizeBytes))")
                    }
                    if snapshot.reusedFileCount > 0 {
                        Text("· 复用 \(snapshot.reusedFileCount) 个文件")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            Button("显示") { model.showBackupSnapshotInFinder(snapshot) }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("校验") { model.validateBackupSnapshot(snapshot) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isValidatingBackup || model.isRestoringBackup || !snapshot.isManifestReadable)
            Button("恢复", role: .destructive) { model.restoreBackupSnapshot(snapshot) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isBackingUp || model.isRestoringBackup || !snapshot.isManifestReadable)
        }
    }
}

private func backupByteLabel(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}
