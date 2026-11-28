//go:build darwin || linux

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"strings"
	"time"

	"github.com/split-route/core"
	"github.com/split-route/core/rules"
	"github.com/split-route/macos/daemon/internal/api"
)

// routingState is what the last snapshot said that route_test needs: the servers' names, the selected one, the default
// route and the switches that change the route rules. Servers are known by name even when the VPN is off, so a test can
// say where traffic would go once connected.
type routingState struct {
	known    bool
	tunnels  []api.TunnelSpec // IDs and names are used; options and profiles are not kept
	selected string
	final    api.FinalSpec
	quic     bool
	stun     bool
	ipv6     bool
}

func (a *app) rememberRouting(s api.Snapshot) {
	ts := make([]api.TunnelSpec, len(s.Tunnels))
	for i, t := range s.Tunnels {
		ts[i] = api.TunnelSpec{ID: t.ID, Name: t.Name}
	}
	a.mu.Lock()
	a.routing = routingState{known: true, tunnels: ts, selected: s.Selected, final: s.Final, quic: s.BlockQUIC && s.ListsOn, stun: s.BlockSTUN, ipv6: s.BlockIPv6}
	a.mu.Unlock()
}

// placeholderOptions stand in for a server's real options: the rule walk never starts a tunnel, it only needs the names to
// exist, so no profile, key or password is read for it.
var placeholderOptions = json.RawMessage(`{"type":"trojan","server":"example.invalid","server_port":443,"password":"x"}`)

// RouteTest says where a connection to a name or address would go by the lists and routes the engine has now (or would
// have once connected: servers need not be connected).
func (a *app) RouteTest(query string) (api.RouteResult, error) {
	a.mu.Lock()
	rs := a.routing
	a.mu.Unlock()
	if !rs.known {
		return api.RouteResult{}, errors.New("Splitroute hasn't sent its settings to the service yet")
	}
	lists := a.host.listsCopy()
	byName := map[string]string{}
	var names = map[string]string{} // ID → name, to say a server by its name
	cfg := core.Config{WorkDir: a.host.workDir, BlockQUIC: rs.quic, BlockSTUN: rs.stun, BlockIPv6: rs.ipv6}
	for _, t := range rs.tunnels {
		byName[strings.ToLower(t.Name)] = t.ID
		names[t.ID] = t.Name
		cfg.Tunnels = append(cfg.Tunnels, core.Tunnel{ID: t.ID, Name: t.Name, Protocol: "trojan", Options: placeholderOptions})
	}
	if len(cfg.Tunnels) == 0 {
		cfg.Tunnels = []core.Tunnel{{ID: "none", Name: "none", Protocol: "trojan", Options: placeholderOptions}}
	}
	cfg.Default = rs.selected
	if _, ok := names[cfg.Default]; !ok {
		cfg.Default = cfg.Tunnels[0].ID
	}
	cfg.Final = core.Final{Action: rs.final.Action}
	if rs.final.Action == rules.Tunnel && rs.final.Tunnel != "" {
		if id, ok := byName[strings.ToLower(rs.final.Tunnel)]; ok {
			cfg.Final.Tunnel = id
		} else {
			cfg.Final = core.Final{Action: rules.Block} // like the engine: a server that isn't there never hands its traffic on
		}
	}
	for _, l := range lists {
		cl := core.List{ID: l.ID, Name: l.Name, Action: l.Action, Binary: l.Binary}
		if l.Action == rules.Tunnel && l.Tunnel != "" {
			if id, ok := byName[strings.ToLower(l.Tunnel)]; ok {
				cl.Tunnel = id
			} else {
				cl.Action = rules.Block
			}
		}
		cfg.Lists = append(cfg.Lists, cl)
	}
	res, err := core.RouteTest(cfg, query)
	if err != nil {
		return api.RouteResult{}, err
	}
	return api.RouteResult{Kind: res.Kind, List: res.List, Action: res.Action, Tunnel: names[res.Tunnel], Notes: res.Notes}, nil
}

// exitURLs are asked, in this order, for the address the internet sees. Fixed here: the socket never names one.
var exitURLs = []string{"https://api.country.is/", "https://ipwho.is/"}

// exitV4URL has only an A record, so the server reaches it over IPv4. It names no country, so the address is then
// looked up at the services above (their address is part of the path, and only after it parsed as IPv4).
const exitV4URL = "https://api4.ipify.org/?format=json"

const exitMaxBody = 16 << 10

// exitIPv4 asks for the IPv4 address the internet sees, then its country; a failed country lookup leaves it out.
func exitIPv4(eng Engine) (api.ExitIP, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	body, err := eng.Fetch(ctx, exitV4URL, exitMaxBody)
	cancel()
	if err != nil {
		return api.ExitIP{}, err
	}
	out, err := parseExit(body)
	if err != nil {
		return api.ExitIP{}, err
	}
	if ip, err := netip.ParseAddr(out.IP); err != nil || !ip.Is4() {
		return api.ExitIP{}, errors.New("the answer isn't an IPv4 address")
	}
	for _, u := range exitURLs {
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		body, err := eng.Fetch(ctx, u+out.IP, exitMaxBody)
		cancel()
		if err != nil {
			continue
		}
		if e, err := parseExit(body); err == nil && e.IP == out.IP && e.Country != "" {
			out.Country = e.Country
			break
		}
	}
	return out, nil
}

// ExitIP asks for the address the internet sees through the selected server, and its country.
func (a *app) ExitIP() (api.ExitIP, error) {
	a.host.mu.Lock()
	eng := a.host.eng
	v4 := a.host.blockIPv6
	a.host.mu.Unlock()
	if eng == nil {
		return api.ExitIP{}, errors.New("The connection is off")
	}
	if v4 {
		// With Block IPv6 on, show an IPv4 address: the server may reach a dual-stack service over IPv6 and report that.
		if e, err := exitIPv4(eng); err == nil {
			return e, nil
		}
	}
	var last error
	for _, u := range exitURLs {
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		body, err := eng.Fetch(ctx, u, exitMaxBody)
		cancel()
		if err != nil {
			last = err
			continue
		}
		if e, err := parseExit(body); err == nil {
			return e, nil
		} else {
			last = err
		}
	}
	return api.ExitIP{}, fmt.Errorf("couldn't look up the address: %w", last)
}

// parseExit reads the answer of an address service: {"ip": …, "country": "FI"} or {"ip": …, "country_code": "FI", …}.
// Only an address and a two-letter code leave this function, whatever else the answer holds.
func parseExit(body []byte) (api.ExitIP, error) {
	var v struct {
		IP          string `json:"ip"`
		Country     string `json:"country"`
		CountryCode string `json:"country_code"`
	}
	if err := json.Unmarshal(body, &v); err != nil {
		return api.ExitIP{}, errors.New("the answer isn't what was expected")
	}
	ip, err := netip.ParseAddr(strings.TrimSpace(v.IP))
	if err != nil {
		return api.ExitIP{}, errors.New("the answer has no address")
	}
	out := api.ExitIP{IP: ip.Unmap().String()}
	for _, c := range []string{v.CountryCode, v.Country} {
		if len(c) == 2 && c[0] >= 'A' && c[0] <= 'Z' && c[1] >= 'A' && c[1] <= 'Z' {
			out.Country = c
			break
		}
	}
	return out, nil
}
