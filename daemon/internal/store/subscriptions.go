package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// MaxTunnels is the most tunnels the database holds. A subscription can have
// hundreds of nodes; this stops a hostile or broken one from growing the
// database and the app's list without bound.
const MaxTunnels = 5000

// ErrTooManyTunnels: adding would pass MaxTunnels.
var ErrTooManyTunnels = fmt.Errorf("at most %d tunnels; remove some first", MaxTunnels)

// ErrNoSubscription: no subscription has that id.
var ErrNoSubscription = errors.New("no such subscription")

// ErrSubscriptionInUse says which lists use a tunnel of a subscription that was
// to be removed.
type ErrSubscriptionInUse []string

func (e ErrSubscriptionInUse) Error() string {
	return fmt.Sprintf("a tunnel of this subscription is used by the lists %s; choose another tunnel for them first", strings.Join(e, ", "))
}

// Subscription is a group of tunnels that came from one URL. The URL is a
// root-only file, never in the database: it carries the user's token.
type Subscription struct {
	ID        int64
	Name      string
	LastError string
	CreatedAt time.Time
	UpdatedAt time.Time
}

// CleanName makes a display name fit the schema: no control characters, no
// edge spaces, at most 64 bytes without cutting a character, never empty.
func CleanName(s string) string {
	s = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f || r == '‎' || r == '‏' || r == '\ufeff' {
			return ' '
		}
		return r
	}, s)
	s = strings.Join(strings.Fields(s), " ")
	return cutBytes(s, 64, "Tunnel")
}

// cutBytes cuts s to at most n bytes at a character boundary; empty becomes fallback.
func cutBytes(s string, n int, fallback string) string {
	for len(s) > n {
		_, size := utf8.DecodeLastRuneInString(s)
		s = s[:len(s)-size]
	}
	s = strings.TrimSpace(s)
	if s == "" {
		return fallback
	}
	return s
}

// uniqueName returns base, or base with " 2", " 3" ... when a name in table
// already has it (names compare without case). The suffix always fits.
func uniqueName(tx *sql.Tx, table, base string) (string, error) {
	for i := 1; ; i++ {
		name := base
		if i > 1 {
			suffix := " " + strconv.Itoa(i)
			name = cutBytes(base, 64-len(suffix), "Tunnel") + suffix
		}
		var n int
		if err := tx.QueryRow("SELECT count(*) FROM "+table+" WHERE name = ?", name).Scan(&n); err != nil {
			return "", err
		}
		if n == 0 {
			return name, nil
		}
		if i > MaxTunnels+1 {
			return "", errors.New("too many tunnels with the same name")
		}
	}
}

func tunnelCount(tx *sql.Tx) (int, error) {
	var n int
	err := tx.QueryRow("SELECT count(*) FROM tunnels").Scan(&n)
	return n, err
}

// AddTunnels stores tunnels that belong to no subscription, in one transaction:
// all of them or none. A name that is taken gets a number. Each returned
// tunnel has its id and final name.
func (s *Store) AddTunnels(ts []Tunnel) ([]Tunnel, error) {
	_, out, err := s.addAll("", ts)
	return out, err
}

// AddSubscription stores a subscription and its tunnels in one transaction.
// Names that are taken get a number, the subscription's too.
func (s *Store) AddSubscription(name string, ts []Tunnel) (Subscription, []Tunnel, error) {
	sub, out, err := s.addAll(name, ts)
	if err != nil {
		return Subscription{}, nil, err
	}
	return *sub, out, nil
}

func (s *Store) addAll(subName string, ts []Tunnel) (*Subscription, []Tunnel, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return nil, nil, err
	}
	defer tx.Rollback()
	n, err := tunnelCount(tx)
	if err != nil {
		return nil, nil, err
	}
	if n+len(ts) > MaxTunnels {
		return nil, nil, ErrTooManyTunnels
	}
	now := s.stamp()
	var sub *Subscription
	if subName != "" {
		name, err := uniqueName(tx, "subscriptions", CleanName(subName))
		if err != nil {
			return nil, nil, err
		}
		res, err := tx.Exec("INSERT INTO subscriptions (name, created_at, updated_at) VALUES (?, ?, ?)", name, now, now)
		if err != nil {
			return nil, nil, err
		}
		id, err := res.LastInsertId()
		if err != nil {
			return nil, nil, err
		}
		at, _ := time.Parse(time.RFC3339Nano, now)
		sub = &Subscription{ID: id, Name: name, CreatedAt: at, UpdatedAt: at}
	}
	out := make([]Tunnel, 0, len(ts))
	for _, t := range ts {
		if t.Name, err = uniqueName(tx, "tunnels", CleanName(t.Name)); err != nil {
			return nil, nil, err
		}
		if sub != nil {
			t.SubscriptionID = sub.ID
		}
		if t.ID, err = insertTunnel(tx, t, now); err != nil {
			return nil, nil, err
		}
		if t.Kind == "" {
			t.Kind = DefaultKind
		}
		out = append(out, t)
	}
	return sub, out, tx.Commit()
}

// Subscriptions returns every subscription, oldest first.
func (s *Store) Subscriptions() ([]Subscription, error) {
	rows, err := s.db.Query("SELECT id, name, last_error, created_at, updated_at FROM subscriptions ORDER BY id")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Subscription
	for rows.Next() {
		var sub Subscription
		var created, updated string
		if err := rows.Scan(&sub.ID, &sub.Name, &sub.LastError, &created, &updated); err != nil {
			return nil, err
		}
		sub.CreatedAt, _ = time.Parse(time.RFC3339Nano, created)
		sub.UpdatedAt, _ = time.Parse(time.RFC3339Nano, updated)
		out = append(out, sub)
	}
	return out, rows.Err()
}

