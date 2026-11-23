//go:build darwin || linux

// Package api is the control socket: the app's way to the network layer. The
// daemon keeps no settings. The app owns them and sends the desired state; the
// daemon runs it. One JSON request and one JSON response per connection.
//
//	{"cmd": "status"}                                       → status
//	{"cmd": "apply", "apply": {...}}                        the desired state (see Snapshot)
//	{"cmd": "answer", "id": "t3", "username": "…", "password": "…"}   answers a running tunnel's challenge
//	{"cmd": "test", "ids": ["t1"]}                          → tests (one request through each loaded tunnel)
//	{"cmd": "logs"}                                         → logs (the engine's last lines)
//	{"cmd": "restart"}                                      the service exits; launchd starts the updated binary
//
// Stateless helpers (the parsers live in the core, so the app asks):
//
//	{"cmd": "check_profile", "text": "<.ovpn>"}             → check
//	{"cmd": "parse_links", "text": "<links or a body>"}     → nodes
//	{"cmd": "parse_entries", "text": "…", "format": "custom|import|release", "want_lines": true}  → entries
//	{"cmd": "canon_entries", "lines": ["Example.COM"]}      → canon
//	{"cmd": "legacy_export"}                                → legacy (root-only files of versions before 0.3)
package api

import (
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"os"
	"os/user"
	"strconv"
	"time"
)

// Backend is what the socket needs from the daemon.
type Backend interface {
	Status() Status
	Apply(Snapshot) error
	Answer(id string, c Credentials) error
	Logs() []string
	Restart() error
	// Test measures each tunnel (by ID) with one request through it. The address is the daemon's, not the socket's.
	Test(ids []string) map[string]TestResult
	CheckProfile(text string) (TunnelCheck, error)
	ParseLinks(text string) (Nodes, error)
	ParseEntries(text, format string, wantLines bool) (Entries, error)
	CanonEntries(lines []string) []Canon
	LegacyExport() (LegacyState, error)
}

type Request struct {
	Cmd   string    `json:"cmd"`
	Apply *Snapshot `json:"apply,omitempty"`

	ID       string `json:"id,omitempty"`
	Username string `json:"username,omitempty"`
	Password string `json:"password,omitempty"`

	Text      string   `json:"text,omitempty"`
	Format    string   `json:"format,omitempty"`
	WantLines bool     `json:"want_lines,omitempty"`
	Lines     []string `json:"lines,omitempty"`
	IDs       []string `json:"ids,omitempty"`
}

type Response struct {
	OK     bool         `json:"ok"`
	Error  string       `json:"error,omitempty"`
	Status *Status      `json:"status,omitempty"`
	Logs   []string     `json:"logs,omitempty"`
	Check  *TunnelCheck `json:"check,omitempty"`
	Nodes  *Nodes       `json:"nodes,omitempty"`
	// Entries and Canon answer the entry parsers.
	Entries *Entries              `json:"entries,omitempty"`
	Canon   []Canon               `json:"canon,omitempty"`
	Legacy  *LegacyState          `json:"legacy,omitempty"`
	Tests   map[string]TestResult `json:"tests,omitempty"`
}

const (
	// maxRequest bounds one request: a snapshot carries every list's entries
	// (release lists run to a few MB of text each).
	maxRequest  = 64 << 20
	connTimeout = 60 * time.Second
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
	lr := &io.LimitedReader{R: c, N: maxRequest + 1}
	if err := json.NewDecoder(lr).Decode(&req); err != nil {
		if lr.N <= 0 {
			err = errors.New("request too large")
		}
		resp = Response{Error: "bad request: " + err.Error()}
	} else {
		resp = Respond(b, req)
	}
	_ = json.NewEncoder(c).Encode(resp)
}

// Respond answers one request.
func Respond(b Backend, req Request) Response {
	var r Response
	var err error
	switch req.Cmd {
	case "status":
		s := b.Status()
		r.Status = &s
	case "apply":
		if req.Apply == nil {
			return Response{Error: errNeedSnapshot.Error()}
		}
		err = b.Apply(*req.Apply)
	case "answer":
		if req.ID == "" {
			return Response{Error: "answer needs a tunnel id"}
		}
		err = b.Answer(req.ID, Credentials{User: req.Username, Pass: req.Password, HaveAuth: req.Username != "" || req.Password != ""})
	case "test":
		r.Tests = b.Test(req.IDs)
	case "logs":
		r.Logs = b.Logs()
	case "restart":
		err = b.Restart()
	case "check_profile":
		var c TunnelCheck
		if c, err = b.CheckProfile(req.Text); err == nil {
			r.Check = &c
		}
	case "parse_links":
		var n Nodes
		if n, err = b.ParseLinks(req.Text); err == nil {
			r.Nodes = &n
		}
	case "parse_entries":
		var e Entries
		if e, err = b.ParseEntries(req.Text, req.Format, req.WantLines); err == nil {
			r.Entries = &e
		}
	case "canon_entries":
		r.Canon = b.CanonEntries(req.Lines)
	case "legacy_export":
		var l LegacyState
		if l, err = b.LegacyExport(); err == nil {
			r.Legacy = &l
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
