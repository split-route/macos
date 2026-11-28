package geo

import (
	"net/netip"
	"testing"
)

func TestCountry(t *testing.T) {
	db, err := Open()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	for name, tc := range map[string]struct{ ip, want string }{
		"a Finnish server (country.is answered FI for it)": {"65.109.211.117", "FI"},
		"a German address":            {"2a01:4f8:1c1c:c5ac::1", "DE"},
		"mapped IPv4":                 {"::ffff:65.109.211.117", "FI"},
		"cloudflare v4 is a CDN edge": {"104.16.1.1", ""},
		"cloudflare v6 is a CDN edge": {"2606:4700::1", ""},
		"a poisoned private answer":   {"10.10.34.34", ""},
		"loopback":                    {"127.0.0.1", ""},
		"documentation range":         {"203.0.113.9", ""},
		"carrier-grade NAT":           {"100.64.1.1", ""},
		"unspecified":                 {"0.0.0.0", ""},
	} {
		if got := db.Country(netip.MustParseAddr(tc.ip)); got != tc.want {
			t.Errorf("%s: %s = %q, want %q", name, tc.ip, got, tc.want)
		}
	}
	if db.Country(netip.Addr{}) != "" {
		t.Error("the zero address has no country")
	}
}