// SubscriptionTunnels returns the tunnels of one subscription in display order.
func (s *Store) SubscriptionTunnels(id int64) ([]Tunnel, error) {
	rows, err := s.db.Query("SELECT "+tunnelCols+" FROM tunnels WHERE subscription_id = ? ORDER BY position, id", id)
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

// ListsUsingSubscription returns the names of the lists that use a tunnel of
// the subscription.
func (s *Store) ListsUsingSubscription(id int64) ([]string, error) {
	return listsUsingSubscription(s.db, id)
}

type querier interface {
	Query(query string, args ...any) (*sql.Rows, error)
}

func listsUsingSubscription(q querier, id int64) ([]string, error) {
	rows, err := q.Query(`SELECT DISTINCT l.name FROM lists l JOIN tunnels t ON l.tunnel_id = t.id
		WHERE t.subscription_id = ? ORDER BY l.position`, id)
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

// RemoveSubscription deletes a subscription and its tunnels in one transaction.
// It refuses while a list uses one of the tunnels; the lists are named in the
// error and nothing is changed.
func (s *Store) RemoveSubscription(id int64) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	using, err := listsUsingSubscription(tx, id)
	if err != nil {
		return err
	}
	if len(using) > 0 {
		return ErrSubscriptionInUse(using)
	}
	if _, err := tx.Exec("DELETE FROM tunnels WHERE subscription_id = ?", id); err != nil {
		return err
	}
	res, err := tx.Exec("DELETE FROM subscriptions WHERE id = ?", id)
	if err != nil {
		return err
	}
	if n, err := res.RowsAffected(); err != nil || n == 0 {
		if err != nil {
			return err
		}
		return ErrNoSubscription
	}
	return tx.Commit()
}

// ErrSubscriptionExists: a subscription already has that name.
var ErrSubscriptionExists = errors.New("a subscription with that name already exists")

// RenameSubscription changes a subscription's name. Tunnels refer to it by id,
// so nothing else changes.
func (s *Store) RenameSubscription(id int64, name string) error {
	res, err := s.db.Exec("UPDATE subscriptions SET name = ? WHERE id = ?", CleanName(name), id)
	if err != nil {
		if isUnique(err) {
			return ErrSubscriptionExists
		}
		return err
	}
	if n, err := res.RowsAffected(); err != nil || n == 0 {
		if err != nil {
			return err
		}
		return ErrNoSubscription
	}
	return nil
}

// SetSubscriptionError records why the last update failed. The text never
// holds the address.
func (s *Store) SetSubscriptionError(id int64, msg string) error {
	_, err := s.db.Exec("UPDATE subscriptions SET last_error = ? WHERE id = ?", cutBytes(msg, 300, "update failed"), id)
	return err
}

// SubscriptionSync is the change an update makes to a subscription's tunnels.
// Update holds tunnels with their ids; only the hash, the remotes and the
// warning change, so lists and the selected tunnel keep pointing at them.
type SubscriptionSync struct {
	Add    []Tunnel
	Update []Tunnel
	Remove []int64
}

// SyncSubscription applies a sync in one transaction and marks the
// subscription as updated now. Tunnels that a list uses are never removed: the
// whole sync is refused and nothing changes. files runs before the commit with
// the added tunnels (ids and final names set); if it fails nothing is stored.
func (s *Store) SyncSubscription(id int64, sy SubscriptionSync, files func(added []Tunnel) error) ([]Tunnel, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var exists int
	if err := tx.QueryRow("SELECT count(*) FROM subscriptions WHERE id = ?", id).Scan(&exists); err != nil {
		return nil, err
	}
	if exists == 0 {
		return nil, ErrNoSubscription
	}
	n, err := tunnelCount(tx)
	if err != nil {
		return nil, err
	}
	if n+len(sy.Add)-len(sy.Remove) > MaxTunnels {
		return nil, ErrTooManyTunnels
	}
	now := s.stamp()
	for _, tid := range sy.Remove {
		var using []string
		rows, err := tx.Query("SELECT name FROM lists WHERE tunnel_id = ? ORDER BY position", tid)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var name string
			if err := rows.Scan(&name); err != nil {
				rows.Close()
				return nil, err
			}
			using = append(using, name)
		}
		if err := closeRows(rows); err != nil {
			return nil, err
		}
		if len(using) > 0 {
			return nil, ErrTunnelInUse(using)
		}
		res, err := tx.Exec("DELETE FROM tunnels WHERE id = ? AND subscription_id = ?", tid, id)
		if err != nil {
			return nil, err
		}
		if err := affected(res, nil); err != nil {
			return nil, err
		}
	}
	for _, t := range sy.Update {
		res, err := tx.Exec("UPDATE tunnels SET profile_sha256 = ?, remotes = ?, warning = ?, updated_at = ? WHERE id = ? AND subscription_id = ?",
			t.ProfileSHA256, strings.Join(t.Remotes, "\n"), t.Warning, now, t.ID, id)
		if err := affected(res, err); err != nil {
			return nil, err
		}
	}
	added := make([]Tunnel, 0, len(sy.Add))
	for _, t := range sy.Add {
		if t.Name, err = uniqueName(tx, "tunnels", CleanName(t.Name)); err != nil {
			return nil, err
		}
		t.SubscriptionID = id
		if t.ID, err = insertTunnel(tx, t, now); err != nil {
			return nil, err
		}
		if t.Kind == "" {
			t.Kind = DefaultKind
		}
		added = append(added, t)
	}
	if _, err := tx.Exec("UPDATE subscriptions SET updated_at = ?, last_error = '' WHERE id = ?", now, id); err != nil {
		return nil, err
	}
	if files != nil {
		if err := files(added); err != nil {
			return nil, err
		}
	}
	return added, tx.Commit()
}
