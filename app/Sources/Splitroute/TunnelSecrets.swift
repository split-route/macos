import Foundation
import Security

/// Tunnel credentials, one entry per tunnel name. The app reads them and sends them to the service with the
/// snapshot; the service keeps them in memory only.
///
/// For now they are 0600 files under Application Support (`credentials/`), like the tunnels' profiles. The Keychain
/// code below is kept, off: an ad-hoc signed app has a new signature with every build, and macOS then asks the user
/// again for every item. It goes back on (`useKeychain`) when the app is signed with a developer ID, the same step
/// that turns the service into a Network Extension (see CLAUDE.md, "Planned"). Anything saved in the Keychain by an
/// earlier build is not read: the user is asked once more.
///
/// Each item is read once per run and the answer kept in memory, a "not found" or a denied prompt included:
/// the snapshot, the rows and the sheets ask often, and every read of an item this build isn't allowed on is a prompt.
enum TunnelKeychain {
    /// Flip when the app has a stable code signature. Moving saved files into the Keychain then is a one-time step.
    static let useKeychain = false
    private static let service = "io.github.aliraghebi.splitroute.tunnel"
    private static let lock = NSLock()
    private static var cache: [String: TunnelSecrets?] = [:]

    private static func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
    }

    static func load(_ name: String) -> TunnelSecrets? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[name] { return hit }
        let s = read(name)
        cache[name] = .some(s)
        return s
    }

    private static func file(_ name: String) -> URL {
        AppFiles.standard.root.appendingPathComponent("credentials").appendingPathComponent(AppFiles.sha256(Data(name.utf8)) + ".json")
    }

    private static func read(_ name: String) -> TunnelSecrets? {
        if !useKeychain {
            guard let d = try? Data(contentsOf: file(name)) else { return nil }
            return try? JSONDecoder().decode(TunnelSecrets.self, from: d)
        }
        var q = query(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(TunnelSecrets.self, from: data)
    }

    @discardableResult
    static func save(_ name: String, _ s: TunnelSecrets) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(s) else { return false }
        let update = [kSecValueData as String: data]
        if !useKeychain {
            let ok = (try? AppFiles.standard.writePrivate(data, to: file(name))) != nil
            if ok { cache[name] = .some(s) }
            return ok
        }
        var ok = SecItemUpdate(query(name) as CFDictionary, update as CFDictionary) == errSecSuccess
        if !ok {
            var add = query(name)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            ok = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        if ok { cache[name] = .some(s) } // what the user just typed needs no read back
        return ok
    }

    static func delete(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        if useKeychain { SecItemDelete(query(name) as CFDictionary) } else { try? FileManager.default.removeItem(at: file(name)) }
        cache[name] = .some(nil)
    }

    static func rename(_ old: String, to new: String) {
        guard let s = load(old) else { return }
        if save(new, s) { delete(old) }
    }
}
