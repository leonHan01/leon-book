import SwiftUI

public struct NativeSettingsView: View {
    @ObservedObject var model: NativeAppModel

    public init(model: NativeAppModel) {
        self.model = model
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
                Text("文章、草稿、动态、活动记录和用户设置由 SQLite 管理；Markdown、JSON 和媒体文件同时保存在本机，不会启动 Node.js、监听端口或上传到云端。")
                    .foregroundStyle(.secondary)
                Button("在 Finder 中打开项目目录") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: model.dataDirectoryPath)
                }
                Button("重新加载文章") { Task { try? await model.reload() } }
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
                HStack {
                    Button(model.backupDirectoryPath.isEmpty ? "设置备份路径" : "更改备份路径") {
                        model.chooseBackupDirectory()
                    }
                    if !model.backupDirectoryPath.isEmpty {
                        Button("立即备份") { model.backupNow() }
                            .disabled(model.isBackingUp || !model.storageReady)
                        Button("打开目录") { model.openBackupDirectory() }
                        Button("清除路径") { model.clearBackupDirectory() }
                            .disabled(model.isBackingUp)
                    }
                }
                Text("应用会在启动、切换用户和数据变更后自动生成新的完整快照；旧快照不会被覆盖。备份不会上传云端，建议选择另一块磁盘，并为磁盘启用 FileVault 或其他加密。")
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
    }
}
