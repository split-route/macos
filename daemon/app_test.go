//go:build darwin || linux

package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/split-route/core/rules"
	"github.com/split-route/core/ruleset"
	"github.com/split-route/macos/daemon/internal/api"
	"github.com/split-route/macos/daemon/internal/config"
	"github.com/split-route/macos/daemon/internal/store"
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
	a.host.settle = time.Hour
	a.runDir = filepath.Join(dir, "run")
	t.Cleanup(func() { a.host.close(); a.closeSettings() })
	return a, f
}

// onlyCustomLists replaces the default release list, so nothing is downloaded.
func onlyCustomLists(t *testing.T, a *app, ls ...config.List) {
	t.Helper()
	if _, err := a.UpdateConfig(func(config.Config) (config.Config, error) { return config.Config{Lists: ls}, nil }); err != nil {
		t.Fatal(err)
	}
}

// ---- the cleanup of what earlier versions left ----

type recorder struct {
	mu   sync.Mutex
	ran  []string
	fail map[string]bool
}

func (r *recorder) run(name string, args []string, stdin string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.ran = append(r.ran, strings.TrimSpace(name+" "+strings.Join(args, " ")+" "+strings.ReplaceAll(stdin, "\n", ";")))
	return nil
}

func TestCleanupLegacy(t *testing.T) {
	a, _ := testApp(t)
	rec := &recorder{}
	a.exec = rec.run

	// state.json from route mode: two prefixes and one that is not a prefix.
	state := `{"gateway":{"ip":"192.168.1.1","iface":"en0"},"routes":[{"prefix":"5.0.0.0/24","action":"direct","list":"ir-cidr"},` +
		`{"prefix":"2001:db8::/32","action":"block","list":"ads"},{"prefix":"1.2.3.4; rm -rf /","action":"direct","list":"x"}]}`
	if err := os.WriteFile(filepath.Join(a.stateDir, "state.json"), []byte(state), 0o644); err != nil {
		t.Fatal(err)
	}
	// An undo list recorded by the OpenVPN 3 helper: allowed soft commands, a hostile one, a non-soft one.
	if err := os.MkdirAll(a.tunnelsDir(), 0o700); err != nil {
		t.Fatal(err)
	}
	undo := `{"setup":[{"name":"/sbin/route","args":["-n","delete","-net","10.99.0.0"],"soft":true},` +
		`{"name":"/usr/sbin/scutil","stdin":"remove State:/Network/Service/splitroute-utun7/DNS\n","soft":true},` +
		`{"name":"/bin/rm","args":["-rf","/"],"soft":true},{"name":"/sbin/route","args":["add","x"]}],` +
		`"hosts":[{"name":"/sbin/route","args":["-n","delete","-host","203.0.113.9"],"soft":true}]}`
	netFile := filepath.Join(a.tunnelsDir(), "net-1.json")
	if err := os.WriteFile(netFile, []byte(undo), 0o600); err != nil {
		t.Fatal(err)
	}
	// Old rule sets from the previous router.
	oldSets := filepath.Join(a.stateDir, "rulesets")
	if err := os.MkdirAll(oldSets, 0o700); err != nil {
		t.Fatal(err)
	}
	// A stale engine process, and an unrelated process whose pid file also lingers.
	engine := exec.Command("sleep", "30")
	other := exec.Command("sleep", "30")
	for _, c := range []*exec.Cmd{engine, other} {
		if err := c.Start(); err != nil {
			t.Fatal(err)
		}
		c := c
		t.Cleanup(func() { c.Process.Kill(); c.Wait() })
	}
	if err := os.MkdirAll(a.runDir, 0o700); err != nil {
		t.Fatal(err)
	}
	pidFile := func(name string, c *exec.Cmd) string {
		p := filepath.Join(a.runDir, name+".pid")
		os.WriteFile(p, []byte(itoa(c.Process.Pid)), 0o600)
		return p
	}
	ePid, oPid := pidFile("engine-1", engine), pidFile("other", other)
	a.query = func(name string, args ...string) (string, error) {
		if args[1] == itoa(engine.Process.Pid) {
			return "/var/run/splitroute-tunnels/splitroute-engine run -D x", nil
		}
		return "/bin/sleep 30", nil // not ours
	}

	a.cleanupLegacy()

	got := strings.Join(rec.ran, "\n")
	for _, w := range []string{
		"/sbin/route -n delete -net 5.0.0.0/24",
		"/sbin/route -n delete -inet6 -net 2001:db8::/32",
		"/sbin/route -n delete -net 10.99.0.0",
		"/usr/sbin/scutil  remove State:/Network/Service/splitroute-utun7/DNS;",
		"/sbin/route -n delete -host 203.0.113.9",
	} {
		if !strings.Contains(got, w) {
			t.Errorf("missing %q in\n%s", w, got)
		}
	}
	for _, bad := range []string{"rm", "1.2.3.4", "route add"} {
		if strings.Contains(got, bad) {
			t.Errorf("ran something it must not (%q):\n%s", bad, got)
		}
	}
	for _, f := range []string{filepath.Join(a.stateDir, "state.json"), netFile, oldSets, ePid, oPid} {
		if _, err := os.Stat(f); !os.IsNotExist(err) {
			t.Errorf("%s left behind", f)
		}
	}
	if err := waitDead(engine.Process.Pid); err != nil {
		t.Errorf("the stale engine still runs: %v", err)
	}
	if syscall.Kill(other.Process.Pid, 0) != nil {
		t.Error("a process that isn't the engine was killed")
	}

	// A second run finds nothing and does nothing.
	rec.ran = nil
	a.cleanupLegacy()
	if len(rec.ran) != 0 {
		t.Errorf("a second cleanup ran %v", rec.ran)
	}
}

