import Foundation
import Security

/// Tunnel credentials in the login Keychain, one item per tunnel name. The app
/// reads them and sends them to the service when a tunnel connects; the
/// service keeps them in memory only. (The Keychain item belongs to this app's
/// code signature: after an update macOS may ask once to allow access again.)
enum TunnelKeychain {
    private static let service = "io.github.aliraghebi.splitroute.tunnel"

    private static func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
    }

    static func load(_ name: String) -> TunnelSecrets? {
        var q = query(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(TunnelSecrets.self, from: data)
    }

    @discardableResult
    static func save(_ name: String, _ s: TunnelSecrets) -> Bool {
        guard let data = try? JSONEncoder().encode(s) else { return false }
        let update = [kSecValueData as String: data]
        let st = SecItemUpdate(query(name) as CFDictionary, update as CFDictionary)
        if st == errSecSuccess { return true }
        var add = query(name)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ name: String) { SecItemDelete(query(name) as CFDictionary) }

    static func rename(_ old: String, to new: String) {
        guard let s = load(old) else { return }
        if save(new, s) { delete(old) }
    }
}
