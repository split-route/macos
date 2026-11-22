//go:build darwin || linux

// Tunnels: stored OpenVPN profiles and the operations the app asks for. Running
// them is the host's job (host.go).

package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"

	"github.com/split-route/core"
	"github.com/split-route/core/importers/openvpn"
	"github.com/split-route/macos/daemon/internal/api"
	"github.com/split-route/macos/daemon/internal/store"
)

var tunnelMu sync.Mutex // serializes imports and removals (file and row change together)

func (a *app) tunnelsDir() string { return filepath.Join(a.stateDir, "tunnels") }

func (a *app) profilePath(id int64) string {
	return filepath.Join(a.tunnelsDir(), strconv.FormatInt(id, 10), "profile.ovpn")
}

// secureDir creates dir (root-only) or checks that an existing one is not open
// to other users or a symlink.
func secureDir(dir string) error {
	if err := os.MkdirAll(filepath.Dir(dir), 0o755); err != nil {
		return err
	}
	if err := os.Mkdir(dir, 0o700); err != nil && !errors.Is(err, os.ErrExist) {
		return err
	}
	fi, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !fi.IsDir() || fi.Mode()&0o077 != 0 || !ok || int(st.Uid) != os.Geteuid() {
		return fmt.Errorf("%s must be a directory owned by this user with mode 0700", dir)
	}
	return nil
}

func (a *app) writeProfile(id int64, text []byte) error {
	if err := secureDir(a.tunnelsDir()); err != nil {
		return err
	}
	if err := secureDir(filepath.Dir(a.profilePath(id))); err != nil {
		return err
	}
	return writePrivate(a.profilePath(id), text)
}

// engineCheck is why no tunnel can run here, or "". The core's protocols come
// with the sing-box build tags; an app built without them says so.
func engineCheck() string {
	if len(core.Protocols()) == 0 {
		return "this build has no tunnel protocols"
	}
	return ""
}

func (a *app) tunnelStore() (*store.Store, error) {
	s, err := a.settings()
	if err != nil {
		return nil, err
	}
	return s, nil
}

func (a *app) tunnelByName(s *store.Store, name string) (store.Tunnel, error) {
	ts, err := s.Tunnels()
	if err != nil {
		return store.Tunnel{}, err
	}
	for _, t := range ts {
		if t.Name == name {
			return t, nil
		}
	}
	return store.Tunnel{}, fmt.Errorf("no tunnel named %q", name)
}

func (a *app) apiTunnel(t store.Tunnel) api.Tunnel {
	v := a.host.snapshot(tunnelID(t.ID))
	return api.Tunnel{Name: t.Name, Remotes: t.Remotes, NeedsAuth: t.NeedsAuth, KeyEncrypted: t.KeyEncrypted,
		AutoConnect: t.AutoConnect, State: v.state, Error: v.err, Need: v.need, LocalIP: v.local, RemoteIP: v.remote, Since: v.since}
}

// ---- api.Tunnels ----

func (a *app) Tunnels() (api.TunnelList, error) {
	l := api.TunnelList{Tunnels: []api.Tunnel{}, Unavailable: engineCheck()}
	s, err := a.settings()
	if err != nil {
		return l, err
	}
	ts, err := s.Tunnels()
	if err != nil {
		return l, err
	}
	for _, t := range ts {
		l.Tunnels = append(l.Tunnels, a.apiTunnel(t))
	}
	return l, nil
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
	if _, err := openvpn.Endpoint(p, "x", "x", "x"); err != nil {
		return p, fmt.Errorf("the engine can't run this profile: %w", err)
	}
	return p, nil
}

func (a *app) TunnelImport(name string, text []byte) (api.Tunnel, error) {
	s, err := a.tunnelStore()
	if err != nil {
		return api.Tunnel{}, err
	}
	p, err := checkProfile(text)
	if err != nil {
		return api.Tunnel{}, err
	}
	tunnelMu.Lock()
	defer tunnelMu.Unlock()
	sum := sha256.Sum256(text)
	t := store.Tunnel{Name: name, ProfileSHA256: hex.EncodeToString(sum[:]), Remotes: p.Remotes, NeedsAuth: p.NeedsAuth, KeyEncrypted: p.KeyEncrypted}
	if t.ID, err = s.AddTunnel(t); err != nil {
		return api.Tunnel{}, err
	}
	if err := a.writeProfile(t.ID, text); err != nil {
		_ = s.RemoveTunnel(t.ID)
		_ = os.RemoveAll(filepath.Dir(a.profilePath(t.ID)))
		return api.Tunnel{}, err
	}
	return a.apiTunnel(t), nil
}

