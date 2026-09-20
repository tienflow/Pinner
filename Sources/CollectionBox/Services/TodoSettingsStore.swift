import Foundation
import Security

/// Three-field LLM configuration for todo parsing (OpenAI-compatible API).
/// Stored in the login Keychain as a single JSON generic-password item.
struct TodoLLMConfig: Codable, Equatable {
    var baseURL: String
    var apiKey: String
    var model: String

    static let empty = TodoLLMConfig(baseURL: "", apiKey: "", model: "")
}

@MainActor
final class TodoSettingsStore {
    static let shared = TodoSettingsStore()

    private let service = "pinner.todo.llm.config"
    private let account = "pinner.todo.llm.config"

    private init() {}

    var config: TodoLLMConfig {
        get { load() ?? .empty }
        set { save(newValue) }
    }

    var isConfigured: Bool {
        let c = config
        return !c.baseURL.isEmpty && !c.apiKey.isEmpty && !c.model.isEmpty
    }

    // MARK: - Keychain

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Ad-hoc signed builds: use the classic file keychain rather than
            // the data-protection keychain that expects an application-identifier
            // entitlement.
            kSecUseDataProtectionKeychain as String: false,
        ]
    }

    private func load() -> TodoLLMConfig? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(TodoLLMConfig.self, from: data)
    }

    private func save(_ config: TodoLLMConfig) {
        // Delete-then-add: after an ad-hoc re-sign the old item's ACL may no
        // longer match (errSecItemNotFound on read, errSecDuplicateItem on
        // add), so a plain update is not reliable.
        SecItemDelete(baseQuery() as CFDictionary)
        guard let data = try? JSONEncoder().encode(config) else { return }
        var query = baseQuery()
        query[kSecValueData as String] = data
        SecItemAdd(query as CFDictionary, nil)
    }

    func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}