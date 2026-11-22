package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"github.com/split-route/core/importers/openvpn"
)

// ErrNoTunnel: no tunnel has that id.
var ErrNoTunnel = errors.New("no such tunnel")

// ErrTunnelExists: a tunnel already has that name.
var ErrTunnelExists = errors.New("a tunnel with that name already exists")

// DefaultKind is the protocol of a tunnel stored before there were others.
const DefaultKind = "openvpn"

// Tunnel is a stored tunnel's metadata. What it runs (an OpenVPN profile, or a
// link's options) is a root-only file; ProfileSHA256 is that file's hash.
type Tunnel struct {
	ID   int64
	Name string
	// Kind is the core's protocol name ("openvpn", "vless", ...). Empty on
	// insert means openvpn.
	Kind          string
	ProfileSHA256 string
	Remotes       []string
	NeedsAuth     bool
	KeyEncrypted  bool
	Scripts       []string // confirmed script directives
	AutoConnect   bool
	// SubscriptionID is the subscription the tunnel came from; 0 for none.
	SubscriptionID int64
	// Warning is something to show on the tunnel (certificate checks are off).
	Warning string
}

const tunnelCols = "id, name, kind, profile_sha256, remotes, needs_auth, key_encrypted, scripts, auto_connect, subscription_id, warning"

type scanner interface{ Scan(...any) error }

func scanTunnel(r scanner) (Tunnel, error) {
	var t Tunnel
	var remotes, scripts string
	var auth, key, auto int
	var sub sql.NullInt64
	if err := r.Scan(&t.ID, &t.Name, &t.Kind, &t.ProfileSHA256, &remotes, &auth, &key, &scripts, &auto, &sub, &t.Warning); err != nil {
		return Tunnel{}, err
	}
	t.SubscriptionID = sub.Int64
	t.NeedsAuth, t.KeyEncrypted, t.AutoConnect = auth == 1, key == 1, auto == 1
	if remotes != "" {
		t.Remotes = strings.Split(remotes, "\n")
	}
	t.Scripts = strings.Fields(scripts)
	return t, nil
}

// Tunnels returns all tunnels in display order.
func (s *Store) Tunnels() ([]Tunnel, error) {
	rows, err := s.db.Query("SELECT " + tunnelCols + " FROM tunnels ORDER BY position, id")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Tunnel
	for rows.Next() {
		t, err := scanTunnel(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// TunnelByID returns one tunnel, or ErrNoTunnel.
func (s *Store) TunnelByID(id int64) (Tunnel, error) {
	t, err := scanTunnel(s.db.QueryRow("SELECT "+tunnelCols+" FROM tunnels WHERE id = ?", id))
	if errors.Is(err, sql.ErrNoRows) {
		return Tunnel{}, ErrNoTunnel
	}
	return t, err
}

// execer is a database or a transaction.
type execer interface {
	Exec(query string, args ...any) (sql.Result, error)
}

// insertTunnel stores t at the end of the list.
func insertTunnel(x execer, t Tunnel, now string) (int64, error) {
	if err := openvpn.ValidName(t.Name); err != nil {
		return 0, err
	}
	if len(t.ProfileSHA256) != 64 {
		return 0, errors.New("tunnel needs the content's sha256")
	}
	if t.Kind == "" {
		t.Kind = DefaultKind
	}
	var sub any
	if t.SubscriptionID != 0 {
		sub = t.SubscriptionID
	}
	res, err := x.Exec(`INSERT INTO tunnels (name, kind, profile_sha256, remotes, needs_auth, key_encrypted, scripts, auto_connect, subscription_id, warning, position, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, (SELECT coalesce(max(position), -1) + 1 FROM tunnels), ?, ?)`,
		t.Name, t.Kind, t.ProfileSHA256, strings.Join(t.Remotes, "\n"), b2i(t.NeedsAuth), b2i(t.KeyEncrypted),
		strings.Join(t.Scripts, " "), b2i(t.AutoConnect), sub, t.Warning, now, now)
	if err != nil {
		if isUnique(err) {
			return 0, ErrTunnelExists
		}
		return 0, err
	}
	return res.LastInsertId()
}

// AddTunnel stores a new tunnel at the end of the list and returns its id.
func (s *Store) AddTunnel(t Tunnel) (int64, error) {
	return insertTunnel(s.db, t, s.stamp())
}

// RemoveTunnel deletes a tunnel's row.
func (s *Store) RemoveTunnel(id int64) error {
	using, err := s.ListsUsingTunnel(id)
	if err != nil {
		return err
	}
	if len(using) > 0 {
		return ErrTunnelInUse(using)
	}
	res, err := s.db.Exec("DELETE FROM tunnels WHERE id = ?", id)
	return affected(res, err)
}

// ErrTunnelInUse says which lists use a tunnel that was to be removed.
type ErrTunnelInUse []string

func (e ErrTunnelInUse) Error() string {
	return fmt.Sprintf("this tunnel is used by the lists %s; choose another tunnel for them first", strings.Join(e, ", "))
}

// ListsUsingTunnel returns the names of the lists that name the tunnel.
func (s *Store) ListsUsingTunnel(id int64) ([]string, error) {
	rows, err := s.db.Query("SELECT name FROM lists WHERE tunnel_id = ? ORDER BY position", id)
	if err != nil {
		return nil, err
	}
	var using []string
	for rows.Next() {
		var n string
		if err := rows.Scan(&n); err != nil {
			rows.Close()
			return nil, err
		}
		using = append(using, n)
	}
	return using, closeRows(rows)
}

// RenameTunnel changes a tunnel's name.
func (s *Store) RenameTunnel(id int64, name string) error {
	if err := openvpn.ValidName(name); err != nil {
		return err
	}
	res, err := s.db.Exec("UPDATE tunnels SET name = ?, updated_at = ? WHERE id = ?", name, s.stamp(), id)
	if err != nil && isUnique(err) {
		return ErrTunnelExists
	}
	return affected(res, err)
}

// SetTunnelAutoConnect says whether the daemon connects the tunnel itself
// when it starts.
func (s *Store) SetTunnelAutoConnect(id int64, on bool) error {
	res, err := s.db.Exec("UPDATE tunnels SET auto_connect = ?, updated_at = ? WHERE id = ?", b2i(on), s.stamp(), id)
	return affected(res, err)
}

func affected(res sql.Result, err error) error {
	if err != nil {
		return err
	}
	if n, err := res.RowsAffected(); err != nil || n == 0 {
		if err != nil {
			return err
		}
		return ErrNoTunnel
	}
	return nil
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}

// isUnique reports a UNIQUE constraint violation (SQLITE_CONSTRAINT_UNIQUE).
func isUnique(err error) bool {
	var e interface{ Code() int }
	return errors.As(err, &e) && e.Code() == 2067
}
