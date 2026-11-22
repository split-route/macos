//go:build darwin || linux

// Package api is the control socket. It speaks one JSON request and one JSON
// response per connection. The menu bar app uses it; the daemon is the only
// writer of the config, so the app never needs root.
//
//	{"cmd": "status"}                          → status
//	{"cmd": "get_config"}                      → config
//	{"cmd": "set_config", "config": {...}}     → config (validated, saved, applied)
//	{"cmd": "set_enabled", "enabled": false}   → config
//	{"cmd": "apply_preset", "preset": "iran"}  → config
//	{"cmd": "lists"}                           → lists available in the latest release
//	{"cmd": "presets"}                         → presets
//
// Tunnels (addressed by name; see tunnels.go). Credentials in a
// request are used for that connection only:
//
//	{"cmd": "tunnels"}                                          → tunnels
//	{"cmd": "tunnel_check", "text": "<.ovpn>"}                  → check (what the profile asks for)
//	{"cmd": "tunnel_import", "name": "Work", "text": "<.ovpn>"}                    → tunnel
//	{"cmd": "vpn_set", "enabled": true}                                             turns the VPN on or off
//	{"cmd": "tunnel_select", "name": "Work"}                                        the tunnel for all traffic no list names
//	{"cmd": "tunnels_add", "text": "<links or a subscription body>"}               → added
//	{"cmd": "tunnels_add", "url": "https://…", "name": "Provider"}                  → added (kept as a subscription)
//	{"cmd": "tunnel_group_remove", "name": "Provider"}                              removes a subscription and its tunnels
//	{"cmd": "tunnel_connect", "name": "Work", "username": "…", "password": "…"}
//	{"cmd": "tunnel_credentials", "name": "Work", "username": "…", "password": "…", "key_password": "…"}
//	{"cmd": "tunnel_disconnect" | "tunnel_remove" | "tunnel_logs", "name": "Work"}  (logs → logs)
//	{"cmd": "tunnel_rename", "name": "Work", "new_name": "Office"}
//	{"cmd": "tunnel_auto_connect", "name": "Work", "enabled": true}
//
// List edits (each → config; entry edits also → edit counts):
//
//	{"cmd": "list_create", "name": "Work", "action": "direct"}       new custom list
//	{"cmd": "list_enable", "name": "telegram", "action": "tunnel"}   add a release list
//	{"cmd": "list_remove", "name": "Work"}
//	{"cmd": "list_rename", "name": "Work", "new_name": "Office"}     custom lists only
//	{"cmd": "list_set_action", "name": "Work", "action": "block"}
//	{"cmd": "list_move", "name": "Work", "position": 0}              0-based
//	{"cmd": "entries_add", "name": "Work", "entries": ["example.com"]}
//	{"cmd": "entries_remove", "name": "Work", "entries": ["example.com"]}
//	{"cmd": "entries_set", "name": "Work", "entries": ["example.com"]}           replaces all entries
//	{"cmd": "list_import", "name": "Ads", "action": "block", "url": "https://…"}   downloaded by the service
//	{"cmd": "list_refresh", "name": "Ads"}                                         download now → no config
package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/user"
	"strconv"
	"time"

	"github.com/split-route/core/lists"
	"github.com/split-route/core/rules"
	"github.com/split-route/macos/daemon/internal/catalog"
	"github.com/split-route/macos/daemon/internal/config"
)

// Backend is what the socket needs from the daemon.
type Backend interface {
	Status() (Status, error)
	LoadConfig() (config.Config, error)
	// UpdateConfig loads the config, changes it with f, validates, saves and
	// applies it.
	UpdateConfig(f func(config.Config) (config.Config, error)) (config.Config, error)
	AvailableLists() ([]string, error)
	// RefreshImport marks an import to be downloaded on the next pass.
	RefreshImport(name string) error
	// Restart makes the service stop its tunnels and exit; its service manager
	// starts the updated binary.
	Restart() error
}

