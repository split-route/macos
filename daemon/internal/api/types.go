//go:build darwin || linux

package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/split-route/core"
	"github.com/split-route/core/rules"
)

// State is a tunnel's state as the app shows it.
type State string

const (
	Disconnected State = "disconnected"
	Connecting   State = "connecting"
	NeedsAuth    State = "needs_auth" // waiting for credentials from the app
	Connected    State = "connected"
	// Ready is a tunnel with no session of its own (VLESS, Trojan, ...): the
	// engine runs it and traffic can use it, but nothing has proven the server
	// answers. Shown as "Ready", never as "Connected".
	Ready        State = "ready"
	Reconnecting State = "reconnecting"
	Failed       State = "failed" // stopped for the reason in Error (bad credentials, a start that failed)
)

// ProtocolOpenVPN is the one protocol whose tunnel is a profile, not options.
const ProtocolOpenVPN = "openvpn"

// Credentials are kept in the daemon's memory only, while a tunnel is wanted.
type Credentials struct {
	User, Pass string
	HaveAuth   bool
}

// Snapshot is everything the daemon needs to run the network layer. The app
// owns the settings and sends the whole desired state on every change, and
// again whenever Status.BootID changes (the daemon restarted and remembers
// nothing). Sending the same snapshot twice changes nothing.
type Snapshot struct {
	// VPN is whether the user wants the VPN on. Off stops the engine and drops
	// every tunnel's credentials.
	VPN bool `json:"vpn"`
	// ListsOn is whether the lists are applied (routing). Off, only the default route is left: it still
	// sends everything where Final says.
	ListsOn bool `json:"lists_on"`
	// Selected is the ID of the tunnel that carries all traffic no list names.
	Selected string `json:"selected,omitempty"`
	// Final is where traffic no list matches goes: direct, block, or a tunnel (Tunnel empty: the selected one). The
	// zero value is the selected tunnel. It applies whether or not the lists do.
	Final FinalSpec `json:"final,omitempty"`
	// BlockQUIC refuses QUIC that no list matched, so browsers use TCP, where names can be read. Ignored while ListsOn is false.
	BlockQUIC bool `json:"block_quic,omitempty"`
	// BlockSTUN refuses STUN (WebRTC's way of learning a public address), so a browser can't show the real address
	// while its traffic goes through a tunnel. It applies whether or not the lists do.
	BlockSTUN bool `json:"block_stun,omitempty"`
	// BlockIPv6 refuses IPv6 (the tun carries IPv4 only, so IPv6 would go around it); apps' AAAA lookups are answered empty.
	BlockIPv6 bool `json:"block_ipv6,omitempty"`
	// TLSFingerprint makes vless, vmess and trojan tunnels' TLS handshake look like this browser's (core.TLSFingerprints);
	// a tunnel that chose one keeps it. Empty: each tunnel's own.
	TLSFingerprint string `json:"tls_fingerprint,omitempty"`
	// Retry names tunnels that failed and may be tried again because the user
	// asked: IDs, or "*" for all. A failed tunnel is never retried without it
	// (retrying bad credentials locks accounts).
	Retry []string `json:"retry,omitempty"`
	// LoadAll loads every tunnel, OpenVPN ones included, which are otherwise loaded only when selected or named by a
	// list: for the app's connectivity test, which measures them all. A failed tunnel stays failed (see Retry).
	LoadAll bool `json:"load_all,omitempty"`
	// KillSwitch blocks all traffic that isn't the engine's while the VPN is on, so a dropped tunnel
	// can't leak; KillSwitchLAN keeps the local network reachable meanwhile.
	// Bootstrap is how proxy tunnels' server names are found: "" (automatic: the first of 1.1.1.1, 8.8.8.8 and 9.9.9.9 that answers a DoH query from this network), a DoH server's IP address, or
	// "system" (the system resolver, for a network that resets DoH).
	Bootstrap     string       `json:"bootstrap,omitempty"`
	KillSwitch    bool         `json:"kill_switch,omitempty"`
	KillSwitchLAN bool         `json:"kill_switch_lan,omitempty"`
	Tunnels       []TunnelSpec `json:"tunnels"`
	Lists         []ListSpec   `json:"lists"`
}

