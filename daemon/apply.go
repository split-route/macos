//go:build darwin || linux

// Apply: the app's desired state becomes what the host runs. This file decides
// which tunnels the engine loads and builds their options; the host (host.go)
// runs them. Nothing here is stored: a restarted daemon knows nothing until the
// app sends the snapshot again (it does, on a new boot ID).

package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"strings"
	"time"

	"github.com/split-route/core"
	"github.com/split-route/core/importers/openvpn"
	"github.com/split-route/core/lists"
	"github.com/split-route/core/rules"
	"github.com/split-route/core/ruleset"
	"github.com/split-route/macos/daemon/internal/api"
)

// engineCheck is why no tunnel can run here, or "". The core's protocols come
// with the sing-box build tags; an app built without them says so.
func engineCheck() string {
	if len(core.Protocols()) == 0 {
		return "this build has no tunnel protocols"
	}
	return ""
}

// desiredTunnels is which tunnels the engine loads while the VPN is on: every
// tunnel with no session of its own (cheap, and then choosing between them needs
// no restart), the selected tunnel, and each OpenVPN tunnel that a list names (a
// loaded OpenVPN tunnel opens a real session, so no others), unless all is set (a connectivity test).
func desiredTunnels(ts []api.TunnelSpec, selected string, ls []api.ListSpec, final api.FinalSpec, all bool) map[string]bool {
	named := map[string]bool{}
	if final.Tunnel != "" {
		named[strings.ToLower(final.Tunnel)] = true
	}
	for _, l := range ls {
		if l.Tunnel != "" {
			named[strings.ToLower(l.Tunnel)] = true
		}
	}
	want := map[string]bool{}
	for _, t := range ts {
		if all || t.Protocol != api.ProtocolOpenVPN || t.ID == selected || named[strings.ToLower(t.Name)] {
			want[t.ID] = true
		}
	}
	return want
}

// bootstrapFor is the resolver the engine gets: what the app chose, or, when it chose none ("automatic"), the first public
// resolver that answers from this network. The choice is made as the connection comes up and kept until it goes down.
func (a *app) bootstrapFor(s api.Snapshot) string {
	if s.Bootstrap != "" {
		a.boot.reset()
		return s.Bootstrap
	}
	if !s.VPN {
		a.boot.reset() // the next connection asks again: it may be another network
		return ""
	}
	up, current := a.host.engineUp()
	return a.boot.choose(up, current)
}

// activeLists are the lists the engine applies: none while routing is off, when only the default route is left.
func activeLists(s api.Snapshot) []api.ListSpec {
	if !s.ListsOn {
		return nil
	}
	return s.Lists
}

// listID is the engine's ID for a list. Names can hold spaces and any script;
// the engine's IDs go into file names, so the ID is a hash of the name. It is
// the daemon's choice, never taken from the socket.
func listID(name string) string {
	h := sha256.Sum256([]byte(name))
	return "l-" + hex.EncodeToString(h[:6])
}

// Apply makes the host run the snapshot. A repeated snapshot changes nothing;
// a tunnel that failed stays failed until Retry names it.
func (a *app) Apply(s api.Snapshot) error {
	if err := s.Validate(); err != nil {
		return err
	}
	a.applyMu.Lock()
	defer a.applyMu.Unlock()
	if err := a.applyLists(s); err != nil {
		return err
	}
	// Before the engine starts, so the VPN never comes up unprotected; a failure stops the apply. Off, or the
	// VPN switched off, is the user's intent: that alone removes the rules (a crash never does).
	if err := a.ks.set(s.VPN && s.KillSwitch, s.KillSwitchLAN); err != nil {
		return err
	}
	for _, id := range s.Retry {
		if id == "*" {
			id = ""
		}
		a.host.retry(id)
	}
	a.host.setBootstrap(a.bootstrapFor(s))
	a.host.setSelected(s.Selected)
	a.host.setFinal(s.Final)
	a.host.setBlockQUIC(s.BlockQUIC && s.ListsOn)
	a.host.setBlockSTUN(s.BlockSTUN) // privacy, not routing: it applies with the lists off too
	a.host.setBlockIPv6(s.BlockIPv6)
	a.host.setTLSFingerprint(s.TLSFingerprint)
	a.host.setVPN(s.VPN)
	a.reconcile(s)
	a.rememberRouting(s)
	a.mu.Lock()
	a.appliedAt = time.Now().UTC()
	a.mu.Unlock()
	return nil
}

