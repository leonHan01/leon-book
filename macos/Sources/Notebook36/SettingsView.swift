import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: BrowserModel
    @State private var address = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("博客地址", text: $address, prompt: Text("https://blog.example.com"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            Text("应用会保留该站点的登录 Cookie、主题偏好和草稿恢复数据。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("保存并打开", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            address = model.siteURL.absoluteString
        }
    }

    private func save() {
        do {
            try model.updateSiteURL(address)
            address = model.siteURL.absoluteString
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