// FinalSpec is the route of everything no list matches. Tunnel is a tunnel's name (case-insensitive), like a list's.
type FinalSpec struct {
	Action rules.Action `json:"action,omitempty"` // direct, block or tunnel; empty means tunnel
	Tunnel string       `json:"tunnel,omitempty"`
}

// TunnelSpec is one tunnel. An OpenVPN tunnel carries its profile text and the
// daemon builds the engine's options from it; any other protocol carries the
// engine's options, which the core refuses if they could read a file or steer
// the engine's own traffic. Username, Password and KeyPassword (the passphrase of an encrypted private key in the
// profile) are used and dropped.
type TunnelSpec struct {
	ID        string          `json:"id"` // "t12": the app's row ID
	Name      string          `json:"name"`
	Protocol  string          `json:"protocol"`
	Profile   string          `json:"profile,omitempty"`
	Options   json.RawMessage `json:"options,omitempty"`
	NeedsAuth bool            `json:"needs_auth,omitempty"`
	Username  string          `json:"username,omitempty"`
	Password  string          `json:"password,omitempty"`
	// KeyPassword opens the profile's encrypted client key. The engine is given the plain key, in memory only.
	KeyPassword string `json:"key_password,omitempty"`
}

// List formats: how a ListSpec carries its entries.
const (
	FormatCustom  = "custom"  // Entries, canonical lines
	FormatImport  = "import"  // Text: a downloaded list (plain entries, hosts file, domain set)
	FormatRelease = "release" // Text: a release list file
	FormatRules   = "rules"   // Rules: a rule built from fields (domain, domain_suffix, port, process_name, ...)
	FormatRuleSet = "ruleset" // Data: a sing-box binary rule-set, an imported .srs or JSON source, used as it is
)

// ListSpec is one list, in config order. Tunnel is a tunnel's name (empty: the
// default tunnel).
type ListSpec struct {
	Name    string         `json:"name"`
	Action  rules.Action   `json:"action"`
	Tunnel  string         `json:"tunnel,omitempty"`
	Format  string         `json:"format,omitempty"` // "" is custom
	Entries []string       `json:"entries,omitempty"`
	Text    string         `json:"text,omitempty"`
	Rules   *core.RuleSpec `json:"rules,omitempty"` // FormatRules
	Data    []byte         `json:"data,omitempty"`  // FormatRuleSet: base64 in the JSON
}

// RuleSetInfo is the answer to "check_ruleset": the rule-set as the engine will read it (binary), and how many rules it has.
type RuleSetInfo struct {
	Data  []byte `json:"data"`
	Rules int    `json:"rules"`
}

const (
	MaxTunnels = 2000
	MaxLists   = 500
	maxName    = 64
)

