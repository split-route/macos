//go:build darwin || linux

package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/split-route/macos/daemon/internal/api"
)

type pfCalls struct {
	calls []string
	fail  string // a call containing this fails
}

func (p *pfCalls) run(args []string, stdin string) (string, error) {
	c := strings.Join(args, " ")
	p.calls = append(p.calls, c)
	if p.fail != "" && strings.Contains(c, p.fail) {
		return "boom", errors.New("exit 1")
	}
	if c == "-E" {
		return "pf enabled\nToken : 4242\n", nil
	}
	return "", nil
}

func ksApp(t *testing.T) (*app, *pfCalls) {
	a, _ := testApp(t)
	p := &pfCalls{}
	a.ks.run = p.run
	return a, p
}

func TestKillSwitchRules(t *testing.T) {
	for _, lan := range []bool{false, true} {
		r := killSwitchRules(lan)
		if !strings.HasSuffix(r, "block drop out quick all\n") {
			t.Errorf("lan=%v: the block rule must be last:\n%s", lan, r)
		}
		if got := strings.Contains(r, "192.168.0.0/16"); got != lan {
			t.Errorf("lan=%v: LAN rule present = %v", lan, got)
		}
		for _, want := range []string{
			"pass quick on lo0 all no state\n",
			"pass out quick inet from 172.19.0.0/30 to any no state\n", // the engine's tun (core/build.go)
			"user 0",
		} {
			if !strings.Contains(r, want) {
				t.Errorf("lan=%v: missing %q", lan, want)
			}
		}
		// Apple's pf never matches `on utun` against utunN: that rule dropped all tun traffic.
		if strings.Contains(r, "on utun") {
			t.Errorf("lan=%v: interface-group match on utun:\n%s", lan, r)
		}
	}
}

func TestApplyArmsBeforeTheEngineAndOffRemoves(t *testing.T) {
	a, p := ksApp(t)
	s := api.Snapshot{VPN: true, ListsOn: true, Selected: "t1", KillSwitch: true, Tunnels: []api.TunnelSpec{proxy("t1", "Alpha")}}
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(p.calls, "|"); got != "-E|-a "+ksAnchor+" -f -" {
		t.Fatalf("arm calls = %s", got)
	}
	if armed, _ := a.ks.status(); !armed {
		t.Fatal("not armed")
	}
	if b, _ := os.ReadFile(a.ks.marker); string(b) != "nolan\n" {
		t.Fatalf("marker = %q", b)
	}
	s.VPN = false // the VPN switch off is the user's intent: the rules go
	p.calls = nil
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(p.calls, "|"); got != "-a "+ksAnchor+" -F all|-X 4242" {
		t.Fatalf("disarm calls = %s", got)
	}
	if armed, _ := a.ks.status(); armed {
		t.Fatal("still armed")
	}
	if _, err := os.Stat(a.ks.marker); !os.IsNotExist(err) {
		t.Fatalf("marker left behind: %v", err)
	}
}

func TestMarkerSurvivesAFailedFlush(t *testing.T) {
	a, p := ksApp(t)
	s := api.Snapshot{VPN: true, Selected: "t1", KillSwitch: true, KillSwitchLAN: true, Tunnels: []api.TunnelSpec{proxy("t1", "Alpha")}}
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	p.fail = "-F all"
	s.KillSwitch = false
	if err := a.Apply(s); err == nil {
		t.Fatal("a failed flush was reported as done")
	}
	if b, _ := os.ReadFile(a.ks.marker); string(b) != "lan\n" {
		t.Fatalf("marker = %q: the rules may still be loaded, so a reboot must restore them", b)
	}
}

func TestRestoreFromTheMarkerAfterReboot(t *testing.T) {
	for _, tc := range []struct {
		name, marker string
		want         string // "" = nothing runs
		lan          bool
	}{
		{"none", "", "", false},
		{"lan", "lan\n", "-E|-a " + ksAnchor + " -f -", true},
		{"nolan", "nolan\n", "-E|-a " + ksAnchor + " -f -", false},
		{"garbage blocks with no LAN", "???", "-E|-a " + ksAnchor + " -f -", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			a, p := ksApp(t)
			if tc.marker != "" {
				if err := os.WriteFile(a.ks.marker, []byte(tc.marker), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			a.ks.restore()
			if got := strings.Join(p.calls, "|"); got != tc.want {
				t.Fatalf("calls = %q, want %q", got, tc.want)
			}
			if tc.want != "" {
				if armed, _ := a.ks.status(); !armed {
					t.Fatal("not armed")
				}
			}
		})
	}
}

func TestArmRefusesWithoutAMarker(t *testing.T) {
	a, p := ksApp(t)
	blocker := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(blocker, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	a.ks.marker = filepath.Join(blocker, ksMarker) // the directory is a file: the write fails
	if err := a.ks.set(true, false); err == nil {
		t.Fatal("armed without a marker")
	}
	if len(p.calls) != 0 {
		t.Fatalf("pfctl ran: %v", p.calls)
	}
}

func TestKillSwitchStaysArmedWhenTheEngineFails(t *testing.T) {
	a, p := ksApp(t)
	bad := proxy("t1", "Alpha")
	bad.Options = []byte(`{"type":"vless","server":"x","server_port":1,"uuid":"u","detour":"direct"}`) // refused: the tunnel fails
	s := api.Snapshot{VPN: true, Selected: "t1", KillSwitch: true, Tunnels: []api.TunnelSpec{bad}}
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	for _, c := range p.calls {
		if strings.Contains(c, "-F") || strings.HasPrefix(c, "-X") {
			t.Fatalf("a failed tunnel removed the rules: %v", p.calls)
		}
	}
	if armed, _ := a.ks.status(); !armed {
		t.Fatal("not armed")
	}
}

func TestApplyRefusesToStartUnprotected(t *testing.T) {
	a, p := ksApp(t)
	p.fail = "-f -"
	s := api.Snapshot{VPN: true, Selected: "t1", KillSwitch: true, Tunnels: []api.TunnelSpec{proxy("t1", "Alpha")}}
	if err := a.Apply(s); err == nil {
		t.Fatal("apply succeeded without the rules")
	}
	if a.host.vpnOn {
		t.Fatal("the VPN started without the kill switch")
	}
	if _, msg := a.ks.status(); msg == "" {
		t.Fatal("no error in status")
	}
}

func TestKillSwitchRearmsEveryApplyAndOffFlushesOnlyWhenUnknown(t *testing.T) {
	a, p := ksApp(t)
	s := api.Snapshot{VPN: true, Selected: "t1", KillSwitch: true, Tunnels: []api.TunnelSpec{proxy("t1", "Alpha")}}
	_ = a.Apply(s)
	_ = a.Apply(s)
	if n := strings.Count(strings.Join(p.calls, "|"), "-f -"); n != 2 {
		t.Fatalf("rules loaded %d times, want 2 (undoes an outside flush)", n)
	}
	if n := strings.Count(strings.Join(p.calls, "|"), "-E"); n != 1 {
		t.Fatalf("pf enabled %d times, want 1", n)
	}
	// A fresh service doesn't know what the last run left: the first "off" flushes once, then it stays quiet.
	b, q := ksApp(t)
	off := api.Snapshot{}
	_ = b.Apply(off)
	_ = b.Apply(off)
	if len(q.calls) != 1 || !strings.Contains(q.calls[0], "-F all") {
		t.Fatalf("off calls = %v", q.calls)
	}
}
