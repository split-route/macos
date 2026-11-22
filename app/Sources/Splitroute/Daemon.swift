import Foundation

// Wire types: mirror internal/config/config.go, internal/api/api.go and internal/api/status.go.

enum Action: String, Codable, CaseIterable, Identifiable {
    case direct, block, tunnel
    var id: String { rawValue }
    var label: String {
        switch self {
        case .direct: return "Direct"
        case .block: return "Block"
        case .tunnel: return "Tunnel"
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
    /// Set for a list downloaded from a URL. Its entries live in the daemon's
    /// database, never in the config. Must survive set_config round trips.
    var importSource: ImportSource?
    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, action, tunnel, custom, entries, importSource = "import"
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
        importSource = try c.decodeIfPresent(ImportSource.self, forKey: .importSource)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(action, forKey: .action)
        try c.encodeIfPresent(tunnel, forKey: .tunnel)
        if custom { try c.encode(custom, forKey: .custom) }
        if !entries.isEmpty { try c.encode(entries, forKey: .entries) }
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

    enum CodingKeys: String, CodingKey {
        case baseURL = "base_url", disabled, lists
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL)
        disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        lists = try c.decodeIfPresent([RouteList].self, forKey: .lists) ?? []
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

struct Preset: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var lists: [RouteList]
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
        case name, protocolName = "protocol", group, warning, remotes, needsAuth = "needs_auth", keyEncrypted = "key_encrypted",
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
struct SubscriptionUsage: Decodable, Equatable {
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

    enum CodingKeys: String, CodingKey {
        case remotes, needsAuth = "needs_auth", keyEncrypted = "key_encrypted", scripts, scriptSecurity = "script_security"
    }
}

/// Credentials for one connection. The service keeps them in memory only.
struct TunnelSecrets: Codable, Equatable {
    var username = ""
    var password = ""
    var keyPassword = ""
}

private struct Request: Encodable {
    var cmd: String
    var config: Config?
    var enabled: Bool?
    var preset: String?
    var name: String?
    var newName: String?
    var action: Action?
    var tunnel: String?
    var position: Int?
    var entries: [String]?
    var url: String?
    var text: String?
    var username: String?
    var password: String?
    var keyPassword: String?

    enum CodingKeys: String, CodingKey {
        case cmd, config, enabled, preset, name, newName = "new_name", action, tunnel, position, entries, url, text,
             username, password, keyPassword = "key_password"
    }
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

private struct Response: Decodable {
    var ok: Bool
    var error: String?
    var status: Status?
    var config: Config?
    var lists: [String]?
    var catalog: [ListInfo]?
    var presets: [Preset]?
    var edit: EntryEdit?
    var tunnels: TunnelList?
    var tunnel: Tunnel?
    var check: TunnelCheck?
    var logs: [String]?
    var added: AddResult?
    var updated: UpdateResult?
    var groupURL: String?

    enum CodingKeys: String, CodingKey {
        case ok, error, status, config, lists, catalog, presets, edit, tunnels, tunnel, check, logs, added, updated
        case groupURL = "group_url"
    }
}

enum DaemonError: LocalizedError, Equatable {
    case notRunning
    case denied
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: return "The Splitroute service is not running."
        case .denied: return "Only administrator accounts can control Splitroute."
        case .failed(let msg): return msg
        }
    }
}

/// Client for the daemon's control socket: one JSON request, one JSON response per connection.
enum Daemon {
    #if DEBUG
    /// Debug builds: SPLITROUTE_SOCKET points the app at a fake service.
    static let socketPath = ProcessInfo.processInfo.environment["SPLITROUTE_SOCKET"] ?? "/var/run/splitroute.sock"
    #else
    static let socketPath = "/var/run/splitroute.sock"
    #endif

    static func status() async throws -> Status { try await send(Request(cmd: "status")).status! }
    static func config() async throws -> Config { try await send(Request(cmd: "get_config")).config! }
    static func setConfig(_ c: Config) async throws -> Config { try await send(Request(cmd: "set_config", config: c)).config! }
    static func setEnabled(_ on: Bool) async throws -> Config { try await send(Request(cmd: "set_enabled", enabled: on)).config! }
    static func applyPreset(_ id: String) async throws -> Config { try await send(Request(cmd: "apply_preset", preset: id)).config! }
    /// Release list names and their descriptions (needs the network).
    static func lists() async throws -> (names: [String], catalog: [ListInfo]) {
        let r = try await send(Request(cmd: "lists"))
        return (r.lists ?? [], r.catalog ?? [])
    }
    static func presets() async throws -> [Preset] { try await send(Request(cmd: "presets")).presets ?? [] }

    /// A per-list edit (list_create, list_enable, list_import, list_remove, list_rename,
    /// list_set_action, list_move, entries_set): the daemon applies it to its current
    /// config in one transaction, so edits from the CLI meanwhile are kept.
    static func edit(_ cmd: String, name: String, newName: String? = nil, action: Action? = nil, tunnel: String? = nil,
                     position: Int? = nil, entries: [String]? = nil, url: String? = nil) async throws -> Config {
        let r = try await send(Request(cmd: cmd, name: name, newName: newName, action: action, tunnel: tunnel,
                                       position: position, entries: entries, url: url))
        guard let c = r.config else { throw DaemonError.failed("The service is a different version; reinstall it from Settings.") }
        return c
    }

    /// Creates a custom list from a list file's text, parsed by the daemon like an
    /// import (plain entries, hosts files, domain sets), in one transaction.
    static func createFromText(name: String, action: Action, text: String) async throws -> (config: Config, edit: EntryEdit?) {
        let r = try await send(Request(cmd: "list_create", name: name, action: action, text: text))
        guard let c = r.config else { throw DaemonError.failed("The service is a different version; reinstall it from Settings.") }
        return (c, r.edit)
    }

    /// Asks the service to exit keeping its routes; launchd starts the updated binary.
    static func restart() async throws { _ = try await send(Request(cmd: "restart")) }

    static func refreshImport(_ name: String) async throws { _ = try await send(Request(cmd: "list_refresh", name: name)) }

    // MARK: Tunnels

    private static let oldService = DaemonError.failed("The service is older than this app and has no tunnels. Update it (Advanced → Restart service).")

    static func tunnels() async throws -> TunnelList {
        do {
            guard let t = try await send(Request(cmd: "tunnels")).tunnels else { throw oldService }
            return t
        } catch DaemonError.failed(let m) where m.contains("unknown command") { throw oldService }
    }

    static func tunnelCheck(text: String) async throws -> TunnelCheck {
        guard let c = try await send(Request(cmd: "tunnel_check", text: text)).check else { throw oldService }
        return c
    }

    static func tunnelImport(name: String, text: String) async throws {
        _ = try await send(Request(cmd: "tunnel_import", name: name, text: text))
    }

    static func tunnelConnect(_ name: String, secrets: TunnelSecrets?) async throws {
        _ = try await send(Request(cmd: "tunnel_connect", name: name, username: secrets?.username.nilIfEmpty,
                                   password: secrets?.password.nilIfEmpty, keyPassword: secrets?.keyPassword.nilIfEmpty))
    }

    static func tunnelCredentials(_ name: String, secrets: TunnelSecrets) async throws {
        _ = try await send(Request(cmd: "tunnel_credentials", name: name, username: secrets.username.nilIfEmpty,
                                   password: secrets.password.nilIfEmpty, keyPassword: secrets.keyPassword.nilIfEmpty))
    }

    /// Imports share links or a subscription: `text` is pasted links, a subscription body or one
    /// address; `url` is fetched by the service and kept as a subscription named `name`.
    static func tunnelsAdd(text: String?, url: String?, name: String?) async throws -> AddResult {
        guard let r = try await send(Request(cmd: "tunnels_add", name: name?.nilIfEmpty, url: url?.nilIfEmpty, text: text?.nilIfEmpty)).added else {
            throw oldService
        }
        return r
    }

    /// Turns the VPN on or off.
    static func vpnSet(_ on: Bool) async throws { _ = try await send(Request(cmd: "vpn_set", enabled: on)) }

    /// Makes a tunnel the one that carries all traffic no list names.
    static func tunnelSelect(_ name: String) async throws { _ = try await send(Request(cmd: "tunnel_select", name: name)) }

    static func tunnelGroupRemove(_ name: String) async throws { _ = try await send(Request(cmd: "tunnel_group_remove", name: name)) }

    /// Downloads the subscription again; the service keeps the tunnels that lists and the selection use.
    static func tunnelGroupUpdate(_ name: String) async throws -> UpdateResult {
        guard let r = try await send(Request(cmd: "tunnel_group_update", name: name)).updated else { throw oldService }
        return r
    }

    /// The saved address (it carries the user's token).
    static func tunnelGroupURL(_ name: String) async throws -> String {
        guard let u = try await send(Request(cmd: "tunnel_group_url", name: name)).groupURL else { throw oldService }
        return u
    }

    /// Renames a subscription and/or replaces its address; nil leaves it as it is.
    static func tunnelGroupEdit(_ name: String, newName: String?, url: String?) async throws {
        _ = try await send(Request(cmd: "tunnel_group_edit", name: name, newName: newName?.nilIfEmpty, url: url?.nilIfEmpty))
    }

    static func tunnelDisconnect(_ name: String) async throws { _ = try await send(Request(cmd: "tunnel_disconnect", name: name)) }
    static func tunnelRemove(_ name: String) async throws { _ = try await send(Request(cmd: "tunnel_remove", name: name)) }
    static func tunnelRename(_ name: String, to new: String) async throws {
        _ = try await send(Request(cmd: "tunnel_rename", name: name, newName: new))
    }
    static func tunnelAutoConnect(_ name: String, _ on: Bool) async throws {
        _ = try await send(Request(cmd: "tunnel_auto_connect", enabled: on, name: name))
    }
    static func tunnelLogs(_ name: String) async throws -> [String] {
        try await send(Request(cmd: "tunnel_logs", name: name)).logs ?? []
    }

    private static func send(_ req: Request) async throws -> Response {
        let payload = try JSONEncoder().encode(req) + Data("\n".utf8)
        let data = try await Task.detached { try roundTrip(payload) }.value
        let resp: Response
        do {
            resp = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw DaemonError.failed("Unexpected reply from the service: \(error.localizedDescription)")
        }
        guard resp.ok else { throw DaemonError.failed(resp.error ?? "unknown error") }
        // Every successful reply to these commands carries its payload; a missing
        // one means a daemon/app version mismatch.
        switch req.cmd {
        case "status" where resp.status == nil, "get_config" where resp.config == nil,
             "set_config" where resp.config == nil, "set_enabled" where resp.config == nil,
             "apply_preset" where resp.config == nil:
            throw DaemonError.failed("The service is a different version; reinstall it from Settings.")
        default:
            return resp
        }
    }

    /// Blocking Unix-socket round trip; runs off the main thread.
    private static func roundTrip(_ payload: Data) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket") }
        defer { close(fd) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 95, tv_usec: 0) // the daemon allows 90 s ("lists" downloads)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in path.prefix(buf.count - 1).enumerated() { buf[i] = b }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            switch errno {
            case ENOENT, ECONNREFUSED: throw DaemonError.notRunning
            case EACCES, EPERM: throw DaemonError.denied
            default: throw posixError("connect")
            }
        }

        try payload.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 { throw posixError("write") }
                off += n
            }
        }

        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                out.append(chunk, count: n)
            } else if n == 0 {
                return out
            } else {
                throw posixError("read")
            }
        }
    }

    private static func posixError(_ op: String) -> DaemonError {
        .failed("\(op): \(String(cString: strerror(errno)))")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