type Request struct {
	Cmd     string         `json:"cmd"`
	Config  *config.Config `json:"config,omitempty"`
	Enabled *bool          `json:"enabled,omitempty"`
	Preset  string         `json:"preset,omitempty"`

	// List edits.
	Name     string       `json:"name,omitempty"`
	NewName  string       `json:"new_name,omitempty"`
	Action   rules.Action `json:"action,omitempty"`
	Tunnel   string       `json:"tunnel,omitempty"` // list_set_action: the tunnel for the tunnel action (empty: the default)
	Position *int         `json:"position,omitempty"`
	Entries  []string     `json:"entries,omitempty"`
	URL      string       `json:"url,omitempty"`
	// Text is a list file's contents for list_create (plain entries, hosts
	// file or domain set, read like an import). The app reads the file; the
	// daemon never opens a path from the socket.
	Text string `json:"text,omitempty"`

	// Tunnel commands. Credentials are used and dropped; they are never
	// stored, logged or returned.
	Username    string `json:"username,omitempty"`
	Password    string `json:"password,omitempty"`
	KeyPassword string `json:"key_password,omitempty"`
}

type Response struct {
	OK      bool              `json:"ok"`
	Error   string            `json:"error,omitempty"`
	Status  *Status           `json:"status,omitempty"`
	Config  *config.Config    `json:"config,omitempty"`
	Lists   []string          `json:"lists,omitempty"`
	Catalog []catalog.Info    `json:"catalog,omitempty"` // "lists": titles of the release lists
	Presets []config.Preset   `json:"presets,omitempty"`
	Edit    *config.EntryEdit `json:"edit,omitempty"` // entries_add, entries_remove, entries_set

	Tunnels *TunnelList  `json:"tunnels,omitempty"` // tunnels
	Tunnel  *Tunnel      `json:"tunnel,omitempty"`  // tunnel_import
	Added   *AddResult   `json:"added,omitempty"`   // tunnels_add
	Check   *TunnelCheck `json:"check,omitempty"`   // tunnel_check
	Logs    []string     `json:"logs,omitempty"`    // tunnel_logs
}

const (
	maxRequest  = 8 << 20          // list_create text: 100k hosts lines are about 3 MB
	connTimeout = 90 * time.Second // "lists" downloads SHA256SUMS
)

// SockPath is the socket's path on goos.
func SockPath(goos string) string {
	if goos == "darwin" {
		return "/var/run/splitroute.sock"
	}
	return "/run/splitroute.sock"
}

// Listen opens the control socket. On macOS members of the admin group may
// connect (they can sudo anyway); elsewhere only root.
func Listen(goos string) (net.Listener, error) {
	p := SockPath(goos)
	_ = os.Remove(p) // stale socket from a crash; watch holds the lock, so no other daemon owns it
	ln, err := net.Listen("unix", p)
	if err != nil {
		return nil, err
	}
	mode := os.FileMode(0o600)
	if goos == "darwin" {
		if g, err := user.LookupGroup("admin"); err == nil {
			if gid, err := strconv.Atoi(g.Gid); err == nil && os.Chown(p, 0, gid) == nil {
				mode = 0o660
			}
		}
	}
	if err := os.Chmod(p, mode); err != nil {
		ln.Close()
		return nil, err
	}
	return ln, nil
}

// Serve handles connections until ln is closed.
func Serve(ln net.Listener, b Backend) {
	for {
		c, err := ln.Accept()
		if err != nil {
			if !errors.Is(err, net.ErrClosed) {
				log.Printf("control socket: %v", err)
			}
			return
		}
		go Handle(c, b)
	}
}

// Handle reads one request from c, answers it and closes c.
func Handle(c net.Conn, b Backend) {
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(connTimeout))
	var req Request
	var resp Response
	if err := json.NewDecoder(io.LimitReader(c, maxRequest)).Decode(&req); err != nil {
		resp = Response{Error: "bad request: " + err.Error()}
	} else {
		resp = Respond(b, req)
	}
	_ = json.NewEncoder(c).Encode(resp)
}

