//go:build with_openvpn

package main

import (
	"net"
	"os"
	"os/exec"
	"strconv"
	"testing"
	"time"

	"encoding/json"
	"github.com/split-route/core"
	"github.com/split-route/core/importers/openvpn"
	"github.com/split-route/core/rules"
	"github.com/split-route/core/ruleset"
	"github.com/split-route/macos/daemon/internal/api"
)

// Opt in with SPLITROUTE_TEST_PROFILE=/path/to/client.ovpn (certificate-only, its
// server running) and the sing-box build tags. The host runs the real core
// engine in proxy mode: the tunnel connects, a list applies, and disconnecting
// the last tunnel stops the engine.
func TestHostLive(t *testing.T) {
	prof := os.Getenv("SPLITROUTE_TEST_PROFILE")
	if prof == "" {
		t.Skip("SPLITROUTE_TEST_PROFILE not set")
	}
	text, err := os.ReadFile(prof)
	if err != nil {
		t.Fatal(err)
	}
	p, err := openvpn.Parse(text)
	if err != nil {
		t.Fatal(err)
	}
	ep, err := openvpn.Endpoint(p, "x", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	options, _ := json.Marshal(ep)
	l, _ := net.Listen("tcp", "127.0.0.1:0")
	port := l.Addr().(*net.TCPAddr).Port
	l.Close()
	dir, _ := os.MkdirTemp("", "srl")
	defer os.RemoveAll(dir)

	h := newHost(dir, coreEngine)
	h.settle = 20 * time.Millisecond
	h.inbound = core.Inbound{Mode: "proxy", Listen: "127.0.0.1", Port: port}
	defer h.close()
	if _, err := ruleset.Write(ruleset.Dir(dir), "l-direct", rules.Direct, rules.Entries{Suffixes: []string{"example.com"}}); err != nil {
		t.Fatal(err)
	}
	h.setLists([]hostList{{ID: "l-direct", Name: "Direct", Action: rules.Direct}})
	h.connect("t1", "Lab", options)

	var v view
	for deadline := time.Now().Add(15 * time.Second); time.Now().Before(deadline); time.Sleep(100 * time.Millisecond) {
		if v = h.snapshot("t1"); v.state == api.Connected {
			break
		}
	}
	if v.state != api.Connected || v.local == "" {
		t.Fatalf("the tunnel never connected: %+v", v)
	}
	if running, connected, _, errText := h.engineStatus(); !running || connected != 1 || errText != "" {
		t.Errorf("engine: running %v connected %d error %q", running, connected, errText)
	}
	out, _ := exec.Command("curl", "-s", "-o", "/dev/null", "-m", "8", "-w", "%{http_code}", "-x", "socks5h://127.0.0.1:"+strconv.Itoa(port), "https://example.com/").Output()
	if string(out) != "200" {
		t.Errorf("a direct-list domain returned %q", out)
	}
	if len(h.logLines()) == 0 {
		t.Error("no engine log lines reached the host")
	}
	h.disconnect("t1")
	h.applyNow()
	if running, _, _, _ := h.engineStatus(); running || h.snapshot("t1").state != api.Disconnected {
		t.Error("the engine kept running after the last tunnel was disconnected")
	}
}
