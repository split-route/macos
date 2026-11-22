//go:build darwin || linux

package main

import (
	"encoding/json"
	"fmt"
	"net"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/split-route/core"
	"github.com/split-route/core/rules"
	"github.com/split-route/macos/daemon/internal/api"
)

// Engine is the part of core.Engine the host uses. It is an interface so the
// host's rules (below) are tested without root or sing-box.
type Engine interface {
	Start() error
	Reload(core.Config) (restarted bool, err error)
	Status() core.Status
	Events() <-chan core.Event
	AnswerChallenge(tunnelID string, r core.ChallengeResponse) error
	Close() error // stops the engine too
}

type engineFactory func(core.Config) (Engine, error)

func coreEngine(c core.Config) (Engine, error) { return core.New(c) }

// hostList is a list as the host needs it: the app resolved its ID, and Tunnel
// is the tunnel's name (empty: the default tunnel).
type hostList struct {
	ID, Name string
	Action   rules.Action
	Tunnel   string
}

// wantedTunnel is a tunnel the user asked to have connected. Its options hold
// the credentials; they live here, in memory, for as long as the tunnel is
// wanted: every reload rebuilds all the options and nothing else holds them.
type wantedTunnel struct {
	id, name string
	options  json.RawMessage
}

// view is what the API shows for a tunnel.
type view struct {
	state         api.State
	err           string
	need          string
	local, remote string
	since         time.Time
	wasConnected  bool
}

// host runs the core engine for the tunnels the user wants. Rules it keeps,
// each with a test:
//
//   - Credentials stay in memory while a tunnel is wanted.
//   - A tunnel that failed is dropped from the wanted set at once and its
//     credentials are cleared, so no later reload retries them (retrying bad
//     credentials locks accounts). The user connects again to try.
//   - One bad tunnel (a start that names it) is failed and dropped; the others start.
//   - Changes are applied after a short settle time, so a burst of edits is one
//     restart, not one reconnect of every tunnel per edit.
//   - The API answers from the engine's Status; events only prompt a re-read.
type host struct {
	newEngine engineFactory
	workDir   string
	settle    time.Duration
	inbound   core.Inbound // zero: the tun; a test runs the proxy (a tun needs root)

	mu      sync.Mutex
	wanted  []*wantedTunnel // connect order: the first is the default tunnel
	waiting map[string]string
	views   map[string]*view
	lists   []hostList
	eng     Engine
	timer   *time.Timer
	logs    []string
	warns   []string
	err     string
	closed  bool
}

const (
	hostSettle = 3 * time.Second
	logLines   = 500
)

func newHost(workDir string, f engineFactory) *host {
	return &host{newEngine: f, workDir: workDir, settle: hostSettle, waiting: map[string]string{}, views: map[string]*view{}}
}

// tunnelID is the core ID for a stored tunnel.
func tunnelID(dbID int64) string { return fmt.Sprintf("t%d", dbID) }

func (h *host) viewLocked(id string) *view {
	v := h.views[id]
	if v == nil {
		v = &view{state: api.Disconnected}
		h.views[id] = v
	}
	return v
}

func (h *host) wantedIndex(id string) int {
	return slices.IndexFunc(h.wanted, func(w *wantedTunnel) bool { return w.id == id })
}

// connect asks for a tunnel: it joins the wanted set (the first one wanted is
// the default tunnel) and the change is applied after the settle time.
func (h *host) connect(id, name string, options json.RawMessage) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.waiting, id)
	v := h.viewLocked(id)
	*v = view{state: api.Connecting}
	if i := h.wantedIndex(id); i >= 0 {
		h.wanted[i].options, h.wanted[i].name = options, name
	} else {
		h.wanted = append(h.wanted, &wantedTunnel{id: id, name: name, options: options})
	}
	h.scheduleLocked()
}

// waitForCredentials marks a tunnel as needing credentials from the app.
func (h *host) waitForCredentials(id, name string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.waiting[id] = name
	*h.viewLocked(id) = view{state: api.NeedsAuth, need: "auth"}
}