// Respond answers one request.
func Respond(b Backend, req Request) Response {
	if r, ok := respondTunnel(b, req); ok {
		return r
	}
	var r Response
	var err error
	switch req.Cmd {
	case "status":
		var s Status
		s, err = b.Status()
		r.Status = &s
	case "get_config":
		var cfg config.Config
		cfg, err = b.LoadConfig()
		r.Config = &cfg
	case "set_config":
		if req.Config == nil {
			return Response{Error: "set_config needs a config"}
		}
		r.Config, err = update(b, func(config.Config) (config.Config, error) { return *req.Config, nil })
	case "set_enabled":
		if req.Enabled == nil {
			return Response{Error: "set_enabled needs enabled"}
		}
		r.Config, err = update(b, func(c config.Config) (config.Config, error) { c.Disabled = !*req.Enabled; return c, nil })
	case "apply_preset":
		r.Config, err = update(b, func(c config.Config) (config.Config, error) { return config.WithPreset(c, req.Preset) })
	case "lists":
		r.Lists, err = b.AvailableLists()
		for _, n := range r.Lists {
			r.Catalog = append(r.Catalog, catalog.Describe(n))
		}
	case "presets":
		r.Presets = config.Presets
	case "restart":
		err = b.Restart()
	case "list_refresh":
		if req.Name == "" {
			return Response{Error: "list_refresh needs a name"}
		}
		err = b.RefreshImport(req.Name)
	case "list_import", "list_create", "list_enable", "list_remove", "list_rename", "list_set_action", "list_move", "entries_add", "entries_remove", "entries_set":
		var edit func(config.Config) (config.Config, error)
		if edit, err = listEdit(req, &r); err == nil {
			r.Config, err = update(b, edit)
		}
	default:
		err = errors.New("unknown command " + strconv.Quote(req.Cmd))
	}
	if err != nil {
		return Response{Error: err.Error()}
	}
	r.OK = true
	return r
}

func update(b Backend, f func(config.Config) (config.Config, error)) (*config.Config, error) {
	cfg, err := b.UpdateConfig(f)
	if err != nil {
		return nil, err
	}
	return &cfg, nil
}

// listEdit turns a list edit request into a config change. Entry counts land
// in r.Edit when the change runs.
func listEdit(req Request, r *Response) (func(config.Config) (config.Config, error), error) {
	if req.Name == "" {
		return nil, fmt.Errorf("%s needs a name", req.Cmd)
	}
	switch req.Cmd {
	case "list_create":
		if req.Text != "" {
			return createFromText(req, r)
		}
		return func(c config.Config) (config.Config, error) { return config.CreateList(c, req.Name, req.Action) }, nil
	case "list_enable":
		return func(c config.Config) (config.Config, error) { return config.EnableRelease(c, req.Name, req.Action) }, nil
	case "list_import":
		return func(c config.Config) (config.Config, error) {
			return config.ImportList(c, req.Name, req.Action, req.URL)
		}, nil
	case "list_remove":
		return func(c config.Config) (config.Config, error) { return config.RemoveList(c, req.Name) }, nil
	case "list_rename":
		return func(c config.Config) (config.Config, error) { return config.RenameList(c, req.Name, req.NewName) }, nil
	case "list_set_action":
		return func(c config.Config) (config.Config, error) {
			return config.SetAction(c, req.Name, req.Action, req.Tunnel)
		}, nil
	case "list_move":
		if req.Position == nil {
			return nil, errors.New("list_move needs a position")
		}
		return func(c config.Config) (config.Config, error) { return config.MoveList(c, req.Name, *req.Position) }, nil
	case "entries_add", "entries_remove", "entries_set":
		op := config.AddEntries
		switch req.Cmd {
		case "entries_remove":
			op = config.RemoveEntries
		case "entries_set":
			op = config.SetEntries
		}
		return func(c config.Config) (config.Config, error) {
			c, ed, err := op(c, req.Name, req.Entries)
			r.Edit = &ed
			return c, err
		}, nil
	}
	return nil, errors.New("unknown command " + strconv.Quote(req.Cmd))
}

// createFromText parses req.Text like an import and creates a custom list
// with its entries in one change, so a refused text leaves no empty list.
func createFromText(req Request, r *Response) (func(config.Config) (config.Config, error), error) {
	es, st, err := lists.ParseText([]byte(req.Text))
	if err != nil {
		return nil, err
	}
	all := es.All()
	if len(all) == 0 {
		return nil, errors.New("the file has no addresses, ranges, domains or AS numbers")
	}
	lines := make([]string, len(all))
	for i, e := range all {
		lines[i] = e.String()
	}
	return func(c config.Config) (config.Config, error) {
		c, err := config.CreateList(c, req.Name, req.Action)
		if err != nil {
			return c, err
		}
		c, ed, err := config.SetEntries(c, req.Name, lines)
		ed.Skipped = st.Invalid + st.Other + st.Reserved
		r.Edit = &ed
		return c, err
	}, nil
}
