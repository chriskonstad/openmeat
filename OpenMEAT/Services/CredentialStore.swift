import Foundation
import Security
import ThermoWorksCloud

/// What we persist to resume a session without asking for the password again.
struct StoredSession: Codable, Equatable {
    var credentials: AuthCredentials
    var project: ThermoWorksProject
}

protocol CredentialStoring: Sendable {
    func load() -> StoredSession?
    func save(_ session: StoredSession)
    func clear()
}

/// Keychain-backed (generic password, this device only).
struct KeychainCredentialStore: CredentialStoring {
    var service = "org.openmeat.OpenMEAT.thermoworks"
    var account = "session"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() -> StoredSession? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    func save(_ session: StoredSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var session: StoredSession?

    init(_ session: StoredSession? = nil) { self.session = session }

    func load() -> StoredSession? { lock.withLock { session } }
    func save(_ session: StoredSession) { lock.withLock { self.session = session } }
    func clear() { lock.withLock { session = nil } }
}
