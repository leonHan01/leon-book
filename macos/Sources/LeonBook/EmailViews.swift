import SwiftUI

struct EmailSettingsPanel: View {
    let account: EmailAccountStore
    @State private var configuration = EmailConfiguration()
    @State private var password = ""
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("SMTP 服务器", text: $configuration.host)
            HStack {
                Picker("连接加密", selection: Binding(get: { configuration.security }, set: { mode in
                    configuration.security = mode
                    if configuration.port == "465" || configuration.port == "587" {
                        configuration.port = mode == .tls ? "465" : "587"
                    }
                })) {
                    ForEach(EmailConfiguration.SecurityMode.allCases, id: \.self) { mode in Text(mode.label).tag(mode) }
                }
                TextField("端口", text: $configuration.port).frame(width: 100)
            }
            TextField("SMTP 登录账号", text: $configuration.username)
            TextField("发件邮箱", text: $configuration.sender)
            SecureField("密码或授权码（留空保留已保存值）", text: $password)
            TextField("默认收件人（可选）", text: $configuration.defaultRecipient)
            Text("请使用邮箱服务商提供的 SMTP 地址及授权码。配置仅用于当前工作空间，密码保存在本机钥匙串。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("保存邮件设置") {
                    do {
                        try account.save(configuration, password: password)
                        configuration = account.load(); password = ""; failed = false
                        message = NativeLocalization.text("邮件设置已保存。")
                    } catch { failed = true; message = error.localizedDescription }
                }
                Button("清除邮件设置", role: .destructive) {
                    do {
                        try account.forget(); configuration = .init(); password = ""; failed = false
                        message = NativeLocalization.text("邮件设置和授权码已清除。")
                    } catch { failed = true; message = error.localizedDescription }
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(failed ? Color.red : Color.secondary).textSelection(.enabled) }
        }
        .onAppear { configuration = account.load() }
    }
}

/// Attach this to a stable container, outside a Menu, so its sheet survives menu dismissal.
struct EmailComposerPresenter: ViewModifier {
    @Binding var content: EmailContent?
    let store: LocalBlogStore

    func body(content view: Content) -> some View {
        view.sheet(item: $content) { draft in EmailComposerSheet(content: draft, store: store) }
    }
}

struct EmailContentButton: View {
    let content: () -> EmailContent
    let store: LocalBlogStore
    var compact = false
    @State private var draft: EmailContent?

    var body: some View {
        Button { draft = content() } label: {
            if compact { NativeIcon.image("envelope", size: 14).frame(width: 30, height: 30).contentShape(Rectangle()) }
            else { Label("发送邮件…", nativeIcon: "envelope") }
        }
        .help("发送邮件…").accessibilityLabel("发送邮件…")
        .modifier(EmailComposerPresenter(content: $draft, store: store))
    }
}

struct EmailComposerSheet: View {
    let content: EmailContent
    let store: LocalBlogStore
    private let account: EmailAccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var recipient: String
    @State private var subject: String
    @State private var bodyText: String
    @State private var includesMedia = true
    @State private var showsSettings = false
    @State private var isSending = false
    @State private var sent = false
    @State private var errorMessage: String?
    @State private var sender: String

    init(content: EmailContent, store: LocalBlogStore) {
        self.content = content; self.store = store
        let account = EmailAccountStore(scope: EmailAccountStore.scope(for: store.rootURL))
        self.account = account
        let settings = account.load()
        _recipient = State(initialValue: settings.defaultRecipient)
        _sender = State(initialValue: settings.sender)
        _subject = State(initialValue: String(content.subject.components(separatedBy: .newlines).joined(separator: " ").prefix(500)))
        _bodyText = State(initialValue: content.editableBody)
        _showsSettings = State(initialValue: settings.host.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("发送邮件", nativeIcon: "envelope").font(.title2.weight(.semibold))
                Spacer()
                Button("邮件设置") { showsSettings = true }.disabled(isSending || sent)
            }
            if sent {
                Spacer()
                Label("邮件已提交至 SMTP 服务器", nativeIcon: "checkmark.circle.fill").foregroundStyle(.green)
                Text("请在收件箱查看邮件，实际送达由邮箱服务商处理。") .foregroundStyle(.secondary)
                Spacer()
            } else {
                Text(sender.isEmpty ? NativeLocalization.text("请先配置发件邮箱。") : NativeLocalization.text("发件人：\(sender)"))
                    .font(.caption).foregroundStyle(.secondary)
                TextField("收件人（多个邮箱用逗号分隔）", text: $recipient).textFieldStyle(.roundedBorder)
                TextField("邮件主题", text: $subject).textFieldStyle(.roundedBorder)
                Text("邮件正文（纯文本，可编辑）").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $bodyText).font(.body).border(Color.secondary.opacity(0.2))
                if !content.localMedia.isEmpty {
                    Toggle(NativeLocalization.text("附带媒体文件（\(content.localMedia.count) 个）"), isOn: $includesMedia)
                    Text(content.localMedia.map(\.name).joined(separator: "、"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2).help(content.localMedia.map(\.name).joined(separator: "\n"))
                }
                Text("邮件总大小上限为 25 MB；远程媒体以链接发送。") .font(.caption).foregroundStyle(.secondary)
                if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            }
            Divider()
            HStack {
                if isSending { ProgressView().controlSize(.small); Text("正在发送邮件…").foregroundStyle(.secondary) }
                Spacer()
                Button(sent ? "完成" : "取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSending)
                if !sent {
                    Button("发送邮件") { send() }.nativePrimaryButton()
                        .disabled(isSending || recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(24).frame(width: 640, height: 590)
        .disabled(isSending)
        .interactiveDismissDisabled(isSending)
        .sheet(isPresented: $showsSettings, onDismiss: {
            let settings = account.load(); sender = settings.sender
            if recipient.isEmpty { recipient = settings.defaultRecipient }
        }) {
            VStack(alignment: .leading) {
                Text("邮件设置").font(.title2.weight(.semibold)).padding([.top, .horizontal], 24)
                Form { EmailSettingsPanel(account: account) }.formStyle(.grouped)
                HStack { Spacer(); Button("完成") { showsSettings = false }.keyboardShortcut(.cancelAction) }.padding(20)
            }.frame(width: 560, height: 510)
        }
    }

    private func send() {
        guard !isSending, !sent else { return }
        errorMessage = nil
        do {
            let configuration = try account.load().validated()
            let recipients = try EmailConfiguration.recipients(recipient)
            let password = try account.password(for: configuration)
            let subject = subject, body = bodyText, includesMedia = includesMedia
            isSending = true
            Task {
                defer { isSending = false }
                do {
                    let attachments = includesMedia ? try await content.attachments(store: store) : []
                    let message = try await Task.detached(priority: .userInitiated) {
                        try EmailMIME.message(sender: configuration.sender, recipients: recipients, subject: subject, body: body, attachments: attachments)
                    }.value
                    try await EmailSMTPTransport.send(settings: configuration, password: password, recipients: recipients, message: message)
                    sent = true
                } catch { errorMessage = error.localizedDescription }
            }
        } catch { errorMessage = error.localizedDescription }
    }
}
