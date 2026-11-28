//go:build darwin || linux

// Package api is the control socket: the app's way to the network layer. The
// daemon keeps no settings. The app owns them and sends the desired state; the
// daemon runs it. One JSON request and one JSON response per connection.
//
//	{"cmd": "status"}                                       → status
//	{"cmd": "apply", "apply": {...}}                        the desired state (see Snapshot)
//	{"cmd": "answer", "id": "t3", "username": "…", "password": "…"}   answers a running tunnel's challenge
//	{"cmd": "stats", "since_bucket": 5900000}  → the traffic log: bytes the engine carried in 5-minute buckets (direct and through a server) and the fastest second, from `since_bucket` on
//	{"cmd": "server_country", "ids": ["t1"]}  → which country each tunnel's server is in (by the address its name resolves to)
//	{"cmd": "test", "ids": ["t1"], "method": "connect|tcp|icmp", "url": "https://…", "timeout_ms": 5000}  → tests (a request through each loaded tunnel, or a connect or ping to its server)
//	{"cmd": "route_test", "text": "example.com"}              → route (where a connection to that name or address would go)
//	{"cmd": "exit_ip"}                                      → exit (the address the internet sees through the selected server)
//	{"cmd": "logs"}                                         → logs (the engine's last lines)
//	{"cmd": "restart"}                                      the service exits; launchd starts the updated binary
//
// Stateless helpers (the parsers live in the core, so the app asks):
//
//	{"cmd": "check_profile", "text": "<.ovpn>"}             → check
//	{"cmd": "parse_links", "text": "<links or a body>"}     → nodes
//	{"cmd": "check_rules", "rules": {...}}                   → ok, or the first value that is wrong
//	{"cmd": "check_ruleset", "data": "<base64 .srs or JSON source>"}  → ruleset (the binary rule-set the engine will read, and its rule count)
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

	"github.com/split-route/core"
)

// Backend is what the socket needs from the daemon.
type Backend interface {
	Status() Status
	Apply(Snapshot) error
	Answer(id string, c Credentials) error
	Logs() []string
	Restart() error
	// Test measures each tunnel (by ID): one request through it, or a TCP connect or ping to its server. The options are
	// validated before the call (https only for a request's address).
	Test(ids []string, o TestOptions) map[string]TestResult
	CheckProfile(text string) (TunnelCheck, error)
	ParseLinks(text string) (Nodes, error)
	ParseEntries(text, format string, wantLines bool) (Entries, error)
	CheckRuleSet(data []byte) (RuleSetInfo, error)
	CheckRules(spec core.RuleSpec) error
	CanonEntries(lines []string) []Canon
	LegacyExport() (LegacyState, error)
	// RouteTest says where a connection to a name or address would go, by the rules the engine has now.
	RouteTest(query string) (RouteResult, error)
	// ExitIP asks a fixed address through the selected server for the address the internet sees. The address is the
	// service's own, never the socket's.
	ExitIP() (ExitIP, error)
	// ServerCountries says which country each tunnel's server is in (by the address its name resolves to, against the
	// embedded database). An ID is absent when the server's name couldn't be looked up, "XC" when it is behind
	// Cloudflare (no country), and "" when it resolved to something that says nothing (a private address, an unknown one). Never more than MaxLocateIDs ids.
	ServerCountries(ids []string) map[string]string
	// Traffic is the log of what the engine carried, in 5-minute buckets from `sinceBucket` on; false while recording is off (the
	// snapshot's stats flag). The log is in memory only and starts empty with the service.
	Traffic(sinceBucket int64) (Traffic, bool)
}

type Request struct {
	Cmd   string    `json:"cmd"`
	Apply *Snapshot `json:"apply,omitempty"`

	ID       string `json:"id,omitempty"`
	Username string `json:"username,omitempty"`
	Password string `json:"password,omitempty"`

	Text string `json:"text,omitempty"`
	// Data is a rule-set (a sing-box .srs, or its JSON source) for check_ruleset; JSON carries it as base64.
	// Rules is a rule built from fields, for check_rules.
	Rules     *core.RuleSpec `json:"rules,omitempty"`
	Data      []byte         `json:"data,omitempty"`
	Format    string         `json:"format,omitempty"`
	WantLines bool           `json:"want_lines,omitempty"`
	Lines     []string       `json:"lines,omitempty"`
	IDs       []string       `json:"ids,omitempty"`
	// SinceBucket is the first bucket stats should return.
	SinceBucket int64 `json:"since_bucket,omitempty"`
	// Method, URL and TimeoutMS are the options of "test" (see TestOptions).
	Method    string `json:"method,omitempty"`
	URL       string `json:"url,omitempty"`
	TimeoutMS int    `json:"timeout_ms,omitempty"`
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
	RuleSet *RuleSetInfo          `json:"ruleset,omitempty"`
	Canon   []Canon               `json:"canon,omitempty"`
	Legacy  *LegacyState          `json:"legacy,omitempty"`
	Tests   map[string]TestResult `json:"tests,omitempty"`
	Route   *RouteResult          `json:"route,omitempty"`
	Exit    *ExitIP               `json:"exit,omitempty"`
	// Countries answers server_country: tunnel ID to two-letter code (see Backend.ServerCountries).
	Countries map[string]string `json:"countries,omitempty"`
	// Traffic answers stats; absent while the engine is stopped or not counting.
	Traffic *Traffic `json:"traffic,omitempty"`
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
		o := TestOptions{Method: req.Method, URL: req.URL, TimeoutMS: req.TimeoutMS}
		if err = o.Validate(); err == nil {
			r.Tests = b.Test(req.IDs, o)
		}
	case "server_country":
		if len(req.IDs) > MaxLocateIDs {
			return Response{Error: "server_country takes at most " + strconv.Itoa(MaxLocateIDs) + " ids"}
		}
		r.Countries = b.ServerCountries(req.IDs)
	case "stats":
		if t, ok := b.Traffic(req.SinceBucket); ok {
			r.Traffic = &t
		}
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
	case "check_rules":
		if req.Rules == nil {
			return Response{Error: "check_rules needs the rules"}
		}
		err = b.CheckRules(*req.Rules)
	case "check_ruleset":
		var i RuleSetInfo
		if i, err = b.CheckRuleSet(req.Data); err == nil {
			r.RuleSet = &i
		}
	case "canon_entries":
		r.Canon = b.CanonEntries(req.Lines)
	case "route_test":
		var rr RouteResult
		if rr, err = b.RouteTest(req.Text); err == nil {
			r.Route = &rr
		}
	case "exit_ip":
		var e ExitIP
		if e, err = b.ExitIP(); err == nil {
			r.Exit = &e
		}
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
