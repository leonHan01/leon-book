import AppKit
import CoreImage
import Darwin
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class NativeMobileSyncController: ObservableObject {
    struct Device: Decodable, Identifiable {
        let id: String
        let name: String
        let lastSeenAt: Double
    }

    struct Invitation: Decodable, Encodable {
        let type: String
        let version: Int
        let url: String
        let workspaceID: String
        let code: String
        let expiresAt: Double
    }

    private struct Message: Decodable {
        let type: String
        let url: String?
        let certificate: String?
        let invitation: Invitation?
        let devices: [Device]?
        let expiresAt: Double?
        let message: String?
    }

    struct Workspace: Equatable {
        let root: String
        let userID: String
        let name: String
    }

    static let shared = NativeMobileSyncController()
    @Published private(set) var workspace: Workspace?
    @Published private(set) var url: String?
    @Published private(set) var certificate: String?
    @Published private(set) var devices: [Device] = []
    @Published private(set) var invitation: Invitation?
    @Published private(set) var error: String?
    @Published private(set) var stopping = false
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var outputBuffer = Data()

    func start(workspace: Workspace, address: String, port: Int) {
        guard process == nil else { return }
        error = nil
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("MobileSync", isDirectory: true),
              let cli = Bundle.main.url(forAuxiliaryExecutable: "LeonBookCLI"),
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("node_modules/busboy/package.json").path) else {
            error = "同步组件未打包。请在 mobile 目录运行 npm ci，再重新构建 Mac 应用。"
            return
        }
        guard let node = Self.nodeExecutable() else {
            error = "手机同步需要 Node.js 22.13 或更高版本。"
            return
        }
        let child = Process()
        let control = Pipe()
        let messages = Pipe()
        child.executableURL = node
        child.arguments = [
            resources.appendingPathComponent("server/main.js").path,
            "--root", workspace.root, "--user", workspace.userID, "--cli", cli.path,
            "--host", address, "--port", String(port), "--managed", "--control-stdio",
        ]
        child.standardInput = control
        child.standardOutput = messages
        child.standardError = FileHandle.nullDevice
        let reader = messages.fileHandleForReading
        reader.readabilityHandler = { [weak self, weak child] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async {
                guard let self, let child, self.process === child else { return }
                self.receive(data, eof: data.isEmpty)
            }
        }
        child.terminationHandler = { [weak self] child in
            DispatchQueue.main.async {
                guard let self, self.process === child else { return }
                // Let the pipe deliver any structured startup error before fallback.
                if self.output == nil { self.finished() }
            }
        }
        process = child
        input = control.fileHandleForWriting
        output = reader
        self.workspace = workspace
        do {
            try child.run()
        } catch {
            reader.readabilityHandler = nil
            self.error = error.localizedDescription
            finished()
        }
    }

    func stop() {
        guard process != nil, !stopping else { return }
        stopping = true
        invitation = nil
        // Closing stdin also shuts the helper down when the Mac application quits.
        try? input?.close()
        input = nil
    }

    func refresh() { send("status") }
    func createInvitation() { send("invite") }
    func cancelInvitation() { invitation = nil; send("cancel-invite") }
    func removeDevice(_ id: String) { send("revoke", id: id) }

    private func send(_ action: String, id: String? = nil) {
        guard let input, process?.isRunning == true, !stopping else { return }
        var message = ["action": action]
        message["id"] = id
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(10)
        try? input.write(contentsOf: data)
    }

    private func receive(_ data: Data, eof: Bool) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 10) {
            let line = Data(outputBuffer[..<newline])
            outputBuffer.removeSubrange(...newline)
            guard let message = try? JSONDecoder().decode(Message.self, from: line) else { continue }
            switch message.type {
            case "ready":
                url = message.url
                certificate = message.certificate
            case "invite":
                invitation = message.invitation
            case "status":
                devices = message.devices ?? []
                if invitation?.expiresAt != message.expiresAt { invitation = nil }
            case "error":
                error = message.message
            default:
                break
            }
        }
        if eof { finished() }
    }

    private func finished() {
        if !stopping && error == nil { error = "同步服务已退出。请检查端口与 Node.js 版本后重试。" }
        process = nil
        try? input?.close()
        input = nil
        output = nil
        outputBuffer.removeAll()
        workspace = nil
        url = nil
        certificate = nil
        invitation = nil
        devices = []
        stopping = false
    }

    private static func nodeExecutable() -> URL? {
        var directories = ["/opt/homebrew/bin", "/usr/local/bin"]
        directories += ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        return directories.map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("node") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

struct NativeMobileSyncSettings: View {
    @ObservedObject var model: NativeAppModel
    @ObservedObject private var sync = NativeMobileSyncController.shared
    @AppStorage("leonBook.mobileSync.address") private var address = ""
    @AppStorage("leonBook.mobileSync.port") private var port = "8765"
    @State private var availableAddresses: [String] = []
    @State private var selectedDevice: NativeMobileSyncController.Device?
    @State private var exportError: String?

    private var workspace: NativeMobileSyncController.Workspace {
        .init(root: model.dataRootDirectoryPath, userID: model.currentUser.id, name: model.currentUser.name)
    }
    private var ownsService: Bool { sync.workspace == workspace }
    private var validPort: Int? {
        guard let port = Int(port), (1024...65535).contains(port) else { return nil }
        return port
    }

    var body: some View {
        Section("手机同步") {
            Text("在 Mac 与手机连接同一局域网时同步文章、微博、待办和附件。")
                .foregroundStyle(.secondary)
            if let active = sync.workspace {
                LabeledContent("同步工作区", value: active.name)
                LabeledContent("服务状态", value: sync.stopping ? "正在停止…" : sync.url == nil ? "正在启动…" : "已开启")
                if ownsService, let url = sync.url {
                    LabeledContent("连接地址") { Text(url).textSelection(.enabled) }
                    Text("首次使用这台 Mac，请把同步证书安装到手机并信任，然后在 LeonBook 中扫码。之后重启服务会保留已有设备。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("导出同步证书", action: exportCertificate)
                            .disabled(sync.certificate == nil)
                        Button("生成配对二维码") { sync.createInvitation() }
                        Button("停止同步") { sync.stop() }
                    }
                    .disabled(sync.stopping)
                    if let invitation = sync.invitation { invitationView(invitation) }
                    devicesView
                } else {
                    Button("停止同步") { sync.stop() }.disabled(sync.stopping)
                }
            } else {
                Picker("局域网地址", selection: $address) {
                    if availableAddresses.isEmpty { Text("未找到局域网 IPv4 地址").tag("") }
                    ForEach(availableAddresses, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    TextField("端口", text: $port).frame(maxWidth: 145)
                    Button("刷新地址", action: refreshAddresses)
                    Button("启动同步") {
                        guard let validPort else { return }
                        sync.start(workspace: workspace, address: address, port: validPort)
                    }
                    .disabled(!model.storageReady || !availableAddresses.contains(address) || validPort == nil)
                }
            }
            if let error = exportError ?? sync.error {
                Text(error).foregroundStyle(.red)
            }
        }
        .onAppear(perform: refreshAddresses)
        .task(id: sync.url) {
            guard sync.url != nil else { return }
            while !Task.isCancelled {
                sync.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .confirmationDialog("移除此设备？", isPresented: Binding(
            get: { selectedDevice != nil }, set: { if !$0 { selectedDevice = nil } }
        ), presenting: selectedDevice) { device in
            Button("移除设备", role: .destructive) { sync.removeDevice(device.id) }
        } message: { device in
            Text("“\(device.name)”将失去这个工作区的同步权限。")
        }
    }

    @ViewBuilder
    private var devicesView: some View {
        if sync.devices.isEmpty {
            Text("尚未配对设备").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(sync.devices) { device in
            HStack {
                VStack(alignment: .leading) {
                    Text(device.name)
                    Text("上次连接：\(Date(timeIntervalSince1970: device.lastSeenAt / 1_000).formatted())")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("移除") { selectedDevice = device }
            }
        }
    }

    @ViewBuilder
    private func invitationView(_ invitation: NativeMobileSyncController.Invitation) -> some View {
        if let data = try? JSONEncoder().encode(invitation), let text = String(data: data, encoding: .utf8),
           let image = Self.qrCode(data) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 176, height: 176)
                    .padding(10)
                    .background(.white)
                    .accessibilityLabel("LeonBook 手机配对二维码")
                VStack(alignment: .leading, spacing: 8) {
                    Text("手机中打开「连接 Mac → 扫描配对码」")
                    Text("五分钟内有效，只能使用一次。").font(.caption).foregroundStyle(.secondary)
                    Button("复制配对信息") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    Button("取消配对码") { sync.cancelInvitation() }
                }
            }
        }
    }

    private static func qrCode(_ data: Data) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func refreshAddresses() {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return }
        defer { freeifaddrs(first) }
        var addresses: [String] = []
        var next = first
        while let current = next {
            let interface = current.pointee
            next = interface.ifa_next
            guard let endpoint = interface.ifa_addr, endpoint.pointee.sa_family == UInt8(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP) != 0, interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(endpoint, socklen_t(endpoint.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if !ip.hasPrefix("169.254."), !addresses.contains(ip) { addresses.append(ip) }
        }
        availableAddresses = addresses
        if !addresses.contains(address) { address = addresses.first ?? "" }
    }

    private func exportCertificate() {
        guard let source = sync.certificate else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "leonbook-ca.cer"
        panel.allowedContentTypes = [UTType(filenameExtension: "cer") ?? .data]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            try Data(contentsOf: URL(fileURLWithPath: source)).write(to: target, options: .atomic)
            exportError = nil
        } catch {
            exportError = error.localizedDescription
        }
    }
}
