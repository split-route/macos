package store

import (
	"errors"
	"strings"
	"testing"

	"github.com/split-route/core/rules"
	"github.com/split-route/macos/daemon/internal/config"
)

// 0005 rebuilds tunnels. The rows, their ids, the lists that point at them and
// the id sequence must all survive: ids name files and running tunnels, and a
// removed tunnel's id must never come back.
func TestMigrationSubscriptions(t *testing.T) {
	saved := migrationFS
	defer func() { migrationFS = saved }()
	migrationFS = migrationsUpTo(t, saved, 4)

	s, file := openTemp(t)
	for _, q := range []string{
		`INSERT INTO settings (id, created_at) VALUES (1, 'now')`,
		`INSERT INTO tunnels (id, name, kind, profile_sha256, remotes, needs_auth, auto_connect, position, created_at, updated_at) VALUES
			(1, 'Office', 'openvpn', '` + sha + `', 'vpn.example.com:1194', 1, 1, 0, 'now', 'now'),
			(2, 'Home', 'openvpn', '` + sha + `', '', 0, 0, 1, 'now', 'now'),
			(3, 'Gone', 'openvpn', '` + sha + `', '', 0, 0, 2, 'now', 'now')`,
		`DELETE FROM tunnels WHERE id = 3`, // the sequence is now ahead of the largest id
		`INSERT INTO lists (id, name, source, action, tunnel_id, position, created_at, updated_at) VALUES
			(1, 'social', 'custom', 'tunnel', 1, 0, 'now', 'now')`,
	} {
		if _, err := s.db.Exec(q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	s.Close()

	migrationFS = migrationsUpTo(t, saved, 5)
	s2, err := Open(file)
	if err != nil {
		t.Fatal(err)
	}
	defer s2.Close()

	ts, err := s2.Tunnels()
	if err != nil || len(ts) != 2 {
		t.Fatalf("Tunnels() = %+v, %v", ts, err)
	}
	if ts[0].ID != 1 || ts[0].Name != "Office" || ts[0].Kind != "openvpn" || !ts[0].NeedsAuth || !ts[0].AutoConnect ||
		ts[0].SubscriptionID != 0 || ts[0].Remotes[0] != "vpn.example.com:1194" {
		t.Errorf("tunnel 0 = %+v", ts[0])
	}
	// The next id is 4, not 3: the removed tunnel's id is not reused.
	id, err := s2.AddTunnel(Tunnel{Name: "New", ProfileSHA256: sha, Kind: "vless"})
	if err != nil || id != 4 {
		t.Errorf("new id = %d (%v), want 4", id, err)
	}
	// The list still points at its tunnel, and the tunnel can't be removed under it.
	cfg, err := s2.Config()
	if err != nil || cfg.Lists[0].Tunnel != "Office" {
		t.Errorf("list tunnel = %q (%v)", cfg.Lists[0].Tunnel, err)
	}
	if err := s2.RemoveTunnel(1); err == nil || !strings.Contains(err.Error(), "social") {
		t.Errorf("a tunnel in use was removed: %v", err)
	}
	var fk, v int
	s2.db.QueryRow("PRAGMA foreign_keys").Scan(&fk)
	s2.db.QueryRow("PRAGMA user_version").Scan(&v)
	if fk != 1 || v != 5 {
		t.Errorf("foreign_keys %d (want 1), version %d (want 5)", fk, v)
	}
	// kind is no longer limited to openvpn in the schema; Go checks the protocol.
	if _, err := s2.db.Exec(`UPDATE tunnels SET kind = '' WHERE id = 2`); err == nil {
		t.Error("an empty kind was accepted")
	}
}

func node(name, kind string) Tunnel {
	return Tunnel{Name: name, Kind: kind, ProfileSHA256: sha, Remotes: []string{"a.example.com:443"}}
}

func TestSubscriptions(t *testing.T) {
	s, _ := openTemp(t)
	if _, err := s.Init(config.Config{Lists: []config.List{{Name: "social", Action: rules.Tunnel}}}, ""); err != nil {
		t.Fatal(err)
	}
	own, err := s.AddTunnels([]Tunnel{node("🇺🇸 US 01", "vless")})
	if err != nil || len(own) != 1 || own[0].SubscriptionID != 0 || own[0].Kind != "vless" {
		t.Fatalf("AddTunnels: %+v, %v", own, err)
	}

	// Names repeat inside a subscription and against existing tunnels: a number is added.
	insecure := node("🇺🇸 US 01", "trojan")
	insecure.Warning = "Certificate checks are off for this server."
	sub, ts, err := s.AddSubscription("Provider", []Tunnel{node("🇺🇸 US 01", "vless"), node("🇺🇸 us 01", "vless"), insecure, node("", "vmess")})
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, tu := range ts {
		names = append(names, tu.Name)
		if tu.SubscriptionID != sub.ID || tu.ID == 0 {
			t.Errorf("tunnel %+v is not in the subscription", tu)
		}
	}
	if got := strings.Join(names, "|"); got != "🇺🇸 US 01 2|🇺🇸 us 01 3|🇺🇸 US 01 4|Tunnel" {
		t.Errorf("names = %q", got)
	}
	all, _ := s.Tunnels()
	if len(all) != 5 || all[3].Warning == "" {
		t.Errorf("tunnels: %+v", all)
	}
	// The subscription's own name is made unique too.
	sub2, _, err := s.AddSubscription("provider", []Tunnel{node("x", "vless")})
	if err != nil || sub2.Name != "provider 2" {
		t.Errorf("second subscription: %q, %v", sub2.Name, err)
	}
	subs, err := s.Subscriptions()
	if err != nil || len(subs) != 2 || subs[0].Name != "Provider" || subs[0].UpdatedAt.IsZero() {
		t.Errorf("Subscriptions() = %+v, %v", subs, err)
	}
	got, _ := s.SubscriptionTunnels(sub.ID)
	if len(got) != 4 {
		t.Errorf("SubscriptionTunnels = %d", len(got))
	}

	// A list that uses one of its tunnels blocks the removal, and nothing changes.
	if _, err := s.Update(func(c config.Config) (config.Config, error) {
		return config.SetAction(c, "social", rules.Tunnel, ts[1].Name)
	}); err != nil {
		t.Fatal(err)
	}
	var inUse ErrSubscriptionInUse
	if err := s.RemoveSubscription(sub.ID); !errors.As(err, &inUse) || inUse[0] != "social" {
		t.Fatalf("a subscription in use was removed: %v", err)
	}
	if got, _ := s.SubscriptionTunnels(sub.ID); len(got) != 4 {
		t.Errorf("the refusal changed something: %d tunnels left", len(got))
	}
	if _, err := s.Update(func(c config.Config) (config.Config, error) {
		return config.SetAction(c, "social", rules.Tunnel, "")
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.RemoveSubscription(sub.ID); err != nil {
		t.Fatal(err)
	}
	all, _ = s.Tunnels()
	if len(all) != 2 || all[0].Name != "🇺🇸 US 01" || all[1].SubscriptionID != sub2.ID {
		t.Errorf("after removal: %+v", all)
	}
	if err := s.RemoveSubscription(sub.ID); !errors.Is(err, ErrNoSubscription) {
		t.Errorf("removing twice: %v", err)
	}
}

func TestAddAllIsAtomic(t *testing.T) {
	s, _ := openTemp(t)
	bad := node("ok", "vless")
	bad.ProfileSHA256 = "short" // the second node can't be stored
	if _, _, err := s.AddSubscription("Sub", []Tunnel{node("first", "vless"), bad}); err == nil {
		t.Fatal("expected an error")
	}
	subs, _ := s.Subscriptions()
	all, _ := s.Tunnels()
	if len(subs) != 0 || len(all) != 0 {
		t.Errorf("a failed import left %d subscriptions and %d tunnels", len(subs), len(all))
	}
}

func TestCleanName(t *testing.T) {
	long := strings.Repeat("🇺🇸", 20) // 8 bytes each
	for in, want := range map[string]string{
		"  a \t b\n": "a b",
		"":           "Tunnel",
		"\x00\x01":   "Tunnel",
		"a‎b":        "a b",
	} {
		if got := CleanName(in); got != want {
			t.Errorf("CleanName(%q) = %q, want %q", in, got, want)
		}
	}
	got := CleanName(long)
	if len(got) > 64 || !strings.HasPrefix(long, got) || strings.ContainsRune(got, '�') {
		t.Errorf("long name cut badly: %q (%d bytes)", got, len(got))
	}
}

func TestVPNChoiceIsKeptAndSurvivesConfigWrites(t *testing.T) {
	s, _ := openTemp(t)
	if _, err := s.VPN(); !errors.Is(err, ErrNotInitialized) {
		t.Errorf("before init: %v", err)
	}
	if _, err := s.Init(config.Config{Lists: []config.List{{Name: "social", Action: rules.Direct}}}, ""); err != nil {
		t.Fatal(err)
	}
	if v, err := s.VPN(); err != nil || v.On || v.Selected != 0 {
		t.Fatalf("defaults: %+v %v", v, err)
	}
	id, err := s.AddTunnel(Tunnel{Name: "Office", ProfileSHA256: sha})
	if err != nil {
		t.Fatal(err)
	}
	if err := s.SetSelected(999); !errors.Is(err, ErrNoTunnel) {
		t.Errorf("selecting a tunnel that doesn't exist: %v", err)
	}
	if err := s.SetSelected(id); err != nil {
		t.Fatal(err)
	}
	if err := s.SetVPNOn(true); err != nil {
		t.Fatal(err)
	}
	// A config write must not reset the choice.
	if _, err := s.Update(func(c config.Config) (config.Config, error) { return config.SetAction(c, "social", rules.Block, "") }); err != nil {
		t.Fatal(err)
	}
	if v, _ := s.VPN(); !v.On || v.Selected != id {
		t.Errorf("after a config write: %+v", v)
	}
	// Removing the tunnel clears the selection (the daemon refuses this while the VPN is on).
	if err := s.RemoveTunnel(id); err != nil {
		t.Fatal(err)
	}
	if v, _ := s.VPN(); v.Selected != 0 || !v.On {
		t.Errorf("after removing the selected tunnel: %+v", v)
	}
	if err := s.SetSelected(0); err != nil {
		t.Errorf("clearing: %v", err)
	}
}

// 0006 adds the VPN columns to settings with ADD COLUMN: existing settings keep
// their values, and the VPN starts off with no tunnel selected.
func TestMigrationVPN(t *testing.T) {
	saved := migrationFS
	defer func() { migrationFS = saved }()
	migrationFS = migrationsUpTo(t, saved, 5)
	s, file := openTemp(t)
	for _, q := range []string{
		`INSERT INTO settings (id, base_url, disabled, created_at) VALUES (1, 'https://lists.example.com', 1, 'now')`,
		`INSERT INTO tunnels (id, name, kind, profile_sha256, position, created_at, updated_at) VALUES (1, 'Office', 'openvpn', '` + sha + `', 0, 'now', 'now')`,
	} {
		if _, err := s.db.Exec(q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	s.Close()
	migrationFS = saved
	s2, err := Open(file)
	if err != nil {
		t.Fatal(err)
	}
	defer s2.Close()
	if v, err := s2.VPN(); err != nil || v.On || v.Selected != 0 {
		t.Errorf("VPN after the migration: %+v %v", v, err)
	}
	cfg, err := s2.Config()
	if err != nil || cfg.BaseURL != "https://lists.example.com" || !cfg.Disabled {
		t.Errorf("settings changed by the migration: %+v %v", cfg, err)
	}
	var v int
	s2.db.QueryRow("PRAGMA user_version").Scan(&v)
	if v != 6 {
		t.Errorf("version %d, want 6", v)
	}
	if _, err := s2.db.Exec(`UPDATE settings SET vpn_on = 2`); err == nil {
		t.Error("vpn_on accepted a value that is not 0 or 1")
	}
	if _, err := s2.db.Exec(`UPDATE settings SET selected_tunnel_id = 99`); err == nil {
		t.Error("selected_tunnel_id accepted a tunnel that doesn't exist")
	}
}