func (h *host) isWaiting(id string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	_, ok := h.waiting[id]
	return ok
}

// disconnect stops wanting a tunnel and drops its credentials.
func (h *host) disconnect(id string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.waiting, id)
	if i := h.wantedIndex(id); i >= 0 {
		h.wanted = slices.Delete(h.wanted, i, i+1)
		h.scheduleLocked()
	}
	*h.viewLocked(id) = view{state: api.Disconnected}
}

// forget drops everything about a tunnel that was removed.
func (h *host) forget(id string) {
	h.disconnect(id)
	h.mu.Lock()
	delete(h.views, id)
	h.mu.Unlock()
}

// rename keeps the name lists use in step with a renamed tunnel.
func (h *host) rename(id, name string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if i := h.wantedIndex(id); i >= 0 {
		h.wanted[i].name = name
		h.scheduleLocked()
	}
}

// setLists replaces the lists the engine applies.
func (h *host) setLists(ls []hostList) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.lists = slices.Clone(ls)
	h.scheduleLocked()
}

// answer gives a running tunnel the credentials it is waiting for (a challenge).
func (h *host) answer(id string, r core.ChallengeResponse) error {
	h.mu.Lock()
	eng := h.eng
	h.mu.Unlock()
	if eng == nil {
		return fmt.Errorf("the tunnel isn't running")
	}
	return eng.AnswerChallenge(id, r)
}

func (h *host) scheduleLocked() {
	if h.closed {
		return
	}
	if h.timer != nil {
		h.timer.Stop()
	}
	h.timer = time.AfterFunc(h.settle, h.applyNow)
}

// applyNow applies the wanted tunnels and lists to the engine.
func (h *host) applyNow() {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed {
		return
	}
	h.applyLocked()
}

var badTunnelRE = regexp.MustCompile(`\[t-([a-z0-9_-]+)\]`)

func (h *host) applyLocked() {
	// Each failed pass drops one tunnel, so this ends.
	for attempt := 0; attempt <= len(h.wanted)+1; attempt++ {
		if len(h.wanted) == 0 {
			h.stopLocked()
			h.err = ""
			return
		}
		err := h.runLocked(h.buildLocked())
		if err == nil {
			h.err = ""
			return
		}
		h.discardLocked() // a failed (re)start leaves the engine stopped
		if m := badTunnelRE.FindStringSubmatch(err.Error()); m != nil {
			if i := h.wantedIndex(m[1]); i >= 0 {
				h.failLocked(m[1], err.Error())
				continue
			}
		}
		for _, w := range slices.Clone(h.wanted) {
			h.failLocked(w.id, err.Error())
		}
		h.err = err.Error()
		return
	}
}

func (h *host) runLocked(cfg core.Config) error {
	if h.eng == nil {
		e, err := h.newEngine(cfg)
		if err != nil {
			return err
		}
		if err := e.Start(); err != nil {
			e.Close()
			return err
		}
		h.eng = e
		go h.pump(e)
		return nil
	}
	_, err := h.eng.Reload(cfg)
	return err
}

// failLocked marks a tunnel failed and drops it, with its credentials, from the wanted set.
func (h *host) failLocked(id, msg string) {
	if i := h.wantedIndex(id); i >= 0 {
		h.wanted[i].options = nil
		h.wanted = slices.Delete(h.wanted, i, i+1)
	}
	*h.viewLocked(id) = view{state: api.Failed, err: msg}
}

func (h *host) discardLocked() {
	if h.eng != nil {
		h.eng.Close()
		h.eng = nil
	}
}

func (h *host) stopLocked() {
	h.discardLocked()
	for id, v := range h.views {
		if v.state != api.Failed && v.state != api.NeedsAuth {
			*h.views[id] = view{state: api.Disconnected}
		}
	}
}

