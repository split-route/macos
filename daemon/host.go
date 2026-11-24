//go:build darwin || linux

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"net"
	"os"
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
	Test(ctx context.Context, tunnelID, link string) (time.Duration, error)
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
	protocol string // the core's protocol name
	options  json.RawMessage
	sig      string // fingerprint of what the options were built from; Apply skips a tunnel that still matches
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
//     restart, not one reconnect of every tunnel per edit. A restart of proxy
//     tunnels takes a fraction of a second, so the time is short.
//   - The engine runs only while the VPN is on and the selected tunnel is loaded.
//     The selected tunnel is the engine's default: it carries all traffic no list
//     names. If it can't be loaded (it waits for credentials, or failed) the
//     engine stops and traffic goes direct: never through another tunnel.
//   - The API answers from the engine's Status; events only prompt a re-read.
type host struct {
	newEngine   engineFactory
	workDir     string
	settle      time.Duration
	testTimeout time.Duration
	inbound     core.Inbound // zero: the tun; a test runs the proxy (a tun needs root)

	mu        sync.Mutex
	vpnOn     bool
	selected  string          // the core ID of the default tunnel; "" for none
	blockQUIC bool            // refuse QUIC no list matched
	final     api.FinalSpec   // where traffic no list matches goes; the tunnel is named, like a list's
	bootstrap string          // core.DNS.Bootstrap: how proxy tunnels' servers are found by name
	wanted    []*wantedTunnel // the tunnels the engine loads
	waiting   map[string]string
	views     map[string]*view
	lists     []hostList
	eng       Engine
	timer     *time.Timer
	logs      []string
	warns     []string
	err       string
	closed    bool
}

// defaultBootstrap is the DoH server that finds proxy tunnels' servers when the app chose none. The core's own
// default is 1.1.1.1; this app's users have it reset on some networks.
const defaultBootstrap = "8.8.8.8"

const (
	hostSettle = 250 * time.Millisecond
	logLines   = 500
)

func newHost(workDir string, f engineFactory) *host {
	return &host{newEngine: f, workDir: workDir, settle: hostSettle, testTimeout: hostTestTimeout, waiting: map[string]string{}, views: map[string]*view{}}
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

// setVPN turns the VPN on or off. Off drops every wanted tunnel and its
// credentials; the engine stops.
func (h *host) setVPN(on bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.vpnOn == on {
		return
	}
	h.vpnOn = on
	if !on {
		for _, w := range h.wanted {
			w.options = nil
		}
		h.wanted = nil
		h.waiting = map[string]string{}
		for id, v := range h.views {
			if v.state != api.Failed {
				*h.views[id] = view{state: api.Disconnected}
			}
		}
	}
	h.scheduleLocked()
}

// setBootstrap chooses how proxy tunnels' server names are resolved; a change restarts the engine.
func (h *host) setBootstrap(b string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.bootstrap == b {
		return
	}
	h.bootstrap = b
	h.scheduleLocked()
}

// setBlockQUIC turns the QUIC rule on or off; a change restarts the engine.
func (h *host) setBlockQUIC(on bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.blockQUIC == on {
		return
	}
	h.blockQUIC = on
	h.scheduleLocked()
}

// setFinal chooses where traffic no list matches goes; a change restarts the engine.
func (h *host) setFinal(f api.FinalSpec) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.final == f {
		return
	}
	h.final = f
	h.scheduleLocked()
}

// setSelected chooses the default tunnel; "" for none.
func (h *host) setSelected(id string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.selected == id {
		return
	}
	h.selected = id
	h.scheduleLocked()
}

func (h *host) isWanted(id string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.wantedIndex(id) >= 0
}

// markFailed shows a tunnel as failed with msg, outside the wanted set.
func (h *host) markFailed(id, msg string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.failLocked(id, msg)
}

// isFailed reports whether a tunnel failed and stays out until the user acts.
func (h *host) isFailed(id string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	v := h.views[id]
	return v != nil && v.state == api.Failed
}

// retry forgets that a tunnel failed, so it may be loaded again: the user asked.
// An empty id forgets every failure.
func (h *host) retry(id string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for vid, v := range h.views {
		if (id == "" || id == vid) && v.state == api.Failed {
			*h.views[vid] = view{state: api.Disconnected}
		}
	}
}

// connect asks for a tunnel: it joins the wanted set and the change is applied
// after the settle time.
func (h *host) connect(id, name string, options json.RawMessage) {
	h.connectProtocol(id, name, "openvpn", options)
}

// connectProtocol asks for a tunnel of any protocol the core runs.
func (h *host) connectProtocol(id, name, protocol string, options json.RawMessage) {
	h.connectSig(id, name, protocol, options, "")
}

// connectSig is connectProtocol for a tunnel Apply built from a fingerprinted source.
func (h *host) connectSig(id, name, protocol string, options json.RawMessage, sig string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.waiting, id)
	v := h.viewLocked(id)
	*v = view{state: api.Connecting}
	if i := h.wantedIndex(id); i >= 0 {
		h.wanted[i].options, h.wanted[i].name, h.wanted[i].protocol, h.wanted[i].sig = options, name, protocol, sig
	} else {
		h.wanted = append(h.wanted, &wantedTunnel{id: id, name: name, protocol: protocol, options: options, sig: sig})
	}
	h.scheduleLocked()
}

// loaded reports whether a tunnel is wanted, with the fingerprint and name it was loaded with.
func (h *host) loaded(id string) (sig, name string, ok bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if i := h.wantedIndex(id); i >= 0 {
		return h.wanted[i].sig, h.wanted[i].name, true
	}
	return "", "", false
}

