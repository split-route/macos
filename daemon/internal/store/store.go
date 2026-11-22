// Package store keeps the settings and lists in a SQLite database
// (modernc.org/sqlite: pure Go, so release builds stay CGO_ENABLED=0).
//
// The daemon and root CLI commands open it read-write; anyone else opens it
// read-only. It uses a rollback journal, not WAL: WAL readers need write access
// to the -shm file, which would break non-root `status`. Writes are rare, so
// WAL's concurrency buys nothing here.
package store

import (
	"context"
	"database/sql"
	"embed"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
	"time"

	_ "modernc.org/sqlite"

	"github.com/split-route/core/rules"
	"github.com/split-route/macos/daemon/internal/config"
)

//go:embed migrations/*.sql
var embedded embed.FS

// migrationFS holds the numbered migrations (tests swap it).
var migrationFS, _ = fs.Sub(embedded, "migrations")

// fkOff marks a migration that rebuilds a table: it runs with foreign keys
// off, because PRAGMA foreign_keys is a no-op inside a transaction and
// DROP TABLE lists would otherwise cascade to every entry. The runner checks
// foreign_key_check before committing.
const fkOff = "-- splitroute: foreign_keys=off"

// ErrNotInitialized: the database has no settings yet (before the first
// run as root imported the config file).
var ErrNotInitialized = errors.New("settings database not initialized")

// Store is an open settings database. Its methods are safe for concurrent use.
type Store struct {
	file     string
	db       *sql.DB
	now      func() time.Time
	dataVer  int64
	verKnown bool
}

// Open opens the database read-write, creating it (mode 0644) and its
// directory if needed, checks it and applies pending migrations. A corrupt
// database or one from a newer splitroute is an error, never reset.
func Open(file string) (*Store, error) {
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		return nil, err
	}
	if f, err := os.OpenFile(file, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0o644); err == nil {
		f.Close()
	} else if !errors.Is(err, fs.ErrExist) {
		return nil, err
	}
	// 0644 regardless of umask: non-root status and config export read it.
	// SQLite gives its journal file the same mode and owner.
	if err := os.Chmod(file, 0o644); err != nil {
		return nil, err
	}
	s, err := open(file, "rwc", "_txlock=immediate", "_pragma=journal_mode(DELETE)")
	if err != nil {
		return nil, err
	}
	if err := s.migrate(); err != nil {
		s.Close()
		return nil, fmt.Errorf("%s: %w", file, err)
	}
	return s, nil
}

// OpenReadOnly opens an existing database for reading. It fails with
// fs.ErrNotExist if there is none, and if its schema is not exactly the one
// this binary knows (a root run migrates it).
func OpenReadOnly(file string) (*Store, error) {
	if _, err := os.Stat(file); err != nil {
		return nil, err
	}
	s, err := open(file, "ro")
	if err != nil {
		return nil, err
	}
	v, err := s.version()
	if err == nil && v != len(migrations()) {
		err = fmt.Errorf("%s: schema version %d, this splitroute reads %d (run a root command to migrate)", file, v, len(migrations()))
	}
	if err != nil {
		s.Close()
		return nil, err
	}
	return s, nil
}

