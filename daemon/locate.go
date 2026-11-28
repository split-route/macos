package main

import (
	"context"
	"net/netip"
	"sync"
	"time"

	"github.com/split-route/macos/daemon/geo"
)

const locateTimeout = 4 * time.Second // per name; 64 ids at 8 a time stay well inside the socket's minute

// resolve is the server's address; a variable so a test needn't ask the network.
var resolve = resolveServer

// ServerCountries looks up the country of each tunnel's server: its name is resolved the way the tests do it (the
// bootstrap resolver over DoH from the physical interface while the engine runs, so a name is never asked of the tun), and
// the address is matched against the embedded database. Servers that share a name are resolved once. An id whose name
// can't be resolved is left out, so the app keeps what it knew.
func (a *app) ServerCountries(ids []string) map[string]string {
	a.mu.Lock()
	eps := a.endpoints
	a.mu.Unlock()
	up, bootstrap := a.host.engineUp()
	bound := 0
	if up {
		var err error
		if bound, err = physicalInterface(); err != nil {
			return nil
		}
	}
	db, err := geo.Open()
	if err != nil {
		return nil
	}
	defer db.Close()

	hosts := map[string]netip.Addr{}
	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, testParallelism)
	for _, id := range ids {
		ep, ok := eps[id]
		if !ok {
			continue
		}
		mu.Lock()
		_, seen := hosts[ep.Host]
		hosts[ep.Host] = netip.Addr{} // claimed; filled in below
		mu.Unlock()
		if seen {
			continue
		}
		wg.Add(1)
		sem <- struct{}{}
		go func(host string) {
			defer func() { <-sem; wg.Done() }()
			ctx, cancel := context.WithTimeout(context.Background(), locateTimeout)
			defer cancel()
			if ip, err := resolve(ctx, host, bound, bootstrap); err == nil {
				mu.Lock()
				hosts[host] = ip
				mu.Unlock()
			}
		}(ep.Host)
	}
	wg.Wait()
	out := make(map[string]string, len(ids))
	for _, id := range ids {
		if ep, ok := eps[id]; ok {
			if ip := hosts[ep.Host]; ip.IsValid() {
				out[id] = db.Country(ip)
			}
		}
	}
	return out
}
