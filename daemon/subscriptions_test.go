//go:build darwin || linux

package main

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/split-route/core"
	"github.com/split-route/macos/daemon/internal/api"
	"github.com/split-route/macos/daemon/internal/config"
	"github.com/split-route/macos/daemon/internal/store"
)

const (
	goodTrojan = "trojan://hunter2@a.example.com:443?sni=a.example.com#Alpha"
	goodVLESS  = "vless://b831381d-6324-4d53-ad4f-8cda48b30811@b.example.com:443?security=tls&sni=b.example.com&type=ws&path=%2Fws#Beta"
	xhttpNode  = "vless://b831381d-6324-4d53-ad4f-8cda48b30811@c.example.com:443?security=tls&type=xhttp#Gamma"
)

func allPerm(t *testing.T, paths ...string) {
	t.Helper()
	for _, p := range paths {
		if fi, err := os.Stat(p); err != nil || fi.Mode().Perm()&0o077 != 0 {
			t.Errorf("%s: %v %v (credentials: no group or other access)", p, fi, err)
		}
	}
}

func TestTunnelsAddFromPastedLinks(t *testing.T) {
	a, f := testApp(t)
	res, err := a.TunnelsAdd([]byte(goodTrojan+"\n"+xhttpNode+"\n"+goodVLESS+"\n"), "", "")
	if err != nil {
		t.Fatal(err)
	}
	if res.Added != 2 || res.Group != "" || len(res.Skipped) != 1 || res.Skipped[0].Label != "Gamma" || !strings.Contains(res.Skipped[0].Reason, "xhttp") {
		t.Fatalf("result = %+v", res)
	}
	l, _ := a.Tunnels()
	if len(l.Tunnels) != 2 || l.Tunnels[0].Name != "Alpha" || l.Tunnels[0].Protocol != "trojan" || l.Tunnels[0].Group != "" ||
		l.Tunnels[1].Protocol != "vless" || l.Tunnels[0].State != api.Disconnected || len(l.Subscriptions) != 0 {
		t.Fatalf("tunnels = %+v", l)
	}
	if l.Tunnels[0].NeedsAuth || len(l.Tunnels[0].Remotes) != 1 || l.Tunnels[0].Remotes[0] != "a.example.com:443" {
		t.Errorf("tunnel 0 = %+v", l.Tunnels[0])
	}
	s, _ := a.settings()
	ts, _ := s.Tunnels()
	allPerm(t, a.optionsPath(ts[0].ID), filepath.Dir(a.optionsPath(ts[0].ID)), a.tunnelsDir())

	// Turning the VPN on selects the first tunnel. It needs no credentials, and every
	// proxy tunnel is loaded (so choosing between them needs no restart); the first is the default.
	if err := a.VPNSet(true); err != nil {
		t.Fatal(err)
	}
	cfg := f.latest().last()
	if len(cfg.Tunnels) != 2 || cfg.Tunnels[0].Protocol != "trojan" || !strings.Contains(string(cfg.Tunnels[0].Options), "hunter2") || cfg.Default != cfg.Tunnels[0].ID {
		t.Fatalf("engine config = default %q, %+v", cfg.Default, cfg.Tunnels)
	}
	f.latest().set(core.Status{Tunnels: []core.TunnelStatus{
		{ID: cfg.Tunnels[0].ID, State: core.StateReady}, {ID: cfg.Tunnels[1].ID, State: core.StateReady}}})
	// "Ready" is not "connected": nothing proved the server answers. Only the selected
	// tunnel shows as in use; the other is loaded but idle.
	if l, _ := a.Tunnels(); l.Tunnels[0].State != api.Ready || l.Tunnels[1].State != api.Disconnected || !l.VPN || l.Selected != "Alpha" {
		t.Errorf("tunnels = %+v", l)
	}
	if st, _ := a.Status(); st.Connected != 1 {
		t.Errorf("the selected tunnel is ready and carries traffic, the other is idle: connected = %d", st.Connected)
	}
}

