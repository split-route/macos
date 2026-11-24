//go:build darwin || linux

package main

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/split-route/core"
	"github.com/split-route/core/rules"
	"github.com/split-route/macos/daemon/internal/api"
)

// fakeEngine stands in for core.Engine: it records the configs it is given and
// reports whatever status the test sets.
type fakeEngine struct {
	mu        sync.Mutex
	cfgs      []core.Config // Start's config, then each Reload's
	startErr  error
	reloadErr error
	status    core.Status
	events    chan core.Event
	closed    bool
	answered  []string
	testLinks map[string]string        // tunnel ID → the address its test requested
	testErrs  map[string]error         // tunnel ID → the error its request fails with
	tests     map[string]time.Duration // tunnel ID → how long its request takes; absent: no answer
}

func (e *fakeEngine) Start() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.startErr
}
func (e *fakeEngine) Reload(c core.Config) (bool, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.cfgs = append(e.cfgs, c)
	return true, e.reloadErr
}
func (e *fakeEngine) Status() core.Status {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.status
}
func (e *fakeEngine) Test(ctx context.Context, id, link string) (time.Duration, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.testLinks == nil {
		e.testLinks = map[string]string{}
	}
	e.testLinks[id] = link
	if err, ok := e.testErrs[id]; ok {
		return 0, err
	}
	if d, ok := e.tests[id]; ok {
		return d, nil
	}
	<-ctx.Done() // no answer: the host's timeout ends it
	return 0, ctx.Err()
}

func (e *fakeEngine) Events() <-chan core.Event { return e.events }
func (e *fakeEngine) AnswerChallenge(id string, r core.ChallengeResponse) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.answered = append(e.answered, id+":"+r.Username)
	return nil
}
func (e *fakeEngine) Close() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.closed {
		e.closed = true
		close(e.events)
	}
	return nil
}
func (e *fakeEngine) set(s core.Status) {
	e.mu.Lock()
	e.status = s
	e.mu.Unlock()
}
func (e *fakeEngine) cfgCount() int {
	e.mu.Lock()
	defer e.mu.Unlock()
	return len(e.cfgs)
}
func (e *fakeEngine) isClosed() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.closed
}
func (e *fakeEngine) last() core.Config {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.cfgs[len(e.cfgs)-1]
}

type fakes struct {
	mu       sync.Mutex
	engines  []*fakeEngine
	startErr func(core.Config) error // decides, per config, whether Start fails
}

func (f *fakes) factory(c core.Config) (Engine, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	e := &fakeEngine{cfgs: []core.Config{c}, events: make(chan core.Event, 8)}
	if f.startErr != nil {
		e.startErr = f.startErr(c)
	}
	f.engines = append(f.engines, e)
	return e, nil
}
func (f *fakes) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.engines)
}
func (f *fakes) latest() *fakeEngine {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.engines[len(f.engines)-1]
}

// testHost is a host whose apply the test calls itself.
func testHost(t *testing.T) (*host, *fakes) {
	t.Helper()
	f := &fakes{}
	h := newHost("/data/work", f.factory)
	h.settle = time.Hour
	h.vpnOn, h.selected = true, "t1" // the VPN is on and t1 is selected, unless a test says otherwise
	t.Cleanup(h.close)
	return h, f
}

func opts(user, pass string) json.RawMessage {
	b, _ := json.Marshal(map[string]any{"type": "openvpn-client", "username": user, "password": pass})
	return b
}

func ids(c core.Config) []string {
	var out []string
	for _, t := range c.Tunnels {
		out = append(out, t.ID)
	}
	return out
}

func TestHostAppliesABurstOnce(t *testing.T) {
	f := &fakes{}
	h := newHost("/data/work", f.factory)
	h.settle = 40 * time.Millisecond
	h.vpnOn, h.selected = true, "t1"
	defer h.close()
	h.connect("t1", "Office", opts("a", "pa"))
	h.connect("t2", "Home", opts("b", "pb"))
	h.setLists([]hostList{{ID: "l-1", Name: "Ads", Action: rules.Block}})
	h.setLists([]hostList{{ID: "l-1", Name: "Ads", Action: rules.Direct}})
	time.Sleep(250 * time.Millisecond)
	if f.count() != 1 {
		t.Fatalf("%d engines for one burst of edits", f.count())
	}
	c := f.latest().last()
	if got := ids(c); len(got) != 2 || got[0] != "t1" || c.Default != "t1" || c.Lists[0].Action != rules.Direct {
		t.Errorf("config = tunnels %v default %q lists %+v", got, c.Default, c.Lists)
	}
	// Later changes reload the running engine instead of making another.
	h.connect("t3", "Lab", opts("c", "pc"))
	time.Sleep(250 * time.Millisecond)
	if f.count() != 1 || f.latest().cfgCount() != 2 || len(f.latest().last().Tunnels) != 3 {
		t.Errorf("engines %d, configs %d", f.count(), f.latest().cfgCount())
	}
}

