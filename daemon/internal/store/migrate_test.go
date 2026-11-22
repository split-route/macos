package store

import (
	"io/fs"
	"path/filepath"
	"sync"
	"syscall"
	"testing"
	"testing/fstest"

	"github.com/split-route/macos/daemon/internal/config"
)

// The daemon and a root CLI opening a new file together: both must succeed,
// and the settings are seeded once.
func TestConcurrentFirstOpen(t *testing.T) {
	file := filepath.Join(t.TempDir(), "splitroute.db")
	var wg sync.WaitGroup
	errs := make(chan error, 8)
	seeded := make(chan bool, 8)
	for range 8 {
		wg.Go(func() {
			s, err := Open(file)
			if err != nil {
				errs <- err
				return
			}
			defer s.Close()
			ok, err := s.Init(sample, "")
			if err != nil {
				errs <- err
			}
			seeded <- ok
		})
	}
	wg.Wait()
	close(errs)
	close(seeded)
	for err := range errs {
		t.Error(err)
	}
	n := 0
	for ok := range seeded {
		if ok {
			n++
		}
	}
	if n != 1 {
		t.Fatalf("seeded %d times", n)
	}
}

// A future migration that rebuilds lists (the only way to change a CHECK in
// SQLite) must keep every entry and leave foreign keys enforced.
func TestRebuildMigrationKeepsEntries(t *testing.T) {
	init, err := fs.ReadFile(migrationFS, "0001_init.sql")
	if err != nil {
		t.Fatal(err)
	}
	saved := migrationFS
	defer func() { migrationFS = saved }()
	migrationFS = fstest.MapFS{"0001_init.sql": {Data: init}}

	s, file := openTemp(t)
	seedOld(t, s)
	var before int
	s.db.QueryRow("SELECT count(*) FROM entries").Scan(&before)
	s.Close()

	migrationFS = fstest.MapFS{
		"0001_init.sql": {Data: init},
		"0002_rebuild.sql": {Data: []byte(fkOff + `
CREATE TABLE lists_new (
    id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE,
    source TEXT NOT NULL CHECK (source IN ('release', 'custom', 'import', 'other')),
    action TEXT NOT NULL, position INTEGER NOT NULL, note TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
INSERT INTO lists_new SELECT * FROM lists;
DROP TABLE lists;
ALTER TABLE lists_new RENAME TO lists;
`)},
	}
	s2, err := Open(file)
	if err != nil {
		t.Fatal(err)
	}
	defer s2.Close()
	var after, fk, v int
	s2.db.QueryRow("SELECT count(*) FROM entries").Scan(&after)
	s2.db.QueryRow("PRAGMA foreign_keys").Scan(&fk)
	s2.db.QueryRow("PRAGMA user_version").Scan(&v)
	if before == 0 || after != before || fk != 1 || v != 2 {
		t.Fatalf("entries %d→%d, foreign_keys %d, version %d", before, after, fk, v)
	}
	if _, err := s2.db.Exec("INSERT INTO entries (list_id, position, kind, value) VALUES (9999, 0, 'cidr', '1.2.3.0/24')"); err == nil {
		t.Fatal("foreign keys not enforced after the migration")
	}
}

func TestDurabilityPragmas(t *testing.T) {
	s, _ := openTemp(t)
	for pragma, want := range map[string]int{"synchronous": 3 /* EXTRA */, "fullfsync": 1, "foreign_keys": 1} {
		var got int
		if err := s.db.QueryRow("PRAGMA " + pragma).Scan(&got); err != nil || got != want {
			t.Errorf("%s = %d, %v; want %d", pragma, got, err, want)
		}
	}
	var mode string
	s.db.QueryRow("PRAGMA journal_mode").Scan(&mode)
	if mode != "delete" {
		t.Errorf("journal_mode %q", mode)
	}
}

func TestModeIgnoresUmask(t *testing.T) {
	old := syscall.Umask(0o077)
	defer syscall.Umask(old)
	s, file := openTemp(t)
	if _, err := s.Init(config.Default(), ""); err != nil {
		t.Fatal(err)
	}
	if _, err := OpenReadOnly(file); err != nil {
		t.Fatal(err)
	}
	assertMode(t, file, 0o644)
}

// seedOld fills a database at an older schema with plain SQL (the store's own
// write code targets the current schema): three lists, entries in one, and
// settings, the shape of sample.
func seedOld(t *testing.T, s *Store) {
	t.Helper()
	for _, q := range []string{
		`INSERT INTO settings (id, base_url, disabled, created_at) VALUES (1, 'https://example.com/dl', 1, 'now')`,
		`INSERT INTO lists (id, name, source, action, position, created_at, updated_at) VALUES
			(1, 'malware', 'release', 'block', 0, 'now', 'now'),
			(2, 'Work', 'custom', 'direct', 1, 'now', 'now'),
			(3, 'ir-cidr', 'release', 'direct', 2, 'now', 'now')`,
		`INSERT INTO entries (list_id, position, kind, value) VALUES
			(2, 0, 'cidr', '203.0.113.7/32'), (2, 1, 'domain', 'example.com'), (2, 2, 'asn', '13335')`,
	} {
		if _, err := s.db.Exec(q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
}