func TestTunnelsAddRefusesWhatIsNotLinks(t *testing.T) {
	a, _ := testApp(t)
	for name, body := range map[string]string{
		"empty": "", "html": "<html>login</html>", "clash": "proxies:\n  - name: a\n",
	} {
		if _, err := a.TunnelsAdd([]byte(body), "", ""); err == nil {
			t.Errorf("%s was accepted", name)
		}
	}
	// Everything skipped: no error, nothing stored, and the reasons come back.
	res, err := a.TunnelsAdd([]byte(xhttpNode), "", "")
	if err != nil || res.Added != 0 || len(res.Skipped) != 1 {
		t.Errorf("all skipped: %+v %v", res, err)
	}
	if l, _ := a.Tunnels(); len(l.Tunnels) != 0 {
		t.Errorf("tunnels stored: %+v", l.Tunnels)
	}
	// A node the core refuses (a file path in the options) is skipped, not stored.
	bad := `{"outbounds":[{"type":"trojan","tag":"P","server":"a.example.com","server_port":443,"password":"x","tls":{"enabled":true,"certificate_path":"/etc/passwd"}}]}`
	if res, err := a.TunnelsAdd([]byte(bad), "", ""); err != nil || res.Added != 0 || len(res.Skipped) != 1 || !strings.Contains(res.Skipped[0].Reason, "certificate_path") {
		t.Errorf("unsafe options: %+v %v", res, err)
	}
}

func subscriptionServer(t *testing.T, a *app, status int, body string) (url string, hits *int) {
	t.Helper()
	n := 0
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n++
		w.WriteHeader(status)
		w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	a.httpClient = srv.Client()
	return srv.URL + "/sub/TOKEN-s3cret?flag=clash", &n
}

func TestSubscriptionIsKeptAsAGroup(t *testing.T) {
	a, _ := testApp(t)
	body := base64.StdEncoding.EncodeToString([]byte(goodTrojan + "\n" + goodVLESS + "\n" + xhttpNode + "\n"))
	url, _ := subscriptionServer(t, a, 200, body)

	res, err := a.TunnelsAdd(nil, url, "Provider")
	if err != nil {
		t.Fatal(err)
	}
	if res.Added != 2 || res.Group != "Provider" || len(res.Skipped) != 1 {
		t.Fatalf("result = %+v", res)
	}
	l, _ := a.Tunnels()
	if len(l.Subscriptions) != 1 || l.Subscriptions[0].Name != "Provider" || l.Subscriptions[0].Tunnels != 2 ||
		l.Subscriptions[0].UpdatedAt.IsZero() || l.Tunnels[0].Group != "Provider" || l.Tunnels[1].Group != "Provider" {
		t.Fatalf("list = %+v", l)
	}
	// The address carries a token: it is a private file, and the API never returns it.
	s, _ := a.settings()
	subs, _ := s.Subscriptions()
	saved, err := os.ReadFile(a.subscriptionURLPath(subs[0].ID))
	if err != nil || string(saved) != url {
		t.Errorf("saved URL = %q (%v)", saved, err)
	}
	allPerm(t, a.subscriptionURLPath(subs[0].ID), filepath.Dir(a.subscriptionURLPath(subs[0].ID)), a.subscriptionsDir())
	if out, _ := jsonString(l); strings.Contains(out, "TOKEN-s3cret") {
		t.Error("the subscription's address is in the API's answer")
	}

	// A list that uses one of its tunnels keeps the group; then removing it takes tunnels and files.
	onlyCustomLists(t, a, config.List{Name: "social", Action: "tunnel", Tunnel: "Alpha", Custom: true})
	if err := a.TunnelGroupRemove("provider"); err == nil || !strings.Contains(err.Error(), "social") {
		t.Fatalf("a group in use was removed: %v", err)
	}
	if l, _ := a.Tunnels(); len(l.Tunnels) != 2 {
		t.Fatal("the refusal changed something")
	}
	onlyCustomLists(t, a)
	if err := a.TunnelGroupRemove("provider"); err != nil {
		t.Fatal(err)
	}
	l, _ = a.Tunnels()
	if len(l.Tunnels) != 0 || len(l.Subscriptions) != 0 {
		t.Errorf("after removal: %+v", l)
	}
	if _, err := os.Stat(filepath.Dir(a.subscriptionURLPath(subs[0].ID))); !os.IsNotExist(err) {
		t.Errorf("the subscription's files are still there: %v", err)
	}
	if err := a.TunnelGroupRemove("provider"); err == nil {
		t.Error("removing twice succeeded")
	}
}

func TestPastedAddressIsASubscription(t *testing.T) {
	a, _ := testApp(t)
	url, hits := subscriptionServer(t, a, 200, goodTrojan+"\n")
	res, err := a.TunnelsAdd([]byte("  "+url+"\n"), "", "")
	if err != nil || *hits != 1 || res.Added != 1 || res.Group == "" {
		t.Fatalf("%+v %v hits=%d", res, err, *hits)
	}
}