// The selected tunnel is the engine's default, whatever order tunnels were loaded in.
func TestHostDefaultTunnelIsTheSelectedOne(t *testing.T) {
	h, f := testHost(t)
	h.connect("t2", "Home", opts("b", "pb"))
	h.connect("t1", "Office", opts("a", "pa"))
	h.applyNow()
	if c := f.latest().last(); c.Default != "t1" {
		t.Errorf("default = %q, want the selected tunnel (t1)", c.Default)
	}
	// Choosing another is a reload of the one engine with a new default, not a new engine.
	h.setSelected("t2")
	h.applyNow()
	if c := f.latest().last(); c.Default != "t2" || f.count() != 1 {
		t.Errorf("after selecting t2: default %q, engines %d", c.Default, f.count())
	}
}

// If the selected tunnel can't be loaded, the engine stops: traffic goes direct,
// never through whichever other tunnel happens to be loaded.
func TestHostStopsWhenTheSelectedTunnelIsNotLoaded(t *testing.T) {
	h, f := testHost(t)
	h.connect("t2", "Home", opts("b", "pb")) // t1 (selected) is waiting for credentials
	h.waitForCredentials("t1", "Office")
	h.applyNow()
	if f.count() != 0 {
		t.Fatal("an engine started with another tunnel as the default")
	}
	if v := h.snapshot("t1"); v.state != api.NeedsAuth {
		t.Errorf("selected tunnel = %+v, want it to show it needs sign-in", v)
	}
	// Credentials arrive: now it starts, with t1 the default.
	h.connect("t1", "Office", opts("a", "pa"))
	h.applyNow()
	if f.count() != 1 || f.latest().last().Default != "t1" {
		t.Errorf("engines %d", f.count())
	}
	// The selected tunnel fails: the engine stops instead of re-pointing.
	f.latest().set(core.Status{Tunnels: []core.TunnelStatus{{ID: "t1", State: core.StateFailed, Error: "auth failed"}, {ID: "t2", State: core.StateReady}}})
	h.snapshot("t1")
	h.applyNow()
	if !f.latest().isClosed() {
		t.Error("the engine kept running with a failed default tunnel")
	}
	if v := h.snapshot("t1"); v.state != api.Failed {
		t.Errorf("t1 = %+v", v)
	}
}

// Off drops every loaded tunnel and its credentials, and stops the engine.
func TestHostVPNOffStopsAndForgetsCredentials(t *testing.T) {
	h, f := testHost(t)
	h.connect("t1", "Office", opts("alice", "s3cr3t"))
	h.applyNow()
	h.setVPN(false)
	h.applyNow()
	if !f.latest().isClosed() {
		t.Error("the engine kept running with the VPN off")
	}
	h.mu.Lock()
	n := len(h.wanted)
	h.mu.Unlock()
	if n != 0 {
		t.Errorf("%d tunnels still wanted (their credentials with them)", n)
	}
}

// A tunnel the engine reports failed is final: dropped and its credentials
// cleared at once, so the next reload (any edit) can't retry them.
func TestHostAFailedTunnelIsNotRetried(t *testing.T) {
	h, f := testHost(t)
	h.selected = "t2" // a failed default would stop the engine (see TestHostStopsWhenTheSelectedTunnelIsNotLoaded)
	h.connect("t1", "Office", opts("a", "wrong"))
	h.connect("t2", "Home", opts("b", "pb"))
	h.applyNow()
	f.latest().set(core.Status{Running: true, Tunnels: []core.TunnelStatus{
		{ID: "t1", State: core.StateFailed, Error: "authentication failed"},
		{ID: "t2", State: core.StateConnected},
	}})
	if v := h.snapshot("t1"); v.state != api.Failed || !strings.Contains(v.err, "authentication") {
		t.Errorf("t1 = %+v", v)
	}
	h.mu.Lock()
	for _, w := range h.wanted {
		if w.id == "t1" {
			t.Error("the failed tunnel is still wanted")
		}
	}
	h.mu.Unlock()
	// An unrelated edit reloads: the failed tunnel's credentials are not in it.
	h.setLists([]hostList{{ID: "l-1", Name: "Ads", Action: rules.Block}})
	h.applyNow()
	if c := f.latest().last(); len(c.Tunnels) != 1 || c.Tunnels[0].ID != "t2" || strings.Contains(string(c.Tunnels[0].Options), "wrong") {
		t.Errorf("reload after a failure carried %v", ids(c))
	}
	if h.snapshot("t2").state != api.Connected {
		t.Error("the healthy tunnel was affected")
	}
}

