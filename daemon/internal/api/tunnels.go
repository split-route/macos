//go:build darwin || linux

package api

import (
	"errors"
	"strconv"
	"time"

	"github.com/split-route/core/importers/openvpn"
)

// State is a tunnel's state as the app shows it.
type State string

const (
	Disconnected State = "disconnected"
	Connecting   State = "connecting"
	NeedsAuth    State = "needs_auth" // waiting for credentials from the app
	Connected    State = "connected"
	// Ready is a tunnel with no session of its own (VLESS, Trojan, ...): the
	// engine runs it and traffic can use it, but nothing has proven the server
	// answers. Shown as "Ready", never as "Connected".
	Ready        State = "ready"
	Reconnecting State = "reconnecting"
	Failed       State = "failed" // stopped for the reason in Error (bad credentials, a start that failed)
)

// Credentials are kept in the daemon's memory only, while a tunnel is wanted.
type Credentials struct {
	User, Pass string
	KeyPass    string // reserved: encrypted private keys are not supported yet
	HaveAuth   bool
	HaveKey    bool
}

// Tunnel is a stored tunnel and its live state. The daemon never returns
// credentials or profile text.
type Tunnel struct {
	Name string `json:"name"`
	// Protocol is the core's protocol name ("openvpn", "vless", ...).
	Protocol string `json:"protocol"`
	// Group is the subscription the tunnel came from; empty for the default group.
	Group string `json:"group,omitempty"`
	// Warning is something to show on the tunnel (certificate checks are off).
	Warning      string    `json:"warning,omitempty"`
	Remotes      []string  `json:"remotes,omitempty"`
	NeedsAuth    bool      `json:"needs_auth"`
	KeyEncrypted bool      `json:"key_encrypted"`
	AutoConnect  bool      `json:"auto_connect"`
	State        State     `json:"state"`
	Error        string    `json:"error,omitempty"`
	Need         string    `json:"need,omitempty"` // "auth" or "key" while State is needs_auth
	LocalIP      string    `json:"local_ip,omitempty"`
	RemoteIP     string    `json:"remote_ip,omitempty"`
	Since        time.Time `json:"since,omitzero"`
	BytesIn      uint64    `json:"bytes_in,omitempty"`
	BytesOut     uint64    `json:"bytes_out,omitempty"`
}

// TunnelCheck is what a profile asks for, shown before it is imported.
type TunnelCheck struct {
	Remotes        []string `json:"remotes"`
	NeedsAuth      bool     `json:"needs_auth"`
	KeyEncrypted   bool     `json:"key_encrypted"`
	Scripts        []string `json:"scripts,omitempty"`
	ScriptSecurity int      `json:"script_security"`
}

// Subscription is a group of tunnels that came from one URL. The URL itself
// is never sent: it carries the user's token.
type Subscription struct {
	Name      string    `json:"name"`
	Tunnels   int       `json:"tunnels"`
	UpdatedAt time.Time `json:"updated_at,omitzero"`
	Error     string    `json:"error,omitempty"` // why the last update failed
}

// Skipped is a link that was not imported. Label never holds credentials.
type Skipped struct {
	Label  string `json:"label"`
	Reason string `json:"reason"`
}

// AddResult is the answer to "tunnels_add".
type AddResult struct {
	Added   int       `json:"added"`
	Skipped []Skipped `json:"skipped,omitempty"`
	// Group is the subscription that was created, or "".
	Group string `json:"group,omitempty"`
}

// TunnelList is the answer to "tunnels".
type TunnelList struct {
	Tunnels       []Tunnel       `json:"tunnels"`
	Subscriptions []Subscription `json:"subscriptions,omitempty"`
	// VPN is whether the user has the VPN on; Selected is the name of the tunnel
	// that carries all traffic no list names ("" for none).
	VPN      bool   `json:"vpn"`
	Selected string `json:"selected,omitempty"`
	// Unavailable is why tunnels can't run here, or "".
	Unavailable string `json:"unavailable,omitempty"`
}

