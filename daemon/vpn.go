//go:build darwin || linux

// The VPN switch and the selected tunnel. The engine runs once while the VPN is
// on; the selected tunnel carries all traffic no list names, and choosing another
// switches the engine's selector without a restart. This file decides which
// tunnels the engine loads; the host (host.go) runs them.

package main

import (
	"errors"
	"fmt"
	"log"

	"github.com/split-route/macos/daemon/internal/api"
	"github.com/split-route/macos/daemon/internal/config"
	"github.com/split-route/macos/daemon/internal/store"
)

// desiredTunnels is which stored tunnels the engine loads while the VPN is on:
// every tunnel with no session of its own (cheap, and then choosing between them
// needs no restart), the selected tunnel, and each OpenVPN tunnel that a list
// names (a loaded OpenVPN tunnel opens a real session, so no others).
func desiredTunnels(ts []store.Tunnel, selected int64, lists []config.List) map[int64]bool {
	named := map[string]bool{}
	for _, l := range lists {
		if l.Tunnel != "" {
			named[l.Tunnel] = true
		}
	}
	want := map[int64]bool{}
	for _, t := range ts {
		if t.Kind != store.DefaultKind || t.ID == selected || named[t.Name] {
			want[t.ID] = true
		}
	}
	return want
}

// reconcile makes the host load what the settings say: nothing while the VPN is
// off, the desired tunnels while it is on. A tunnel that failed is not tried
// again here (retrying bad credentials locks accounts); the user's next switch
// or selection does that. Tunnels already loaded keep their credentials.
func (a *app) reconcile() error {
	s, err := a.settings()
	if err != nil {
		return err
	}
	vpn, err := s.VPN()
	if err != nil {
		return err
	}
	ts, err := s.Tunnels()
	if err != nil {
		return err
	}
	cfg, err := a.LoadConfig()
	if err != nil {
		return err
	}
	sel := ""
	if vpn.Selected != 0 {
		sel = tunnelID(vpn.Selected)
	}
	a.host.setSelected(sel)
	a.host.setVPN(vpn.On)
	if !vpn.On {
		return nil
	}
	want := desiredTunnels(ts, vpn.Selected, cfg.Lists)
	for _, t := range ts {
		id := tunnelID(t.ID)
		loaded := a.host.isWanted(id) || a.host.isWaiting(id)
		switch {
		case want[t.ID] && !loaded && !a.host.isFailed(id):
			if err := a.connect(t, api.Credentials{}); err != nil {
				log.Printf("tunnel %s: %v", t.Name, err)
				a.host.markFailed(id, err.Error())
			}
		case !want[t.ID] && loaded:
			a.host.disconnect(id)
		}
	}
	return nil
}

// VPNSet turns the VPN on or off. Turning it on with no tunnel selected selects
// the first one; with no tunnels it is refused.
func (a *app) VPNSet(on bool) error {
	s, err := a.tunnelStore()
	if err != nil {
		return err
	}
	tunnelMu.Lock()
	defer tunnelMu.Unlock()
	if on {
		vpn, err := s.VPN()
		if err != nil {
			return err
		}
		ts, err := s.Tunnels()
		if err != nil {
			return err
		}
		if len(ts) == 0 {
			return errors.New("add a tunnel first")
		}
		if vpn.Selected == 0 {
			if err := s.SetSelected(ts[0].ID); err != nil {
				return err
			}
		}
		a.host.retry("") // the user asked: tunnels that failed may be tried again
	}
	if err := s.SetVPNOn(on); err != nil {
		return err
	}
	if err := a.reconcile(); err != nil {
		return err
	}
	a.host.applyNow() // a switch the user made takes effect now, not after the settle time
	return nil
}

// TunnelSelect makes a tunnel the one that carries traffic no list names. While
// the VPN is on, the engine switches to it without restarting, unless it is an
// OpenVPN tunnel that isn't loaded yet.
func (a *app) TunnelSelect(name string) error {
	s, err := a.tunnelStore()
	if err != nil {
		return err
	}
	tunnelMu.Lock()
	defer tunnelMu.Unlock()
	t, err := a.tunnelByName(s, name)
	if err != nil {
		return err
	}
	if err := s.SetSelected(t.ID); err != nil {
		return err
	}
	a.host.retry(tunnelID(t.ID))
	if err := a.reconcile(); err != nil {
		return err
	}
	a.host.applyNow()
	return nil
}

// selectedGuard refuses to remove the selected tunnel while the VPN is on: the
// engine would lose its default and traffic would silently go direct.
func selectedGuard(s *store.Store, ids ...int64) error {
	vpn, err := s.VPN()
	if err != nil || !vpn.On {
		return err
	}
	for _, id := range ids {
		if id == vpn.Selected {
			return fmt.Errorf("this tunnel is selected and the VPN is on: select another tunnel or turn the VPN off first")
		}
	}
	return nil
}
