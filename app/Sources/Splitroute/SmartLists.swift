import Foundation

/// A named set of servers Smart Select can choose from (the dropdown on the Servers page). Kept in the app's preferences:
/// nothing about it changes what the engine runs. A server is a database row ID, which is never reused.
struct SmartList: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var servers: [Int64] = []
}

enum SmartLists {
    static func load(_ defaults: UserDefaults = .standard) -> [SmartList] { decode(defaults.data(forKey: Prefs.smartLists)) }

    static func decode(_ data: Data?) -> [SmartList] { data.flatMap { try? JSONDecoder().decode([SmartList].self, from: $0) } ?? [] }

    static func save(_ lists: [SmartList], _ defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(lists), forKey: Prefs.smartLists)
    }

    /// The lists without servers that are gone: a list keeps the rest.
    static func removing(missingFrom existing: Set<Int64>, in lists: [SmartList]) -> [SmartList] {
        lists.map { var l = $0; l.servers.removeAll { !existing.contains($0) }; return l }
    }

    /// A list's name, tidied; refused when empty or already used (ignoring case) by another list.
    static func validName(_ raw: String, among lists: [SmartList], excluding id: UUID? = nil) throws -> String {
        let name = Store.cleanName(raw, fallback: "")
        guard !name.isEmpty else { throw StoreError("A list needs a name.") }
        if lists.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw StoreError("A list named \"\(name)\" already exists.")
        }
        return name
    }

    /// The `smartScope` value that selects a list.
    static func scopeValue(_ id: UUID) -> String { "list:\(id.uuidString)" }

    static func listID(in scope: String) -> UUID? {
        scope.hasPrefix("list:") ? UUID(uuidString: String(scope.dropFirst(5))) : nil
    }
}
