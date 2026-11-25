//go:build darwin || linux

package main

import (
	"context"
	"net"
	"net/netip"
	"runtime"
	"testing"
	"time"

	"github.com/split-route/core"
	"github.com/split-route/macos/daemon/internal/api"
)

func TestTestUsesTheRequestedAddress(t *testing.T) {
	a, f := testApp(t)
	work := ovpn("t3", "Work")
	work.Username, work.Password = "u", "p"
	if err := a.Apply(api.Snapshot{VPN: true, Selected: "t1", LoadAll: true, Tunnels: []api.TunnelSpec{proxy("t1", "Alpha"), work}}); err != nil {
		t.Fatal(err)
	}
	eng := applied2(t, a, f)
	eng.mu.Lock()
	eng.tests = map[string]time.Duration{"t1": time.Millisecond, "t3": time.Millisecond}
	eng.mu.Unlock()
	a.Test([]string{"t1", "t3"}, api.TestOptions{Method: api.TestConnect, URL: "https://example.org/ping"})
	eng.mu.Lock()
	defer eng.mu.Unlock()
	if eng.testLinks["t1"] != "https://example.org/ping" || eng.testLinks["t3"] != "https://example.org/ping" {
		t.Errorf("links = %v", eng.testLinks)
	}
}

func TestTCPProbeMeasuresTheServerAndNamesWhatItCannot(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			c.Close()
		}
	}()
	closed, _ := net.Listen("tcp", "127.0.0.1:0")
	closedPort := closed.Addr().(*net.TCPAddr).Port
	closed.Close()

	a, _ := testApp(t)
	port := ln.Addr().(*net.TCPAddr).Port
	a.endpoints = map[string]core.Endpoint{
		"up":      {Host: "127.0.0.1", Port: port},
		"udp":     {Host: "127.0.0.1", Port: port, UDP: true},
		"refused": {Host: "127.0.0.1", Port: closedPort},
	}
	got := a.Test([]string{"up", "udp", "refused", "unknown"}, api.TestOptions{Method: api.TestTCP, TimeoutMS: 2000})
	if got["up"].MS < 1 || got["up"].Error != "" {
		t.Errorf("up = %+v", got["up"])
	}
	if got["udp"].Error != "UDP only" {
		t.Errorf("a UDP server can't be measured by TCP: %+v", got["udp"])
	}
	if got["refused"].Error != "Failed" {
		t.Errorf("a closed port is a failure: %+v", got["refused"])
	}
	if got["unknown"].Error != "No address" {
		t.Errorf("unknown = %+v", got["unknown"])
	}
}

func TestICMPIsRefusedWhileTheKillSwitchIsArmed(t *testing.T) {
	a, _ := testApp(t)
	if err := a.ks.set(true, true); err != nil {
		t.Fatal(err)
	}
	a.endpoints = map[string]core.Endpoint{"t1": {Host: "127.0.0.1", Port: 443}}
	if got := a.Test([]string{"t1"}, api.TestOptions{Method: api.TestICMP}); got["t1"].Error != "Blocked by the kill switch" {
		t.Errorf("got %+v", got["t1"])
	}
}

func TestPingLoopback(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("ping is built for macOS")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	d, err := pingOnce(ctx, netip.MustParseAddr("127.0.0.1"), 0)
	if err != nil {
		t.Fatalf("ping 127.0.0.1: %v", err)
	}
	if d <= 0 || d > time.Second {
		t.Errorf("took %v", d)
	}
}

func TestTunnelEndpointOfAnOpenVPNProfile(t *testing.T) {
	ep, err := tunnelEndpoint(ovpn("t3", "Work"))
	if err != nil || ep.Host == "" || ep.Port == 0 {
		t.Fatalf("got %+v, %v", ep, err)
	}
	if _, err := tunnelEndpoint(proxy("t1", "Alpha")); err != nil {
		t.Fatal(err)
	}
}

func TestPhysicalInterfaceIsFoundOrSaysWhy(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS routing table")
	}
	idx, err := physicalInterface()
	if err != nil {
		t.Skipf("no default route here: %v", err) // an offline machine
	}
	if ifi, err := net.InterfaceByIndex(idx); err != nil || ifi.Flags&net.FlagLoopback != 0 {
		t.Errorf("index %d: %v %v", idx, ifi, err)
	}
}
