import Foundation

// The control socket to the service (daemon/internal/api). The service runs the network layer and keeps nothing: the
// app owns the settings and sends them as a snapshot. Change these types and the Go ones together.

/// One tunnel in a snapshot. Username and password are used and dropped by the service.
struct WireTunnel: Encodable {
    var id: String
    var name: String
    var `protocol`: String
    var profile: String?
    var options: JSONValue?
    var needsAuth: Bool
    var username: String?
    var password: String?
    var keyPassword: String?

    enum CodingKeys: String, CodingKey { case id, name, `protocol`, profile, options, needsAuth = "needs_auth", username, password, keyPassword = "key_password" }
}

struct WireList: Encodable {
    var name: String
    var action: Action
    var tunnel: String?
    var format: String?
    var entries: [String]?
    var text: String?
    /// A custom list's rule, built from fields (format "rules").
    var rules: RuleSpec?
    /// A rule-set kept as it was imported (format "ruleset"): sing-box's binary file, base64 in the JSON.
    var data: Data?
}

struct WireFinal: Encodable {
    var action: Action
    var tunnel: String?
}

struct Snapshot: Encodable {
    var vpn: Bool
    var listsOn: Bool
    var selected: String?
    /// Where traffic no list matches goes; nil is the selected tunnel.
    var final: WireFinal?
    var blockQuic: Bool?
    var blockStun: Bool?
    var blockIPv6: Bool?
    var tlsFingerprint: String?
    var retry: [String]?
    var loadAll: Bool?
    var bootstrap: String?
    var killSwitch: Bool?
    var killSwitchLAN: Bool?
    var tunnels: [WireTunnel]
    var lists: [WireList]

    enum CodingKeys: String, CodingKey {
        case vpn, listsOn = "lists_on", selected, final, blockQuic = "block_quic", blockStun = "block_stun", blockIPv6 = "block_ipv6", tlsFingerprint = "tls_fingerprint", retry, loadAll = "load_all", bootstrap, killSwitch = "kill_switch", killSwitchLAN = "kill_switch_lan", tunnels, lists
    }
}

struct WireTunnelStatus: Decodable, Equatable {
    var state: TunnelState
    var error: String?
    var need: String?
    var localIP: String?
    var remoteIP: String?
    var since: String?

    enum CodingKeys: String, CodingKey { case state, error, need, localIP = "local_ip", remoteIP = "remote_ip", since }
}

struct WireKillSwitch: Decodable, Equatable {
    var armed: Bool
    var error: String?
}

struct ServiceStatus: Decodable, Equatable {
    var version: String
    /// What the service understands (Go: api.APIRevision); an older one ignores newer snapshot fields without a word.
    var apiRev: Int?
    var bootID: String
    var running: Bool
    var connected: Int
    var tunnels: [String: WireTunnelStatus]
    var lists: [ListCount]
    var warnings: [String]?
    var error: String?
    var unavailable: String?
    /// Whether the firewall rules that block a leak are loaded (nil from a service without a kill switch).
    var killSwitch: WireKillSwitch?

    enum CodingKeys: String, CodingKey {
        case version, apiRev = "api_rev", bootID = "boot_id", running, connected, tunnels, lists, warnings, error, unavailable, killSwitch = "kill_switch"
    }

    /// Go encodes an empty slice or map as null when it was never set; that is "none", not a different format.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        apiRev = try c.decodeIfPresent(Int.self, forKey: .apiRev)
        bootID = try c.decode(String.self, forKey: .bootID)
        running = try c.decode(Bool.self, forKey: .running)
        connected = try c.decode(Int.self, forKey: .connected)
        tunnels = try c.decodeIfPresent([String: WireTunnelStatus].self, forKey: .tunnels) ?? [:]
        lists = try c.decodeIfPresent([ListCount].self, forKey: .lists) ?? []
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        unavailable = try c.decodeIfPresent(String.self, forKey: .unavailable)
        killSwitch = try c.decodeIfPresent(WireKillSwitch.self, forKey: .killSwitch)
    }
}

struct WireNode: Decodable {
    var name: String
    var `protocol`: String
    var options: JSONValue
    var server: String
    var warning: String?
}

/// Where a connection to a name or address would go (command route_test).
struct WireRoute: Decodable, Equatable {
    var kind: String // "list", "local", "ipv6" or "default"
    var list: String?
    var action: Action
    var tunnel: String? // the server's name; nil is the selected one
    var notes: [String]?
}