// applyLists writes every list as a sing-box rule-set (the engine reloads
// rewritten files without restarting) and tells the host which lists to apply.
// A list that can't be read is an error and changes nothing.
func (a *app) applyLists(s api.Snapshot) error {
	b, _ := json.Marshal(struct {
		On    bool
		Lists []api.ListSpec
	}{s.ListsOn, s.Lists})
	sum := sha256.Sum256(b)
	sig := hex.EncodeToString(sum[:])
	if sig == a.listsSig {
		return nil
	}
	// Each list is entries (custom text, an import, a release list) or a binary rule-set (built from rules, or
	// imported as an .srs / JSON source and kept as it is).
	type content struct {
		es       rules.Entries
		srs      []byte // set for a rule-set list
		programs bool
	}
	data := make([]content, len(s.Lists))
	for i, l := range s.Lists {
		switch l.Format {
		case api.FormatRules:
			b, err := core.CompileRules(*l.Rules)
			if err != nil {
				return fmt.Errorf("list %s: %w", l.Name, err)
			}
			data[i].srs = b
		case api.FormatRuleSet:
			data[i].srs = l.Data
		default:
			es, _, err := entriesOf(l.Format, l.Entries, l.Text)
			if err != nil {
				return fmt.Errorf("list %s: %w", l.Name, err)
			}
			data[i].es, data[i].programs = es, es.MatchesPrograms()
		}
	}
	dir := ruleset.Dir(a.host.workDir)
	var hl []hostList
	var counts []api.ListCount
	var warn, keep []string
	for i, l := range s.Lists {
		id := listID(l.Name)
		binary := data[i].srs != nil
		if binary {
			files, programs, err := core.RuleSetFiles(id, l.Action, data[i].srs)
			if err == nil {
				err = ruleset.WriteFiles(dir, id, files)
			}
			if err != nil {
				return fmt.Errorf("list %s: %w", l.Name, err)
			}
			data[i].programs = programs
		} else {
			w, err := ruleset.Write(dir, id, l.Action, data[i].es)
			if err != nil {
				return fmt.Errorf("list %s: %w", l.Name, err)
			}
			if w != "" {
				warn = append(warn, l.Name+": "+w)
			}
		}
		keep = append(keep, id)
		counts = append(counts, api.ListCount{Name: l.Name, Action: l.Action, Entries: entryCount(data[i].es)})
		hl = append(hl, hostList{ID: id, Name: l.Name, Action: l.Action, Tunnel: l.Tunnel, Binary: binary, Programs: data[i].programs})
	}
	if err := ruleset.Prune(dir, keep); err != nil {
		log.Printf("rulesets: %v", err)
	}
	if !s.ListsOn {
		hl = nil // lists off: everything goes through the default tunnel
	}
	a.mu.Lock()
	a.counts, a.listWarn = counts, warn
	a.mu.Unlock()
	a.host.setLists(hl)
	a.listsSig = sig
	return nil
}

func entryCount(es rules.Entries) int {
	return es.Count() - len(es.ASNs) // AS numbers are kept but not routed
}

// entriesOf reads a list's entries in the format it came in, with the parse
// statistics when it was text.
func entriesOf(format string, entries []string, text string) (rules.Entries, lists.Stats, error) {
	switch format {
	case "", api.FormatCustom:
		es, err := rules.ParseEntries(entries)
		return es, lists.Stats{}, err
	case api.FormatImport:
		if strings.TrimSpace(text) == "" {
			return rules.Entries{}, lists.Stats{}, nil // not downloaded yet
		}
		return lists.ParseText([]byte(text))
	case api.FormatRelease:
		return lists.Parse([]byte(text))
	}
	return rules.Entries{}, lists.Stats{}, fmt.Errorf("unknown format %q", format)
}

// reconcile makes the host load what the snapshot says: nothing while the VPN is
// off, the desired tunnels while it is on. A tunnel that failed is not tried
// again here (retrying bad credentials locks accounts); Retry does that.
func (a *app) reconcile(s api.Snapshot) {
	a.rememberEndpoints(s.Tunnels)
	byID := map[string]bool{}
	for _, t := range s.Tunnels {
		byID[t.ID] = true
	}
	for _, id := range a.host.known() { // removed in the app: stop wanting it
		if !byID[id] {
			a.host.forget(id)
		}
	}
	if !s.VPN {
		return
	}
	want := desiredTunnels(s.Tunnels, s.Selected, activeLists(s), s.Final, s.LoadAll)
	for _, t := range s.Tunnels {
		_, _, wanted := a.host.loaded(t.ID)
		loaded := wanted || a.host.isWaiting(t.ID)
		switch {
		case want[t.ID] && !a.host.isFailed(t.ID):
			if err := a.connect(t); err != nil {
				log.Printf("tunnel %s: %v", t.Name, err)
				a.host.markFailed(t.ID, err.Error())
			}
		case !want[t.ID] && loaded:
			a.host.disconnect(t.ID)
		}
	}
}

