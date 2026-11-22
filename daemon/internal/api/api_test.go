//go:build darwin || linux

package api

import (
	"encoding/json"
	"fmt"
	"net"
	"reflect"
	"slices"
	"strings"
	"testing"

	"github.com/split-route/macos/daemon/internal/config"
)

// noBackend fails every call; "presets" must not need the daemon.
type noBackend struct{}

func (noBackend) Status() (Status, error)            { panic("unexpected") }
func (noBackend) LoadConfig() (config.Config, error) { panic("unexpected") }
func (noBackend) UpdateConfig(func(config.Config) (config.Config, error)) (config.Config, error) {
	panic("unexpected")
}
func (noBackend) AvailableLists() ([]string, error) { panic("unexpected") }
func (noBackend) RefreshImport(string) error        { panic("unexpected") }
func (noBackend) Restart() error                    { panic("unexpected") }

func TestHandleSocket(t *testing.T) {
	srv, cli := net.Pipe()
	go Handle(srv, noBackend{})
	if _, err := cli.Write([]byte(`{"cmd":"presets"}` + "\n")); err != nil {
		t.Fatal(err)
	}
	var r Response
	if err := json.NewDecoder(cli).Decode(&r); err != nil || !r.OK || len(r.Presets) != len(config.Presets) {
		t.Fatalf("got %+v, %v", r, err)
	}
}

// memBackend keeps the config in memory, applying updates like the store
// (f, then Validate).
type memBackend struct {
	noBackend
	cfg       config.Config
	refreshed []string
	restarts  int
}

func (m *memBackend) Restart() error {
	m.restarts++
	return nil
}

func (m *memBackend) RefreshImport(name string) error {
	m.refreshed = append(m.refreshed, name)
	return nil
}

func (m *memBackend) LoadConfig() (config.Config, error) { return m.cfg, nil }
func (m *memBackend) UpdateConfig(f func(config.Config) (config.Config, error)) (config.Config, error) {
	c, err := f(m.cfg)
	if err == nil {
		err = c.Validate()
	}
	if err != nil {
		return config.Config{}, err
	}
	m.cfg = c
	return c, nil
}

func TestListEditCommands(t *testing.T) {
	m := &memBackend{cfg: config.Default()}
	pos := 0
	steps := []struct {
		req  Request
		ok   bool
		want string // list names and actions after
	}{
		{Request{Cmd: "list_create", Name: "Work", Action: "block"}, true, "ir-cidr:direct Work:block"},
		{Request{Cmd: "list_create", Name: "Work", Action: "block"}, false, ""},
		{Request{Cmd: "list_create", Action: "block"}, false, ""},
		{Request{Cmd: "list_enable", Name: "telegram", Action: "tunnel"}, true, "ir-cidr:direct Work:block telegram:tunnel"},
		{Request{Cmd: "list_set_action", Name: "Work", Action: "direct"}, true, "ir-cidr:direct Work:direct telegram:tunnel"},
		{Request{Cmd: "list_set_action", Name: "Work", Action: "nope"}, false, ""},
		{Request{Cmd: "list_move", Name: "telegram"}, false, ""},
		{Request{Cmd: "list_move", Name: "telegram", Position: &pos}, true, "telegram:tunnel ir-cidr:direct Work:direct"},
		{Request{Cmd: "list_rename", Name: "Work", NewName: "Office"}, true, "telegram:tunnel ir-cidr:direct Office:direct"},
		{Request{Cmd: "list_remove", Name: "ir-cidr"}, true, "telegram:tunnel Office:direct"},
		{Request{Cmd: "list_remove", Name: "ir-cidr"}, false, ""},
		{Request{Cmd: "list_import", Name: "Ads", Action: "block", URL: "https://example.com/hosts"}, true, "telegram:tunnel Office:direct Ads:block"},
		{Request{Cmd: "list_import", Name: "Ads2", Action: "block", URL: "http://example.com/hosts"}, false, ""},
		{Request{Cmd: "list_import", Name: "Ads3", Action: "block", URL: "https://u:p@example.com/hosts"}, false, ""},
	}
	for _, s := range steps {
		r := Respond(m, s.req)
		if r.OK != s.ok {
			t.Fatalf("%+v: ok=%v error=%q", s.req, r.OK, r.Error)
		}
		if !s.ok {
			continue
		}
		var got []string
		for _, l := range r.Config.Lists {
			got = append(got, l.Name+":"+string(l.Action))
		}
		if strings.Join(got, " ") != s.want {
			t.Fatalf("%+v: got %v, want %s", s.req, got, s.want)
		}
	}

	r := Respond(m, Request{Cmd: "entries_add", Name: "Office", Entries: []string{"example.com", "Example.com", "AS13335"}})
	if !r.OK || r.Edit == nil || r.Edit.Added != 2 || r.Edit.Duplicates != 1 {
		t.Fatalf("entries_add: %+v %+v", r, r.Edit)
	}
	r = Respond(m, Request{Cmd: "entries_remove", Name: "Office", Entries: []string{"example.com", "example.net"}})
	if !r.OK || r.Edit.Removed != 1 || len(r.Edit.NotFound) != 1 {
		t.Fatalf("entries_remove: %+v %+v", r, r.Edit)
	}
	if got := m.cfg.Lists[1].Entries; len(got) != 1 || got[0] != "AS13335" {
		t.Fatalf("stored entries %q", got)
	}
	r = Respond(m, Request{Cmd: "entries_set", Name: "Office", Entries: []string{"198.51.100.0/24", "example.org"}})
	if !r.OK || r.Edit == nil || r.Edit.Added != 2 || !slices.Equal(r.Config.Lists[1].Entries, []string{"198.51.100.0/24", "example.org"}) {
		t.Fatalf("entries_set: %+v %+v", r, r.Edit)
	}
	if r := Respond(m, Request{Cmd: "list_refresh", Name: "Ads"}); !r.OK || len(m.refreshed) != 1 || r.Config != nil {
		t.Fatalf("list_refresh: %+v %v", r, m.refreshed)
	}
	if r := Respond(m, Request{Cmd: "entries_add", Name: "Ads", Entries: []string{"example.com"}}); r.OK {
		t.Fatal("entries added to an import")
	}
	// A failed edit stores nothing and reports no counts.
	before := m.cfg
	if r := Respond(m, Request{Cmd: "entries_add", Name: "Office", Entries: []string{"10.0.0.1"}}); r.OK || r.Edit != nil {
		t.Fatalf("invalid entry: %+v", r)
	}
	if !reflect.DeepEqual(m.cfg, before) {
		t.Fatal("failed edit changed the config")
	}
}