/// The address the internet sees through the selected server (command exit_ip).
struct WireExit: Decodable, Equatable {
    var ip: String
    var country: String?
}

struct WireTest: Decodable {
    var ms: Int?
    var error: String?
    var detail: String?
}

struct WireNodes: Decodable {
    var nodes: [WireNode]
    var skipped: [SkippedNode]?
}

struct WireRuleSet: Decodable {
    var data: Data
    var rules: Int
}

struct WireEntries: Decodable {
    var count: Int
    var skipped: Int?
    var lines: [String]?
}

struct WireCanon: Decodable {
    var line: String
    var entry: String?
    var error: String?
}

struct WireLegacy: Decodable {
    struct Tunnel: Decodable { var profile: String?; var options: String? }
    struct Sub: Decodable { var url: String; var usage: SubscriptionUsage? }
    var tunnels: [String: Tunnel]
    var subscriptions: [String: Sub]
}

/// Any JSON value, kept as it is: a link's options pass from the service's parser to the database file to the
/// snapshot without this app interpreting them.
enum JSONValue: Codable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

private struct Request: Encodable {
    var cmd: String
    var apply: Snapshot?
    var id: String?
    var username: String?
    var password: String?
    var text: String?
    var data: Data? // a rule-set (.srs or JSON source), base64 in the JSON
    var rules: RuleSpec?
    var format: String?
    var wantLines: Bool?
    var lines: [String]?
    var ids: [String]?
    /// Options of "test": "connect", "tcp" or "icmp"; an https address for connect; the time one test may take.
    var method: String?
    var url: String?
    var timeoutMS: Int?

    enum CodingKeys: String, CodingKey { case cmd, apply, id, username, password, text, data, rules, format, wantLines = "want_lines", lines, ids, method, url, timeoutMS = "timeout_ms" }
}

private struct Response: Decodable {
    var ok: Bool
    var error: String?
    var status: ServiceStatus?
    var logs: [String]?
    var check: TunnelCheck?
    var nodes: WireNodes?
    var entries: WireEntries?
    var ruleset: WireRuleSet?
    var canon: [WireCanon]?
    var legacy: WireLegacy?
    var tests: [String: WireTest]?
    var route: WireRoute?
    var exit: WireExit?
    /// server_country: tunnel ID to two-letter code ("" when the address says nothing; absent when it couldn't be looked up).
    var countries: [String: String]?
}

enum DaemonError: LocalizedError, Equatable {
    case notRunning
    case denied
    /// The service answers in an older format (the app was updated and the service still runs the old binary).
    case outdated
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: return "The Splitroute service is not running."
        case .denied: return "Only administrator accounts can control Splitroute."
        case .outdated: return "The Splitroute service is older than this app. Restarting it…"
        case .failed(let msg): return msg
        }
    }
}

/// Client for the service's control socket: one JSON request, one JSON response per connection.
enum Daemon {
    /// The service revision this app needs (Go: api.APIRevision).
    static let requiredAPIRev = 16

    #if DEBUG
    /// Debug builds: SPLITROUTE_SOCKET points the app at a fake service.
    static let socketPath = ProcessInfo.processInfo.environment["SPLITROUTE_SOCKET"] ?? "/var/run/splitroute.sock"
    #else
    static let socketPath = "/var/run/splitroute.sock"
    #endif

    static func status() async throws -> ServiceStatus {
        guard let s = try await send(Request(cmd: "status")).status else { throw DaemonError.outdated }
        return s
    }

    static func apply(_ s: Snapshot) async throws { _ = try await send(Request(cmd: "apply", apply: s)) }

    /// The credentials a running OpenVPN tunnel's challenge asks for.
    static func answer(_ id: String, username: String, password: String) async throws {
        _ = try await send(Request(cmd: "answer", id: id, username: username.nilIfEmpty, password: password.nilIfEmpty))
    }

    /// One request through each named tunnel, measured by the service: milliseconds, or why it failed.
    /// The service allows 60 s per call. The app asks for one tunnel per call so results show as they arrive.
    /// `method` is connect (a request through the tunnel to `url`, or the service's own address when nil), tcp or icmp
    /// (the tunnel's own server, outside it).
    static func test(_ ids: [String], method: String = "connect", url: String? = nil, timeout: Int? = nil) async throws -> [String: WireTest] {
        guard let t = try await send(Request(cmd: "test", ids: ids, method: method, url: url, timeoutMS: timeout.map { $0 * 1000 })).tests else { throw outdated }
        return t
    }