// A start that names a tunnel (a bad CA, say) fails that tunnel only.
func TestHostOneBadTunnelDoesNotStopTheOthers(t *testing.T) {
	h, f := testHost(t)
	f.startErr = func(c core.Config) error {
		for _, tn := range c.Tunnels {
			if tn.ID == "bad" {
				return errors.New("sing-box: post-start endpoint: post-start endpoint/openvpn-client[t-bad]: load TLS configuration: invalid certificate authority bundle")
			}
		}
		return nil
	}
	h.selected = "good"
	h.connect("good", "Good", opts("a", "pa"))
	h.connect("bad", "Bad", opts("b", "pb"))
	h.applyNow()
	if f.count() != 2 || !f.engines[0].isClosed() {
		t.Fatalf("engines %d; the first, failed one must be closed", f.count())
	}
	if got := ids(f.latest().last()); len(got) != 1 || got[0] != "good" {
		t.Errorf("started with %v", got)
	}
	if v := h.snapshot("bad"); v.state != api.Failed || !strings.Contains(v.err, "certificate authority") {
		t.Errorf("bad = %+v", v)
	}
	running, _, _, errText := h.engineStatus()
	if !running || errText != "" {
		t.Errorf("running %v, error %q", running, errText)
	}
}

func TestHostAnEngineThatCannotStartFailsEveryTunnel(t *testing.T) {
	h, f := testHost(t)
	f.startErr = func(core.Config) error { return errors.New("sing-box: configure tun: operation not permitted") }
	h.connect("t1", "Office", opts("a", "pa"))
	h.connect("t2", "Home", opts("b", "pb"))
	h.applyNow()
	for _, id := range []string{"t1", "t2"} {
		if v := h.snapshot(id); v.state != api.Failed || !strings.Contains(v.err, "not permitted") {
			t.Errorf("%s = %+v", id, v)
		}
	}
	running, _, _, errText := h.engineStatus()
	if running || !strings.Contains(errText, "tun") || h.tunnelsRunning() {
		t.Errorf("running %v, error %q, wanted left %v", running, errText, h.tunnelsRunning())
	}
}

// A reload that fails leaves the engine stopped; it must not be reused.
func TestHostAFailedReloadDiscardsTheEngine(t *testing.T) {
	h, f := testHost(t)
	h.connect("t1", "Office", opts("a", "pa"))
	h.applyNow()
	e := f.latest()
	e.mu.Lock()
	e.reloadErr = errors.New("sing-box: boom")
	e.mu.Unlock()
	h.connect("t2", "Home", opts("b", "pb"))
	h.applyNow()
	if !f.engines[0].isClosed() {
		t.Error("the engine whose reload failed was kept")
	}
	if running, _, _, _ := h.engineStatus(); running {
		t.Error("reported running after a failed reload")
	}
}

func TestHostListsNamingAnUnconnectedTunnelAreBlocked(t *testing.T) {
	h, f := testHost(t)
	h.setLists([]hostList{
		{ID: "l-1", Name: "Social", Action: rules.Tunnel, Tunnel: "home"}, // by name, any case
		{ID: "l-2", Name: "Work", Action: rules.Tunnel},                   // the default
	})
	h.connect("t1", "Office", opts("a", "pa"))
	h.applyNow()
	c := f.latest().last()
	if c.Lists[0].Action != rules.Block || c.Lists[0].Tunnel != "" || c.Lists[1].Action != rules.Tunnel || c.Lists[1].Tunnel != "" {
		t.Errorf("lists = %+v", c.Lists)
	}
	if _, _, warns, _ := h.engineStatus(); len(warns) != 1 || !strings.Contains(warns[0], "Social") {
		t.Errorf("warnings = %v", warns)
	}
	h.connect("t2", "Home", opts("b", "pb"))
	h.applyNow()
	c = f.latest().last()
	if c.Lists[0].Action != rules.Tunnel || c.Lists[0].Tunnel != "t2" {
		t.Errorf("once Home is connected: %+v", c.Lists[0])
	}
	if _, _, warns, _ := h.engineStatus(); len(warns) != 0 {
		t.Errorf("warnings = %v", warns)
	}
}