func TestListCreateFromText(t *testing.T) {
	var b strings.Builder
	for i := range config.MaxEntries + 1 {
		fmt.Fprintf(&b, "h%d.example.com\n", i)
	}
	big := b.String()
	tests := []struct {
		name    string
		text    string
		ok      bool
		entries []string
		skipped int
	}{
		{"hosts file", "# comment\n127.0.0.1 localhost\n0.0.0.0 ads.example.com tracker.example.net\n0.0.0.0 bad_name!\n", true,
			[]string{"full:ads.example.com", "full:tracker.example.net"}, 1},
		{"plain entries", "198.51.100.0/24\nexample.org\nAS13335\n10.0.0.0/8\n", true,
			[]string{"198.51.100.0/24", "example.org", "AS13335"}, 1},
		{"domain set", ".example.com\nwww.example.net\n", true,
			[]string{"full:www.example.net", "example.com"}, 0},
		{"no entries", "# only notes\n!adblock\n", false, nil, 0},
		{"too broad", "0.0.0.0/4\n", false, nil, 0},
		{"over the cap", big, false, nil, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			m := &memBackend{cfg: config.Default()}
			before := m.cfg
			r := Respond(m, Request{Cmd: "list_create", Name: "File", Action: "block", Text: tt.text})
			if r.OK != tt.ok {
				t.Fatalf("ok=%v error=%q", r.OK, r.Error)
			}
			if !tt.ok {
				if !reflect.DeepEqual(m.cfg, before) {
					t.Fatal("a refused text changed the config")
				}
				return
			}
			l := m.cfg.Lists[len(m.cfg.Lists)-1]
			if l.Name != "File" || !l.Custom || l.Action != "block" || !slices.Equal(l.Entries, tt.entries) {
				t.Fatalf("list %+v, want entries %q", l, tt.entries)
			}
			if r.Edit == nil || r.Edit.Added != len(tt.entries) || r.Edit.Skipped != tt.skipped {
				t.Fatalf("edit %+v, want added %d skipped %d", r.Edit, len(tt.entries), tt.skipped)
			}
		})
	}
	// A taken name creates nothing.
	m := &memBackend{cfg: config.Default()}
	if r := Respond(m, Request{Cmd: "list_create", Name: "ir-cidr", Action: "block", Text: "example.com\n"}); r.OK {
		t.Fatal("created a list over an existing name")
	}
}

type listsBackend struct{ noBackend }

func (listsBackend) AvailableLists() ([]string, error) { return []string{"ir-cidr", "brand-new"}, nil }

func TestListsCatalog(t *testing.T) {
	r := Respond(listsBackend{}, Request{Cmd: "lists"})
	if !r.OK || len(r.Catalog) != 2 {
		t.Fatalf("%+v", r)
	}
	if c := r.Catalog[0]; c.Name != "ir-cidr" || c.Title != "Iran IP ranges" || c.Action != "direct" {
		t.Fatalf("known list: %+v", c)
	}
	if c := r.Catalog[1]; c.Name != "brand-new" || c.Title != "brand-new" || c.Description != "" {
		t.Fatalf("unknown list falls back to its name: %+v", c)
	}
}