    static func logs() async throws -> [String] { try await send(Request(cmd: "logs")).logs ?? [] }

    /// Asks the service to exit; launchd starts the updated binary.
    static func restart() async throws { _ = try await send(Request(cmd: "restart")) }

    static func checkProfile(_ text: String) async throws -> TunnelCheck {
        guard let c = try await send(Request(cmd: "check_profile", text: text)).check else { throw outdated }
        return c
    }

    static func parseLinks(_ text: String) async throws -> WireNodes {
        guard let n = try await send(Request(cmd: "parse_links", text: text)).nodes else { throw outdated }
        return n
    }

    /// format: "custom" (a file for a new list), "import" (a download) or "release".
    static func parseEntries(_ text: String, format: String, wantLines: Bool = false) async throws -> WireEntries {
        guard let e = try await send(Request(cmd: "parse_entries", text: text, format: format, wantLines: wantLines ? true : nil)).entries else { throw outdated }
        return e
    }

    /// A rule-set (sing-box's binary .srs, or its JSON source): the service checks that the engine can run it and answers
    /// with the binary file, which is what the list keeps. A binary one comes back as it was.
    static func checkRuleSet(_ data: Data) async throws -> (data: Data, rules: Int) {
        guard data.count <= maxRuleSet else { throw DaemonError.failed("This rule-set is larger than \(maxRuleSet >> 20) MB.") }
        guard let r = try await send(Request(cmd: "check_ruleset", data: data)).ruleset else { throw outdated }
        return (r.data, r.rules)
    }

    /// Where a connection to `query` (a name or an address) would go by the lists the service has.
    static func routeTest(_ query: String) async throws -> WireRoute {
        guard let r = try await send(Request(cmd: "route_test", text: query)).route else { throw outdated }
        return r
    }

    /// The address the internet sees through the selected server, looked up by the service through it.
    static func exitIP() async throws -> WireExit {
        guard let e = try await send(Request(cmd: "exit_ip")).exit else { throw outdated }
        return e
    }

    /// Which country each server is in, by the address its name resolves to, looked up by the service in its own database
    /// (at most `maxLocate` at a time). The IDs are core IDs ("t5").
    static let maxLocate = 40
    static func serverCountries(_ ids: [String]) async throws -> [String: String] {
        try await send(Request(cmd: "server_country", ids: ids)).countries ?? [:]
    }

    /// Whether the engine can run a rule built from fields; throws the service's message about the first value that is wrong.
    static func checkRules(_ spec: RuleSpec) async throws {
        _ = try await send(Request(cmd: "check_rules", rules: spec))
    }

    static let maxRuleSet = 16 << 20

    /// A sing-box binary rule-set starts with "SRS"; the JSON source starts with a brace.
    static func looksLikeRuleSet(_ d: Data) -> Bool {
        if d.starts(with: [0x53, 0x52, 0x53]) { return true }
        let head = d.prefix(64).drop { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
        return head.first == UInt8(ascii: "{")
    }

    static func canonEntries(_ lines: [String]) async throws -> [WireCanon] {
        guard let c = try await send(Request(cmd: "canon_entries", lines: lines)).canon else { throw outdated }
        return c
    }

    static func legacyExport() async throws -> WireLegacy {
        guard let l = try await send(Request(cmd: "legacy_export")).legacy else { throw outdated }
        return l
    }

    private static let outdated = DaemonError.failed("The service is older than this app. Restart it from Settings (Advanced → Restart service).")

    private static func send(_ req: Request) async throws -> Response {
        // Encoding a big snapshot and decoding a big answer (a list's lines) both happen off the main actor.
        let resp: Response = try await Task.detached(priority: .userInitiated) {
            let payload = try JSONEncoder().encode(req) + Data("\n".utf8)
            let data = try roundTrip(payload)
            do {
                return try JSONDecoder().decode(Response.self, from: data)
            } catch {
                if req.cmd == "status" { throw DaemonError.outdated }
                throw DaemonError.failed("Unexpected reply from the service: \(error.localizedDescription)")
            }
        }.value
        guard resp.ok else {
            let msg = resp.error ?? "unknown error"
            throw msg.hasPrefix("unknown command") ? outdated : DaemonError.failed(msg)
        }
        return resp
    }

    /// Blocking Unix-socket round trip; runs off the main thread.
    private static func roundTrip(_ payload: Data) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket") }
        defer { close(fd) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 65, tv_usec: 0) // the service allows 60 s
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
