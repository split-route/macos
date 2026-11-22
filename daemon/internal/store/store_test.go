package store

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/split-route/core/rules"
	"github.com/split-route/macos/daemon/internal/config"
)

func openTemp(t *testing.T) (*Store, string) {
	t.Helper()
	file := filepath.Join(t.TempDir(), "db", "splitroute.db")
	s, err := Open(file)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s, file
}

var sample = config.Config{
	BaseURL:  "https://example.com/dl",
	Disabled: true,
	Lists: []config.List{
		{Name: "malware", Action: rules.Block},
		{Name: "Work", Custom: true, Action: rules.Direct, Entries: []string{
			"# office", "#  VPN gateway", "203.0.113.7", "", "Example.COM", "198.51.100.9/24",
			"example.com", // duplicate after canonicalization
			"full:api.example.org", "as13335", "2400:cb00::/32", "# trailing note",
		}},
		{Name: "ir-cidr", Action: rules.Direct},
	},
}

func TestRoundTrip(t *testing.T) {
	s, file := openTemp(t)
	if _, err := s.Config(); !errors.Is(err, ErrNotInitialized) {
		t.Fatalf("fresh db: %v", err)
	}
	if ok, err := s.Init(sample, "/etc/splitroute.conf"); !ok || err != nil {
		t.Fatalf("init: %v %v", ok, err)
	}
	if ok, err := s.Init(config.Default(), ""); ok || err != nil {
		t.Fatalf("second init must be a no-op: %v %v", ok, err)
	}
	want := sample
	want.Lists = append([]config.List{}, sample.Lists...)
	want.Lists[1].Entries = []string{"# office", "# VPN gateway", "203.0.113.7", "example.com", "198.51.100.0/24",
		"full:api.example.org", "AS13335", "2400:cb00::/32", "# trailing note"}
	got, err := s.Config()
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v, %v\nwant %+v", got, err, want)
	}
	// Reading back what was read is stable.
	if _, err := s.Update(func(c config.Config) (config.Config, error) { return c, nil }); err != nil {
		t.Fatal(err)
	}
	if again, _ := s.Config(); !reflect.DeepEqual(again, want) {
		t.Fatalf("not stable: %+v", again)
	}
	if from, _, err := s.MigratedFrom(); from != "/etc/splitroute.conf" || err != nil {
		t.Fatalf("migrated from %q, %v", from, err)
	}
	fi, err := os.Stat(file)
	if err != nil || fi.Mode().Perm() != 0o644 {
		t.Fatalf("mode %v, %v", fi.Mode(), err)
	}
	// Survives a reopen.
	s.Close()
	s2, err := Open(file)
	if err != nil {
		t.Fatal(err)
	}
	defer s2.Close()
	if got, err := s2.Config(); err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("after reopen: %+v, %v", got, err)
	}
}

func TestUpdate(t *testing.T) {
	s, _ := openTemp(t)
	if _, err := s.Update(func(c config.Config) (config.Config, error) { return c, nil }); !errors.Is(err, ErrNotInitialized) {
		t.Fatalf("update before init: %v", err)
	}
	if _, err := s.Init(sample, ""); err != nil {
		t.Fatal(err)
	}
	var workID, workCreated string
	s.db.QueryRow("SELECT id, created_at FROM lists WHERE name = 'Work'").Scan(&workID, &workCreated)

	// Reorder, drop a list, change an action and entries.
	next := config.Config{Lists: []config.List{
		{Name: "Work", Custom: true, Action: rules.Block, Entries: []string{"203.0.113.8"}},
		{Name: "malware", Action: rules.Block},
	}}
	got, err := s.Update(func(config.Config) (config.Config, error) { return next, nil })
	if err != nil || !reflect.DeepEqual(got, next) {
		t.Fatalf("update: %+v, %v", got, err)
	}
	if read, _ := s.Config(); !reflect.DeepEqual(read, next) {
		t.Fatalf("read %+v", read)
	}
	var id, created string
	s.db.QueryRow("SELECT id, created_at FROM lists WHERE name = 'Work'").Scan(&id, &created)
	if id != workID || created != workCreated {
		t.Errorf("Work lost its identity: id %s→%s created %s→%s", workID, id, workCreated, created)
	}
	var orphans int
	s.db.QueryRow("SELECT count(*) FROM entries WHERE list_id NOT IN (SELECT id FROM lists)").Scan(&orphans)
	var lists int
	s.db.QueryRow("SELECT count(*) FROM lists").Scan(&lists)
	if orphans != 0 || lists != 2 {
		t.Errorf("orphans %d, lists %d", orphans, lists)
	}

	// An invalid result or an error from f writes nothing.
	for _, f := range []func(config.Config) (config.Config, error){
		func(c config.Config) (config.Config, error) {
			c.Lists = append(c.Lists, config.List{Name: "x", Custom: true, Action: rules.Direct, Entries: []string{"10.0.0.1"}})
			return c, nil
		},
		func(c config.Config) (config.Config, error) { c.Disabled = true; return c, errors.New("nope") },
	} {
		if _, err := s.Update(f); err == nil {
			t.Error("want error")
		}
	}
	if read, _ := s.Config(); !reflect.DeepEqual(read, next) {
		t.Fatalf("failed update changed the settings: %+v", read)
	}
}