func TestRestart(t *testing.T) {
	m := &memBackend{cfg: config.Default()}
	before := m.cfg
	r := Respond(m, Request{Cmd: "restart"})
	if !r.OK || m.restarts != 1 || r.Config != nil || !reflect.DeepEqual(m.cfg, before) {
		t.Fatalf("restart: %+v, %d restarts", r, m.restarts)
	}
}

// tunnelBackend records tunnel calls.
type tunnelBackend struct {
	noBackend
	calls []string
	creds Credentials
}

func (b *tunnelBackend) Tunnels() (TunnelList, error) {
	return TunnelList{Tunnels: []Tunnel{{Name: "Work", State: Connected}}}, nil
}
func (b *tunnelBackend) TunnelImport(name string, p []byte) (Tunnel, error) {
	b.calls = append(b.calls, fmt.Sprintf("import %s %d", name, len(p)))
	return Tunnel{Name: name}, nil
}
func (b *tunnelBackend) TunnelRemove(n string) error {
	b.calls = append(b.calls, "remove "+n)
	return nil
}
func (b *tunnelBackend) TunnelRename(n, m string) error {
	b.calls = append(b.calls, "rename "+n+" "+m)
	return nil
}
func (b *tunnelBackend) TunnelAutoConnect(n string, on bool) error {
	b.calls = append(b.calls, fmt.Sprintf("auto %s %v", n, on))
	return nil
}
func (b *tunnelBackend) TunnelConnect(n string, c Credentials) error {
	b.calls, b.creds = append(b.calls, "connect "+n), c
	return nil
}
func (b *tunnelBackend) TunnelCredentials(n string, c Credentials) error {
	b.calls, b.creds = append(b.calls, "credentials "+n), c
	return nil
}
func (b *tunnelBackend) VPNSet(on bool) error {
	b.calls = append(b.calls, fmt.Sprintf("vpn %v", on))
	return nil
}
func (b *tunnelBackend) TunnelSelect(n string) error {
	b.calls = append(b.calls, "select "+n)
	return nil
}
func (b *tunnelBackend) TunnelsAdd(text []byte, url, name string) (AddResult, error) {
	b.calls = append(b.calls, fmt.Sprintf("add %d %q %q", len(text), url, name))
	return AddResult{Added: 2, Skipped: []Skipped{{Label: "x", Reason: "y"}}, Group: name}, nil
}
func (b *tunnelBackend) TunnelGroupRemove(n string) error {
	b.calls = append(b.calls, "group-remove "+n)
	return nil
}
func (b *tunnelBackend) TunnelGroupUpdate(n string) (UpdateResult, error) {
	b.calls = append(b.calls, "group-update "+n)
	return UpdateResult{Added: 1, Updated: 2, Removed: 3}, nil
}
func (b *tunnelBackend) TunnelGroupURL(n string) (string, error) {
	b.calls = append(b.calls, "group-url "+n)
	return "https://example.com/sub/TOKEN", nil
}
func (b *tunnelBackend) TunnelGroupEdit(n, newName, url string) error {
	b.calls = append(b.calls, "group-edit "+n+" "+newName+" "+url)
	return nil
}
func (b *tunnelBackend) TunnelDisconnect(n string) error {
	b.calls = append(b.calls, "disconnect "+n)
	return nil
}
func (b *tunnelBackend) TunnelLogs(n string) ([]string, error) { return []string{"line"}, nil }

