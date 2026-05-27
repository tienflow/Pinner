import Foundation
import Observation

@Observable
public final class OTPStore {
    public var accounts: [OTPAccount] = []
    private let persistenceKey = "CollectionBox.otpAccounts"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    public func addAccount(_ account: OTPAccount) {
        accounts.append(account)
        save()
    }

    public func removeAccount(_ id: UUID) {
        accounts.removeAll { $0.id == id }
        save()
    }

    /// Generate the current TOTP code for an account.
    public func code(for account: OTPAccount, at date: Date = Date()) -> String? {
        OTPService.generateCode(secret: account.secret, at: date)
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(data, forKey: persistenceKey)
    }

    private func load() {
        guard let data = defaults.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([OTPAccount].self, from: data) else { return }
        accounts = decoded
    }
}
