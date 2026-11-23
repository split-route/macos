//go:build darwin || linux

package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/split-route/core"
	"github.com/split-route/core/rules"
	"github.com/split-route/core/ruleset"
	"github.com/split-route/macos/daemon/internal/api"
)

const testProfile = "client\ndev tun\nremote vpn.example.com 443 tcp\nauth-user-pass\n<ca>\n-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n</ca>\n"

func testApp(t *testing.T) (*app, *fakes) {
	t.Helper()
	f := &fakes{}
	dir, err := os.MkdirTemp("", "sra")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	a := newApp(dir, f.factory)
	a.ks.run = func([]string, string) (string, error) { return "", nil } // never the real pfctl
	a.host.settle = time.Hour
	a.runDir = filepath.Join(dir, "run")
	t.Cleanup(a.host.close)
	return a, f
}

func proxy(id, name string) api.TunnelSpec {
	return api.TunnelSpec{ID: id, Name: name, Protocol: "vless", Options: json.RawMessage(`{"type":"vless","server":"example.com","server_port":443,"uuid":"b0e80a62-8a51-47f0-91f1-f0f7faf8d9d4"}`)}
}

func ovpn(id, name string) api.TunnelSpec {
	return api.TunnelSpec{ID: id, Name: name, Protocol: api.ProtocolOpenVPN, Profile: testProfile, NeedsAuth: true}
}

func tunnelNames(c core.Config) string {
	var out []string
	for _, t := range c.Tunnels {
		out = append(out, t.Name)
	}
	return strings.Join(out, ",")
}

// applied runs the host's pending change now and returns the engine's latest config.
func applied(t *testing.T, a *app, f *fakes) core.Config {
	t.Helper()
	a.host.applyNow()
	return f.latest().last()
}

func TestApplyLoadsProxiesTheSelectedAndTheNamed(t *testing.T) {
	a, f := testApp(t)
	s := api.Snapshot{VPN: true, ListsOn: true, Selected: "t2",
		Tunnels: []api.TunnelSpec{proxy("t1", "Alpha"), proxy("t2", "Beta"), ovpn("t3", "Work"), ovpn("t4", "Home")},
		Lists:   []api.ListSpec{{Name: "work", Action: rules.Tunnel, Tunnel: "work", Entries: []string{"corp.example.com"}}}}
	s.Tunnels[2].Username, s.Tunnels[2].Password = "u", "p"
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	c := applied(t, a, f)
	if got := tunnelNames(c); got != "Alpha,Beta,Work" { // Home: an OpenVPN tunnel no list names stays unloaded
		t.Errorf("loaded %s", got)
	}
	if c.Default != "t2" {
		t.Errorf("default %q", c.Default)
	}
	if len(c.Lists) != 1 || c.Lists[0].Tunnel != "t3" {
		t.Errorf("lists %+v", c.Lists)
	}
	if _, err := os.Stat(ruleset.Path(ruleset.Dir(a.host.workDir), c.Lists[0].ID)); err != nil {
		t.Errorf("the list's rule set was not written: %v", err)
	}
}

func TestApplyTwiceChangesNothing(t *testing.T) {
	a, f := testApp(t)
	s := api.Snapshot{VPN: true, ListsOn: true, Selected: "t1", Tunnels: []api.TunnelSpec{proxy("t1", "Alpha")},
		Lists: []api.ListSpec{{Name: "ads", Action: rules.Block, Entries: []string{"ads.example.com"}}}}
	for range 2 {
		if err := a.Apply(s); err != nil {
			t.Fatal(err)
		}
	}
	applied(t, a, f)
	if n := f.latest().cfgCount(); n != 1 {
		t.Errorf("a repeated snapshot reloaded the engine %d times", n)
	}
}

func TestApplyVPNOffStopsEverything(t *testing.T) {
	a, f := testApp(t)
	s := api.Snapshot{VPN: true, Selected: "t1", Tunnels: []api.TunnelSpec{proxy("t1", "Alpha")}}
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	applied(t, a, f)
	s.VPN = false
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	a.host.applyNow()
	if !f.latest().isClosed() {
		t.Error("the engine kept running with the VPN off")
	}
	if a.host.tunnelsRunning() {
		t.Error("a tunnel is still wanted")
	}
}

