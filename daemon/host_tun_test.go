//go:build with_openvpn

package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/split-route/core/importers/openvpn"
	"github.com/split-route/macos/daemon/internal/api"
)

func sh(name string, args ...string) string {
	out, _ := exec.Command(name, args...).CombinedOutput()
	return string(out)
}

// Opt in, as root, with SPLITROUTE_TEST_TUN=1 and SPLITROUTE_TEST_PROFILE=...
// (certificate-only, its server running). Build the test binary the way
// build-app.sh builds the service (CGO_ENABLED=0) and run it with sudo: it
// creates the real tun, so the machine's traffic goes into it for a few seconds
// (the profile's server drops everything), and it checks the tun and its route
// appear, and are gone after the last tunnel is disconnected.
func TestHostLiveTun(t *testing.T) {
	prof := os.Getenv("SPLITROUTE_TEST_PROFILE")
	if os.Getenv("SPLITROUTE_TEST_TUN") != "1" || prof == "" || os.Geteuid() != 0 {
		t.Skip("SPLITROUTE_TEST_TUN=1, SPLITROUTE_TEST_PROFILE and root are required")
	}
	text, err := os.ReadFile(prof)
	if err != nil {
		t.Fatal(err)
	}
	p, err := openvpn.Parse(text)
	if err != nil {
		t.Fatal(err)
	}
	ep, err := openvpn.Endpoint(p, "x", "", "")
	if err != nil {
		t.Fatal(err)
	}
	options, _ := json.Marshal(ep)
	dir, _ := os.MkdirTemp("", "srt")
	defer os.RemoveAll(dir)

	before := sh("route", "-n", "get", "1.1.1.1")
	h := newHost(dir, coreEngine)
	h.settle = 20 * time.Millisecond
	defer h.close()
	h.connect("t1", "Lab", options)
	var v view
	for deadline := time.Now().Add(20 * time.Second); time.Now().Before(deadline); time.Sleep(100 * time.Millisecond) {
		if v = h.snapshot("t1"); v.state == api.Connected {
			break
		}
	}
	if v.state != api.Connected {
		t.Fatalf("the tunnel never connected: %+v\n%s", v, strings.Join(h.logLines(), "\n"))
	}
	time.Sleep(time.Second)
	during := sh("route", "-n", "get", "1.1.1.1")
	ifc := sh("ifconfig")
	t.Logf("route to 1.1.1.1 before:\n%s\nduring:\n%s", before, during)
	if !strings.Contains(ifc, "172.19.0.1") {
		t.Errorf("no interface with the engine's address 172.19.0.1 while connected")
	}
	if !strings.Contains(during, "interface: utun") {
		t.Errorf("traffic isn't routed into a utun while connected:\n%s", during)
	}

	h.disconnect("t1")
	h.applyNow()
	time.Sleep(2 * time.Second)
	after := sh("route", "-n", "get", "1.1.1.1")
	if strings.Contains(sh("ifconfig"), "172.19.0.1") {
		t.Error("the engine's interface is still there after the last tunnel was disconnected")
	}
	if strings.Contains(after, "172.19.0.1") || iface(after) != iface(before) {
		t.Errorf("the route did not return: before %q, after %q", iface(before), iface(after))
	}
}

func iface(route string) string {
	for _, l := range strings.Split(route, "\n") {
		if k, v, ok := strings.Cut(strings.TrimSpace(l), ":"); ok && k == "interface" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}
