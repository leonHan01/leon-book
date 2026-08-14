import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: BrowserModel
    @State private var address = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("本机博客地址", text: $address, prompt: Text("http://localhost:3000"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            Text("只接受 localhost 或 127.0.0.1 地址；文章和媒体不会发送到远程站点。")
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
