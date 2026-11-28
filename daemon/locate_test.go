package main

import (
	"context"
	"errors"
	"net/netip"
	"sync/atomic"
	"testing"

	"github.com/split-route/core"
)

func TestServerCountries(t *testing.T) {
	a, _ := testApp(t)
	a.endpoints = map[string]core.Endpoint{
		"t1": {Host: "fi.example", Port: 443},
		"t2": {Host: "fi.example", Port: 8443}, // the same name: resolved once
		"t3": {Host: "edge.example", Port: 443},
		"t4": {Host: "poisoned.example", Port: 443},
		"t5": {Host: "gone.example", Port: 443},
		"t6": {Host: "2a01:4f8:1c1c:c5ac::1", Port: 443}, // an address needs no lookup
	}
	var calls atomic.Int32
	answers := map[string]string{"fi.example": "65.109.211.117", "edge.example": "104.16.1.1", "poisoned.example": "10.10.34.34"}
	old := resolve
	resolve = func(ctx context.Context, host string, bound int, bootstrap string) (netip.Addr, error) {
		calls.Add(1)
		if ip, err := netip.ParseAddr(host); err == nil {
			return ip, nil
		}
		if s, ok := answers[host]; ok {
			return netip.MustParseAddr(s), nil
		}
		return netip.Addr{}, errors.New("no such name")
	}
	t.Cleanup(func() { resolve = old })

	got := a.ServerCountries([]string{"t1", "t2", "t3", "t4", "t5", "t6", "unknown"})
	want := map[string]string{"t1": "FI", "t2": "FI", "t3": "XC", "t4": "", "t6": "DE"}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v (a name that can't be looked up, and an unknown id, are absent)", got, want)
	}
	for id, c := range want {
		if v, ok := got[id]; !ok || v != c {
			t.Errorf("%s: %q (present %v), want %q", id, v, ok, c)
		}
	}
	if n := calls.Load(); n != 5 {
		t.Errorf("%d lookups, want 5 (fi.example once for two servers)", n)
	}
}