// Tunnels is what the socket needs from the daemon for tunnels. Tunnels are
// addressed by name.
type Tunnels interface {
	Tunnels() (TunnelList, error)
	TunnelImport(name string, profile []byte) (Tunnel, error)
	// VPNSet turns the VPN on or off.
	VPNSet(on bool) error
	// TunnelSelect makes a tunnel the one that carries traffic no list names.
	TunnelSelect(name string) error
	// TunnelsAdd imports share links or a subscription: from text, or from url
	// (kept as a subscription named name, or the URL's host).
	TunnelsAdd(text []byte, url, name string) (AddResult, error)
	// TunnelGroupRemove removes a subscription and its tunnels.
	TunnelGroupRemove(name string) error
	TunnelRemove(name string) error
	TunnelRename(name, newName string) error
	TunnelAutoConnect(name string, on bool) error
	TunnelConnect(name string, c Credentials) error
	TunnelCredentials(name string, c Credentials) error
	TunnelDisconnect(name string) error
	TunnelLogs(name string) ([]string, error)
}

func checkOf(p openvpn.Profile) *TunnelCheck {
	return &TunnelCheck{Remotes: p.Remotes, NeedsAuth: p.NeedsAuth, KeyEncrypted: p.KeyEncrypted, Scripts: p.Scripts, ScriptSecurity: p.ScriptSecurity}
}

func credsOf(req Request) Credentials {
	return Credentials{User: req.Username, Pass: req.Password, KeyPass: req.KeyPassword,
		HaveAuth: req.Username != "" || req.Password != "", HaveKey: req.KeyPassword != ""}
}

// respondTunnel answers the tunnel_* commands and "tunnels".
func respondTunnel(b Backend, req Request) (r Response, handled bool) {
	if req.Cmd != "vpn_set" && (len(req.Cmd) < 7 || req.Cmd[:6] != "tunnel") {
		return r, false
	}
	t, ok := b.(Tunnels)
	if !ok {
		return Response{Error: "this build has no tunnel support"}, true
	}
	need := func() bool { return req.Name != "" }
	var err error
	switch req.Cmd {
	case "tunnels":
		var l TunnelList
		if l, err = t.Tunnels(); err == nil {
			r.Tunnels = &l
		}
	case "tunnel_check":
		var p openvpn.Profile
		if p, err = openvpn.Parse([]byte(req.Text)); err == nil {
			r.Check = checkOf(p)
		}
	case "vpn_set":
		if req.Enabled == nil {
			return Response{Error: "vpn_set needs enabled"}, true
		}
		err = t.VPNSet(*req.Enabled)
	case "tunnel_select":
		if !need() {
			return Response{Error: "tunnel_select needs a name"}, true
		}
		err = t.TunnelSelect(req.Name)
	case "tunnels_add":
		if (req.Text == "") == (req.URL == "") {
			return Response{Error: "tunnels_add needs either text or a url"}, true
		}
		var res AddResult
		if res, err = t.TunnelsAdd([]byte(req.Text), req.URL, req.Name); err == nil {
			r.Added = &res
		}
	case "tunnel_group_remove":
		if !need() {
			return Response{Error: "tunnel_group_remove needs the subscription's name"}, true
		}
		err = t.TunnelGroupRemove(req.Name)
	case "tunnel_import":
		if !need() || req.Text == "" {
			return Response{Error: "tunnel_import needs a name and the profile text"}, true
		}
		var tn Tunnel
		if tn, err = t.TunnelImport(req.Name, []byte(req.Text)); err == nil {
			r.Tunnel = &tn
		}
	case "tunnel_remove", "tunnel_disconnect", "tunnel_logs", "tunnel_rename", "tunnel_auto_connect", "tunnel_connect", "tunnel_credentials":
		if !need() {
			return Response{Error: req.Cmd + " needs a name"}, true
		}
		switch req.Cmd {
		case "tunnel_remove":
			err = t.TunnelRemove(req.Name)
		case "tunnel_disconnect":
			err = t.TunnelDisconnect(req.Name)
		case "tunnel_logs":
			r.Logs, err = t.TunnelLogs(req.Name)
		case "tunnel_rename":
			err = t.TunnelRename(req.Name, req.NewName)
		case "tunnel_auto_connect":
			if req.Enabled == nil {
				return Response{Error: "tunnel_auto_connect needs enabled"}, true
			}
			err = t.TunnelAutoConnect(req.Name, *req.Enabled)
		case "tunnel_connect":
			err = t.TunnelConnect(req.Name, credsOf(req))
		case "tunnel_credentials":
			err = t.TunnelCredentials(req.Name, credsOf(req))
		}
	default:
		err = errors.New("unknown command " + strconv.Quote(req.Cmd))
	}
	if err != nil {
		return Response{Error: err.Error()}, true
	}
	r.OK = true
	return r, true
}