func waitDead(pid int) error {
	for deadline := time.Now().Add(3 * time.Second); time.Now().Before(deadline); time.Sleep(50 * time.Millisecond) {
		// A killed child stays a zombie until waited for; signal 0 still succeeds then.
		var ws syscall.WaitStatus
		if p, _ := syscall.Wait4(pid, &ws, syscall.WNOHANG, nil); p == pid {
			return nil
		}
		if syscall.Kill(pid, 0) != nil {
			return nil
		}
	}
	return os.ErrDeadlineExceeded
}

func itoa(n int) string { b, _ := json.Marshal(n); return string(b) }

// ---- tunnels ----

func TestTunnelImportRefusesWhatTheEngineCannotRun(t *testing.T) {
	a, _ := testApp(t)
	for name, text := range map[string]string{
		"script":    testProfile + "up /etc/up.sh\n",
		"directive": testProfile + "fragment 1300\n",
		"no ca":     "client\ndev tun\nremote h 1\nauth-user-pass\n",
	} {
		if _, err := a.TunnelImport(name, []byte(text)); err == nil {
			t.Errorf("%s imported", name)
		}
	}
	if _, err := a.TunnelImport("Office", []byte(testProfile+"fragment 1300\n")); err == nil || !strings.Contains(err.Error(), "fragment") {
		t.Errorf("the refusal doesn't name the directive: %v", err)
	}
	tn, err := a.TunnelImport("Office", []byte(testProfile))
	if err != nil || !tn.NeedsAuth || tn.State != api.Disconnected {
		t.Fatalf("import: %+v %v", tn, err)
	}
	s, _ := a.settings()
	ts, _ := s.Tunnels()
	p := a.profilePath(ts[0].ID)
	for _, path := range []string{p, filepath.Dir(p), a.tunnelsDir()} {
		if fi, err := os.Stat(path); err != nil || fi.Mode().Perm()&0o077 != 0 {
			t.Errorf("%s: %v %v (profiles can hold keys: no group or other access)", path, fi, err)
		}
	}
}

