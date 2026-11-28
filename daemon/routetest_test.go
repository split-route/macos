//go:build darwin || linux

package main

import (
	"testing"

	"github.com/split-route/core/rules"
	"github.com/split-route/macos/daemon/internal/api"
)

func TestRouteTestUsesTheListsTheEngineHas(t *testing.T) {
	a, _ := testApp(t)
	if _, err := a.RouteTest("example.com"); err == nil {
		t.Error("before any snapshot the service has nothing to test with")
	}
	s := api.Snapshot{
		VPN: false, ListsOn: true, Selected: "t1", BlockIPv6: true,
		Tunnels: []api.TunnelSpec{proxy("t1", "Alpha"), proxy("t2", "Beta")},
		Lists: []api.ListSpec{
			{Name: "Ads", Action: rules.Block, Format: api.FormatCustom, Entries: []string{"ads.example"}},
			{Name: "Work", Action: rules.Direct, Format: api.FormatCustom, Entries: []string{"corp.example"}},
			{Name: "TV", Action: rules.Tunnel, Tunnel: "Beta", Format: api.FormatCustom, Entries: []string{"tv.example"}},
			{Name: "Gone", Action: rules.Tunnel, Tunnel: "Missing", Format: api.FormatCustom, Entries: []string{"gone.example"}},
		},
	}
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		query, kind, list string
		action            rules.Action
		tunnel            string
	}{
		{"x.ads.example", "list", "Ads", rules.Block, ""},
		{"corp.example", "list", "Work", rules.Direct, ""},
		{"tv.example", "list", "TV", rules.Tunnel, "Beta"}, // by name, though the VPN is off
		{"gone.example", "list", "Gone", rules.Block, ""},  // the server isn't there: blocked, never sent elsewhere
		{"other.example", "default", "", rules.Tunnel, ""},
		{"192.168.0.1", "local", "", rules.Direct, ""},
		{"2001:db8::1", "ipv6", "", rules.Block, ""},
	} {
		got, err := a.RouteTest(tc.query)
		if err != nil {
			t.Fatalf("%s: %v", tc.query, err)
		}
		if got.Kind != tc.kind || got.List != tc.list || got.Action != tc.action || got.Tunnel != tc.tunnel {
			t.Errorf("%s: got %+v", tc.query, got)
		}
	}
	// Routing off: no lists apply, only the default route.
	s.ListsOn = false
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	if got, err := a.RouteTest("x.ads.example"); err != nil || got.Kind != "default" {
		t.Errorf("lists off: %+v, %v", got, err)
	}
	if _, err := a.RouteTest("not a name"); err == nil {
		t.Error("a bad query was accepted")
	}
}

func TestApplyBlockIPv6ReachesTheEngine(t *testing.T) {
	a, f := testApp(t)
	s := api.Snapshot{VPN: true, Selected: "t1", BlockIPv6: true, Tunnels: []api.TunnelSpec{proxy("t1", "Alpha")}}
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	if !applied(t, a, f).BlockIPv6 {
		t.Error("BlockIPv6 did not reach the engine")
	}
	s.BlockIPv6 = false
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	if applied(t, a, f).BlockIPv6 {
		t.Error("it stayed on")
	}
}

func TestParseExit(t *testing.T) {
	for name, tc := range map[string]struct {
		body string
		want api.ExitIP
		ok   bool
	}{
		// copied from the services' real answers
		"country.is":                        {`{"ip":"65.109.211.117","country":"FI"}`, api.ExitIP{IP: "65.109.211.117", Country: "FI"}, true},
		"ipwho.is":                          {`{"ip":"65.109.211.117","success":true,"type":"IPv4","continent":"Europe","country":"Finland","country_code":"FI","flag":{"emoji":"🇫🇮"}}`, api.ExitIP{IP: "65.109.211.117", Country: "FI"}, true},
		"ipv6":                              {`{"ip":"2001:db8::1","country":"DE"}`, api.ExitIP{IP: "2001:db8::1", Country: "DE"}, true},
		"mapped":                            {`{"ip":"::ffff:1.2.3.4","country":"DE"}`, api.ExitIP{IP: "1.2.3.4", Country: "DE"}, true},
		"no country":                        {`{"ip":"1.2.3.4"}`, api.ExitIP{IP: "1.2.3.4"}, true},
		"bad country is dropped, not shown": {`{"ip":"1.2.3.4","country":"<b>x</b>","country_code":"fi"}`, api.ExitIP{IP: "1.2.3.4"}, true},
		"not json":                          {`<html>blocked</html>`, api.ExitIP{}, false},
		"no address":                        {`{"country":"FI"}`, api.ExitIP{}, false},
		"bad address":                       {`{"ip":"not an ip","country":"FI"}`, api.ExitIP{}, false},
	} {
		got, err := parseExit([]byte(tc.body))
		if (err == nil) != tc.ok || got != tc.want {
			t.Errorf("%s: %+v, %v", name, got, err)
		}
	}
}

func TestExitIPShowsIPv4WhenIPv6IsBlocked(t *testing.T) {
	a, f := testApp(t)
	if err := a.Apply(api.Snapshot{VPN: true, Selected: "t1", BlockIPv6: true, Tunnels: []api.TunnelSpec{proxy("t1", "Alpha")}}); err != nil {
		t.Fatal(err)
	}
	eng := applied2(t, a, f)
	eng.mu.Lock()
	eng.fetched = map[string][]byte{
		exitV4URL:                   []byte(`{"ip":"203.0.113.9"}`),
		exitURLs[0] + "203.0.113.9": []byte(`{"ip":"203.0.113.9","country":"DE"}`),
		exitURLs[0]:                 []byte(`{"ip":"2001:db8::1","country":"DE"}`),
	}
	eng.mu.Unlock()
	got, err := a.ExitIP()
	if err != nil || got != (api.ExitIP{IP: "203.0.113.9", Country: "DE"}) {
		t.Errorf("IPv6 blocked: want the IPv4 address and its country: %+v, %v", got, err)
	}
	eng.mu.Lock()
	eng.fetched = map[string][]byte{exitV4URL: []byte(`{"ip":"2001:db8::1"}`), exitURLs[0]: []byte(`{"ip":"198.51.100.4","country":"NL"}`)}
	eng.mu.Unlock()
	if got, err = a.ExitIP(); err != nil || got.IP != "198.51.100.4" {
		t.Errorf("an IPv6 answer from the IPv4 service falls back to the services: %+v, %v", got, err)
	}
}

func TestExitIPAsksTheServicesInOrder(t *testing.T) {
	a, f := testApp(t)
	if _, err := a.ExitIP(); err == nil {
		t.Error("with the connection off there is no address to look up")
	}
	if err := a.Apply(api.Snapshot{VPN: true, Selected: "t1", Tunnels: []api.TunnelSpec{proxy("t1", "Alpha")}}); err != nil {
		t.Fatal(err)
	}
	eng := applied2(t, a, f)
	eng.mu.Lock()
	eng.fetched = map[string][]byte{exitURLs[0]: []byte(`<html>`), exitURLs[1]: []byte(`{"ip":"203.0.113.9","country_code":"NL"}`)}
	eng.mu.Unlock()
	got, err := a.ExitIP()
	if err != nil || got != (api.ExitIP{IP: "203.0.113.9", Country: "NL"}) {
		t.Errorf("a bad first answer falls through to the next service: %+v, %v", got, err)
	}
}
