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
)

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
