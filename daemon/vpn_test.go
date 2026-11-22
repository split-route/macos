//go:build darwin || linux

package main

import (
	"fmt"
	"strings"
	"testing"

	"github.com/split-route/core"
	"github.com/split-route/core/rules"
	"github.com/split-route/macos/daemon/internal/api"
	"github.com/split-route/macos/daemon/internal/config"
	"github.com/split-route/macos/daemon/internal/store"
)

func tunnelNames(c core.Config) string {
	var n []string
	for _, t := range c.Tunnels {
		n = append(n, t.Name)
	}
	return strings.Join(n, ",")
}

// A setup with two OpenVPN tunnels (Office, Home) and two proxy nodes (Alpha, Beta).
func vpnApp(t *testing.T) (*app, *fakes) {
	t.Helper()
	a, f := testApp(t)
	onlyCustomLists(t, a)
	for _, n := range []string{"Office", "Home"} {
		if _, err := a.TunnelImport(n, []byte(testProfile)); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := a.TunnelsAdd([]byte(goodTrojan+"\n"+goodVLESS), "", ""); err != nil {
		t.Fatal(err)
	}
	return a, f
}

func TestVPNNeedsATunnel(t *testing.T) {
	a, f := testApp(t)
	if err := a.VPNSet(true); err == nil || !strings.Contains(err.Error(), "add a tunnel") {
		t.Errorf("VPN on with no tunnels: %v", err)
	}
	if l, _ := a.Tunnels(); l.VPN {
		t.Error("the refusal turned the VPN on")
	}
	if f.count() != 0 {
		t.Error("an engine started")
	}
}

// The engine loads every proxy tunnel, the selected tunnel, and the OpenVPN
// tunnels that lists name: a loaded OpenVPN tunnel is a real session, so no others.
func TestVPNLoadsProxiesTheSelectedAndTheNamed(t *testing.T) {
	a, f := vpnApp(t)
	if err := a.TunnelSelect("Beta"); err != nil {
		t.Fatal(err)
	}
	if f.count() != 0 {
		t.Fatal("selecting with the VPN off started an engine")
	}
	if err := a.VPNSet(true); err != nil {
		t.Fatal(err)
	}
	c := f.latest().last()
	if got := tunnelNames(c); got != "Alpha,Beta" {
		t.Errorf("loaded %q, want only the proxy tunnels (Office and Home are OpenVPN and not selected)", got)
	}
	if c.Default == "" || !strings.Contains(string(c.Tunnels[1].Options), "vless") || c.Default != c.Tunnels[1].ID {
		t.Errorf("default %q, want Beta's id", c.Default)
	}

	// A list that names Home makes the engine load it; it needs credentials first.
	onlyCustomLists(t, a, config.List{Name: "Work", Custom: true, Action: rules.Tunnel, Tunnel: "Home", Entries: []string{"corp.example"}})
	a.refresh()
	a.host.applyNow()
	if got := tunnelNames(f.latest().last()); got != "Alpha,Beta" {
		t.Errorf("Home loaded without credentials: %q", got)
	}
	if l, _ := a.Tunnels(); l.Tunnels[1].Name != "Home" || l.Tunnels[1].State != api.NeedsAuth {
		t.Errorf("Home = %+v", l.Tunnels[1])
	}
	if err := a.TunnelCredentials("Home", api.Credentials{User: "u", Pass: "p", HaveAuth: true}); err != nil {
		t.Fatal(err)
	}
	a.host.applyNow()
	if got := tunnelNames(f.latest().last()); got != "Alpha,Beta,Home" && got != "Home,Alpha,Beta" {
		t.Errorf("after credentials: %q", got)
	}
	// Taking the list away unloads Home again, and drops its credentials.
	onlyCustomLists(t, a)
	a.refresh()
	a.host.applyNow()
	if got := tunnelNames(f.latest().last()); got != "Alpha,Beta" {
		t.Errorf("after the list went: %q", got)
	}
	if f.count() != 1 {
		t.Errorf("%d engines: every change reloads the one engine", f.count())
	}
}

// Choosing another proxy tunnel changes the default of the one running engine.
func TestSelectingSwitchesTheDefaultOfTheRunningEngine(t *testing.T) {
	a, f := vpnApp(t)
	if err := a.TunnelSelect("Alpha"); err != nil {
		t.Fatal(err)
	}
	if err := a.VPNSet(true); err != nil {
		t.Fatal(err)
	}
	first := f.latest().last()
	alpha, beta := first.Tunnels[0].ID, first.Tunnels[1].ID
	if first.Default != alpha {
		t.Fatalf("default %q, want %q", first.Default, alpha)
	}
	if err := a.TunnelSelect("Beta"); err != nil {
		t.Fatal(err)
	}
	c := f.latest().last()
	if f.count() != 1 || c.Default != beta || tunnelNames(c) != "Alpha,Beta" {
		t.Errorf("engines %d, default %q (want %q), loaded %q", f.count(), c.Default, beta, tunnelNames(c))
	}
	if l, _ := a.Tunnels(); l.Selected != "Beta" || !l.VPN {
		t.Errorf("selected %q, vpn %v", l.Selected, l.VPN)
	}
	if err := a.TunnelSelect("Nowhere"); err == nil {
		t.Error("selected a tunnel that doesn't exist")
	}
}

// Selecting an OpenVPN tunnel that needs credentials stops the engine until they
// arrive: traffic never silently takes another tunnel.
func TestSelectingAnOpenVPNTunnelWaitsForCredentials(t *testing.T) {
	a, f := vpnApp(t)
	if err := a.TunnelSelect("Alpha"); err != nil {
		t.Fatal(err)
	}
	if err := a.VPNSet(true); err != nil {
		t.Fatal(err)
	}
	engine := f.latest()
	if err := a.TunnelSelect("Office"); err != nil {
		t.Fatal(err)
	}
	if !engine.isClosed() {
		t.Error("the engine kept running with a default that is waiting for credentials")
	}
	if l, _ := a.Tunnels(); l.Selected != "Office" || l.Tunnels[0].State != api.NeedsAuth {
		t.Errorf("tunnels = %+v", l)
	}
	if err := a.TunnelCredentials("Office", api.Credentials{User: "u", Pass: "p", HaveAuth: true}); err != nil {
		t.Fatal(err)
	}
	a.host.applyNow()
	got := f.latest().last()
	var office core.Tunnel
	for _, tn := range got.Tunnels {
		if tn.Name == "Office" {
			office = tn
		}
	}
	if f.latest().isClosed() || office.ID == "" || got.Default != office.ID || !strings.Contains(string(office.Options), `"password":"p"`) {
		t.Errorf("not running with Office as the default (default %q): %q", got.Default, tunnelNames(got))
	}
}

func TestSelectedTunnelCanNotBeRemovedWhileTheVPNIsOn(t *testing.T) {
	a, _ := vpnApp(t)
	if err := a.TunnelSelect("Alpha"); err != nil {
		t.Fatal(err)
	}
	if err := a.VPNSet(true); err != nil {
		t.Fatal(err)
	}
	if err := a.TunnelRemove("Alpha"); err == nil || !strings.Contains(err.Error(), "selected") {
		t.Errorf("removed the selected tunnel: %v", err)
	}
	if err := a.TunnelRemove("Beta"); err != nil {
		t.Errorf("an unselected tunnel can't be removed: %v", err)
	}
	// Its group too.
	if err := a.VPNSet(false); err != nil {
		t.Fatal(err)
	}
	if err := a.TunnelRemove("Alpha"); err != nil {
		t.Errorf("with the VPN off the selected tunnel goes: %v", err)
	}
	if l, _ := a.Tunnels(); l.Selected != "" {
		t.Errorf("selection after removing: %q", l.Selected)
	}
}

func TestSelectedGroupCanNotBeRemovedWhileTheVPNIsOn(t *testing.T) {
	a, _ := testApp(t)
	onlyCustomLists(t, a)
	body := goodTrojan + "\n" + goodVLESS
	url, _ := subscriptionServer(t, a, 200, body)
	if _, err := a.TunnelsAdd(nil, url, "Provider"); err != nil {
		t.Fatal(err)
	}
	if err := a.VPNSet(true); err != nil { // selects the first tunnel, which is in the group
		t.Fatal(err)
	}
	if err := a.TunnelGroupRemove("Provider"); err == nil || !strings.Contains(err.Error(), "selected") {
		t.Errorf("removed the group of the selected tunnel: %v", err)
	}
	if err := a.VPNSet(false); err != nil {
		t.Fatal(err)
	}
	if err := a.TunnelGroupRemove("Provider"); err != nil {
		t.Errorf("with the VPN off: %v", err)
	}
}

// What the user left on stays on across a restart of the service, and what they
// left off stays off.
func TestVPNComesBackAfterARestart(t *testing.T) {
	a, f := vpnApp(t)
	if err := a.TunnelSelect("Beta"); err != nil {
		t.Fatal(err)
	}
	if err := a.VPNSet(true); err != nil {
		t.Fatal(err)
	}
	dir := a.stateDir
	a.host.close()
	a.closeSettings()

	g := &fakes{}
	b := newApp(dir, g.factory)
	b.host.settle = 0
	b.runDir = a.runDir
	t.Cleanup(func() { b.host.close(); b.closeSettings() })
	b.startAutoConnect()
	b.host.applyNow()
	if g.count() != 1 || g.latest().last().Default == "" || tunnelNames(g.latest().last()) != "Alpha,Beta" {
		t.Fatalf("after a restart: engines %d", g.count())
	}
	if l, _ := b.Tunnels(); !l.VPN || l.Selected != "Beta" {
		t.Errorf("vpn %v selected %q", l.VPN, l.Selected)
	}
	_ = f
	if err := b.VPNSet(false); err != nil {
		t.Fatal(err)
	}
	b.host.close()
	b.closeSettings()
	h := &fakes{}
	c := newApp(dir, h.factory)
	t.Cleanup(func() { c.host.close(); c.closeSettings() })
	c.startAutoConnect()
	c.host.applyNow()
	if h.count() != 0 {
		t.Error("the VPN came back after the user turned it off")
	}
}

// A node the engine refuses fails alone, and no later change retries it: only the
// user's next switch or selection does.
func TestAFailedNodeIsNotRetriedUntilTheUserActs(t *testing.T) {
	a, f := vpnApp(t)
	s, _ := a.settings()
	ts, _ := s.Tunnels()
	var betaID string
	for _, tn := range ts {
		if tn.Name == "Beta" {
			betaID = tunnelID(tn.ID)
		}
	}
	rejected := true
	f.startErr = func(c core.Config) error {
		for _, tn := range c.Tunnels {
			if rejected && tn.ID == betaID {
				return fmt.Errorf("sing-box: initialize outbound[1]: vless[t-%s]: unsupported option", betaID)
			}
		}
		return nil
	}
	if err := a.TunnelSelect("Alpha"); err != nil {
		t.Fatal(err)
	}
	if err := a.VPNSet(true); err != nil {
		t.Fatal(err)
	}
	if got := tunnelNames(f.latest().last()); got != "Alpha" {
		t.Fatalf("loaded %q, want Alpha alone: Beta was refused", got)
	}
	if l, _ := a.Tunnels(); l.Tunnels[3].Name != "Beta" || l.Tunnels[3].State != api.Failed || !strings.Contains(l.Tunnels[3].Error, "unsupported option") {
		t.Errorf("Beta = %+v", l.Tunnels[3])
	}
	// A list refresh reconciles; it must not try Beta again.
	engines := f.count()
	a.refresh()
	a.host.applyNow()
	if f.count() != engines || tunnelNames(f.latest().last()) != "Alpha" {
		t.Errorf("a refresh retried the failed node: engines %d, loaded %q", f.count(), tunnelNames(f.latest().last()))
	}
	// The user turns the VPN off and on: now it is tried again, and works.
	rejected = false
	if err := a.VPNSet(false); err != nil {
		t.Fatal(err)
	}
	if err := a.VPNSet(true); err != nil {
		t.Fatal(err)
	}
	if got := tunnelNames(f.latest().last()); got != "Alpha,Beta" {
		t.Errorf("after the user retried: %q", got)
	}
}

func TestDesiredTunnels(t *testing.T) {
	ts := []store.Tunnel{{ID: 1, Name: "Office", Kind: "openvpn"}, {ID: 2, Name: "Home", Kind: "openvpn"}, {ID: 3, Name: "Node", Kind: "vless"}}
	got := desiredTunnels(ts, 1, []config.List{{Name: "L", Tunnel: "Home"}, {Name: "M"}})
	if !got[1] || !got[2] || !got[3] || len(got) != 3 {
		t.Errorf("selected + named + proxy: %v", got)
	}
	got = desiredTunnels(ts, 3, nil)
	if got[1] || got[2] || !got[3] {
		t.Errorf("only the proxy tunnel: %v", got)
	}
}
