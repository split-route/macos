//go:build darwin || linux

package main

import (
	"context"
	"net"
	"net/http"
	"sync"
	"time"
)

// The bootstrap is how the engine finds proxy servers' addresses by name: DNS over HTTPS to a public resolver, reached
// directly (not through a tunnel, which isn't up yet). Networks block different resolvers (one drops Google's and Quad9's
// and lets Cloudflare through, another resets Cloudflare), so the app's default is "automatic": ask each one once when
// the connection comes up and use the first that answers.

// bootstrapCandidates in the order they are preferred.
var bootstrapCandidates = []string{"1.1.1.1", "8.8.8.8", "9.9.9.9"}

const (
	probeTimeout = 1500 * time.Millisecond
	// bootstrapSystem is the name for "the system resolver", also the last resort when no resolver answers.
	bootstrapSystem = "system"
)

// bootstrapPicker remembers which resolver answered for as long as the connection stays up.
type bootstrapPicker struct {
	// probe says whether the resolver at ip answers a DoH query from here. Tests replace it.
	probe func(ctx context.Context, ip string) bool

	mu     sync.Mutex
	chosen string
}

func newBootstrapPicker() *bootstrapPicker { return &bootstrapPicker{probe: probeDoH} }

// reset forgets the choice: the connection is down, so the next one asks again (it may be another network by then).
func (p *bootstrapPicker) reset() {
	p.mu.Lock()
	p.chosen = ""
	p.mu.Unlock()
}

// choose returns the resolver to use. A probe sent while the engine runs would go through its tun and find every resolver
// reachable, so with the engine up and nothing chosen yet the current one is kept until the next connection.
func (p *bootstrapPicker) choose(engineRunning bool, current string) string {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.chosen != "" {
		return p.chosen
	}
	if engineRunning {
		if current != "" {
			return current
		}
		return bootstrapCandidates[0]
	}
	p.chosen = p.pick()
	return p.chosen
}

// pick asks every candidate at once and takes the first, in preference order, that answered.
func (p *bootstrapPicker) pick() string {
	ctx, cancel := context.WithTimeout(context.Background(), probeTimeout)
	defer cancel()
	results := make([]chan bool, len(bootstrapCandidates))
	for i, ip := range bootstrapCandidates {
		results[i] = make(chan bool, 1)
		go func() { results[i] <- p.probe(ctx, ip) }()
	}
	for i, ip := range bootstrapCandidates {
		if <-results[i] {
			return ip
		}
	}
	return bootstrapSystem
}

// probeDoH sends one DoH query to ip and says whether a 200 came back. The certificate is checked, as the engine's own
// lookups check it: a network that answers with its own certificate is no resolver for us.
func probeDoH(ctx context.Context, ip string) bool {
	client := &http.Client{
		Timeout: probeTimeout,
		Transport: &http.Transport{
			DialContext:       (&net.Dialer{Timeout: probeTimeout}).DialContext,
			DisableKeepAlives: true,
		},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://"+ip+"/dns-query?name=example.com&type=A", nil)
	if err != nil {
		return false
	}
	req.Header.Set("Accept", "application/dns-json")
	resp, err := client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}