func TestApplyRenamesInPlaceAndReconnectsOnChange(t *testing.T) {
	a, f := testApp(t)
	s := api.Snapshot{VPN: true, Selected: "t1", Tunnels: []api.TunnelSpec{proxy("t1", "Alpha")}}
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	applied(t, a, f)
	s.Tunnels[0].Name = "Renamed"
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	if got := tunnelNames(applied(t, a, f)); got != "Renamed" {
		t.Errorf("after a rename: %s", got)
	}
	s.Tunnels[0].Options = json.RawMessage(`{"type":"vless","server":"other.example.com","server_port":443,"uuid":"b0e80a62-8a51-47f0-91f1-f0f7faf8d9d4"}`)
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	if c := applied(t, a, f); !strings.Contains(string(c.Tunnels[0].Options), "other.example.com") {
		t.Errorf("a changed tunnel kept its old options: %s", c.Tunnels[0].Options)
	}
}

func TestApplyOpenVPNWaitsForCredentialsThenConnects(t *testing.T) {
	a, f := testApp(t)
	s := api.Snapshot{VPN: true, Selected: "t3", Tunnels: []api.TunnelSpec{ovpn("t3", "Work")}}
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	if st := a.Status().Tunnels["t3"]; st.State != api.NeedsAuth || st.Need != "auth" {
		t.Fatalf("no credentials: %+v", st)
	}
	s.Tunnels[0].Username, s.Tunnels[0].Password = "alice", "secret"
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	c := applied(t, a, f)
	if len(c.Tunnels) != 1 || !strings.Contains(string(c.Tunnels[0].Options), "alice") {
		t.Errorf("the credentials did not reach the engine: %v", ids(c))
	}
}

// A failed tunnel stays out when the app sends the same snapshot again (every
// change does); only Retry brings it back. Retrying bad credentials locks accounts.
func TestApplyAFailedTunnelIsNotRetriedUntilAsked(t *testing.T) {
	a, f := testApp(t)
	good := proxy("t2", "Beta")
	bad := ovpn("t1", "Work")
	bad.Username, bad.Password = "a", "wrong"
	// A list names Work, so the engine loads it although it isn't selected.
	s := api.Snapshot{VPN: true, Selected: "t2", Tunnels: []api.TunnelSpec{bad, good},
		Lists: []api.ListSpec{{Name: "l", Action: rules.Tunnel, Tunnel: "Work", Entries: []string{"example.com"}}}}
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	applied(t, a, f)
	f.latest().set(core.Status{Running: true, Tunnels: []core.TunnelStatus{
		{ID: "t1", State: core.StateFailed, Error: "authentication failed"}, {ID: "t2", State: core.StateReady}}})
	if st := a.Status().Tunnels["t1"]; st.State != api.Failed {
		t.Fatalf("t1 = %+v", st)
	}
	for range 3 {
		if err := a.Apply(s); err != nil {
			t.Fatal(err)
		}
	}
	if c := applied(t, a, f); strings.Contains(string(c.Tunnels[0].Options), "wrong") || len(c.Tunnels) != 1 {
		t.Errorf("a re-sent snapshot brought the failed tunnel back: %v", ids(c))
	}
	s.Retry = []string{"t1"}
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	if c := applied(t, a, f); len(c.Tunnels) != 2 {
		t.Errorf("Retry did not load it again: %v", ids(c))
	}
}

func TestApplyForgetsTunnelsTheAppRemoved(t *testing.T) {
	a, f := testApp(t)
	s := api.Snapshot{VPN: true, Selected: "t1", Tunnels: []api.TunnelSpec{proxy("t1", "Alpha"), proxy("t2", "Beta")}}
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	applied(t, a, f)
	s.Tunnels = s.Tunnels[:1]
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	if got := tunnelNames(applied(t, a, f)); got != "Alpha" {
		t.Errorf("loaded %s", got)
	}
	if _, ok := a.Status().Tunnels["t2"]; ok {
		t.Error("the removed tunnel is still reported")
	}
}

func TestApplyListsOffSendsNoLists(t *testing.T) {
	a, f := testApp(t)
	s := api.Snapshot{VPN: true, ListsOn: true, Selected: "t1", Tunnels: []api.TunnelSpec{proxy("t1", "Alpha")},
		Lists: []api.ListSpec{{Name: "ads", Action: rules.Block, Entries: []string{"ads.example.com"}}}}
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	if c := applied(t, a, f); len(c.Lists) != 1 {
		t.Fatalf("lists %+v", c.Lists)
	}
	s.ListsOn = false
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	if c := applied(t, a, f); len(c.Lists) != 0 {
		t.Errorf("lists off still applied %+v", c.Lists)
	}
	if got := a.Status().Lists; len(got) != 1 || got[0].Entries != 1 {
		t.Errorf("counts %+v", got)
	}
}