var idRE = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,31}$`)

// Validate refuses what the engine must never be asked: odd IDs (they become
// tags and file names), duplicates, and shapes that don't belong together.
func (s Snapshot) Validate() error {
	if !core.ValidTLSFingerprint(s.TLSFingerprint) {
		return fmt.Errorf("tls fingerprint %q is not one of %s", s.TLSFingerprint, strings.Join(core.TLSFingerprints, ", "))
	}
	if b := s.Bootstrap; b != "" && b != "system" {
		if _, err := netip.ParseAddr(b); err != nil {
			return fmt.Errorf("bootstrap %q must be an IP address or \"system\"", b)
		}
	}
	if len(s.Tunnels) > MaxTunnels {
		return fmt.Errorf("%d tunnels; the limit is %d", len(s.Tunnels), MaxTunnels)
	}
	if len(s.Lists) > MaxLists {
		return fmt.Errorf("%d lists; the limit is %d", len(s.Lists), MaxLists)
	}
	ids, names := map[string]bool{}, map[string]bool{}
	for _, t := range s.Tunnels {
		key := strings.ToLower(t.Name)
		switch {
		case !idRE.MatchString(t.ID):
			return fmt.Errorf("tunnel id %q: lowercase letters, digits, - and _ (1-32 characters)", t.ID)
		case t.Name == "" || len(t.Name) > maxName:
			return fmt.Errorf("tunnel %s: name must be 1-%d characters", t.ID, maxName)
		case ids[t.ID]:
			return fmt.Errorf("tunnel id %q sent twice", t.ID)
		case names[key]:
			return fmt.Errorf("tunnel name %q sent twice", t.Name)
		case t.Protocol == "":
			return fmt.Errorf("tunnel %q has no protocol", t.Name)
		case t.Protocol == ProtocolOpenVPN && t.Profile == "":
			return fmt.Errorf("tunnel %q: an OpenVPN tunnel needs its profile", t.Name)
		case t.Protocol != ProtocolOpenVPN && len(t.Options) == 0:
			return fmt.Errorf("tunnel %q: a %s tunnel needs its options", t.Name, t.Protocol)
		}
		ids[t.ID], names[key] = true, true
	}
	if s.Selected != "" && !ids[s.Selected] {
		return fmt.Errorf("the selected tunnel %q is not in the snapshot", s.Selected)
	}
	switch f := s.Final; {
	case f.Action != "" && f.Action != rules.Direct && f.Action != rules.Block && f.Action != rules.Tunnel:
		return fmt.Errorf("final route: action must be direct, block or tunnel, not %q", f.Action)
	case f.Tunnel != "" && f.Action != rules.Tunnel:
		return fmt.Errorf("final route: only the tunnel action can name a tunnel")
	case len(f.Tunnel) > maxName:
		return fmt.Errorf("final route: tunnel name longer than %d characters", maxName)
	}
	lists := map[string]bool{}
	for _, l := range s.Lists {
		switch {
		case l.Name == "" || len(l.Name) > maxName:
			return fmt.Errorf("list name %q: 1-%d characters", l.Name, maxName)
		case lists[l.Name]:
			return fmt.Errorf("list %q sent twice", l.Name)
		case l.Action != rules.Direct && l.Action != rules.Block && l.Action != rules.Tunnel:
			return fmt.Errorf("list %q: action must be direct, block or tunnel, not %q", l.Name, l.Action)
		case l.Tunnel != "" && l.Action != rules.Tunnel:
			return fmt.Errorf("list %q: only a tunnel list can name a tunnel", l.Name)
		case l.Format != "" && l.Format != FormatCustom && l.Format != FormatImport && l.Format != FormatRelease && l.Format != FormatRules && l.Format != FormatRuleSet:
			return fmt.Errorf("list %q: unknown format %q", l.Name, l.Format)
		case l.Format == FormatRules && l.Rules == nil:
			return fmt.Errorf("list %q: a rules list needs its rules", l.Name)
		case l.Format == FormatRuleSet && len(l.Data) == 0:
			return fmt.Errorf("list %q: a rule-set list needs its rule-set", l.Name)
		case len(l.Data) > core.MaxRuleSetBytes:
			return fmt.Errorf("list %q: the rule-set is larger than %d MB", l.Name, core.MaxRuleSetBytes>>20)
		}
		lists[l.Name] = true
	}
	return nil
}

// TunnelStatus is a tunnel's live state. The daemon never returns credentials.
type TunnelStatus struct {
	State    State     `json:"state"`
	Error    string    `json:"error,omitempty"`
	Need     string    `json:"need,omitempty"` // "auth" while State is needs_auth
	LocalIP  string    `json:"local_ip,omitempty"`
	RemoteIP string    `json:"remote_ip,omitempty"`
	Since    time.Time `json:"since,omitzero"`
}

// ListCount is how many entries a list holds.
type ListCount struct {
	Name    string       `json:"name"`
	Action  rules.Action `json:"action"`
	Entries int          `json:"entries"`
}

// APIRevision is bumped when the app needs something of the service that an older one would silently ignore (a new
// snapshot field, say). The app compares it with the one it needs and says the service must be restarted.
const APIRevision = 16 // 16: server_country (the country of each server, offline); 15: route_test and exit_ip, block IPv6; 14: block STUN and a default TLS fingerprint; 13: test methods (tcp, icmp, connect with a URL and a timeout); 12: rules and rule-set lists (check_rules, check_ruleset); 11: keyword, regexp, port, app and process list entries; 10: automatic bootstrap resolver; 9: block QUIC; 8: .srs lists (parse_entries data); 7: key password for an encrypted OpenVPN key; 6: final route; 5: bootstrap resolver; 4: kill switch (3: OpenVPN tunnels are tested by address)

// Status is what the control socket returns for `status`.
type Status struct {
	Version string `json:"version"`
	// APIRev is APIRevision of this service.
	APIRev int `json:"api_rev"`
	// BootID is new for every run of the daemon. When it differs from the last
	// one the app saw, the daemon restarted with no state: send the snapshot.
	BootID string `json:"boot_id"`
	// Running is whether the engine is up; Connected is how many tunnels carry
	// traffic right now.
	Running   bool                    `json:"running"`
	Connected int                     `json:"connected"`
	Tunnels   map[string]TunnelStatus `json:"tunnels"` // by tunnel ID
	Lists     []ListCount             `json:"lists"`
	AppliedAt time.Time               `json:"applied_at,omitzero"`
	Warnings  []string                `json:"warnings,omitempty"`
	Error     string                  `json:"error,omitempty"` // the last engine start failed
	// Unavailable is why tunnels can't run in this build, or "".
	Unavailable string `json:"unavailable,omitempty"`
	// KillSwitch is the kill switch's state: armed means traffic that isn't the engine's is blocked.
	KillSwitch KillSwitchStatus `json:"kill_switch"`
}

// KillSwitchStatus is whether the pf rules are loaded, and why the last change failed.
type KillSwitchStatus struct {
	Armed bool   `json:"armed"`
	Error string `json:"error,omitempty"`
}

// TunnelCheck is what a profile asks for, shown before it is imported.
// Refused is why the engine can't run it ("" when it can).
type TunnelCheck struct {
	Remotes        []string `json:"remotes"`
	NeedsAuth      bool     `json:"needs_auth"`
	KeyEncrypted   bool     `json:"key_encrypted"`
	Scripts        []string `json:"scripts,omitempty"`
	ScriptSecurity int      `json:"script_security"`
	Refused        string   `json:"refused,omitempty"`
}

// Node is a tunnel found in share links or a subscription body.
type Node struct {
	Name     string          `json:"name"`
	Protocol string          `json:"protocol"`
	Options  json.RawMessage `json:"options"`
	Server   string          `json:"server"` // host:port, for display
	Warning  string          `json:"warning,omitempty"`
}

// Skipped is a link that was not imported. Label never holds credentials.
type Skipped struct {
	Label  string `json:"label"`
	Reason string `json:"reason"`
}

// Nodes is the answer to "parse_links".
type Nodes struct {
	Nodes   []Node    `json:"nodes"`
	Skipped []Skipped `json:"skipped,omitempty"`
}

// Entries is the answer to "parse_entries".
type Entries struct {
	Count   int      `json:"count"`
	Skipped int      `json:"skipped,omitempty"` // lines that aren't entries
	Lines   []string `json:"lines,omitempty"`   // canonical lines, only when asked for
}

// Canon is one line of "canon_entries": its canonical form, or why it isn't an entry.
type Canon struct {
	Line  string `json:"line"`
	Entry string `json:"entry,omitempty"`
	Error string `json:"error,omitempty"`
}

// Test methods: connect times one request through the tunnel; tcp and icmp time the tunnel's own server, outside it.
const (
	TestConnect = "connect"
	TestTCP     = "tcp"
	TestICMP    = "icmp"
)

// TestOptions is how the app wants a test done. The zero value is a connect test to the service's own address.
type TestOptions struct {
	Method string // "" is connect
	// URL is the address a connect test requests; empty is the service's own (an IP address for OpenVPN tunnels, whose
	// name would be looked up through the selected tunnel). https only: anything else is refused.
	URL       string
	TimeoutMS int // 0 is the default; clamped to MinTestTimeout..MaxTestTimeout
}

const (
	MinTestTimeout = time.Second
	MaxTestTimeout = 30 * time.Second
	maxTestURLLen  = 2048
)

// Validate refuses a method it doesn't know and an address that isn't plain https.
func (o TestOptions) Validate() error {
	switch o.Method {
	case "", TestConnect, TestTCP, TestICMP:
	default:
		return fmt.Errorf("unknown test method %q", o.Method)
	}
	if o.URL == "" {
		return nil
	}
	u, err := url.Parse(o.URL)
	if err != nil || len(o.URL) > maxTestURLLen || u.Scheme != "https" || u.Hostname() == "" || u.User != nil {
		return errors.New("the test address must be an https address")
	}
	return nil
}

// Timeout is the time one test may take: def when none was asked, else the request clamped to the allowed range.
func (o TestOptions) Timeout(def time.Duration) time.Duration {
	if o.TimeoutMS <= 0 {
		return def
	}
	return min(max(time.Duration(o.TimeoutMS)*time.Millisecond, MinTestTimeout), MaxTestTimeout)
}

// RouteResult is where a connection to a name or address would go (command route_test).
type RouteResult struct {
	// Kind is "list", "local", "ipv6" or "default".
	Kind string `json:"kind"`
	List string `json:"list,omitempty"`
	// Action is direct, block or tunnel; Tunnel names the server (empty: the selected one).
	Action rules.Action `json:"action"`
	Tunnel string       `json:"tunnel,omitempty"`
	Notes  []string     `json:"notes,omitempty"`
}

// MaxLocateIDs bounds one server_country request: each name is looked up, a few at a time, within the socket's timeout.
const MaxLocateIDs = 64

// ExitIP is the address the internet sees through the selected server (command exit_ip): the address and its country's
// two-letter code, both checked by the service before they are returned.
type ExitIP struct {
	IP      string `json:"ip"`
	Country string `json:"country,omitempty"`
}

// TestResult is one tunnel's connectivity test: the time of one request through it in
// milliseconds, or why it failed ("Timeout" when it didn't answer in time).
type TestResult struct {
	MS    int    `json:"ms,omitempty"`
	Error string `json:"error,omitempty"`
	// Detail is the engine's own message behind a "Failed", for a tooltip.
	Detail string `json:"detail,omitempty"`
}

// Usage is the provider's Subscription-Userinfo.
type Usage struct {
	Upload   int64 `json:"upload"`
	Download int64 `json:"download"`
	Total    int64 `json:"total,omitempty"`
	Expire   int64 `json:"expire,omitempty"` // unix seconds
}

// LegacyState is what versions before 0.3 kept in root-only files: the app now
// owns them, and reads them once with "legacy_export". Keys are the old numeric
// row IDs.
type LegacyState struct {
	Tunnels       map[string]LegacyTunnel `json:"tunnels"`
	Subscriptions map[string]LegacySub    `json:"subscriptions"`
}

// LegacyTunnel is a stored tunnel's file as it was on disk (the app checks its hash): Profile for OpenVPN,
// Options (the options JSON, as text) otherwise.
type LegacyTunnel struct {
	Profile string `json:"profile,omitempty"`
	Options string `json:"options,omitempty"`
}

// LegacySub is a subscription's address (it carries the user's token) and the usage the provider reported.
type LegacySub struct {
	URL   string `json:"url"`
	Usage *Usage `json:"usage,omitempty"`
}

var errNeedSnapshot = errors.New("apply needs a snapshot")