// The constraints catch what a bug or a hand edit could slip past Validate.
func TestConstraints(t *testing.T) {
	s, _ := openTemp(t)
	if _, err := s.Init(sample, ""); err != nil {
		t.Fatal(err)
	}
	for _, q := range []string{
		"UPDATE lists SET action = 'teleport'",
		"UPDATE lists SET source = 'other'",
		"UPDATE lists SET name = 'malware' WHERE name = 'Work'",
		"UPDATE settings SET base_url = 'http://x'",
		"INSERT INTO settings (id, created_at) VALUES (2, 'x')",
		"UPDATE entries SET kind = 'regex'",
		"INSERT INTO entries (list_id, position, kind, value) VALUES (9999, 0, 'cidr', '1.2.3.0/24')",
	} {
		if _, err := s.db.Exec(q); err == nil {
			t.Errorf("%s: accepted", q)
		}
	}
	// A hand edit the constraints allow but Validate doesn't is refused on read.
	if _, err := s.db.Exec("UPDATE entries SET value = '10.0.0.0/24' WHERE kind = 'cidr' AND value = '203.0.113.7'"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Config(); err == nil || !strings.Contains(err.Error(), "never routed") {
		t.Fatalf("invalid stored config read back: %v", err)
	}
}

func TestNewerSchemaRefused(t *testing.T) {
	s, file := openTemp(t)
	if _, err := s.db.Exec("PRAGMA user_version = 99"); err != nil {
		t.Fatal(err)
	}
	s.Close()
	if _, err := Open(file); err == nil || !strings.Contains(err.Error(), "newer") {
		t.Fatalf("open: %v", err)
	}
	if _, err := OpenReadOnly(file); err == nil {
		t.Fatal("read-only open of a newer schema: want error")
	}
}

func TestDamagedRefused(t *testing.T) {
	file := filepath.Join(t.TempDir(), "splitroute.db")
	if err := os.WriteFile(file, []byte(strings.Repeat("not a database ", 100)), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(file); err == nil {
		t.Fatal("garbage file opened")
	}
	if b, _ := os.ReadFile(file); !strings.HasPrefix(string(b), "not a database") {
		t.Fatal("damaged file was overwritten")
	}
}

// A second process (the CLI) writes; the daemon's handle notices.
func TestReadOnlyAndChanged(t *testing.T) {
	if _, err := OpenReadOnly(filepath.Join(t.TempDir(), "none.db")); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("missing db: %v", err)
	}
	daemon, file := openTemp(t)
	if _, err := daemon.Init(config.Default(), ""); err != nil {
		t.Fatal(err)
	}
	if c, err := daemon.Changed(); c || err != nil {
		t.Fatalf("baseline: %v %v", c, err)
	}
	ro, err := OpenReadOnly(file)
	if err != nil {
		t.Fatal(err)
	}
	defer ro.Close()
	if _, err := ro.Update(func(c config.Config) (config.Config, error) { return c, nil }); err == nil {
		t.Fatal("read-only store wrote")
	}
	cli, err := Open(file)
	if err != nil {
		t.Fatal(err)
	}
	defer cli.Close()
	if _, err := cli.Update(func(c config.Config) (config.Config, error) { c.Disabled = true; return c, nil }); err != nil {
		t.Fatal(err)
	}
	if c, err := daemon.Changed(); !c || err != nil {
		t.Fatalf("after another writer: %v %v", c, err)
	}
	if c, _ := daemon.Changed(); c {
		t.Fatal("changed twice for one write")
	}
	// The daemon's own writes don't count.
	if _, err := daemon.Update(func(c config.Config) (config.Config, error) { c.Disabled = false; return c, nil }); err != nil {
		t.Fatal(err)
	}
	if c, _ := daemon.Changed(); c {
		t.Fatal("own write reported as a change")
	}
	if got, err := ro.Config(); err != nil || got.Disabled {
		t.Fatalf("read-only view: %+v, %v", got, err)
	}
}

func TestBigList(t *testing.T) {
	s, _ := openTemp(t)
	entries := make([]string, 0, 50000)
	for i := range 50000 {
		entries = append(entries, "host"+strings.Repeat("x", i%7)+itoa(i)+".example.com")
	}
	cfg := config.Config{Lists: []config.List{{Name: "big", Custom: true, Action: rules.Block, Entries: entries}}}
	if _, err := s.Init(cfg, ""); err != nil {
		t.Fatal(err)
	}
	got, err := s.Config()
	if err != nil || len(got.Lists[0].Entries) != 50000 || got.Lists[0].Entries[49999] != entries[49999] {
		t.Fatalf("got %d entries, %v", len(got.Lists[0].Entries), err)
	}
}

func itoa(i int) string {
	b := []byte{}
	for {
		b = append([]byte{byte('0' + i%10)}, b...)
		if i /= 10; i == 0 {
			return string(b)
		}
	}
}

func assertMode(t *testing.T, file string, want os.FileMode) {
	t.Helper()
	fi, err := os.Stat(file)
	if err != nil || fi.Mode().Perm() != want {
		t.Fatalf("%s: mode %v, %v; want %v", file, fi.Mode().Perm(), err, want)
	}
}
