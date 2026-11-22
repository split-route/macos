package store

import (
	"database/sql"
	"io/fs"
	"os"
	"strings"
	"testing"
	"testing/fstest"

	"github.com/split-route/core/rules"
	"github.com/split-route/macos/daemon/internal/config"
)

// 0004 renames the vpn action to tunnel by rebuilding lists. The children of
// lists (entries, import_sources) must survive: ids are kept and the rebuild
// runs with foreign keys off.
func TestMigrationTunnelAction(t *testing.T) {
	saved := migrationFS
	defer func() { migrationFS = saved }()
	old := fstest.MapFS{}
	for _, n := range []string{"0001_init.sql", "0002_imports.sql", "0003_tunnels.sql"} {
		b, err := fs.ReadFile(saved, n)
		if err != nil {
			t.Fatal(err)
		}
		old[n] = &fstest.MapFile{Data: b}
	}
	migrationFS = old

	s, file := openTemp(t)
	for _, q := range []string{
		`INSERT INTO settings (id, created_at) VALUES (1, 'now')`,
		`INSERT INTO lists (id, name, source, action, position, created_at, updated_at) VALUES
			(1, 'telegram', 'release', 'vpn', 0, 'now', 'now'),
			(2, 'ir-cidr', 'release', 'direct', 1, 'now', 'now'),
			(3, 'Ads', 'import', 'block', 2, 'now', 'now'),
			(4, 'Work', 'custom', 'vpn', 3, 'now', 'now')`,
		`INSERT INTO entries (list_id, position, kind, value) VALUES (4, 0, 'cidr', '203.0.113.0/24'), (4, 1, 'domain', 'example.com'), (3, 0, 'domain_suffix', 'ads.example')`,
		`INSERT INTO import_sources (list_id, url) VALUES (3, 'https://example.com/hosts')`,
	} {
		if _, err := s.db.Exec(q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	s.Close()

	migrationFS = saved // all four migrations
	s2, err := Open(file)
	if err != nil {
		t.Fatal(err)
	}
	defer s2.Close()

	got := map[string]string{}
	rows, err := s2.db.Query("SELECT name, action FROM lists")
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var n, a string
		if err := rows.Scan(&n, &a); err != nil {
			t.Fatal(err)
		}
		got[n] = a
	}
	rows.Close()
	want := map[string]string{"telegram": "tunnel", "ir-cidr": "direct", "Ads": "block", "Work": "tunnel"}
	for n, a := range want {
		if got[n] != a {
			t.Errorf("list %s action = %q, want %q", n, got[n], a)
		}
	}
	var entries, sources, v, fk int
	s2.db.QueryRow("SELECT count(*) FROM entries").Scan(&entries)
	s2.db.QueryRow("SELECT count(*) FROM import_sources").Scan(&sources)
	s2.db.QueryRow("PRAGMA user_version").Scan(&v)
	s2.db.QueryRow("PRAGMA foreign_keys").Scan(&fk)
	if entries != 3 || sources != 1 || v != 4 || fk != 1 {
		t.Errorf("entries %d (want 3), import sources %d (want 1), version %d (want 4), foreign_keys %d (want 1)", entries, sources, v, fk)
	}
	// The upgrade left a copy of the database as it was, for going back.
	if fi, err := os.Stat(file + ".v3"); err != nil || fi.Mode().Perm() != 0o600 {
		t.Errorf("backup: %v %v", fi, err)
	} else if bk, err := sql.Open("sqlite", "file:"+file+".v3?mode=ro"); err != nil {
		t.Error(err)
	} else {
		var ver int
		var act string
		bk.QueryRow("PRAGMA user_version").Scan(&ver)
		bk.QueryRow("SELECT action FROM lists WHERE name = 'telegram'").Scan(&act)
		bk.Close()
		if ver != 3 || act != "vpn" {
			t.Errorf("the backup is at version %d with action %q, want version 3 and the old action", ver, act)
		}
	}
	// The config reads back with the new name.
	cfg, err := s2.Config()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Lists[0].Name != "telegram" || cfg.Lists[0].Action != "tunnel" {
		t.Errorf("config list 0 = %+v", cfg.Lists[0])
	}
	// The new CHECK takes tunnel and refuses the old name; foreign keys still hold.
	if _, err := s2.db.Exec(`UPDATE lists SET action = 'tunnel' WHERE id = 2`); err != nil {
		t.Errorf("tunnel refused: %v", err)
	}
	if _, err := s2.db.Exec(`UPDATE lists SET action = 'vpn' WHERE id = 2`); err == nil {
		t.Error("the old action name is still accepted")
	}
	if _, err := s2.db.Exec(`INSERT INTO entries (list_id, position, kind, value) VALUES (9999, 0, 'cidr', '1.2.3.0/24')`); err == nil {
		t.Error("foreign keys not enforced after the migration")
	}
	// Deleting a list still cascades to its entries.
	if _, err := s2.db.Exec(`DELETE FROM lists WHERE id = 4`); err != nil {
		t.Fatal(err)
	}
	s2.db.QueryRow("SELECT count(*) FROM entries WHERE list_id = 4").Scan(&entries)
	if entries != 0 {
		t.Errorf("entries of a deleted list left: %d", entries)
	}
}

// A list can name its tunnel. The link is by id, so renaming the tunnel keeps
// it; an unknown tunnel is refused; a tunnel that lists use can't be removed.
func TestListNamesATunnel(t *testing.T) {
	s, _ := openTemp(t)
	if _, err := s.Init(config.Config{Lists: []config.List{{Name: "malware", Action: rules.Block}, {Name: "social", Action: rules.Tunnel}}}, ""); err != nil {
		t.Fatal(err)
	}
	id, err := s.AddTunnel(Tunnel{Name: "Office", ProfileSHA256: sha})
	if err != nil {
		t.Fatal(err)
	}
	set := func(tunnel string) error {
		_, err := s.Update(func(c config.Config) (config.Config, error) {
			return config.SetAction(c, "social", rules.Tunnel, tunnel)
		})
		return err
	}
	if err := set("office"); err != nil { // names compare case-insensitively, like the tunnels table
		t.Fatal(err)
	}
	read := func() string {
		c, err := s.Config()
		if err != nil {
			t.Fatal(err)
		}
		return c.Lists[1].Tunnel
	}
	if got := read(); got != "Office" {
		t.Errorf("tunnel = %q, want the tunnel's own spelling", got)
	}
	if err := set("Nowhere"); err == nil || !strings.Contains(err.Error(), "no tunnel named") {
		t.Errorf("unknown tunnel: %v", err)
	}
	if err := s.RenameTunnel(id, "HQ"); err != nil {
		t.Fatal(err)
	}
	if got := read(); got != "HQ" {
		t.Errorf("after rename = %q", got)
	}
	if err := s.RemoveTunnel(id); err == nil || !strings.Contains(err.Error(), "social") {
		t.Errorf("a tunnel in use was removed (or the error names no list): %v", err)
	}
	if err := set(""); err != nil { // back to the default tunnel
		t.Fatal(err)
	}
	if err := s.RemoveTunnel(id); err != nil {
		t.Errorf("an unused tunnel can't be removed: %v", err)
	}
	// The database refuses a tunnel on a list that isn't a tunnel list.
	if _, err := s.db.Exec(`UPDATE lists SET tunnel_id = 1 WHERE name = 'malware'`); err == nil {
		t.Error("a tunnel on a block list was accepted")
	}
}