func (a *app) TunnelRemove(name string) error {
	s, err := a.tunnelStore()
	if err != nil {
		return err
	}
	tunnelMu.Lock()
	defer tunnelMu.Unlock()
	t, err := a.tunnelByName(s, name)
	if err != nil {
		return err
	}
	// Refuse before touching anything: a tunnel that lists use stays whole.
	if using, err := s.ListsUsingTunnel(t.ID); err != nil {
		return err
	} else if len(using) > 0 {
		return store.ErrTunnelInUse(using)
	}
	a.host.forget(tunnelID(t.ID)) // stops wanting it
	// Files first: if this fails the row stays and the removal can be retried.
	if err := os.RemoveAll(filepath.Dir(a.profilePath(t.ID))); err != nil {
		return err
	}
	return s.RemoveTunnel(t.ID)
}

func (a *app) TunnelRename(name, newName string) error {
	s, err := a.tunnelStore()
	if err != nil {
		return err
	}
	t, err := a.tunnelByName(s, name)
	if err != nil {
		return err
	}
	if err := s.RenameTunnel(t.ID, newName); err != nil {
		return err
	}
	a.host.rename(tunnelID(t.ID), newName)
	a.wake() // lists name tunnels by name
	return nil
}

func (a *app) TunnelAutoConnect(name string, on bool) error {
	s, err := a.tunnelStore()
	if err != nil {
		return err
	}
	t, err := a.tunnelByName(s, name)
	if err != nil {
		return err
	}
	return s.SetTunnelAutoConnect(t.ID, on)
}

// options builds the engine's options for a stored tunnel from its profile and
// the credentials. The profile is read once, checked against the hash stored at
// import and translated again: a file changed on disk is refused.
func (a *app) options(t store.Tunnel, c api.Credentials) (json.RawMessage, error) {
	text, err := os.ReadFile(a.profilePath(t.ID))
	if err != nil {
		return nil, fmt.Errorf("profile: %w", err)
	}
	if sum := sha256.Sum256(text); hex.EncodeToString(sum[:]) != t.ProfileSHA256 {
		return nil, errors.New("the stored profile changed since it was imported; import it again")
	}
	p, err := checkProfile(text)
	if err != nil {
		return nil, err
	}
	ep, err := openvpn.Endpoint(p, "x", c.User, c.Pass)
	if err != nil {
		return nil, err
	}
	return json.Marshal(ep)
}

// connect asks for a tunnel with these credentials; one that needs credentials
// and has none waits for the app to send them.
func (a *app) connect(t store.Tunnel, c api.Credentials) error {
	id := tunnelID(t.ID)
	if t.NeedsAuth && !c.HaveAuth {
		a.host.waitForCredentials(id, t.Name)
		return nil
	}
	opts, err := a.options(t, c)
	if err != nil {
		return err
	}
	a.host.connect(id, t.Name, opts)
	return nil
}

func (a *app) TunnelConnect(name string, c api.Credentials) error {
	s, err := a.tunnelStore()
	if err != nil {
		return err
	}
	t, err := a.tunnelByName(s, name)
	if err != nil {
		return err
	}
	return a.connect(t, c)
}

// TunnelCredentials gives a tunnel the credentials it waits for: to start it, or
// to answer a challenge it is running with.
func (a *app) TunnelCredentials(name string, c api.Credentials) error {
	s, err := a.tunnelStore()
	if err != nil {
		return err
	}
	t, err := a.tunnelByName(s, name)
	if err != nil {
		return err
	}
	if a.host.isWaiting(tunnelID(t.ID)) {
		return a.connect(t, c)
	}
	return a.host.answer(tunnelID(t.ID), core.ChallengeResponse{Username: c.User, Password: c.Pass})
}

func (a *app) TunnelDisconnect(name string) error {
	s, err := a.tunnelStore()
	if err != nil {
		return err
	}
	t, err := a.tunnelByName(s, name)
	if err != nil {
		return err
	}
	a.host.disconnect(tunnelID(t.ID))
	return nil
}

func (a *app) TunnelLogs(name string) ([]string, error) {
	s, err := a.tunnelStore()
	if err != nil {
		return nil, err
	}
	if _, err := a.tunnelByName(s, name); err != nil {
		return nil, err
	}
	return a.host.logLines(), nil
}

// startAutoConnect connects the tunnels the user marked. One that needs
// credentials waits for the app, which has them in the Keychain.
func (a *app) startAutoConnect() {
	s, err := a.settings()
	if err != nil {
		return
	}
	ts, err := s.Tunnels()
	if err != nil {
		log.Printf("auto-connect: %v", err)
		return
	}
	for _, t := range ts {
		if !t.AutoConnect {
			continue
		}
		if err := a.connect(t, api.Credentials{}); err != nil {
			log.Printf("auto-connect %s: %v", t.Name, err)
		}
	}
}