func TestTunnelCommands(t *testing.T) {
	yes := true
	tests := []struct {
		req     Request
		call    string
		wantErr string
	}{
		{req: Request{Cmd: "tunnel_import", Name: "Work", Text: "remote h"}, call: "import Work 8"},
		{req: Request{Cmd: "tunnel_import", Name: "Work"}, wantErr: "needs a name and the profile"},
		{req: Request{Cmd: "tunnel_remove", Name: "Work"}, call: "remove Work"},
		{req: Request{Cmd: "tunnel_remove"}, wantErr: "needs a name"},
		{req: Request{Cmd: "tunnel_rename", Name: "Work", NewName: "Office"}, call: "rename Work Office"},
		{req: Request{Cmd: "tunnel_auto_connect", Name: "Work", Enabled: &yes}, call: "auto Work true"},
		{req: Request{Cmd: "tunnel_auto_connect", Name: "Work"}, wantErr: "needs enabled"},
		{req: Request{Cmd: "tunnel_connect", Name: "Work"}, call: "connect Work"},
		{req: Request{Cmd: "tunnel_disconnect", Name: "Work"}, call: "disconnect Work"},
		{req: Request{Cmd: "vpn_set", Enabled: &yes}, call: "vpn true"},
		{req: Request{Cmd: "vpn_set"}, wantErr: "needs enabled"},
		{req: Request{Cmd: "tunnel_select", Name: "Work"}, call: "select Work"},
		{req: Request{Cmd: "tunnel_select"}, wantErr: "needs a name"},
		{req: Request{Cmd: "tunnels_add", Text: "vless://x"}, call: `add 9 "" ""`},
		{req: Request{Cmd: "tunnels_add", URL: "https://example.com/s", Name: "P"}, call: `add 0 "https://example.com/s" "P"`},
		{req: Request{Cmd: "tunnels_add"}, wantErr: "either text or a url"},
		{req: Request{Cmd: "tunnels_add", Text: "a", URL: "https://example.com"}, wantErr: "either text or a url"},
		{req: Request{Cmd: "tunnel_group_remove", Name: "P"}, call: "group-remove P"},
		{req: Request{Cmd: "tunnel_group_remove"}, wantErr: "needs the subscription's name"},
		{req: Request{Cmd: "tunnel_group_update", Name: "P"}, call: "group-update P"},
		{req: Request{Cmd: "tunnel_group_update"}, wantErr: "needs the subscription's name"},
		{req: Request{Cmd: "tunnel_group_url", Name: "P"}, call: "group-url P"},
		{req: Request{Cmd: "tunnel_group_edit", Name: "P", NewName: "Q", URL: "https://x"}, call: "group-edit P Q https://x"},
		{req: Request{Cmd: "tunnel_group_edit"}, wantErr: "needs the subscription's name"},
		{req: Request{Cmd: "tunnel_nope", Name: "Work"}, wantErr: "unknown command"},
	}
	for _, tt := range tests {
		b := &tunnelBackend{}
		r := Respond(b, tt.req)
		if tt.wantErr != "" {
			if r.OK || !strings.Contains(r.Error, tt.wantErr) {
				t.Errorf("%s: got %+v, want error %q", tt.req.Cmd, r, tt.wantErr)
			}
			continue
		}
		if !r.OK || !slices.Equal(b.calls, []string{tt.call}) {
			t.Errorf("%s: got %+v, calls %q, want %q", tt.req.Cmd, r, b.calls, tt.call)
		}
	}
	if r := Respond(&tunnelBackend{}, Request{Cmd: "tunnels_add", URL: "https://example.com/s", Name: "P"}); !r.OK || r.Added == nil || r.Added.Added != 2 || r.Added.Group != "P" || len(r.Added.Skipped) != 1 {
		t.Errorf("tunnels_add: %+v", r)
	}
	// Credentials reach the backend, and only as credentials.
	b := &tunnelBackend{}
	Respond(b, Request{Cmd: "tunnel_credentials", Name: "Work", Username: "u", Password: "p", KeyPassword: "k"})
	if want := (Credentials{User: "u", Pass: "p", KeyPass: "k", HaveAuth: true, HaveKey: true}); b.creds != want {
		t.Errorf("creds = %+v, want %+v", b.creds, want)
	}
	b = &tunnelBackend{}
	Respond(b, Request{Cmd: "tunnel_connect", Name: "Work"})
	if b.creds.HaveAuth || b.creds.HaveKey {
		t.Errorf("connect without credentials claims to have some: %+v", b.creds)
	}
	if r := Respond(b, Request{Cmd: "tunnels"}); !r.OK || len(r.Tunnels.Tunnels) != 1 {
		t.Errorf("tunnels: %+v", r)
	}
	if r := Respond(b, Request{Cmd: "tunnel_logs", Name: "Work"}); !r.OK || len(r.Logs) != 1 {
		t.Errorf("tunnel_logs: %+v", r)
	}
	// check parses without touching the backend; scripts show up for the confirm step.
	r := Respond(&tunnelBackend{}, Request{Cmd: "tunnel_check", Text: "remote h 1\nup x.sh\nauth-user-pass\n"})
	if !r.OK || r.Check == nil || !r.Check.NeedsAuth || !slices.Equal(r.Check.Scripts, []string{"up"}) {
		t.Errorf("tunnel_check: %+v", r)
	}
	if r := Respond(&tunnelBackend{}, Request{Cmd: "tunnel_check", Text: "remote h\nmanagement 1 2\n"}); r.OK {
		t.Error("tunnel_check accepted a management directive")
	}
	// A backend without tunnel support says so instead of panicking.
	if r := Respond(noBackend{}, Request{Cmd: "tunnels"}); r.OK || !strings.Contains(r.Error, "no tunnel support") {
		t.Errorf("no support: %+v", r)
	}
}
