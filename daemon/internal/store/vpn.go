package store

import (
	"database/sql"
	"errors"
)

// VPN is the user's choice: whether the VPN is on, and which tunnel carries the
// traffic no list names (Selected is a tunnel id, 0 for none).
type VPN struct {
	On       bool
	Selected int64
}

// VPN reads the switch and the selected tunnel.
func (s *Store) VPN() (VPN, error) {
	var on int
	var sel sql.NullInt64
	err := s.db.QueryRow("SELECT vpn_on, selected_tunnel_id FROM settings WHERE id = 1").Scan(&on, &sel)
	if errors.Is(err, sql.ErrNoRows) {
		return VPN{}, ErrNotInitialized
	}
	return VPN{On: on == 1, Selected: sel.Int64}, err
}

// SetVPNOn turns the switch.
func (s *Store) SetVPNOn(on bool) error {
	res, err := s.db.Exec("UPDATE settings SET vpn_on = ? WHERE id = 1", b2i(on))
	return settingsAffected(res, err)
}

// SetSelected chooses the tunnel; id 0 clears the choice. A tunnel that doesn't
// exist is refused (ErrNoTunnel).
func (s *Store) SetSelected(id int64) error {
	var v any
	if id != 0 {
		v = id
		var n int
		if err := s.db.QueryRow("SELECT count(*) FROM tunnels WHERE id = ?", id).Scan(&n); err != nil {
			return err
		}
		if n == 0 {
			return ErrNoTunnel
		}
	}
	res, err := s.db.Exec("UPDATE settings SET selected_tunnel_id = ? WHERE id = 1", v)
	return settingsAffected(res, err)
}

func settingsAffected(res sql.Result, err error) error {
	if err != nil {
		return err
	}
	if n, err := res.RowsAffected(); err != nil || n == 0 {
		if err != nil {
			return err
		}
		return ErrNotInitialized
	}
	return nil
}
