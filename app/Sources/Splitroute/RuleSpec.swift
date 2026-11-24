import Foundation

/// A custom list's rule, built from fields the way sing-box describes one. The fields keep sing-box's names and mean what
/// they mean there (the service checks every value, and the core compiles it to sing-box's own rule-set). `mode` says how
/// the fields combine: "or" (the default: matching any field matches) or "and" (every field must match); `invert` negates
/// the rule. `applications` is the one addition: application paths picked from Finder, matched as the application and
/// everything in it. The JSON is the core's `RuleSpec`.
struct RuleSpec: Codable, Equatable, Hashable {
    var mode = "or"
    var invert = false
    var domain: [String] = []
    var domainSuffix: [String] = []
    var domainKeyword: [String] = []
    var domainRegex: [String] = []
    var ipCIDR: [String] = []
    var port: [Int] = []
    var portRange: [String] = []
    var processName: [String] = []
    var processPath: [String] = []
    var processPathRegex: [String] = []
    var applications: [String] = []
    var network: [String] = []

    enum CodingKeys: String, CodingKey {
        case mode, invert, domain, domainSuffix = "domain_suffix", domainKeyword = "domain_keyword", domainRegex = "domain_regex",
             ipCIDR = "ip_cidr", port, portRange = "port_range", processName = "process_name", processPath = "process_path",
             processPathRegex = "process_path_regex", applications, network
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "or"
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
        domain = try c.decodeIfPresent([String].self, forKey: .domain) ?? []
        domainSuffix = try c.decodeIfPresent([String].self, forKey: .domainSuffix) ?? []
        domainKeyword = try c.decodeIfPresent([String].self, forKey: .domainKeyword) ?? []
        domainRegex = try c.decodeIfPresent([String].self, forKey: .domainRegex) ?? []
        ipCIDR = try c.decodeIfPresent([String].self, forKey: .ipCIDR) ?? []
        port = try c.decodeIfPresent([Int].self, forKey: .port) ?? []
        portRange = try c.decodeIfPresent([String].self, forKey: .portRange) ?? []
        processName = try c.decodeIfPresent([String].self, forKey: .processName) ?? []
        processPath = try c.decodeIfPresent([String].self, forKey: .processPath) ?? []
        processPathRegex = try c.decodeIfPresent([String].self, forKey: .processPathRegex) ?? []
        applications = try c.decodeIfPresent([String].self, forKey: .applications) ?? []
        network = try c.decodeIfPresent([String].self, forKey: .network) ?? []
    }

    /// Only what is set, like the core's omitempty: the mode only when it is "and".
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if mode == "and" { try c.encode(mode, forKey: .mode) }
        if invert { try c.encode(invert, forKey: .invert) }
        func put(_ v: [String], _ k: CodingKeys) throws { if !v.isEmpty { try c.encode(v, forKey: k) } }
        try put(domain, .domain); try put(domainSuffix, .domainSuffix); try put(domainKeyword, .domainKeyword)
        try put(domainRegex, .domainRegex); try put(ipCIDR, .ipCIDR)
        if !port.isEmpty { try c.encode(port, forKey: .port) }
        try put(portRange, .portRange); try put(processName, .processName); try put(processPath, .processPath)
        try put(processPathRegex, .processPathRegex); try put(applications, .applications); try put(network, .network)
    }

    var isEmpty: Bool {
        domain.isEmpty && domainSuffix.isEmpty && domainKeyword.isEmpty && domainRegex.isEmpty && ipCIDR.isEmpty && port.isEmpty
            && portRange.isEmpty && processName.isEmpty && processPath.isEmpty && processPathRegex.isEmpty && applications.isEmpty
            && network.isEmpty
    }

    /// Plain list lines (a file the user picked: domains, addresses, and the typed forms v2fly lists use) as fields.
    /// `lines` are canonical (from the service); notes and AS numbers (which sing-box has no rule for) are left out.
    init(canonicalLines lines: [String]) {
        self.init()
        for l in lines where !l.hasPrefix("#") && !l.trimmingCharacters(in: .whitespaces).isEmpty {
            let k = Entries.kind(l), v = Entries.value(l)
            switch k {
            case "domain": domain.append(v)
            case "domain_suffix": domainSuffix.append(v)
            case "cidr": ipCIDR.append(v)
            case "keyword": domainKeyword.append(v)
            case "regex": domainRegex.append(v)
            case "port":
                if v.contains("-") { portRange.append(v.replacingOccurrences(of: "-", with: ":")) } else if let p = Int(v) { port.append(p) }
            case "app": applications.append(v)
            case "process": processName.append(v)
            default: break // an AS number: no rule for it
            }
        }
    }
}
