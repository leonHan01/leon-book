import CryptoKit
import Foundation
import Security

enum EmailError: LocalizedError {
    case invalidSettings, invalidRecipients, invalidSubject, missingPassword, oversized, missingAttachment(String)
    case keychain(OSStatus), delivery(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidSettings: return NativeLocalization.text("请检查 SMTP 服务器、端口、登录账号和发件邮箱。")
        case .invalidRecipients: return NativeLocalization.text("请输入有效邮箱，多个收件人用逗号或分号分隔，最多 50 位。")
        case .invalidSubject: return NativeLocalization.text("邮件主题不能为空、换行或超过 500 个字符。")
        case .missingPassword: return NativeLocalization.text("请先在邮件设置中保存邮箱密码或授权码。")
        case .oversized: return NativeLocalization.text("邮件编码后超过 25 MB，请减少正文或取消附带媒体。")
        case .missingAttachment(let name): return NativeLocalization.text("无法读取邮件附件：\(name)")
        case .keychain(let status): return NativeLocalization.text("无法访问 macOS 钥匙串（\(status)），请解锁钥匙串后重试。")
        case .delivery(67): return NativeLocalization.text("SMTP 登录失败，请检查账号、授权码及邮箱的 SMTP 服务是否已开启。")
        case .delivery(60), .delivery(35): return NativeLocalization.text("SMTP 安全连接失败，请检查服务器、端口和加密方式。")
        case .delivery(6), .delivery(7): return NativeLocalization.text("无法连接 SMTP 服务器，请检查网络、服务器地址和端口。")
        case .delivery(let code): return NativeLocalization.text("邮件发送未确认（\(code)）。请先检查收件箱，避免重复发送，再检查 SMTP 设置。")
        }
    }
}

struct EmailConfiguration: Codable, Equatable {
    enum SecurityMode: String, Codable, CaseIterable {
        case tls, startTLS
        var label: String { self == .tls ? "TLS (465)" : "STARTTLS (587)" }
    }
    var host = ""
    var port = "465"
    var security = SecurityMode.tls
    var username = ""
    var sender = ""
    var defaultRecipient = ""