func (h *host) buildLocked() core.Config {
	cfg := core.Config{WorkDir: h.workDir, Default: h.wanted[0].id, Inbound: h.inbound, Log: core.Log{Level: "info"}}
	byName := map[string]string{}
	for _, w := range h.wanted {
		cfg.Tunnels = append(cfg.Tunnels, core.Tunnel{ID: w.id, Name: w.name, Protocol: "openvpn", Options: w.options})
		byName[strings.ToLower(w.name)] = w.id
	}
	h.warns = nil
	for _, l := range h.lists {
		cl := core.List{ID: l.ID, Name: l.Name, Action: l.Action}
		if l.Action == rules.Tunnel && l.Tunnel != "" {
			if id, ok := byName[strings.ToLower(l.Tunnel)]; ok {
				cl.Tunnel = id
			} else {
				// The list asked for a tunnel that isn't connected: block it, never use another path.
				cl.Action = rules.Block
				h.warns = append(h.warns, fmt.Sprintf("%s: the tunnel %q isn't connected, so this list's traffic is blocked", l.Name, l.Tunnel))
			}
		}
		cfg.Lists = append(cfg.Lists, cl)
	}
	return cfg
}

// pump re-reads the engine when it reports something, and keeps its log lines.
func (h *host) pump(e Engine) {
	for ev := range e.Events() {
		switch ev.Kind {
		case core.EventLog:
			h.mu.Lock()
			h.logs = append(h.logs, ev.Message)
			if len(h.logs) > logLines {
				h.logs = append(h.logs[:0], h.logs[len(h.logs)-logLines:]...)
			}
			h.mu.Unlock()
		case core.EventTunnel:
			h.sync(e)
		}
	}
}

// sync reads the engine's status into the views. A tunnel the engine reports
// failed is final: it is dropped from the wanted set now, so no later reload
// brings its credentials back.
func (h *host) sync(e Engine) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.eng != e {
		return
	}
	h.syncLocked()
}

func (h *host) syncLocked() {
	if h.eng == nil {
		return
	}
	for _, ts := range h.eng.Status().Tunnels {
		if h.wantedIndex(ts.ID) < 0 {
			continue
		}
		v := h.viewLocked(ts.ID)
		switch ts.State {
		case core.StateConnected, core.StateReady:
			v.state, v.err, v.need, v.wasConnected = api.Connected, "", "", true
			if ts.Info != nil {
				v.local = ""
				if len(ts.Info.IPv4) > 0 {
					v.local, _, _ = strings.Cut(ts.Info.IPv4[0], "/")
				}
				v.remote, _, _ = net.SplitHostPort(ts.Info.Server)
				if !ts.Info.Since.IsZero() {
					v.since = ts.Info.Since
				}
			}
		case core.StateNeedsAuth:
			v.state, v.need = api.NeedsAuth, "auth"
		case core.StateFailed:
			h.failLocked(ts.ID, ts.Error)
		case core.StateConnecting:
			v.state, v.need = api.Connecting, ""
			if v.wasConnected {
				v.state = api.Reconnecting
			}
		}
	}
}

// snapshot is a tunnel's state for the API, read from the engine first.
func (h *host) snapshot(id string) view {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.syncLocked()
	if v := h.views[id]; v != nil {
		return *v
	}
	return view{state: api.Disconnected}
}

// engineStatus is what the status page needs.
func (h *host) engineStatus() (running bool, connected int, warnings []string, err string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.syncLocked()
	for _, w := range h.wanted {
		if v := h.views[w.id]; v != nil && v.state == api.Connected {
			connected++
		}
	}
	return h.eng != nil, connected, slices.Clone(h.warns), h.err
}

// tunnelsRunning reports whether any tunnel is wanted.
func (h *host) tunnelsRunning() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.wanted) > 0
}

func (h *host) logLines() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return slices.Clone(h.logs)
}

// close stops the engine (its tun goes away) and applies nothing afterwards.
func (h *host) close() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.closed = true
	if h.timer != nil {
		h.timer.Stop()
	}
	h.discardLocked()
}
