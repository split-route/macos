//go:build darwin || linux

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"sync"
	"time"

	"github.com/split-route/core"
	"github.com/split-route/core/importers/openvpn"
	"github.com/split-route/macos/daemon/internal/api"
)

// TCP and ping tests time the tunnel's own server, outside the tunnel: they say whether the server is up and how far it
// is, not how fast the tunnel is. They need no engine. While the engine runs, its tun takes the Mac's traffic, so a plain
// socket would measure the tunnel (or loop back into it): the sockets here are bound to the physical interface instead.

// rememberEndpoints keeps where every tunnel's server is, for the tests above. An address that can't be read is left out.
func (a *app) rememberEndpoints(ts []api.TunnelSpec) {
	m := make(map[string]core.Endpoint, len(ts))
	for _, t := range ts {
		if ep, err := tunnelEndpoint(t); err == nil {
			m[t.ID] = ep
		}
	}
	a.mu.Lock()
	a.endpoints = m
	a.mu.Unlock()
}

// tunnelEndpoint reads a tunnel's server. An OpenVPN profile is parsed again, as options() does, so the address is the
// one the engine will dial.
func tunnelEndpoint(t api.TunnelSpec) (core.Endpoint, error) {
	if t.Protocol != api.ProtocolOpenVPN {
		return core.TunnelEndpoint(t.Protocol, t.Options)
	}
	p, err := openvpn.Parse([]byte(t.Profile))
	if err != nil {
		return core.Endpoint{}, err
	}
	p.KeyEncrypted = false // only the address is wanted: placeholders stand for the credentials the profile asks for
	ep, err := openvpn.Endpoint(p, "x", "x", "x", "")
	if err != nil {
		return core.Endpoint{}, err
	}
	b, err := json.Marshal(ep)
	if err != nil {
		return core.Endpoint{}, err
	}
	return core.TunnelEndpoint(t.Protocol, b)
}

// probe runs a TCP or ping test on each tunnel, a few at a time.
func (a *app) probe(ids []string, o api.TestOptions) map[string]api.TestResult {
	timeout := o.Timeout(a.host.testTimeout)
	a.mu.Lock()
	eps := a.endpoints
	a.mu.Unlock()
	up, bootstrap := a.host.engineUp()
	bound := 0
	var boundErr error
	if up {
		bound, boundErr = physicalInterface()
	}
	armed, _ := a.ks.status()
	out := make(map[string]api.TestResult, len(ids))
	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, testParallelism)
	for _, id := range ids {
		ep, ok := eps[id]
		var fail string
		switch {
		case !ok:
			fail = "No address"
		case o.Method == api.TestTCP && ep.UDP:
			fail = "UDP only"
		case o.Method == api.TestICMP && armed:
			fail = "Blocked by the kill switch" // pf passes root's TCP and UDP, not ICMP
		case boundErr != nil:
			fail = "No network"
		}
		if fail != "" {
			mu.Lock()
			out[id] = api.TestResult{Error: fail}
			mu.Unlock()
			continue
		}
		wg.Add(1)
		sem <- struct{}{}
		go func() {
			defer func() { <-sem; wg.Done() }()
			ctx, cancel := context.WithTimeout(context.Background(), timeout)
			defer cancel()
			r := probeOne(ctx, o.Method, ep, bound, bootstrap)
			mu.Lock()
			out[id] = r
			mu.Unlock()
		}()
	}
	wg.Wait()
	return out
}

func probeOne(ctx context.Context, method string, ep core.Endpoint, bound int, bootstrap string) api.TestResult {
	ip, err := resolveServer(ctx, ep.Host, bound, bootstrap)
	var d time.Duration
	if err == nil {
		if method == api.TestICMP {
			d, err = pingOnce(ctx, ip, bound)
		} else {
			d, err = tcpConnect(ctx, ip, ep.Port, bound)
		}
	}
	if err != nil {
		return testFailure(ctx, err)
	}
	return api.TestResult{MS: max(int(d.Milliseconds()), 1)} // under a millisecond still answered
}

// resolveServer is the server's address. A name is looked up by the system resolver while the engine is off; while it
// runs (bound set) the system's lookup goes into the tun, so the name is asked of the bootstrap resolver over DoH, from
// the physical interface, like the engine's own lookup. IPv4 first: a ping is IPv4 only, and most servers have one.
func resolveServer(ctx context.Context, host string, bound int, bootstrap string) (netip.Addr, error) {
	if ip, err := netip.ParseAddr(host); err == nil {
		return ip.Unmap(), nil
	}
	var ips []netip.Addr
	var err error
	if bound == 0 {
		ips, err = net.DefaultResolver.LookupNetIP(ctx, "ip", host)
	} else {
		ips, err = dohLookup(ctx, host, bound, bootstrap)
	}
	if err != nil {
		return netip.Addr{}, fmt.Errorf("the server's name can't be looked up: %w", err)
	}
	for _, ip := range ips {
		if ip.Unmap().Is4() {
			return ip.Unmap(), nil
		}
	}
	if len(ips) > 0 {
		return ips[0], nil
	}
	return netip.Addr{}, errors.New("the server's name has no address")
}

// dohLookup asks the bootstrap resolver (a DoH server's address; "" or "system" use the first candidate) for A records.
func dohLookup(ctx context.Context, host string, bound int, resolver string) ([]netip.Addr, error) {
	if resolver == "" || resolver == bootstrapSystem {
		resolver = bootstrapCandidates[0]
	}
	if _, err := netip.ParseAddr(resolver); err != nil {
		return nil, errors.New("the resolver isn't an address")
	}
	client := &http.Client{
		Timeout: probeTimeout * 2,
		Transport: &http.Transport{
			DialContext:       (&net.Dialer{Timeout: probeTimeout, Control: bindControl(bound)}).DialContext,
			DisableKeepAlives: true,
		},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://"+resolver+"/dns-query?type=A&name="+host, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/dns-json")
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("the resolver answered %d", resp.StatusCode)
	}
	var body struct {
		Answer []struct {
			Type int    `json:"type"`
			Data string `json:"data"`
		} `json:"Answer"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<16)).Decode(&body); err != nil {
		return nil, err
	}
	var ips []netip.Addr
	for _, r := range body.Answer {
		if ip, err := netip.ParseAddr(r.Data); err == nil && r.Type == 1 {
			ips = append(ips, ip)
		}
	}
	return ips, nil
}

// tcpConnect times one connection to ip:port, bound to the physical interface when bound is set.
func tcpConnect(ctx context.Context, ip netip.Addr, port, bound int) (time.Duration, error) {
	d := net.Dialer{Control: bindControl(bound)}
	start := time.Now()
	c, err := d.DialContext(ctx, "tcp", netip.AddrPortFrom(ip, uint16(port)).String())
	if err != nil {
		return 0, err
	}
	took := time.Since(start)
	_ = c.Close()
	return took, nil
}
