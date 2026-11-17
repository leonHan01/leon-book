import CryptoKit
import Foundation
import Security

enum AIReadingProvider: String, Codable, CaseIterable, Identifiable {
    case deepSeek, openAI
    var id: String { rawValue }
    var title: String { self == .deepSeek ? "DeepSeek" : "OpenAI" }
    var defaultModel: String { self == .deepSeek ? "deepseek-flash" : "gpt-6-astra" }
    var baseURL: URL {
        URL(string: self == .deepSeek ? "https://api.deepseek.com" : "https://api.openai.com/v1")!
    }
}

struct AIReadingConfiguration: Codable, Equatable {
    var provider: AIReadingProvider = .deepSeek
    var openAIModel = "gpt-6-astra"
    var model: String { provider == .deepSeek ? "deepseek-flash" : openAIModel.trimmingCharacters(in: .whitespacesAndNewlines) }

    func validated() throws -> Self {
        guard !model.isEmpty, model.utf8.count <= 200,
              !model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw AIReadingError.invalidModel
        }
        return self
    }
}

enum AIReadingError: LocalizedError {
    case missingKey, invalidModel, invalidResponse, contextTooLarge, sourceChanged
    case service(Int, String)
    case keychain(OSStatus)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: return NativeLocalization.text("请先在 AI 设置中保存当前服务的 API Key。")
        case .invalidModel: return NativeLocalization.text("请选择一个可用的 OpenAI 模型。")
        case .invalidResponse: return NativeLocalization.text("AI 未返回完整回复，请重试。")
        case .contextTooLarge: return NativeLocalization.text("正文与聊天记录过长，请开启新对话或缩短内容后再发送。")
        case .sourceChanged: return NativeLocalization.text("工作空间已切换，请在原文章或问题中重新操作。")
        case let .service(code, message): return NativeLocalization.text("AI 请求失败（\(code)）：\(message)")
        case let .keychain(code): return NativeLocalization.text("无法访问 AI 密钥（\(code)）。")
        case let .message(message): return message
        }
    }
}

/// Settings contain no credentials. Each provider's key stays in the local Keychain.
struct AIReadingAccountStore {
    let scope: String
    var defaults: UserDefaults = .standard
    init(root: URL, defaults: UserDefaults = .standard) {
        scope = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        self.defaults = defaults
    }
    private var settingsKey: String { "leonBook.aiReading.\(scope)" }
    func load() -> AIReadingConfiguration {
        guard let data = defaults.data(forKey: settingsKey), let value = try? JSONDecoder().decode(AIReadingConfiguration.self, from: data) else { return .init() }
        return value
    }
    func saveConfiguration(_ config: AIReadingConfiguration) throws {
        defaults.set(try JSONEncoder().encode(config.validated()), forKey: settingsKey)
    }
    func loadOpenAIModels() -> [String]? {
        defaults.stringArray(forKey: settingsKey + ".openAIModels")
    }
    func saveOpenAIModels(_ models: [String]) {
        defaults.set(Array(Set(models)).sorted(), forKey: settingsKey + ".openAIModels")
    }
    private func query(_ provider: AIReadingProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "leon-book.ai-reading",
         kSecAttrAccount as String: scope + ":" + provider.rawValue]
    }
    func key(for provider: AIReadingProvider) throws -> String {
        var query = query(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw AIReadingError.missingKey }
        guard status == errSecSuccess else { throw AIReadingError.keychain(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw AIReadingError.missingKey }
        return value
    }
    func saveKey(_ key: String, for provider: AIReadingProvider) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 4096,
              !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }) else { throw AIReadingError.missingKey }
        let query = query(provider), values = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(values) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AIReadingError.keychain(status) }
    }
    func forgetKey(for provider: AIReadingProvider) throws {
        let status = SecItemDelete(query(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AIReadingError.keychain(status) }
    }
}

struct AIReadingContext: Equatable {
    enum Kind: String, Codable { case article, question }
    let kind: Kind
    let id: String
    let title: String
    let body: String
    var identity: String { kind.rawValue + ":" + id }
    var exportLimit: Int { kind == .article ? 2_000 : 10_000 }
    var exportTitle: String { kind == .article ? "转为文章评论" : "转为问题回答" }

    static func article(_ article: NativeArticle) -> Self {
        .init(kind: .article, id: article.slug, title: article.title,
              body: RichArticleDocument.plainText(RichArticleDocument.convertingLegacyBody(article.body)))
    }
    static func question(_ question: NativeQuestion) -> Self {
        .init(kind: .question, id: question.id, title: question.title, body: question.body)
    }
    var input: String {
        // JSON quoting keeps source material structurally separate from user instructions.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try! encoder.encode(["kind": kind.rawValue, "title": title, "body": body])
        return String(decoding: data, as: UTF8.self)
    }
}

struct AIReadingMessage: Codable, Equatable, Identifiable {
    enum Role: String, Codable { case user, assistant }
    let id: String
    let role: Role
    let content: String
    let provider: AIReadingProvider
    let model: String
    let createdAt: String
    var isComplete: Bool

    init(id: String = UUID().uuidString, role: Role, content: String, provider: AIReadingProvider, model: String,
         createdAt: String = NativeTimestamp.string(from: Date()), isComplete: Bool = true) {
        self.id = id; self.role = role; self.content = content; self.provider = provider; self.model = model
        self.createdAt = createdAt; self.isComplete = isComplete
    }
    static func transcript(_ messages: [Self]) -> String {
        messages.map { message in
            let name = message.role == .user ? NativeLocalization.text("我") : "AI (\(message.provider.title) · \(message.model))"
            return "\(name)\n\(message.content)"
        }.joined(separator: "\n\n")
    }
}