    func validated() throws -> Self {
        var value = self
        value.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        value.port = port.trimmingCharacters(in: .whitespacesAndNewlines)
        value.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        value.sender = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.host.isEmpty, value.host.utf8.count <= 253,
              value.host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                  $0.range(of: #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"#, options: .regularExpression) != nil
              }), let port = Int(value.port), (1...65535).contains(port),
              !value.username.isEmpty, value.username.utf8.count <= 320,
              !value.username.contains(":"), !Self.hasControls(value.username),
              Self.isMailbox(value.sender) else { throw EmailError.invalidSettings }
        if !defaultRecipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            value.defaultRecipient = try Self.recipients(defaultRecipient).joined(separator: ", ")
        } else { value.defaultRecipient = "" }
        return value
    }

    static func hasControls(_ text: String) -> Bool { text.rangeOfCharacter(from: .controlCharacters) != nil }

    static func isMailbox(_ value: String) -> Bool {
        guard value.utf8.count <= 254, !hasControls(value),
              value.range(of: #"^[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$"#, options: .regularExpression) != nil else { return false }
        return value.split(separator: "@")[0].utf8.count <= 64
    }

    static func recipients(_ input: String) throws -> [String] {
        guard !hasControls(input) else { throw EmailError.invalidRecipients }
        let values = input.components(separatedBy: CharacterSet(charactersIn: ",;，；"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !values.isEmpty, values.count <= 50, values.allSatisfy(isMailbox) else { throw EmailError.invalidRecipients }
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }
}

/// Only non-secret settings enter UserDefaults. Credentials are isolated by workspace and endpoint.
struct EmailAccountStore {
    let scope: String
    var defaults: UserDefaults = .standard
    private var defaultsKey: String { "leonbook.email." + scope }
    static func scope(for root: URL) -> String { digest(root.standardizedFileURL.path) }
    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func load() -> EmailConfiguration {
        guard let data = defaults.data(forKey: defaultsKey), let config = try? JSONDecoder().decode(EmailConfiguration.self, from: data) else { return .init() }
        return config
    }
    private func query(_ config: EmailConfiguration) -> [String: Any] {
        let identity = [scope, config.host, config.port, config.security.rawValue, config.username, config.sender].joined(separator: "\n")
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "leon-book.smtp",
                kSecAttrAccount as String: Self.digest(identity)]
    }
    func password(for config: EmailConfiguration) throws -> String {
        var query = query(config)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw EmailError.missingPassword }
        guard status == errSecSuccess else { throw EmailError.keychain(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw EmailError.missingPassword }
        return value
    }
    func save(_ configuration: EmailConfiguration, password: String) throws {
        let config = try configuration.validated()
        if password.isEmpty { _ = try self.password(for: config) }
        else {
            guard password.utf8.count <= 4096, !EmailConfiguration.hasControls(password) else { throw EmailError.missingPassword }
            let query = query(config)
            let values = [kSecValueData as String: Data(password.utf8)]
            var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
            if status == errSecItemNotFound {
                var item = query.merging(values) { _, new in new }
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw EmailError.keychain(status) }
        }
        let previous = load()
        defaults.set(try JSONEncoder().encode(config), forKey: defaultsKey)
        if query(previous)[kSecAttrAccount as String] as? String != query(config)[kSecAttrAccount as String] as? String {
            SecItemDelete(query(previous) as CFDictionary)
        }
    }
    func forget() throws {
        let status = SecItemDelete(query(load()) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw EmailError.keychain(status) }
        defaults.removeObject(forKey: defaultsKey)
    }
}

struct EmailAttachment {
    let name: String
    let data: Data
}

enum EmailMIME {
    static let maximumBytes = 25 * 1024 * 1024

    static func message(sender: String, recipients: [String], subject: String, body: String, attachments: [EmailAttachment], date: Date = Date()) throws -> Data {
        guard EmailConfiguration.isMailbox(sender) else { throw EmailError.invalidSettings }
        guard !recipients.isEmpty, recipients.count <= 50, recipients.allSatisfy(EmailConfiguration.isMailbox) else { throw EmailError.invalidRecipients }
        guard !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, subject.count <= 500,
              !EmailConfiguration.hasControls(subject) else { throw EmailError.invalidSubject }
        guard body.utf8.count <= maximumBytes, attachments.reduce(body.utf8.count, { $0 + $1.data.count }) <= maximumBytes else { throw EmailError.oversized }
        let boundary = "leonbook-" + UUID().uuidString
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        var lines = ["From: \(sender)", "To: " + recipients.joined(separator: ",\r\n "), "Subject: " + encodedHeader(subject),
                     "Date: \(formatter.string(from: date))", "Message-ID: <\(UUID().uuidString)@\(sender.split(separator: "@").last!)>",
                     "MIME-Version: 1.0", "Content-Type: multipart/mixed; boundary=\"\(boundary)\"", "",
                     "--\(boundary)", "Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: base64", "", base64(Data(body.utf8))]
        for attachment in attachments {
            let name = ArticleExportDocument.filename(attachment.name, fallback: "attachment")
            lines += ["--\(boundary)", "Content-Type: application/octet-stream",
                      "Content-Disposition: attachment;\r\n " + encodedFilename(name),
                      "Content-Transfer-Encoding: base64", "", base64(attachment.data)]
        }
        lines += ["--\(boundary)--", ""]
        let data = Data(lines.joined(separator: "\r\n").utf8)
        guard data.count <= maximumBytes else { throw EmailError.oversized }
        return data
    }

    private static func base64(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }
    static func encodedHeader(_ value: String) -> String {
        var parts: [String] = [], chunk = ""
        for scalar in value.unicodeScalars {
            let next = String(scalar)
            if chunk.utf8.count + next.utf8.count > 42 {
                parts.append("=?UTF-8?B?\(Data(chunk.utf8).base64EncodedString())?="); chunk = ""
            }
            chunk += next
        }
        if !chunk.isEmpty { parts.append("=?UTF-8?B?\(Data(chunk.utf8).base64EncodedString())?=") }
        return parts.joined(separator: "\r\n ")
    }

    /// RFC 2231 continuations preserve Unicode filenames without overlong header lines.
    private static func encodedFilename(_ value: String) -> String {
        let bytes = Array(value.utf8)
        return stride(from: 0, to: bytes.count, by: 15).enumerated().map { index, start in
            let segment = bytes[start..<min(start + 15, bytes.count)].map { String(format: "%%%02X", $0) }.joined()
            return "filename*\(index)*=" + (index == 0 ? "utf-8''" : "") + segment
        }.joined(separator: ";\r\n ")
    }
}

enum EmailSMTPTransport {
    /// Config travels through stdin, never shell interpolation, process arguments, or logs.
    static func configuration(_ settings: EmailConfiguration, password: String, recipients: [String], messageFile: URL) throws -> String {
        let settings = try settings.validated()
        guard !password.isEmpty, password.utf8.count <= 4096, !EmailConfiguration.hasControls(password) else { throw EmailError.missingPassword }
        guard !recipients.isEmpty, recipients.count <= 50, recipients.allSatisfy(EmailConfiguration.isMailbox) else { throw EmailError.invalidRecipients }
        func quoted(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n") + "\""
        }
        let scheme = settings.security == .tls ? "smtps" : "smtp"
        return (["url = " + quoted("\(scheme)://\(settings.host):\(settings.port)"),
                 "user = " + quoted(settings.username + ":" + password), "mail-from = " + quoted(settings.sender),
                 "upload-file = " + quoted(messageFile.path)] + recipients.map { "mail-rcpt = " + quoted($0) }).joined(separator: "\n") + "\n"
    }

    static func send(settings: EmailConfiguration, password: String, recipients: [String], message: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try deliver(settings: settings, password: password, recipients: recipients, message: message); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func deliver(settings: EmailConfiguration, password: String, recipients: [String], message: Data) throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("leonbook-email-" + UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: directory) }
        let file = directory.appendingPathComponent("message.eml")
        try message.write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let config = try configuration(settings, password: password, recipients: recipients, messageFile: file)
        let process = Process(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        // -q MUST be first: ignore ~/.curlrc. Require TLS and system certificate validation.
        process.arguments = ["-q", "--silent", "--ssl-reqd", "--tlsv1.2", "--proto", "=smtp,smtps",
                             "--connect-timeout", "20", "--max-time", "120", "--config", "-"]
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        do { try input.fileHandleForWriting.write(contentsOf: Data(config.utf8)); try input.fileHandleForWriting.close() }
        catch { try? input.fileHandleForWriting.close(); process.terminate(); process.waitUntilExit(); throw EmailError.delivery(-1) }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw EmailError.delivery(process.terminationStatus) }
    }
}