// A tunnel that lists use is protected, and a refused removal changes nothing.
func TestTunnelInUseIsNotRemoved(t *testing.T) {
	a, _ := testApp(t)
	if _, err := a.TunnelImport("Office", []byte(testProfile)); err != nil {
		t.Fatal(err)
	}
	if _, err := a.UpdateConfig(func(c config.Config) (config.Config, error) {
		c, err := config.CreateList(c, "Work", rules.Tunnel)
		if err != nil {
			return c, err
		}
		return config.SetAction(c, "Work", rules.Tunnel, "Office")
	}); err != nil {
		t.Fatal(err)
	}
	s, _ := a.settings()
	ts, _ := s.Tunnels()
	profile := a.profilePath(ts[0].ID)
	if err := a.TunnelRemove("Office"); err == nil || !strings.Contains(err.Error(), "Work") {
		t.Fatalf("remove err = %v, want one naming the list", err)
	}
	if _, err := os.Stat(profile); err != nil {
		t.Errorf("a refused removal deleted the profile: %v", err)
	}
	if _, err := a.UpdateConfig(func(c config.Config) (config.Config, error) { return config.SetAction(c, "Work", rules.Tunnel, "") }); err != nil {
		t.Fatal(err)
	}
	if err := a.TunnelRemove("Office"); err != nil {
		t.Errorf("an unused tunnel can't be removed: %v", err)
	}
	if _, err := os.Stat(profile); !os.IsNotExist(err) {
		t.Error("the profile of a removed tunnel is still there")
	}
}

func TestTunnelConnectAndCredentials(t *testing.T) {
	a, f := testApp(t)
	if _, err := a.TunnelImport("Office", []byte(testProfile)); err != nil {
		t.Fatal(err)
	}
	// The VPN goes on with the only tunnel selected. It needs credentials and has
	// none: it waits for the app instead of starting.
	if err := a.VPNSet(true); err != nil {
		t.Fatal(err)
	}
	if l, _ := a.Tunnels(); l.Tunnels[0].State != api.NeedsAuth || l.Tunnels[0].Need != "auth" {
		t.Errorf("tunnel = %+v", l.Tunnels[0])
	}
	a.host.applyNow()
	if f.count() != 0 {
		t.Error("an engine started for a tunnel with no credentials")
	}
	// The app sends them: the tunnel starts, with them in the engine's options only.
	if err := a.TunnelCredentials("Office", api.Credentials{User: "alice", Pass: "s3cr3t", HaveAuth: true}); err != nil {
		t.Fatal(err)
	}
	a.host.applyNow()
	if f.count() != 1 || !strings.Contains(string(f.latest().last().Tunnels[0].Options), "s3cr3t") {
		t.Fatal("the tunnel didn't start with its credentials")
	}
	if l, _ := a.Tunnels(); l.Tunnels[0].State == api.NeedsAuth {
		t.Error("still waiting after the credentials were sent")
	}
	out, _ := json.Marshal([]any{a.Tunnels, a.host.logLines()})
	st, _ := a.Status()
	b, _ := json.Marshal(st)
	if strings.Contains(string(out)+string(b), "s3cr3t") {
		t.Error("credentials in the API's answers")
	}
	if err := a.VPNSet(false); err != nil {
		t.Fatal(err)
	}
	if !f.latest().isClosed() {
		t.Error("the engine kept running after the VPN was turned off")
	}
}

func TestTunnelRenameReachesTheHost(t *testing.T) {
	a, f := testApp(t)
	if _, err := a.TunnelImport("Office", []byte(strings.Replace(testProfile, "auth-user-pass\n", "", 1)+"<cert>\nC\n</cert>\n<key>\nK\n</key>\n")); err != nil {
		t.Skipf("fixture profile: %v", err)
	}
	if err := a.VPNSet(true); err != nil {
		t.Fatal(err)
	}
	if err := a.TunnelRename("Office", "HQ"); err != nil {
		t.Fatal(err)
	}
	a.host.applyNow()
	if f.count() != 1 || f.latest().last().Tunnels[0].Name != "HQ" {
		t.Errorf("the engine has the old name: %+v", f.latest().last().Tunnels)
	}
}

