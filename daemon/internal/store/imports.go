package store

import (
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/split-route/core/rules"
	"github.com/split-route/macos/daemon/internal/config"
)

// ErrImportChanged: the import was removed or got a new URL while it was
// being downloaded; the download is discarded.
var ErrImportChanged = errors.New("import changed during the download")

// RetryAfterError is how soon a failed download is tried again.
const RetryAfterError = 15 * time.Minute

// ImportState is an import's source and download state.
type ImportState struct {
	Name         string
	URL          string
	Refresh      time.Duration
	ETag         string
	LastModified string
	SHA256       string
	FetchedAt    time.Time // last download that replaced the entries
	CheckedAt    time.Time // last attempt
	LastError    string
	Force        bool
	Entries      int
	Skipped      int
}

// Due reports whether the import should be downloaded now: never tried,
// forced, its refresh interval passed, or RetryAfterError after a failure.
func (st ImportState) Due(now time.Time) bool {
	wait := st.Refresh
	if st.LastError != "" && RetryAfterError < wait {
		wait = RetryAfterError
	}
	return st.Force || st.CheckedAt.IsZero() || now.Sub(st.CheckedAt) >= wait
}

// Imports returns every import's state, in config order.
func (s *Store) Imports() ([]ImportState, error) {
	rows, err := s.db.Query(`SELECT l.name, i.url, i.refresh_hours, i.etag, i.last_modified, i.sha256,
			i.fetched_at, i.checked_at, i.last_error, i.force, i.skipped,
			(SELECT count(*) FROM entries e WHERE e.list_id = l.id)
		FROM lists l JOIN import_sources i ON i.list_id = l.id ORDER BY l.position, l.id`)
	if err != nil {
		return nil, err
	}
	var out []ImportState
	for rows.Next() {
		var st ImportState
		var hours int
		var fetched, checked string
		if err := rows.Scan(&st.Name, &st.URL, &hours, &st.ETag, &st.LastModified, &st.SHA256,
			&fetched, &checked, &st.LastError, &st.Force, &st.Skipped, &st.Entries); err != nil {
			rows.Close()
			return nil, err
		}
		st.Refresh = config.Import{RefreshHours: hours}.Refresh()
		st.FetchedAt, _ = time.Parse(time.RFC3339Nano, fetched)
		st.CheckedAt, _ = time.Parse(time.RFC3339Nano, checked)
		out = append(out, st)
	}
	return out, closeRows(rows)
}

// ImportEntries reads an import's entries. Each is validated again on the way
// out, like every config read.
func (s *Store) ImportEntries(name string) (rules.Entries, error) {
	var es rules.Entries
	rows, err := s.db.Query(`SELECT e.kind, e.value FROM entries e JOIN lists l ON l.id = e.list_id
		WHERE l.name = ? AND l.source = 'import'`, name)
	if err != nil {
		return es, err
	}
	for rows.Next() {
		var kind, value string
		if err := rows.Scan(&kind, &value); err != nil {
			rows.Close()
			return rules.Entries{}, err
		}
		e, err := rules.ParseEntry(entryText(rules.Kind(kind), value))
		if err != nil {
			rows.Close()
			return rules.Entries{}, fmt.Errorf("settings database: import %q: %w", name, err)
		}
		es.Add(e)
	}
	return es, closeRows(rows)
}

// ForceImport marks an import to be downloaded on the next pass.
func (s *Store) ForceImport(name string) error {
	res, err := s.db.Exec(`UPDATE import_sources SET force = 1
		WHERE list_id = (SELECT id FROM lists WHERE name = ? AND source = 'import')`, name)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("no import named %q", name)
	}
	return nil
}

// Download is a successful download of an import.
type Download struct {
	ETag, LastModified, SHA256 string
	Entries                    rules.Entries
	Skipped                    int
}

// SaveDownload replaces the import's entries with d's in one transaction, so
// readers see either the old list or the new one. url is the URL the download
// came from: if the import no longer has it, nothing is written
// (ErrImportChanged).
func (s *Store) SaveDownload(name, url string, d Download) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	id, err := importID(tx, name, url)
	if err != nil {
		return err
	}
	if _, err := tx.Exec("DELETE FROM entries WHERE list_id = ?", id); err != nil {
		return err
	}
	ins, err := tx.Prepare("INSERT INTO entries (list_id, position, kind, value) VALUES (?, ?, ?, ?)")
	if err != nil {
		return err
	}
	defer ins.Close()
	pos := 0
	for _, e := range d.Entries.All() {
		if _, err := ins.Exec(id, pos, string(e.Kind), entryValue(e)); err != nil {
			return err
		}
		pos++
	}
	now := s.stamp()
	if _, err := tx.Exec(`UPDATE import_sources SET etag = ?, last_modified = ?, sha256 = ?, fetched_at = ?, checked_at = ?,
		last_error = '', force = 0, skipped = ? WHERE list_id = ?`, d.ETag, d.LastModified, d.SHA256, now, now, d.Skipped, id); err != nil {
		return err
	}
	return tx.Commit()
}

// MarkChecked records a download attempt that kept the entries: not
// modified (errMsg ""; etag and lastModified update when the server sent new
// ones), or failed (errMsg set; the last good entries stay).
func (s *Store) MarkChecked(name, url, etag, lastModified, errMsg string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	id, err := importID(tx, name, url)
	if err != nil {
		return err
	}
	if _, err := tx.Exec(`UPDATE import_sources SET checked_at = ?, last_error = ?, force = 0,
		etag = CASE WHEN ? = '' THEN etag ELSE ? END,
		last_modified = CASE WHEN ? = '' THEN last_modified ELSE ? END WHERE list_id = ?`,
		s.stamp(), errMsg, etag, etag, lastModified, lastModified, id); err != nil {
		return err
	}
	return tx.Commit()
}

func importID(tx *sql.Tx, name, url string) (int64, error) {
	var id int64
	err := tx.QueryRow(`SELECT l.id FROM lists l JOIN import_sources i ON i.list_id = l.id
		WHERE l.name = ? AND i.url = ?`, name, url).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrImportChanged
	}
	return id, err
}

// ImportsDue reports whether any import is due (see ImportState.Due). Cheap
// enough for the service's 15 s tick: it doesn't count entries.
func (s *Store) ImportsDue(now time.Time) (bool, error) {
	rows, err := s.db.Query("SELECT refresh_hours, checked_at, last_error, force FROM import_sources")
	if err != nil {
		return false, err
	}
	due := false
	for rows.Next() {
		var st ImportState
		var hours int
		var checked string
		if err := rows.Scan(&hours, &checked, &st.LastError, &st.Force); err != nil {
			rows.Close()
			return false, err
		}
		st.Refresh = config.Import{RefreshHours: hours}.Refresh()
		st.CheckedAt, _ = time.Parse(time.RFC3339Nano, checked)
		due = due || st.Due(now)
	}
	return due, closeRows(rows)
}
