import SwiftUI

struct NativeSettingsView: View {
    @ObservedObject var model: NativeAppModel

    var body: some View {
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
                LabeledContent("存储方式") { Text("Swift FileManager") }
                LabeledContent("数据目录") { Text(model.dataDirectoryPath).textSelection(.enabled) }
            }

            Section("数据") {
                Text("文章、草稿、媒体和设置直接由 Swift 写入本机文件，不会启动 Node.js、监听端口或上传到云端。")
                    .foregroundStyle(.secondary)
                Button("在 Finder 中打开项目目录") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: model.dataDirectoryPath)
                }
                Button("重新加载文章") { Task { try? await model.reload() } }
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