// fingerprint covers everything the engine's options are built from except the
// name, so a renamed tunnel is renamed in place and a changed one reconnects.
func fingerprint(t api.TunnelSpec) string {
	h := sha256.New()
	for _, p := range []string{t.Protocol, t.Profile, string(t.Options), t.Username, t.Password, t.KeyPassword} {
		fmt.Fprintf(h, "%d:%s|", len(p), p)
	}
	return hex.EncodeToString(h.Sum(nil))
}

// lacksCredentials is whether an OpenVPN tunnel needs a sign-in or a key password and has none yet.
func lacksCredentials(t api.TunnelSpec) bool {
	if t.Protocol != api.ProtocolOpenVPN {
		return false
	}
	if t.NeedsAuth && t.Username == "" && t.Password == "" {
		return true
	}
	p, err := openvpn.Parse([]byte(t.Profile))
	return err == nil && p.KeyEncrypted && t.KeyPassword == ""
}

// connect asks the host for a tunnel; one that needs credentials and has none
// waits for the app to send them in the next snapshot. A tunnel the host already
// runs from the same source is left alone.
func (a *app) connect(t api.TunnelSpec) error {
	if lacksCredentials(t) {
		if _, _, wanted := a.host.loaded(t.ID); wanted {
			a.host.disconnect(t.ID) // its credentials are gone
		}
		if !a.host.isWaiting(t.ID) {
			a.host.waitForCredentials(t.ID, t.Name)
		}
		return nil
	}
	sig := fingerprint(t)
	if cur, name, ok := a.host.loaded(t.ID); ok && cur == sig {
		if name != t.Name {
			a.host.rename(t.ID, t.Name)
		}
		return nil
	}
	opts, err := options(t)
	if err != nil {
		return err
	}
	a.host.connectSig(t.ID, t.Name, t.Protocol, opts, sig)
	return nil
}

// options builds the engine's options for a tunnel. An OpenVPN profile is parsed
// again here and the options come from it; the core refuses options of any other
// protocol that could read a file or steer the engine's own traffic.
func options(t api.TunnelSpec) (json.RawMessage, error) {
	if t.Protocol != api.ProtocolOpenVPN {
		if err := core.CheckTunnel(t.Protocol, t.Options); err != nil {
			return nil, err
		}
		return t.Options, nil
	}
	p, err := checkProfile([]byte(t.Profile))
	if err != nil {
		return nil, err
	}
	ep, err := openvpn.Endpoint(p, "x", t.Username, t.Password, t.KeyPassword)
	if err != nil {
		return nil, err
	}
	return json.Marshal(ep)
}

// checkProfile refuses what the engine can't run, by name, so a profile that
// imports is one that starts.
func checkProfile(text []byte) (openvpn.Profile, error) {
	p, err := openvpn.Parse(text)
	if err != nil {
		return p, err
	}
	if len(p.Scripts) > 0 {
		return p, fmt.Errorf("the profile runs %v, which the engine does not support: it runs no scripts or plugins", p.Scripts)
	}
	// An encrypted key is opened later, with the password the app sends: here the profile is only checked, so the
	// key's text is passed through as it is.
	probe := p
	probe.KeyEncrypted = false
	if _, err := openvpn.Endpoint(probe, "x", "x", "x", ""); err != nil {
		return p, fmt.Errorf("the engine can't run this profile: %w", err)
	}
	return p, nil
}

// Test measures the tunnels the app names: a request through each (host.test) or a connect or ping to its server (probe.go).
func (a *app) Test(ids []string, o api.TestOptions) map[string]api.TestResult {
	if o.Method == api.TestTCP || o.Method == api.TestICMP {
		return a.probe(ids, o)
	}
	return a.host.test(ids, o)
}

// Answer gives a running tunnel the credentials of a challenge it is waiting for.
func (a *app) Answer(id string, c api.Credentials) error {
	return a.host.answer(id, core.ChallengeResponse{Username: c.User, Password: c.Pass})
}