// ---- lists ----

// A refresh writes each list as a sing-box rule-set and tells the host which
// lists to apply; the lists' entries never go into the engine's config.
func TestRefreshWritesRuleSetsAndTellsTheHost(t *testing.T) {
	a, f := testApp(t)
	onlyCustomLists(t, a,
		config.List{Name: "Work", Custom: true, Action: rules.Direct, Entries: []string{"203.0.113.0/24", "full:api.example.com", "example.org"}},
		config.List{Name: "Via Office", Custom: true, Action: rules.Tunnel, Tunnel: "", Entries: []string{"corp.example"}})
	if _, err := a.TunnelImport("Office", []byte(testProfile)); err != nil {
		t.Fatal(err)
	}
	a.refresh()
	dir := ruleset.Dir(a.host.workDir)
	got, err := os.ReadFile(ruleset.Path(dir, listID("Work")))
	if err != nil || string(got) != `{"rules":[{"ip_cidr":["203.0.113.0/24"]},{"domain":["api.example.com"]},{"domain_suffix":["example.org"]}],"version":3}` {
		t.Errorf("rule set = %s (%v)", got, err)
	}
	if st, _ := a.Status(); len(st.Lists) != 2 || st.Lists[0].Entries != 3 || st.Fetched.IsZero() || st.Error != "" {
		t.Errorf("status = %+v", st)
	}
	// The lists reach the engine by ID and action only.
	if err := a.VPNSet(true); err != nil {
		t.Fatal(err)
	}
	if err := a.TunnelCredentials("Office", api.Credentials{User: "u", Pass: "p", HaveAuth: true}); err != nil {
		t.Fatal(err)
	}
	a.host.applyNow()
	c := f.latest().last()
	if len(c.Lists) != 2 || c.Lists[0].ID != listID("Work") || c.Lists[0].Action != rules.Direct {
		t.Errorf("engine lists = %+v", c.Lists)
	}
	if strings.Contains(mustJSON(c), "api.example.com") {
		t.Error("a list's entries are in the engine's config")
	}
	// Disabling the lists applies none: everything goes through the default tunnel.
	if _, err := a.UpdateConfig(func(c config.Config) (config.Config, error) { c.Disabled = true; return c, nil }); err != nil {
		t.Fatal(err)
	}
	a.refresh()
	a.host.applyNow()
	if c := f.latest().last(); len(c.Lists) != 0 {
		t.Errorf("lists while disabled: %+v", c.Lists)
	}
	if st, _ := a.Status(); st.Enabled {
		t.Error("status says enabled")
	}
}

func mustJSON(v any) string { b, _ := json.Marshal(v); return string(b) }

// A refresh that can't read the settings keeps what the engine runs and says why.
func TestRefreshFailureIsReportedAndKeepsTheLists(t *testing.T) {
	a, _ := testApp(t)
	onlyCustomLists(t, a, config.List{Name: "Work", Custom: true, Action: rules.Direct, Entries: []string{"example.org"}})
	a.refresh()
	s, _ := a.settings()
	s.Close() // the database goes away under the daemon
	a.dbMu.Lock()
	a.db = s
	a.dbMu.Unlock()
	a.refresh()
	if st, _ := a.Status(); st.Error != "" {
		// Status itself needs the database; what matters is that refresh recorded the error.
		t.Logf("status error: %s", st.Error)
	}
	a.mu.Lock()
	e := a.lastErr
	a.mu.Unlock()
	if e == "" {
		t.Error("a failed refresh left no error")
	}
}

var _ = store.ErrNotInitialized
