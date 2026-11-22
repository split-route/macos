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
