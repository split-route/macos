import Foundation

// What the app shows and stores: lists, tunnels and their state. The database owns them; the daemon only runs them.

enum Action: String, Codable, CaseIterable, Identifiable {
    /// "none": the list is kept but not applied, so it can be switched on later without downloading or typing it again.
    case none, direct, block, tunnel
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "No Action"
        case .direct: return "Direct"
        case .block: return "Block"
        case .tunnel: return "Server"
        }
    }

    /// "vpn" was this action's name before it became "tunnel"; a service that
    /// hasn't restarted since the update still sends it.
    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let a = Action(rawValue: s == "vpn" ? "tunnel" : s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown action \(s)"))
        }
        self = a
    }
}

struct RouteList: Codable, Hashable, Identifiable {
    var name: String
    var action: Action
    /// Action tunnel only: the tunnel's name; nil means the default tunnel.
    var tunnel: String?
    var custom = false
    var entries: [String] = []
    /// A short note the user gave a custom list or an import; shown under its title. Nil: none.
    var description: String?
    /// Set for a list downloaded from a URL. Its entries live in the daemon's
    /// database, never in the config. Must survive set_config round trips.
    var importSource: ImportSource?
    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, action, tunnel, custom, entries, description, importSource = "import"
    }

    init(name: String, action: Action, custom: Bool = false, entries: [String] = []) {
        self.name = name
        self.action = action
        self.custom = custom
        self.entries = entries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        action = try c.decode(Action.self, forKey: .action)
        tunnel = try c.decodeIfPresent(String.self, forKey: .tunnel)
        custom = try c.decodeIfPresent(Bool.self, forKey: .custom) ?? false
        entries = try c.decodeIfPresent([String].self, forKey: .entries) ?? []
        description = try c.decodeIfPresent(String.self, forKey: .description)
        importSource = try c.decodeIfPresent(ImportSource.self, forKey: .importSource)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(action, forKey: .action)
        try c.encodeIfPresent(tunnel, forKey: .tunnel)
        if custom { try c.encode(custom, forKey: .custom) }
        if !entries.isEmpty { try c.encode(entries, forKey: .entries) }
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(importSource, forKey: .importSource)
    }
}

struct ImportSource: Codable, Hashable {
    var url: String
    var refreshHours: Int?

    enum CodingKeys: String, CodingKey {
        case url, refreshHours = "refresh_hours"
    }
}

struct ImportStatus: Decodable, Equatable {
    var name: String
    var url: String
    var entries: Int
    var skipped: Int?
    var fetchedAt: String?
    var checkedAt: String?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case name, url, entries, skipped, fetchedAt = "fetched_at", checkedAt = "checked_at", error
    }
}

struct Config: Codable, Equatable {
    var baseURL: String?
    var disabled = false
    var lists: [RouteList] = []
    /// Where traffic no list matches goes: direct, block or a tunnel (`finalTunnel` nil: the selected one).
    var finalAction: Action = .tunnel
    var finalTunnel: String?
    /// Refuse QUIC no list matched (browsers then use TCP, where names can be read).
    var blockQUIC = true

    enum CodingKeys: String, CodingKey {
        case baseURL = "base_url", disabled, lists, finalAction = "final_action", finalTunnel = "final_tunnel", blockQUIC = "block_quic"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL)
        disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        lists = try c.decodeIfPresent([RouteList].self, forKey: .lists) ?? []
        finalAction = try c.decodeIfPresent(Action.self, forKey: .finalAction) ?? .tunnel
        finalTunnel = try c.decodeIfPresent(String.self, forKey: .finalTunnel)
        blockQUIC = try c.decodeIfPresent(Bool.self, forKey: .blockQUIC) ?? true
    }
}

struct ListCount: Decodable, Equatable {
    var name: String
    var action: Action
    var entries: Int
}

struct Status: Decodable, Equatable {
    var version: String
    /// Whether the lists are applied; off, connected tunnels carry all traffic.
    var enabled: Bool
    /// The engine is up; `connected` is how many tunnels are connected right now.
    var running: Bool
    var connected: Int
    var lists: [ListCount]
    var fetched: String
    var warnings: [String]?
    var error: String?
    var imports: [ImportStatus]?

    enum CodingKeys: String, CodingKey {
        case version, enabled, running, connected, lists, fetched, warnings, error, imports
    }
}

// Tunnels: mirror internal/api/tunnels.go.

enum TunnelState: String, Codable {
    case disconnected, connecting, needsAuth = "needs_auth", connected, reconnecting, failed
    /// A tunnel with no session of its own (VLESS, Trojan, ...): running, but nothing proves the server answers.
    case ready

    /// A state this app doesn't know (a newer service) reads as disconnected, so one new value
    /// can't make the whole tunnel list fail to decode.
    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        self = TunnelState(rawValue: s) ?? .disconnected
    }
}