// Nothing that comes back from a failed download may hold the address: its path
// or query is the user's token, and these errors reach the log and the app.
func TestSubscriptionErrorsDoNotLeakTheAddress(t *testing.T) {
	a, _ := testApp(t)
	for name, tt := range map[string]struct {
		status int
		body   string
	}{
		"404":        {404, "not found"},
		"login page": {200, "<html>please sign in</html>"},
		"clash":      {200, "proxies:\n  - name: x\n"},
	} {
		url, _ := subscriptionServer(t, a, tt.status, tt.body)
		_, err := a.TunnelsAdd(nil, url, "")
		if err == nil {
			t.Errorf("%s: expected an error", name)
			continue
		}
		if strings.Contains(err.Error(), "TOKEN-s3cret") || strings.Contains(err.Error(), "flag=") {
			t.Errorf("%s: the error leaks the address: %v", name, err)
		}
	}
	// A server that isn't there: the transport error must not repeat the address either.
	a.httpClient = &http.Client{}
	if _, err := a.TunnelsAdd(nil, "https://127.0.0.1:1/sub/TOKEN-s3cret", ""); err == nil || strings.Contains(err.Error(), "TOKEN-s3cret") {
		t.Errorf("unreachable: %v", err)
	}
	for name, raw := range map[string]string{
		"plain http": "http://example.com/sub/TOKEN-s3cret",
		"userinfo":   "https://user:pw@example.com/sub",
		"no host":    "https:///sub/TOKEN-s3cret",
	} {
		_, err := a.TunnelsAdd(nil, raw, "")
		if err == nil || strings.Contains(err.Error(), "TOKEN-s3cret") || strings.Contains(err.Error(), "user:pw") {
			t.Errorf("%s: %v", name, err)
		}
	}
	if l, _ := a.Tunnels(); len(l.Tunnels) != 0 || len(l.Subscriptions) != 0 {
		t.Errorf("a failed download stored something: %+v", l)
	}
}

func TestSubscriptionBodyLimit(t *testing.T) {
	a, _ := testApp(t)
	url, _ := subscriptionServer(t, a, 200, strings.Repeat("a", maxSubscriptionBody+10))
	if _, err := a.TunnelsAdd(nil, url, ""); err == nil || !strings.Contains(err.Error(), "larger") {
		t.Errorf("an oversized body: %v", err)
	}
}