func TestApplyRefusesWhatItMustNot(t *testing.T) {
	good := proxy("t1", "Alpha")
	cases := map[string]func(*api.Snapshot){
		"an id that is a path":        func(s *api.Snapshot) { s.Tunnels[0].ID = "../x" },
		"the same id twice":           func(s *api.Snapshot) { s.Tunnels = append(s.Tunnels, s.Tunnels[0]) },
		"the same name in other case": func(s *api.Snapshot) { d := proxy("t2", "ALPHA"); s.Tunnels = append(s.Tunnels, d) },
		"a selected tunnel not sent":  func(s *api.Snapshot) { s.Selected = "t9" },
		"a proxy with no options":     func(s *api.Snapshot) { s.Tunnels[0].Options = nil },
		"a list naming a tunnel and a block action": func(s *api.Snapshot) {
			s.Lists = []api.ListSpec{{Name: "x", Action: rules.Block, Tunnel: "Alpha"}}
		},
		"an unknown list format": func(s *api.Snapshot) { s.Lists = []api.ListSpec{{Name: "x", Action: rules.Direct, Format: "file"}} },
	}
	for name, mod := range cases {
		t.Run(name, func(t *testing.T) {
			a, f := testApp(t)
			s := api.Snapshot{VPN: true, Tunnels: []api.TunnelSpec{good}}
			mod(&s)
			if err := a.Apply(s); err == nil {
				t.Error("accepted")
			}
			if f.count() != 0 {
				t.Error("an engine started")
			}
		})
	}
}

// Options that could read a file or steer the engine's own traffic are the
// core's to refuse: the daemon takes options from the socket, so it must hold.
func TestApplyFailsATunnelWithForbiddenOptions(t *testing.T) {
	a, _ := testApp(t)
	evil := proxy("t1", "Evil")
	evil.Options = json.RawMessage(`{"type":"vless","server":"example.com","server_port":443,"uuid":"b0e80a62-8a51-47f0-91f1-f0f7faf8d9d4","tls":{"enabled":true,"certificate_path":"/etc/master.passwd"}}`)
	if err := a.Apply(api.Snapshot{VPN: true, Selected: "t1", Tunnels: []api.TunnelSpec{evil}}); err != nil {
		t.Fatal(err)
	}
	st := a.Status().Tunnels["t1"]
	if st.State != api.Failed || !strings.Contains(st.Error, "certificate_path") {
		t.Errorf("t1 = %+v", st)
	}
}

func TestApplyListFormats(t *testing.T) {
	a, _ := testApp(t)
	s := api.Snapshot{ListsOn: true, Lists: []api.ListSpec{
		{Name: "mine", Action: rules.Direct, Entries: []string{"example.com", "8.8.8.0/24"}},
		{Name: "feed", Action: rules.Block, Format: api.FormatImport, Text: "0.0.0.0 ads.example.net\n0.0.0.0 track.example.net\n"},
		{Name: "empty", Action: rules.Block, Format: api.FormatImport},
	}}
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	got := map[string]int{}
	for _, c := range a.Status().Lists {
		got[c.Name] = c.Entries
	}
	if got["mine"] == 0 || got["feed"] != 2 || got["empty"] != 0 {
		t.Errorf("counts %v", got)
	}
	s.Lists = []api.ListSpec{{Name: "bad", Action: rules.Direct, Entries: []string{"not an entry!"}}}
	if err := a.Apply(s); err == nil {
		t.Error("an invalid entry was accepted")
	}
}

func TestDesiredTunnels(t *testing.T) {
	ts := []api.TunnelSpec{ovpn("t1", "Work"), ovpn("t2", "Home"), ovpn("t3", "Spare"), proxy("t4", "Alpha")}
	got := desiredTunnels(ts, "t2", []api.ListSpec{{Name: "l", Action: rules.Tunnel, Tunnel: "WORK"}}, false)
	for id, want := range map[string]bool{"t1": true, "t2": true, "t3": false, "t4": true} {
		if got[id] != want {
			t.Errorf("%s: %v, want %v", id, got[id], want)
		}
	}
}