struct Tunnel: Decodable, Identifiable, Equatable {
    var name: String
    /// The core's protocol name ("openvpn", "vless", ...). Old services send none: OpenVPN.
    var protocolName: String = "openvpn"
    /// The subscription the tunnel came from; nil is the default group.
    var group: String?
    var warning: String?
    /// How the proxy carries traffic ("WebSocket", "gRPC", "TCP"...), read from its options; nil when it has none.
    var transport: String?
    var remotes: [String]?
    var needsAuth: Bool
    var keyEncrypted: Bool
    var autoConnect: Bool
    var state: TunnelState
    var error: String?
    /// "auth" or "key" while state is needs_auth.
    var need: String?
    var localIP: String?
    var remoteIP: String?
    var since: String?
    var bytesIn: UInt64?
    var bytesOut: UInt64?
    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, protocolName = "protocol", group, warning, transport, remotes, needsAuth = "needs_auth", keyEncrypted = "key_encrypted",
             autoConnect = "auto_connect", state, error, need, localIP = "local_ip", remoteIP = "remote_ip",
             since, bytesIn = "bytes_in", bytesOut = "bytes_out"
    }

    var isActive: Bool { state != .disconnected && state != .failed }
}

/// A group of tunnels that came from one URL (Go: api.Subscription). The URL itself stays in the service.
struct Subscription: Decodable, Equatable, Identifiable {
    var name: String
    var tunnels: Int
    var updatedAt: String?
    var error: String?
    /// What the provider reported with the last download; nil if it sent nothing.
    var usage: SubscriptionUsage?
    var id: String { name }

    enum CodingKeys: String, CodingKey { case name, tunnels, updatedAt = "updated_at", error, usage }
}

/// The provider's Subscription-Userinfo (Go: api.Usage). Zero `total` or `expire` means none was given.
struct SubscriptionUsage: Codable, Equatable {
    var upload: Int64
    var download: Int64
    var total: Int64?
    var expire: Int64?  // unix seconds
}

/// The answer to tunnel_group_update (Go: api.UpdateResult).
struct UpdateResult: Decodable, Equatable {
    var added: Int
    var updated: Int
    var removed: Int
    /// Tunnels the provider dropped that stay because a list uses them or they are selected.
    var kept: Int?
    var skipped: [SkippedNode]?
}

/// A link or node that was not imported, and why (Go: api.Skipped).
struct SkippedNode: Decodable, Equatable, Identifiable {
    var label: String
    var reason: String
    var id: String { label + reason }
}

/// The answer to tunnels_add (Go: api.AddResult).
struct AddResult: Decodable, Equatable {
    var added: Int
    var skipped: [SkippedNode]?
    var group: String?
}

struct TunnelList: Decodable, Equatable {
    var tunnels: [Tunnel]
    var subscriptions: [Subscription]?
    /// Whether the VPN is on, and the name of the tunnel that carries all traffic no list names.
    var vpn: Bool?  // nil from a service older than this app
    var selected: String?
    /// The kill switch setting, and whether the service has the rules loaded.
    var bootstrap: String?
    var killSwitch: Bool?
    var killSwitchLAN: Bool?
    var killSwitchArmed: Bool?
    /// Why tunnels can't run here (OpenVPN missing or not matching the build).
    var unavailable: String?
}

/// What a profile asks for, before it is imported.
struct TunnelCheck: Decodable, Equatable {
    var remotes: [String]?
    var needsAuth: Bool
    var keyEncrypted: Bool
    var scripts: [String]?
    var scriptSecurity: Int
    /// Why the engine can't run the profile ("" or nil when it can): what it asks for is still shown.
    var refused: String?

    enum CodingKeys: String, CodingKey {
        case remotes, needsAuth = "needs_auth", keyEncrypted = "key_encrypted", scripts, scriptSecurity = "script_security", refused
    }
}

/// Credentials for one connection. The service keeps them in memory only.
struct TunnelSecrets: Codable, Equatable {
    var username = ""
    var password = ""
    var keyPassword = ""
}

/// Entry counts of an entries_* edit.
struct EntryEdit: Decodable, Equatable {
    var added: Int?
    var duplicates: Int?
    var removed: Int?
    var notFound: [String]?
    var skipped: Int?

    enum CodingKeys: String, CodingKey {
        case added, duplicates, removed, notFound = "not_found", skipped
    }
}

/// A release list described for people (Go: lists.Info). The name stays the
/// list's key; the title and description are what the app shows.
struct ListInfo: Decodable, Hashable, Identifiable {
    var name: String
    var title: String
    var description: String
    var action: Action
    var id: String { name }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// One tunnel's connectivity test: the time of a request through it, or why it failed ("Timeout").
enum TunnelTest: Equatable {
    case ms(Int)
    /// `detail` is the engine's own message behind a plain "Failed", for a tooltip.
    case failed(String, detail: String?)
}

extension TunnelTest {
    /// What the row's tooltip and VoiceOver say: the engine's message when there is one, else what the label means.
    var explanation: String {
        switch self {
        case .ms(let ms): return "\(ms) milliseconds"
        case .failed(let why, let detail):
            if let detail, !detail.isEmpty { return detail }
            switch why {
            case "Timeout": return "No answer from this server within 5 seconds."
            case "Needs sign-in": return "This server needs its credentials: use the ... menu, then Credentials."
            default: return "The engine stopped this server without saying why. Open the ... menu, then Show Log."
            }
        }
    }
}
