import Foundation

/// Three-field LLM configuration for todo parsing (OpenAI-compatible API).
/// Stored in UserDefaults as JSON data/string without Keychain authorization prompts.
struct TodoLLMConfig: Codable, Equatable {
    var baseURL: String
    var apiKey: String
    var model: String

    static let empty = TodoLLMConfig(baseURL: "", apiKey: "", model: "")
}

@MainActor
final class TodoSettingsStore {
    static let shared = TodoSettingsStore()

    private let defaults: UserDefaults
    private let key: String
    private var cachedConfig: TodoLLMConfig?

    init(defaults: UserDefaults = .standard, key: String = "CollectionBox.todoLLMConfig") {
        self.defaults = defaults
        self.key = key
    }

    var config: TodoLLMConfig {
        get {
            if let cached = cachedConfig { return cached }
            let loaded = load() ?? .empty
            cachedConfig = loaded
            return loaded
        }
        set {
            cachedConfig = newValue
            save(newValue)
        }
    }

    var isConfigured: Bool {
        let c = config
        return !c.baseURL.isEmpty && !c.apiKey.isEmpty && !c.model.isEmpty
    }

    private func load() -> TodoLLMConfig? {
        if let data = defaults.data(forKey: key) {
            if let decoded = try? JSONDecoder().decode(TodoLLMConfig.self, from: data) {
                return decoded
            }
        }
        if let str = defaults.string(forKey: key), let data = str.data(using: .utf8) {
            if let decoded = try? JSONDecoder().decode(TodoLLMConfig.self, from: data) {
                return decoded
            }
        }
        return nil
    }

    private func save(_ config: TodoLLMConfig) {
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: key)
        }
    }

    func clear() {
        cachedConfig = .empty
        defaults.removeObject(forKey: key)
    }
}