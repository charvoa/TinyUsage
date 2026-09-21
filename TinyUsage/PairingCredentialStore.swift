import Foundation
import Security
import TinyUsageDomain

struct PairingCredentialStore: Sendable {
    private let service = TinyUsageConstants.keychainNamespace + ".pairing"
    private let activeAccount = "active-collector"
    private let pendingAccount = "pending-collector"

    func save(_ payload: PairingPayload) throws {
        try write(payload, account: pendingAccount)
    }

    func promotePending() throws {
        guard let pending = try load(account: pendingAccount) else { return }
        try write(pending, account: activeAccount)
        try delete(account: pendingAccount)
    }

    func hasPending(identity: String) -> Bool { (try? load(account: pendingAccount))?.pskIdentity == identity }

    private func write(_ payload: PairingPayload, account: String) throws {
        try delete(account: account)
        let data = try JSONEncoder.tinyUsage.encode(payload)
        let status = SecItemAdd([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, kSecValueData as String: data] as CFDictionary, nil)
        guard status == errSecSuccess else { throw SyncProtocolError.unauthorized }
    }

    func load() throws -> PairingPayload? {
        try load(account: pendingAccount) ?? load(account: activeAccount)
    }

    private func load(account: String) throws -> PairingPayload? {
        try load(account: account, service: service) ?? load(account: account, service: TinyUsageConstants.legacyPairingService)
    }

    private func load(account: String, service: String) throws -> PairingPayload? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SyncProtocolError.unauthorized }
        return try JSONDecoder.tinyUsage.decode(PairingPayload.self, from: data)
    }

    func delete() throws {
        try delete(account: pendingAccount)
        try delete(account: activeAccount)
    }

    private func delete(account: String) throws {
        for candidate in [service, TinyUsageConstants.legacyPairingService] {
            let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: candidate, kSecAttrAccount as String: account] as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SyncProtocolError.unauthorized }
        }
    }
}