func TestHostFinalRouteNamingAnUnconnectedTunnelIsBlocked(t *testing.T) {
	h, f := testHost(t)
	h.setFinal(api.FinalSpec{Action: rules.Tunnel, Tunnel: "home"})
	h.connect("t1", "Office", opts("a", "pa"))
	h.applyNow()
	if got := f.latest().last().Final; got.Action != rules.Block || got.Tunnel != "" {
		t.Errorf("final = %+v", got)
	}
	if _, _, warns, _ := h.engineStatus(); len(warns) != 1 || !strings.Contains(warns[0], "default route") {
		t.Errorf("warnings = %v", warns)
	}
	h.connect("t2", "Home", opts("b", "pb"))
	h.applyNow()
	if got := f.latest().last().Final; got.Action != rules.Tunnel || got.Tunnel != "t2" {
		t.Errorf("once Home is connected: %+v", got)
	}
}

func TestHostStopsWhenTheLastTunnelGoes(t *testing.T) {
	h, f := testHost(t)
	h.connect("t1", "Office", opts("a", "pa"))
	h.applyNow()
	h.disconnect("t1")
	h.applyNow()
	if !f.latest().isClosed() || h.snapshot("t1").state != api.Disconnected {
		t.Error("the engine kept running with no tunnel wanted")
	}
	if running, connected, _, _ := h.engineStatus(); running || connected != 0 {
		t.Errorf("running %v connected %d", running, connected)
	}
}

func TestHostReportsAConnectedTunnel(t *testing.T) {
	h, f := testHost(t)
	h.connect("t1", "Office", opts("a", "pa"))
	h.applyNow()
	f.latest().set(core.Status{Running: true, Tunnels: []core.TunnelStatus{{ID: "t1", State: core.StateConnected,
		Info: &core.TunnelInfo{Server: "203.0.113.5:1194", IPv4: []string{"10.8.0.2/24"}, Since: time.Unix(1700000000, 0)}}}})
	v := h.snapshot("t1")
	if v.state != api.Connected || v.local != "10.8.0.2" || v.remote != "203.0.113.5" || v.since.IsZero() {
		t.Errorf("view = %+v", v)
	}
	// Dropping to connecting after a connect is a reconnect.
	f.latest().set(core.Status{Running: true, Tunnels: []core.TunnelStatus{{ID: "t1", State: core.StateConnecting}}})
	if v := h.snapshot("t1"); v.state != api.Reconnecting {
		t.Errorf("state = %s", v.state)
	}
	// A challenge shows as needing credentials; the answer reaches the engine.
	f.latest().set(core.Status{Running: true, Tunnels: []core.TunnelStatus{{ID: "t1", State: core.StateNeedsAuth}}})
	if v := h.snapshot("t1"); v.state != api.NeedsAuth || v.need != "auth" {
		t.Errorf("view = %+v", v)
	}
	if err := h.answer("t1", core.ChallengeResponse{Username: "u"}); err != nil || f.latest().answered[0] != "t1:u" {
		t.Errorf("answer: %v %v", err, f.latest().answered)
	}
}

// Credentials are in the wanted set and in the engine's config, nowhere else.
func TestHostKeepsCredentialsToItself(t *testing.T) {
	h, f := testHost(t)
	h.connect("t1", "Office", opts("alice", "s3cr3t-pass"))
	h.applyNow()
	f.latest().set(core.Status{Running: true, Tunnels: []core.TunnelStatus{{ID: "t1", State: core.StateConnected}}})
	_, _, warns, errText := h.engineStatus()
	out, _ := json.Marshal([]any{h.snapshot("t1"), warns, errText, h.logLines()})
	if strings.Contains(string(out), "s3cr3t-pass") || strings.Contains(string(out), "alice") {
		t.Errorf("credentials in what the API shows: %s", out)
	}
	h.disconnect("t1")
	h.mu.Lock()
	n := len(h.wanted)
	h.mu.Unlock()
	if n != 0 {
		t.Error("credentials kept after disconnect")
	}
}

func TestHostDoesNothingAfterClose(t *testing.T) {
	f := &fakes{}
	h := newHost("/data/work", f.factory)
	h.settle = 10 * time.Millisecond
	h.connect("t1", "Office", opts("a", "pa"))
	h.close()
	time.Sleep(100 * time.Millisecond)
	h.applyNow()
	if f.count() != 0 {
		t.Errorf("%d engines started after close", f.count())
	}
}

func TestHostWaitingForCredentials(t *testing.T) {
	h, f := testHost(t)
	h.waitForCredentials("t1", "Office")
	if v := h.snapshot("t1"); v.state != api.NeedsAuth || v.need != "auth" || !h.isWaiting("t1") {
		t.Errorf("view = %+v", v)
	}
	if h.tunnelsRunning() {
		t.Error("a tunnel waiting for credentials counts as running")
	}
	h.connect("t1", "Office", opts("a", "pa"))
	h.applyNow()
	if h.isWaiting("t1") || f.count() != 1 {
		t.Error("credentials didn't start the tunnel")
	}
}