// known is every tunnel the host holds anything for.
func (h *host) known() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	seen := map[string]bool{}
	for _, w := range h.wanted {
		seen[w.id] = true
	}
	for id := range h.waiting {
		seen[id] = true
	}
	for id := range h.views {
		seen[id] = true
	}
	return slices.Collect(maps.Keys(seen))
}

// tunnelStatuses is every tunnel's state for the API, read from the engine first.
func (h *host) tunnelStatuses() map[string]api.TunnelStatus {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.syncLocked()
	out := make(map[string]api.TunnelStatus, len(h.views))
	for id, v := range h.views {
		out[id] = api.TunnelStatus{State: v.state, Error: v.err, Need: v.need, LocalIP: v.local, RemoteIP: v.remote, Since: v.since}
	}
	return out
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
		if !h.vpnOn || len(h.wanted) == 0 || h.wantedIndex(h.selected) < 0 {
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
	bootstrap := h.bootstrap
	if bootstrap == "" {
		bootstrap = defaultBootstrap
	}
	cfg := core.Config{WorkDir: h.workDir, Default: h.selected, BlockQUIC: h.blockQUIC, Inbound: h.inbound, DNS: core.DNS{Bootstrap: bootstrap}, Log: core.Log{Level: "info"}}
	byName := map[string]string{}
	for _, w := range h.wanted {
		cfg.Tunnels = append(cfg.Tunnels, core.Tunnel{ID: w.id, Name: w.name, Protocol: w.protocol, Options: w.options})
		byName[strings.ToLower(w.name)] = w.id
	}
	h.warns = nil
	cfg.Final = core.Final{Action: h.final.Action}
	if h.final.Action == rules.Tunnel && h.final.Tunnel != "" {
		if id, ok := byName[strings.ToLower(h.final.Tunnel)]; ok {
			cfg.Final.Tunnel = id
		} else {
			// Like a list: a tunnel that isn't connected never hands its traffic to another path.
			cfg.Final = core.Final{Action: rules.Block}
			h.warns = append(h.warns, fmt.Sprintf("default route: the tunnel %q isn't connected, so that traffic is blocked", h.final.Tunnel))
		}
	}
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
		case core.StateReady:
			// No session to prove the server answers: say Ready, not Connected. Only the
			// selected tunnel is shown as in use; the others are loaded but idle.
			v.err, v.need = "", ""
			if ts.ID == h.selected {
				v.state = api.Ready
			} else {
				v.state = api.Disconnected
			}
		case core.StateConnected:
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
	// What carries traffic: OpenVPN sessions that are up, and the selected tunnel if it is ready.
	for _, w := range h.wanted {
		if v := h.views[w.id]; v != nil && (v.state == api.Connected || v.state == api.Ready) {
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

const (
	testURL = "http://cp.cloudflare.com/generate_204"
	// An OpenVPN endpoint resolves a hostname with the engine's own DNS, which goes through the selected tunnel: a test
	// by name would depend on which tunnel is selected. An address needs no lookup.
	testURLOpenVPN  = "http://1.1.1.1/generate_204"
	hostTestTimeout = 5 * time.Second
	testParallelism = 8
)

// test measures the tunnels the engine has loaded, a few at a time, OpenVPN included
// (its endpoint dials like an outbound). A tunnel that isn't loaded says so: an OpenVPN
// tunnel no list names is never started just to be tested, it would open a session.
func (h *host) test(ids []string) map[string]api.TestResult {
	h.mu.Lock()
	eng := h.eng
	loaded := map[string]string{} // tunnel ID → the address to request
	for _, w := range h.wanted {
		loaded[w.id] = testURL
		if w.protocol == "openvpn" {
			loaded[w.id] = testURLOpenVPN
		}
	}
	h.mu.Unlock()
	out := make(map[string]api.TestResult, len(ids))
	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, testParallelism)
	for _, id := range ids {
		link, ok := loaded[id]
		if eng == nil || !ok {
			why := "Not loaded"
			if eng == nil {
				why = "The VPN is off"
			}
			mu.Lock()
			out[id] = api.TestResult{Error: why}
			mu.Unlock()
			continue
		}
		wg.Add(1)
		sem <- struct{}{}
		go func() {
			defer func() { <-sem; wg.Done() }()
			ctx, cancel := context.WithTimeout(context.Background(), h.testTimeout)
			defer cancel()
			d, err := eng.Test(ctx, id, link)
			r := api.TestResult{MS: int(d.Milliseconds())}
			if err != nil {
				r = testFailure(ctx, err)
			}
			mu.Lock()
			out[id] = r
			mu.Unlock()
		}()
	}
	wg.Wait()
	return out
}

// testFailure is "Timeout" for a request that ran out of time, and "Failed" with the engine's own message
// (refused, reset, a TLS error...) for anything else.
func testFailure(ctx context.Context, err error) api.TestResult {
	var ne net.Error
	msg := strings.ToLower(err.Error())
	// sing-box wraps its errors in ways that don't always unwrap, so the text is the last resort.
	if ctx.Err() != nil || errors.Is(err, context.DeadlineExceeded) || errors.Is(err, os.ErrDeadlineExceeded) ||
		(errors.As(err, &ne) && ne.Timeout()) || strings.Contains(msg, "timeout") || strings.Contains(msg, "deadline exceeded") {
		return api.TestResult{Error: "Timeout"}
	}
	return api.TestResult{Error: "Failed", Detail: err.Error()}
}