func TestLinkTunnelOptionsAreHashChecked(t *testing.T) {
	a, _ := testApp(t)
	if _, err := a.TunnelsAdd([]byte(goodTrojan), "", ""); err != nil {
		t.Fatal(err)
	}
	s, _ := a.settings()
	ts, _ := s.Tunnels()
	if err := os.WriteFile(a.optionsPath(ts[0].ID), []byte(`{"type":"trojan","server":"evil.example.com","server_port":443,"password":"x","tls":{"enabled":true}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := a.TunnelConnect("Alpha", api.Credentials{}); err == nil || !strings.Contains(err.Error(), "changed") {
		t.Errorf("a changed options file was started: %v", err)
	}
}

func jsonString(v any) (string, error) {
	b, err := json.Marshal(v)
	return string(b), err
}

func TestParseUserinfo(t *testing.T) {
	for name, tt := range map[string]struct {
		in   string
		want *api.Usage
	}{
		"panel":        {"upload=0; download=204300000000; total=400000000000; expire=1780000000", &api.Usage{Download: 204300000000, Total: 400000000000, Expire: 1780000000}},
		"no expire":    {"upload=5;download=7;total=9", &api.Usage{Upload: 5, Download: 7, Total: 9}},
		"upper case":   {"Upload=1; DOWNLOAD=2", &api.Usage{Upload: 1, Download: 2}},
		"empty":        {"", nil},
		"junk":         {"hello; a=b; download=x", nil},
		"negative":     {"download=-5", nil},
		"expire alone": {"expire=1780000000", nil},
	} {
		got := parseUserinfo(tt.in)
		if (got == nil) != (tt.want == nil) || (got != nil && *got != *tt.want) {
			t.Errorf("%s: %+v, want %+v", name, got, tt.want)
		}
	}
}

// changingServer answers with whatever body and header the test sets last.
func changingServer(t *testing.T, a *app) (url string, set func(status int, body, userinfo string)) {
	t.Helper()
	status, body, info := 200, "", ""
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if info != "" {
			w.Header().Set("Subscription-Userinfo", info)
		}
		w.WriteHeader(status)
		w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	a.httpClient = srv.Client()
	return srv.URL + "/sub/TOKEN-s3cret", func(s int, b, i string) { status, body, info = s, b, i }
}

func TestSubscriptionUpdateKeepsWhatListsUse(t *testing.T) {
	a, _ := testApp(t)
	url, set := changingServer(t, a)
	set(200, goodTrojan+"\n"+goodVLESS+"\n", "upload=1; download=2; total=10; expire=1780000000")
	if _, err := a.TunnelsAdd(nil, url, "Provider"); err != nil {
		t.Fatal(err)
	}
	l, _ := a.Tunnels()
	if u := l.Subscriptions[0].Usage; u == nil || u.Download != 2 || u.Total != 10 || u.Expire != 1780000000 {
		t.Fatalf("usage after add = %+v", u)
	}
	s, _ := a.settings()
	before, _ := s.Subscriptions()
	tunnelsBefore, _ := s.SubscriptionTunnels(before[0].ID)
	alphaID := int64(0)
	for _, x := range tunnelsBefore {
		if x.Name == "Alpha" {
			alphaID = x.ID
		}
	}

	// Alpha stays but its password changes; Beta is dropped; Gamma is new.
	changed := "trojan://newpass@a.example.com:443?sni=a.example.com#Alpha"
	set(200, changed+"\n"+xhttpNode+"\n"+"trojan://p@g.example.com:443?sni=g.example.com#Gamma\n", "upload=5; download=6; total=10")
	res, err := a.TunnelGroupUpdate("provider")
	if err != nil {
		t.Fatal(err)
	}
	if res.Added != 1 || res.Updated != 1 || res.Removed != 1 || res.Kept != 0 {
		t.Fatalf("result = %+v", res)
	}
	tunnelsAfter, _ := s.SubscriptionTunnels(before[0].ID)
	names := map[string]int64{}
	for _, x := range tunnelsAfter {
		names[x.Name] = x.ID
	}
	if names["Alpha"] != alphaID || names["Gamma"] == 0 || names["Beta"] != 0 || len(names) != 2 {
		t.Fatalf("tunnels after = %v (Alpha id was %d)", names, alphaID)
	}
	if _, err := a.linkOptions(tunnelsAfterByName(tunnelsAfter, "Alpha")); err != nil {
		t.Errorf("the updated options fail their hash check: %v", err)
	}
	if _, err := os.Stat(filepath.Dir(a.optionsPath(tunnelsBefore[1].ID))); !os.IsNotExist(err) && tunnelsBefore[1].Name == "Beta" {
		t.Errorf("a removed tunnel's files are still there: %v", err)
	}
	l, _ = a.Tunnels()
	if u := l.Subscriptions[0].Usage; u == nil || u.Download != 6 || u.Expire != 0 {
		t.Errorf("usage after update = %+v (the old expiry must not stay)", u)
	}

	// A dropped tunnel that a list uses stays.
	onlyCustomLists(t, a, config.List{Name: "social", Action: "tunnel", Tunnel: "Gamma", Custom: true})
	set(200, changed+"\n", "")
	res, err = a.TunnelGroupUpdate("provider")
	if err != nil || res.Kept != 1 || res.Removed != 0 {
		t.Fatalf("result = %+v, %v", res, err)
	}
	l, _ = a.Tunnels()
	if len(l.Tunnels) != 2 || l.Subscriptions[0].Usage != nil {
		t.Errorf("list = %+v", l)
	}
}

func tunnelsAfterByName(ts []store.Tunnel, name string) store.Tunnel {
	for _, t := range ts {
		if t.Name == name {
			return t
		}
	}
	return store.Tunnel{}
}

// A bad answer must change nothing: an empty or broken download never wipes the group.
func TestSubscriptionUpdateFailureChangesNothing(t *testing.T) {
	a, _ := testApp(t)
	url, set := changingServer(t, a)
	set(200, goodTrojan+"\n"+goodVLESS+"\n", "")
	if _, err := a.TunnelsAdd(nil, url, "Provider"); err != nil {
		t.Fatal(err)
	}
	for name, tt := range map[string]struct {
		status int
		body   string
	}{
		"500":          {500, "oops"},
		"login page":   {200, "<html>sign in</html>"},
		"only skipped": {200, xhttpNode + "\n"},
	} {
		set(tt.status, tt.body, "")
		_, err := a.TunnelGroupUpdate("Provider")
		if err == nil || strings.Contains(err.Error(), "TOKEN-s3cret") {
			t.Errorf("%s: %v", name, err)
		}
		l, _ := a.Tunnels()
		if len(l.Tunnels) != 2 || l.Subscriptions[0].Error == "" || strings.Contains(l.Subscriptions[0].Error, "TOKEN-s3cret") {
			t.Errorf("%s: list = %+v", name, l)
		}
	}
	set(200, goodTrojan+"\n"+goodVLESS+"\n", "")
	if _, err := a.TunnelGroupUpdate("Provider"); err != nil {
		t.Fatal(err)
	}
	if l, _ := a.Tunnels(); l.Subscriptions[0].Error != "" {
		t.Errorf("a good update left the error: %q", l.Subscriptions[0].Error)
	}
	if _, err := a.TunnelGroupUpdate("nope"); err == nil {
		t.Error("updating an unknown subscription succeeded")
	}
}

func TestSubscriptionEdit(t *testing.T) {
	a, _ := testApp(t)
	url, set := changingServer(t, a)
	set(200, goodTrojan+"\n", "")
	if _, err := a.TunnelsAdd(nil, url, "Provider"); err != nil {
		t.Fatal(err)
	}
	if got, err := a.TunnelGroupURL("provider"); err != nil || got != url {
		t.Fatalf("url = %q, %v", got, err)
	}
	if err := a.TunnelGroupEdit("Provider", "Other", "http://example.com/sub/TOKEN-s3cret"); err == nil || strings.Contains(err.Error(), "TOKEN-s3cret") {
		t.Errorf("plain http accepted or leaked: %v", err)
	}
	if got, _ := a.TunnelGroupURL("Provider"); got != url {
		t.Error("a refused edit changed the address or the name")
	}
	newURL := url + "2"
	if err := a.TunnelGroupEdit("Provider", "Other", newURL); err != nil {
		t.Fatal(err)
	}
	l, _ := a.Tunnels()
	if l.Subscriptions[0].Name != "Other" || l.Tunnels[0].Group != "Other" {
		t.Errorf("list = %+v", l)
	}
	if got, _ := a.TunnelGroupURL("Other"); got != newURL {
		t.Errorf("url = %q", got)
	}
	s, _ := a.settings()
	subs, _ := s.Subscriptions()
	allPerm(t, a.subscriptionURLPath(subs[0].ID))
	// Rename only; and a taken name is refused.
	if err := a.TunnelGroupEdit("Other", "Third", ""); err != nil {
		t.Fatal(err)
	}
	if got, _ := a.TunnelGroupURL("Third"); got != newURL {
		t.Error("a rename lost the address")
	}
	if _, err := a.TunnelsAdd(nil, url, "Fourth"); err != nil {
		t.Fatal(err)
	}
	if err := a.TunnelGroupEdit("Fourth", "third", ""); err == nil {
		t.Error("renamed onto an existing name")
	}
	if err := a.TunnelGroupEdit("Fourth", "", ""); err != nil {
		t.Errorf("an empty edit failed: %v", err)
	}
}

// Names that an import suffixed, or that the user changed, must not make every update replace the tunnel.
func TestSubscriptionUpdateKeepsSuffixedAndRenamedTunnels(t *testing.T) {
	a, _ := testApp(t)
	if _, err := a.TunnelsAdd([]byte(goodTrojan), "", ""); err != nil { // a manual "Alpha"
		t.Fatal(err)
	}
	url, set := changingServer(t, a)
	set(200, goodTrojan+"\n"+goodVLESS+"\n", "")
	if _, err := a.TunnelsAdd(nil, url, "Provider"); err != nil { // stored as "Alpha 2" and "Beta"
		t.Fatal(err)
	}
	if err := a.TunnelRename("Beta", "My Beta"); err != nil {
		t.Fatal(err)
	}
	s, _ := a.settings()
	ids := func() map[string]int64 {
		subs, _ := s.Subscriptions()
		ts, _ := s.SubscriptionTunnels(subs[0].ID)
		m := map[string]int64{}
		for _, x := range ts {
			m[x.Name] = x.ID
		}
		return m
	}
	before := ids()
	if before["Alpha 2"] == 0 || before["My Beta"] == 0 {
		t.Fatalf("setup: %v", before)
	}
	for i := 0; i < 2; i++ {
		res, err := a.TunnelGroupUpdate("Provider")
		if err != nil || res.Added != 0 || res.Removed != 0 || res.Updated != 0 || res.Kept != 0 {
			t.Fatalf("update %d: %+v %v", i, res, err)
		}
	}
	after := ids()
	if len(after) != 2 || after["Alpha 2"] != before["Alpha 2"] || after["My Beta"] != before["My Beta"] {
		t.Errorf("tunnels were replaced: %v -> %v", before, after)
	}
}