func TestParsers(t *testing.T) {
	a, _ := testApp(t)
	c, err := a.CheckProfile(testProfile)
	if err != nil || !c.NeedsAuth || c.Refused != "" || len(c.Remotes) == 0 {
		t.Errorf("check = %+v, %v", c, err)
	}
	if c, err := a.CheckProfile(testProfile + "up /tmp/x.sh\nscript-security 2\n"); err != nil || c.Refused == "" {
		t.Errorf("a profile that runs scripts: %+v, %v", c, err)
	}
	n, err := a.ParseLinks("vless://b0e80a62-8a51-47f0-91f1-f0f7faf8d9d4@example.com:443?security=tls&sni=example.com#One\nnot a link\n")
	if err != nil || len(n.Nodes) != 1 || n.Nodes[0].Name != "One" || n.Nodes[0].Protocol != "vless" {
		t.Errorf("links = %+v, %v", n, err)
	}
	canon := a.CanonEntries([]string{"Example.COM", "# note", "", "nope nope"})
	if canon[0].Entry != "example.com" && !strings.Contains(canon[0].Entry, "example.com") || canon[1].Entry != "# note" || canon[3].Error == "" {
		t.Errorf("canon = %+v", canon)
	}
	e, err := a.ParseEntries("example.com\n8.8.8.0/24\n", api.FormatCustom, true)
	if err != nil || e.Count != 2 || len(e.Lines) != 2 {
		t.Errorf("entries = %+v, %v", e, err)
	}
	if _, err := a.ParseEntries("   \n", api.FormatCustom, false); err == nil {
		t.Error("an empty file was accepted as a list")
	}
}

