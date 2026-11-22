import Foundation
import Security

enum Keychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.leon-book.chat",
         kSecAttrAccount as String: "access-token"]
    }
    // Security may wait for the system's keychain authorization after an app update.
    // Never make the main/UI thread wait for that prompt.
    static func read() async -> String {
        await Task.detached { readStored() }.value
    }
    private static func readStored() -> String {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ token: String) async throws {
        try await Task.detached { try saveStored(token) }.value
    }
    private static func saveStored(_ token: String) throws {
        let data = Data(token.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ClientError.message("无法保存到系统钥匙串（\(status)）。") }
    }
}
