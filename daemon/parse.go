//go:build darwin || linux

// The stateless helpers: the core owns the parsers (share links, OpenVPN
// profiles, list text, entry syntax), so the app asks and keeps the answers.
// Nothing here reads or writes the daemon's state.

package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/split-route/core"
	"github.com/split-route/core/importers/links"
	"github.com/split-route/core/importers/openvpn"
	"github.com/split-route/core/lists"
	"github.com/split-route/core/rules"
	"github.com/split-route/macos/daemon/internal/api"
)

// CheckProfile says what an OpenVPN profile asks for and whether the engine can
// run it. A profile that doesn't parse is an error; one that parses but can't
// run is answered with Refused set, so the app can show what it asked for.
func (a *app) CheckProfile(text string) (api.TunnelCheck, error) {
	p, err := openvpn.Parse([]byte(text))
	if err != nil {
		return api.TunnelCheck{}, err
	}
	c := api.TunnelCheck{Remotes: p.Remotes, NeedsAuth: p.NeedsAuth, KeyEncrypted: p.KeyEncrypted, Scripts: p.Scripts, ScriptSecurity: p.ScriptSecurity}
	if _, err := checkProfile([]byte(text)); err != nil {
		c.Refused = err.Error()
	}
	return c, nil
}

// ParseLinks reads share links, a subscription body or a sing-box config into
// nodes the engine can run. Nodes it can't run are skipped with a reason; one
// bad node never rejects the rest.
func (a *app) ParseLinks(text string) (api.Nodes, error) {
	parsed, err := links.Parse([]byte(text))
	if err != nil {
		return api.Nodes{}, err
	}
	out := api.Nodes{Nodes: []api.Node{}}
	for _, sk := range parsed.Skipped {
		out.Skipped = append(out.Skipped, api.Skipped{Label: sk.Label, Reason: sk.Reason})
	}
	for _, n := range parsed.Nodes {
		data, err := json.Marshal(n.Options)
		if err == nil {
			err = core.CheckTunnel(n.Protocol, data)
		}
		if err != nil {
			out.Skipped = append(out.Skipped, api.Skipped{Label: n.Name, Reason: err.Error()})
			continue
		}
		out.Nodes = append(out.Nodes, api.Node{Name: n.Name, Protocol: n.Protocol, Options: data, Server: n.Server, Warning: n.Warning})
	}
	return out, nil
}

// ParseEntries reads list text. "import" applies the checks a download must
// pass before it replaces the last good copy; "custom" is a file the user picked
// for a new list and must hold at least one entry; "release" is a release file.
func (a *app) ParseEntries(text string, data []byte, format string, wantLines bool) (api.Entries, error) {
	var out api.Entries
	var extraSkipped int
	if len(data) > 0 { // a sing-box binary rule-set: read it into entry text first
		if format == api.FormatRelease {
			return out, errors.New("a release list is text")
		}
		if !core.IsRuleSetBinary(data) {
			return out, errors.New("this is not a sing-box rule-set (.srs)")
		}
		var err error
		if text, extraSkipped, err = core.RuleSetText(data); err != nil {
			return out, err
		}
	}
	switch format {
	case api.FormatImport, api.FormatCustom:
		es, st, err := lists.ParseText([]byte(text))
		if err != nil {
			return out, err
		}
		out.Count = len(es.V4) + len(es.V6) + len(es.Domains) + len(es.Suffixes) + len(es.ASNs)
		out.Skipped = st.Reserved + st.Invalid + st.Other + extraSkipped
		if format == api.FormatImport {
			if err := lists.CheckImport(out.Count, st); err != nil {
				return out, err
			}
		} else if out.Count == 0 {
			return out, errors.New("the file has no addresses, ranges, domains or AS numbers")
		}
		if wantLines {
			for _, e := range es.All() {
				out.Lines = append(out.Lines, e.String())
			}
		}
	case api.FormatRelease:
		es, st, err := lists.Parse([]byte(text))
		if err != nil {
			return out, err
		}
		out.Count, out.Skipped = entryCount(es), st.Reserved+st.Invalid+st.Other
	default:
		return out, fmt.Errorf("unknown format %q", format)
	}
	return out, nil
}

// CanonEntries gives each line's canonical form or the reason it isn't an entry.
// Blank lines and "#" notes come back as they are.
func (a *app) CanonEntries(ls []string) []api.Canon {
	out := make([]api.Canon, len(ls))
	for i, l := range ls {
		out[i].Line = l
		t := strings.TrimSpace(l)
		if t == "" || strings.HasPrefix(t, "#") {
			out[i].Entry = t
			continue
		}
		if e, err := rules.ParseEntry(t); err != nil {
			out[i].Error = err.Error()
		} else {
			out[i].Entry = e.String()
		}
	}
	return out
}

// LegacyExport hands the app what versions before 0.3 kept in root-only files
// (profiles, link options, subscription addresses), because the app owns them
// now. It reads; it deletes nothing, so a failed move can be run again.
func (a *app) LegacyExport() (api.LegacyState, error) {
	st := api.LegacyState{Tunnels: map[string]api.LegacyTunnel{}, Subscriptions: map[string]api.LegacySub{}}
	dirs, _ := filepath.Glob(filepath.Join(a.tunnelsDir(), "*"))
	for _, d := range dirs {
		id := filepath.Base(d)
		if !isDigits(id) {
			continue // net-*.json undo lists
		}
		var t api.LegacyTunnel
		if b, err := os.ReadFile(filepath.Join(d, "profile.ovpn")); err == nil {
			t.Profile = string(b)
		}
		if b, err := os.ReadFile(filepath.Join(d, "options.json")); err == nil {
			t.Options = string(b)
		}
		if t.Profile != "" || t.Options != "" {
			st.Tunnels[id] = t
		}
	}
	dirs, _ = filepath.Glob(filepath.Join(a.stateDir, "subscriptions", "*"))
	for _, d := range dirs {
		id := filepath.Base(d)
		b, err := os.ReadFile(filepath.Join(d, "url"))
		if err != nil || !isDigits(id) {
			continue
		}
		s := api.LegacySub{URL: strings.TrimSpace(string(b))}
		if b, err := os.ReadFile(filepath.Join(d, "info.json")); err == nil {
			var u api.Usage
			if json.Unmarshal(b, &u) == nil {
				s.Usage = &u
			}
		}
		st.Subscriptions[id] = s
	}
	return st, nil
}

func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}
