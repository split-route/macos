package store

import (
	"errors"
	"io/fs"
	"reflect"
	"strings"
	"testing"
	"testing/fstest"
)

var sha = strings.Repeat("a", 64)

func TestTunnels(t *testing.T) {
	s, _ := openTemp(t)
	a, err := s.AddTunnel(Tunnel{Name: "Work", ProfileSHA256: sha, Remotes: []string{"vpn.example.com:443", "b:1194"}, NeedsAuth: true, Scripts: []string{"route-up", "up"}})
	if err != nil {
		t.Fatal(err)
	}
	b, err := s.AddTunnel(Tunnel{Name: "Home", ProfileSHA256: sha})
	if err != nil {
		t.Fatal(err)
	}
	got, err := s.Tunnels()
	if err != nil || len(got) != 2 || got[0].ID != a || got[1].ID != b {
		t.Fatalf("Tunnels() = %+v, %v", got, err)
	}
	want := Tunnel{ID: a, Name: "Work", Kind: "openvpn", ProfileSHA256: sha, Remotes: []string{"vpn.example.com:443", "b:1194"}, NeedsAuth: true, Scripts: []string{"route-up", "up"}}
	if !reflect.DeepEqual(got[0], want) {
		t.Errorf("got %+v, want %+v", got[0], want)
	}

	if _, err := s.AddTunnel(Tunnel{Name: "Work", ProfileSHA256: sha}); !errors.Is(err, ErrTunnelExists) {
		t.Errorf("duplicate name: %v", err)
	}
	for _, bad := range []Tunnel{{Name: "", ProfileSHA256: sha}, {Name: strings.Repeat("x", 65), ProfileSHA256: sha}, {Name: "a\nb", ProfileSHA256: sha}, {Name: " pad", ProfileSHA256: sha}, {Name: "ok", ProfileSHA256: "short"}} {
		if _, err := s.AddTunnel(bad); err == nil {
			t.Errorf("AddTunnel(%+v) accepted", bad)
		}
	}

	if _, err := s.AddTunnel(Tunnel{Name: "work", ProfileSHA256: sha}); !errors.Is(err, ErrTunnelExists) {
		t.Errorf("names are case-insensitive: %v", err)
	}
	if _, err := s.AddTunnel(Tunnel{Name: "X", ProfileSHA256: strings.Repeat("G", 64)}); err == nil {
		t.Error("non-hex sha256 accepted")
	}
	if err := s.RenameTunnel(b, "Work"); !errors.Is(err, ErrTunnelExists) {
		t.Errorf("rename onto existing name: %v", err)
	}
	if err := s.RenameTunnel(b, "House"); err != nil {
		t.Fatal(err)
	}
	if err := s.SetTunnelAutoConnect(b, true); err != nil {
		t.Fatal(err)
	}
	if tn, err := s.TunnelByID(b); err != nil || tn.Name != "House" || !tn.AutoConnect {
		t.Errorf("TunnelByID = %+v, %v", tn, err)
	}
	if err := s.RemoveTunnel(a); err != nil {
		t.Fatal(err)
	}
	for name, err := range map[string]error{
		"remove": s.RemoveTunnel(a), "rename": s.RenameTunnel(a, "x"), "auto": s.SetTunnelAutoConnect(a, true),
	} {
		if !errors.Is(err, ErrNoTunnel) {
			t.Errorf("%s of a removed tunnel: %v", name, err)
		}
	}
	if _, err := s.TunnelByID(a); !errors.Is(err, ErrNoTunnel) {
		t.Errorf("TunnelByID of removed: %v", err)
	}
	// Removing the newest tunnel must not free its id for the next one.
	if err := s.RemoveTunnel(b); err != nil {
		t.Fatal(err)
	}
	if c, err := s.AddTunnel(Tunnel{Name: "New", ProfileSHA256: sha}); err != nil || c <= b {
		t.Errorf("id %d reused or failed (%v); last was %d", c, err, b)
	}
}

// A database at schema 2 (before tunnels) upgrades in place and keeps its settings.
func TestUpgradeFromV2AddsTunnels(t *testing.T) {
	saved := migrationFS
	defer func() { migrationFS = saved }()
	v2 := fstest.MapFS{}
	for _, n := range []string{"0001_init.sql", "0002_imports.sql"} {
		b, err := fs.ReadFile(saved, n)
		if err != nil {
			t.Fatal(err)
		}
		v2[n] = &fstest.MapFile{Data: b}
	}
	migrationFS = v2
	s, file := openTemp(t)
	seedOld(t, s)
	s.Close()
	migrationFS = saved
	s2, err := Open(file)
	if err != nil {
		t.Fatal(err)
	}
	defer s2.Close()
	if cfg, err := s2.Config(); err != nil || len(cfg.Lists) != len(sample.Lists) {
		t.Fatalf("settings after upgrade: %v, %v", cfg, err)
	}
	if _, err := s2.AddTunnel(Tunnel{Name: "A", ProfileSHA256: sha}); err != nil {
		t.Fatal(err)
	}
}