func TestLegacyExportReadsTheRootOnlyFiles(t *testing.T) {
	a, _ := testApp(t)
	mk := func(rel, body string) {
		p := filepath.Join(a.stateDir, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	mk("tunnels/1/profile.ovpn", testProfile)
	mk("tunnels/2/options.json", `{"type":"vless"}`)
	mk("tunnels/net-1.json", "{}")
	mk("subscriptions/1/url", "https://example.com/sub?token=abc\n")
	mk("subscriptions/1/info.json", `{"upload":1,"download":2,"total":3}`)
	l, err := a.LegacyExport()
	if err != nil {
		t.Fatal(err)
	}
	if l.Tunnels["1"].Profile != testProfile || l.Tunnels["2"].Options != `{"type":"vless"}` || len(l.Tunnels) != 2 {
		t.Errorf("tunnels = %+v", l.Tunnels)
	}
	if s := l.Subscriptions["1"]; s.URL != "https://example.com/sub?token=abc" || s.Usage == nil || s.Usage.Total != 3 {
		t.Errorf("subscriptions = %+v", l.Subscriptions)
	}
	if _, err := os.Stat(filepath.Join(a.stateDir, "tunnels/1/profile.ovpn")); err != nil {
		t.Error("the export deleted the old file")
	}
}

// The same JSON the app's ServiceLinkTests builds: the two sides must agree on the wire.
func TestSnapshotFromTheApp(t *testing.T) {
	const golden = `{"lists":[{"action":"direct","entries":["# office","example.com","8.8.8.0/24"],"name":"Office"},{"action":"block","name":"malware"},{"action":"tunnel","entries":["full:a.example.com"],"name":"Work list","tunnel":"Work"}],"lists_on":true,"retry":["*"],"selected":"t1","tunnels":[{"id":"t1","name":"Proxy","needs_auth":false,"options":{"server":"example.com","server_port":443,"type":"vless"},"protocol":"vless"},{"id":"t2","name":"Work","needs_auth":true,"password":"pw","profile":"client\n","protocol":"openvpn","username":"alice"}],"vpn":true}`
	dec := json.NewDecoder(strings.NewReader(golden))
	dec.DisallowUnknownFields() // a field the app sends that the daemon doesn't know is a mismatch
	var s api.Snapshot
	if err := dec.Decode(&s); err != nil {
		t.Fatal(err)
	}
	if err := s.Validate(); err != nil {
		t.Fatal(err)
	}
	if !s.VPN || !s.ListsOn || s.Selected != "t1" || len(s.Tunnels) != 2 || len(s.Lists) != 3 || s.Tunnels[1].Username != "alice" || s.Lists[2].Tunnel != "Work" || s.Retry[0] != "*" {
		t.Errorf("decoded %+v", s)
	}
}

func TestTestMeasuresLoadedTunnelsAndTimesOutTheRest(t *testing.T) {
	a, f := testApp(t)
	a.host.testTimeout = 200 * time.Millisecond
	s := api.Snapshot{VPN: true, Selected: "t1", Tunnels: []api.TunnelSpec{proxy("t1", "Alpha"), proxy("t2", "Beta"), ovpn("t3", "Work")}}
	if got := a.Test([]string{"t1"}); got["t1"].Error != "The VPN is off" {
		t.Errorf("the VPN is off: %+v", got)
	}
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	applied(t, a, f)
	eng := f.latest()
	eng.mu.Lock()
	eng.tests = map[string]time.Duration{"t1": 120 * time.Millisecond}
	eng.testErrs = map[string]error{"t2": errors.New("dial tcp 203.0.113.9:443: connect: connection refused")}
	eng.mu.Unlock()
	a.host.testTimeout = 2 * time.Second
	got := a.Test([]string{"t1", "t2", "t3", "t9"})
	if got["t1"].MS != 120 || got["t1"].Error != "" {
		t.Errorf("t1 = %+v", got["t1"])
	}
	if got["t2"].Error != "Failed" || !strings.Contains(got["t2"].Detail, "connection refused") {
		t.Errorf("a refused connection is a failure with its reason: %+v", got["t2"])
	}
	for name, err := range map[string]error{"deadline": context.DeadlineExceeded, "i/o": errors.New("read tcp: i/o timeout"), "wrapped": errors.New("outbound/vless[t-t2]: context deadline exceeded")} {
		if r := testFailure(context.Background(), err); r.Error != "Timeout" {
			t.Errorf("%s: %+v", name, r)
		}
	}
	if r := testFailure(context.Background(), errors.New("tls: handshake failure")); r.Error != "Failed" || r.Detail == "" {
		t.Errorf("tls: %+v", r)
	}
	for _, id := range []string{"t3", "t9"} { // an OpenVPN tunnel no list names, and one that doesn't exist
		if got[id].Error != "Not loaded" {
			t.Errorf("%s = %+v", id, got[id])
		}
	}
}

// A connectivity test loads every tunnel, and puts the extras away again when it is over.
func TestApplyLoadAllLoadsEveryOpenVPNTunnelThenUnloadsThem(t *testing.T) {
	a, f := testApp(t)
	home := ovpn("t4", "Home")
	home.Username, home.Password = "u", "p"
	work := ovpn("t3", "Work")
	work.Username, work.Password = "u", "p"
	s := api.Snapshot{VPN: true, Selected: "t1", Tunnels: []api.TunnelSpec{proxy("t1", "Alpha"), work, home}}
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	if got := tunnelNames(applied(t, a, f)); got != "Alpha" {
		t.Fatalf("loaded %s", got)
	}
	s.LoadAll = true
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	if got := tunnelNames(applied(t, a, f)); got != "Alpha,Work,Home" {
		t.Errorf("a test loads every tunnel: %s", got)
	}
	s.LoadAll = false
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	if got := tunnelNames(applied(t, a, f)); got != "Alpha" {
		t.Errorf("after the test: %s", got)
	}
}

// An OpenVPN tunnel is tested by address: by name it would resolve through the selected tunnel's DNS.
func TestTestUsesAnAddressForOpenVPN(t *testing.T) {
	a, f := testApp(t)
	work := ovpn("t3", "Work")
	work.Username, work.Password = "u", "p"
	s := api.Snapshot{VPN: true, Selected: "t1", LoadAll: true, Tunnels: []api.TunnelSpec{proxy("t1", "Alpha"), work}}
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	eng := applied2(t, a, f)
	eng.mu.Lock()
	eng.tests = map[string]time.Duration{"t1": time.Millisecond, "t3": time.Millisecond}
	eng.mu.Unlock()
	a.Test([]string{"t1", "t3"})
	eng.mu.Lock()
	defer eng.mu.Unlock()
	if !strings.Contains(eng.testLinks["t1"], "cloudflare.com") || strings.Contains(eng.testLinks["t3"], "cloudflare.com") || !strings.HasPrefix(eng.testLinks["t3"], "http://1.1.1.1") {
		t.Errorf("links = %v", eng.testLinks)
	}
}

func applied2(t *testing.T, a *app, f *fakes) *fakeEngine {
	t.Helper()
	a.host.applyNow()
	return f.latest()
}