func open(file, mode string, params ...string) (*Store, error) {
	q := append([]string{
		"mode=" + mode,
		"_pragma=foreign_keys(1)",
		"_pragma=busy_timeout(5000)",
		// EXTRA also syncs the directory after the rollback journal is
		// deleted, so a power cut can't bring the journal back and undo a
		// commit; fullfsync uses F_FULLFSYNC on macOS, where fsync alone
		// doesn't reach the disk. Writes are rare; the cost doesn't matter.
		"_pragma=synchronous(EXTRA)",
		"_pragma=fullfsync(1)",
	}, params...)
	dsn := (&url.URL{Scheme: "file", Path: file, RawQuery: strings.Join(q, "&")}).String()
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// One connection: writes are serialized anyway, and PRAGMA data_version
	// must be read on the same connection every time.
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	db.SetConnMaxLifetime(0)
	s := &Store{file: file, db: db, now: time.Now}
	var res string
	if err := db.QueryRow("PRAGMA quick_check").Scan(&res); err != nil {
		db.Close()
		return nil, fmt.Errorf("%s: %w", file, err)
	}
	if res != "ok" {
		db.Close()
		return nil, fmt.Errorf("%s is damaged (%s); restore it from a backup or move it away and re-import with `splitroute config import`", file, res)
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

func migrations() []string {
	names, _ := fs.Glob(migrationFS, "*.sql")
	slices.Sort(names)
	return names
}

func (s *Store) version() (int, error) {
	var v int
	err := s.db.QueryRow("PRAGMA user_version").Scan(&v)
	return v, err
}

// migrate applies each pending migration in its own immediate transaction,
// together with the user_version bump, so a crash leaves the database at a
// whole version. The version is re-read inside the transaction: another
// process (the daemon and a root CLI starting together on a new file) may
// have applied it while this one waited for the lock.
func (s *Store) migrate() error {
	ms := migrations()
	v, err := s.version()
	if err != nil {
		return err
	}
	if v > len(ms) {
		return fmt.Errorf("schema version %d is newer than this splitroute (%d); upgrade splitroute", v, len(ms))
	}
	for i := v; i < len(ms); i++ {
		if err := s.apply(i+1, ms[i]); err != nil {
			return fmt.Errorf("%s: %w", path.Base(ms[i]), err)
		}
	}
	return nil
}

func (s *Store) apply(version int, name string) (err error) {
	b, err := fs.ReadFile(migrationFS, name)
	if err != nil {
		return err
	}
	rebuild := strings.HasPrefix(string(b), fkOff)
	if rebuild {
		// Outside the transaction, on the pool's only connection.
		if _, err := s.db.Exec("PRAGMA foreign_keys = OFF"); err != nil {
			return err
		}
		defer func() {
			if _, ferr := s.db.Exec("PRAGMA foreign_keys = ON"); ferr != nil && err == nil {
				err = ferr
			}
		}()
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var cur int
	if err := tx.QueryRow("PRAGMA user_version").Scan(&cur); err != nil {
		return err
	}
	if cur >= version {
		return nil // applied by another process meanwhile
	}
	if rebuild {
		if err := s.backup(tx, version-1); err != nil {
			return fmt.Errorf("backup before the migration: %w", err)
		}
	}
	if _, err := tx.Exec(string(b)); err != nil {
		return err
	}
	if rebuild {
		rows, err := tx.Query("PRAGMA foreign_key_check")
		if err != nil {
			return err
		}
		var table, parent string
		var rowid sql.NullInt64
		var fkid int
		bad := rows.Next()
		if bad {
			if err := rows.Scan(&table, &rowid, &parent, &fkid); err != nil {
				rows.Close()
				return err
			}
		}
		if err := closeRows(rows); err != nil {
			return err
		}
		if bad {
			return fmt.Errorf("foreign key violations after the migration (first: a row of %s that references %s; they may predate it)", table, parent)
		}
	}
	if _, err := tx.Exec(fmt.Sprintf("PRAGMA user_version = %d", version)); err != nil {
		return err
	}
	return tx.Commit()
}

// backup copies the database file to <file>.v<version> (0600) before a
// migration that rebuilds a table, so a bad upgrade has something to go back
// to. It runs inside the migration's write transaction, before anything is
// changed: the file on disk is then exactly the committed state, and no other
// process can write meanwhile. A database with no settings (just created) has
// nothing to keep.
func (s *Store) backup(tx *sql.Tx, version int) error {
	var n int
	if err := tx.QueryRow("SELECT count(*) FROM settings").Scan(&n); err != nil || n == 0 {
		return nil
	}
	src, err := os.Open(s.file)
	if err != nil {
		return err
	}
	defer src.Close()
	dst := fmt.Sprintf("%s.v%d", s.file, version)
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, src); err != nil {
		out.Close()
		return err
	}
	if err := out.Sync(); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// Init stores cfg as the first settings, if there are none yet; from records
// where they came from (the imported file, or "" for defaults). It reports
// whether it wrote anything: false means another process got there first.
func (s *Store) Init(cfg config.Config, from string) (bool, error) {
	if err := cfg.Validate(); err != nil {
		return false, err
	}
	tx, err := s.db.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	var n int
	if err := tx.QueryRow("SELECT count(*) FROM settings").Scan(&n); err != nil || n > 0 {
		return false, err
	}
	if _, err := tx.Exec("INSERT INTO settings (id, migrated_from, created_at) VALUES (1, ?, ?)", from, s.stamp()); err != nil {
		return false, err
	}
	if err := s.write(tx, cfg); err != nil {
		return false, err
	}
	return true, tx.Commit()
}

// MigratedFrom is the config file the settings were imported from, or "".
func (s *Store) MigratedFrom() (string, time.Time, error) {
	var from, at string
	err := s.db.QueryRow("SELECT migrated_from, created_at FROM settings WHERE id = 1").Scan(&from, &at)
	if errors.Is(err, sql.ErrNoRows) {
		return "", time.Time{}, ErrNotInitialized
	}
	t, _ := time.Parse(time.RFC3339Nano, at)
	return from, t, err
}

// Config reads the settings. ErrNotInitialized if there are none yet. It
// reads in a plain (deferred) transaction, so it never holds the write lock.
func (s *Store) Config() (config.Config, error) {
	tx, err := s.db.BeginTx(context.Background(), &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return config.Config{}, err
	}
	defer tx.Rollback()
	return read(tx)
}

// Update reads the settings, changes them with f, validates and writes them
// in one transaction, so concurrent writers (the daemon and a root CLI
// command) can't lose each other's changes.
func (s *Store) Update(f func(config.Config) (config.Config, error)) (config.Config, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return config.Config{}, err
	}
	defer tx.Rollback()
	cfg, err := read(tx)
	if err != nil {
		return config.Config{}, err
	}
	if cfg, err = f(cfg); err != nil {
		return config.Config{}, err
	}
	if err := cfg.Validate(); err != nil {
		return config.Config{}, err
	}
	if err := s.write(tx, cfg); err != nil {
		return config.Config{}, err
	}
	return cfg, tx.Commit()
}

// Changed reports whether another connection (another process) committed
// since the last call. The first call only records the baseline.
func (s *Store) Changed() (bool, error) {
	var v int64
	if err := s.db.QueryRow("PRAGMA data_version").Scan(&v); err != nil {
		return false, err
	}
	changed := s.verKnown && v != s.dataVer
	s.dataVer, s.verKnown = v, true
	return changed, nil
}

func (s *Store) stamp() string { return s.now().UTC().Format(time.RFC3339Nano) }

func read(tx *sql.Tx) (config.Config, error) {
	var cfg config.Config
	var disabled int
	err := tx.QueryRow("SELECT base_url, disabled FROM settings WHERE id = 1").Scan(&cfg.BaseURL, &disabled)
	if errors.Is(err, sql.ErrNoRows) {
		return config.Config{}, ErrNotInitialized
	}
	if err != nil {
		return config.Config{}, err
	}
	cfg.Disabled = disabled == 1
	rows, err := tx.Query(`SELECT l.id, l.name, l.source, l.action, t.name, l.note, i.url, i.refresh_hours
		FROM lists l LEFT JOIN import_sources i ON i.list_id = l.id LEFT JOIN tunnels t ON t.id = l.tunnel_id
		ORDER BY l.position, l.id`)
	if err != nil {
		return config.Config{}, err
	}
	idx := map[int64]int{}
	notes := map[int64]string{}
	for rows.Next() {
		var id int64
		var l config.List
		var source, note string
		var url, tunnelName sql.NullString
		var refresh sql.NullInt64
		if err := rows.Scan(&id, &l.Name, &source, &l.Action, &tunnelName, &note, &url, &refresh); err != nil {
			rows.Close()
			return config.Config{}, err
		}
		l.Tunnel = tunnelName.String
		switch source {
		case "custom":
			l.Custom = true
		case "import":
			l.Import = &config.Import{URL: url.String, RefreshHours: int(refresh.Int64)}
			cfg.Lists = append(cfg.Lists, l) // entries stay in the database
			continue
		}
		idx[id] = len(cfg.Lists)
		notes[id] = note
		cfg.Lists = append(cfg.Lists, l)
	}
	if err := closeRows(rows); err != nil {
		return config.Config{}, err
	}
	rows, err = tx.Query("SELECT list_id, kind, value, note FROM entries ORDER BY list_id, position")
	if err != nil {
		return config.Config{}, err
	}
	for rows.Next() {
		var id int64
		var kind, value, note string
		if err := rows.Scan(&id, &kind, &value, &note); err != nil {
			rows.Close()
			return config.Config{}, err
		}
		i, ok := idx[id]
		if !ok {
			continue // unreachable with foreign keys on
		}
		cfg.Lists[i].Entries = append(cfg.Lists[i].Entries, append(noteLines(note), entryText(rules.Kind(kind), value))...)
	}
	if err := closeRows(rows); err != nil {
		return config.Config{}, err
	}
	for id, i := range idx {
		cfg.Lists[i].Entries = append(cfg.Lists[i].Entries, noteLines(notes[id])...)
	}
	// Hand edits bypass config.Validate; never hand an invalid config to the
	// route planner.
	if err := cfg.Validate(); err != nil {
		return config.Config{}, fmt.Errorf("settings database: %w", err)
	}
	return cfg, nil
}

func closeRows(rows *sql.Rows) error {
	err := rows.Err()
	if cerr := rows.Close(); err == nil {
		err = cerr
	}
	return err
}

// write replaces the stored settings with cfg (already validated). Lists keep
// their id and created_at across saves; lists missing from cfg are deleted
// with their entries.
func (s *Store) write(tx *sql.Tx, cfg config.Config) error {
	now := s.stamp()
	if _, err := tx.Exec("UPDATE settings SET base_url = ?, disabled = ? WHERE id = 1", cfg.BaseURL, boolInt(cfg.Disabled)); err != nil {
		return err
	}
	type stored struct {
		id     int64
		source string
	}
	existing := map[string]stored{}
	rows, err := tx.Query("SELECT id, name, source FROM lists")
	if err != nil {
		return err
	}
	for rows.Next() {
		var st stored
		var name string
		if err := rows.Scan(&st.id, &name, &st.source); err != nil {
			rows.Close()
			return err
		}
		existing[name] = st
	}
	if err := closeRows(rows); err != nil {
		return err
	}
	ins, err := tx.Prepare("INSERT INTO entries (list_id, position, kind, value, note) VALUES (?, ?, ?, ?, ?)")
	if err != nil {
		return err
	}
	defer ins.Close()
	for pos, l := range cfg.Lists {
		source := "release"
		switch {
		case l.Custom:
			source = "custom"
		case l.Import != nil:
			source = "import"
		}
		ents, listNote, err := toRows(l.Entries)
		if err != nil {
			return fmt.Errorf("list %q: %w", l.Name, err)
		}
		var tunnelID sql.NullInt64 // NULL: the default tunnel
		if l.Tunnel != "" {
			if err := tx.QueryRow("SELECT id FROM tunnels WHERE name = ?", l.Tunnel).Scan(&tunnelID.Int64); errors.Is(err, sql.ErrNoRows) {
				return fmt.Errorf("list %q: no tunnel named %q", l.Name, l.Tunnel)
			} else if err != nil {
				return err
			}
			tunnelID.Valid = true
		}
		old, ok := existing[l.Name]
		id := old.id
		if ok {
			delete(existing, l.Name)
			if _, err := tx.Exec("UPDATE lists SET source = ?, action = ?, tunnel_id = ?, position = ?, note = ?, updated_at = ? WHERE id = ?",
				source, l.Action, tunnelID, pos, listNote, now, id); err != nil {
				return err
			}
			// An import's entries come from its downloads; keep them unless
			// the list just became an import.
			if source != "import" || old.source != "import" {
				if _, err := tx.Exec("DELETE FROM entries WHERE list_id = ?", id); err != nil {
					return err
				}
			}
			if source != "import" && old.source == "import" {
				if _, err := tx.Exec("DELETE FROM import_sources WHERE list_id = ?", id); err != nil {
					return err
				}
			}
		} else {
			res, err := tx.Exec("INSERT INTO lists (name, source, action, tunnel_id, position, note, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
				l.Name, source, l.Action, tunnelID, pos, listNote, now, now)
			if err != nil {
				return err
			}
			if id, err = res.LastInsertId(); err != nil {
				return err
			}
		}
		if source == "import" {
			if err := writeImport(tx, id, *l.Import); err != nil {
				return err
			}
			continue
		}
		for i, e := range ents {
			if _, err := ins.Exec(id, i, string(e.Kind), e.value, e.note); err != nil {
				return err
			}
		}
	}
	for _, old := range existing {
		id := old.id
		if _, err := tx.Exec("DELETE FROM lists WHERE id = ?", id); err != nil {
			return err
		}
	}
	return nil
}

// writeImport records where an import comes from. A new URL drops the old
// entries and download state: entries from another source would be
// misleading, so the list routes nothing until the new URL is downloaded.
func writeImport(tx *sql.Tx, id int64, im config.Import) error {
	var url string
	err := tx.QueryRow("SELECT url FROM import_sources WHERE list_id = ?", id).Scan(&url)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		_, err = tx.Exec("INSERT INTO import_sources (list_id, url, refresh_hours) VALUES (?, ?, ?)", id, im.URL, im.RefreshHours)
		return err
	case err != nil:
		return err
	case url != im.URL:
		if _, err := tx.Exec("DELETE FROM entries WHERE list_id = ?", id); err != nil {
			return err
		}
		_, err = tx.Exec(`UPDATE import_sources SET url = ?, refresh_hours = ?, etag = '', last_modified = '', sha256 = '',
			fetched_at = '', checked_at = '', last_error = '', force = 0, skipped = 0 WHERE list_id = ?`, im.URL, im.RefreshHours, id)
		return err
	}
	_, err = tx.Exec("UPDATE import_sources SET refresh_hours = ? WHERE list_id = ?", im.RefreshHours, id)
	return err
}

type row struct {
	Kind  rules.Kind
	value string
	note  string
}

// toRows turns a custom list's lines into entry rows in canonical form,
// dropping duplicates. "#" lines become the note of the next entry; those
// after the last entry become the list's note. Blank lines are dropped.
func toRows(lines []string) ([]row, string, error) {
	var out []row
	var pending []string
	seen := map[string]bool{}
	for _, l := range lines {
		l = strings.TrimSpace(l)
		switch {
		case l == "":
		case strings.HasPrefix(l, "#"):
			pending = append(pending, strings.TrimSpace(strings.TrimPrefix(l, "#")))
		default:
			e, err := rules.ParseEntry(l)
			if err != nil {
				return nil, "", err
			}
			v := entryValue(e)
			if k := string(e.Kind) + " " + v; !seen[k] {
				seen[k] = true
				out = append(out, row{e.Kind, v, strings.Join(pending, "\n")})
				pending = nil
			}
		}
	}
	return out, strings.Join(pending, "\n"), nil
}

// entryValue is the stored value: the entry without its kind marker.
func entryValue(e rules.Entry) string {
	switch e.Kind {
	case rules.Domain:
		return e.Name
	case rules.ASN:
		return strings.TrimPrefix(e.String(), "AS")
	}
	return e.String() // CIDR as typed back (a single address without /32), domain suffix as is
}

// entryText is the line a stored entry reads back as (rules.ParseEntry syntax).
func entryText(kind rules.Kind, value string) string {
	switch kind {
	case rules.Domain:
		return "full:" + value
	case rules.ASN:
		return "AS" + value
	}
	return value
}

func noteLines(note string) []string {
	if note == "" {
		return nil
	}
	var out []string
	for _, l := range strings.Split(note, "\n") {
		out = append(out, strings.TrimSpace("# "+l))
	}
	return out
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}
