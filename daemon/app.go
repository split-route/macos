//go:build darwin || linux

// The daemon's app: it owns the settings database, keeps the lists current and
// hands them, with the tunnels the user connects, to the host (host.go), which
// runs the core engine. It implements the control socket's Backend and Tunnels.

package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"time"

	"github.com/split-route/core/lists"
	"github.com/split-route/core/ruleset"
	"github.com/split-route/macos/daemon/internal/api"
	"github.com/split-route/macos/daemon/internal/config"
	"github.com/split-route/macos/daemon/internal/store"
)

// version is set at build time (-X main.version=...).
var version = "dev"

const (
	checkEvery   = 15 * time.Second // how often the loop looks for changes
	refreshEvery = 24 * time.Hour   // release lists are downloaded again this often
	defaultState = "/var/db/splitroute"
)

type app struct {
	stateDir   string
	httpClient *http.Client
	host       *host

	dbMu sync.Mutex
	db   *store.Store

	// Tests replace these; nil runs the real command.
	exec   func(name string, args []string, stdin string) error
	query  func(name string, args ...string) (string, error)
	runDir string // where an earlier version kept its engine pid files

	reload  chan struct{} // something changed: refresh now
	restart chan struct{} // exit, so the service manager starts the updated binary

	mu       sync.Mutex // below
	lastErr  string
	fetched  time.Time
	counts   []api.ListCount
	listWarn []string
}

func newApp(stateDir string, f engineFactory) *app {
	a := &app{stateDir: stateDir, httpClient: lists.ImportClient, reload: make(chan struct{}, 1), restart: make(chan struct{}, 1)}
	a.host = newHost(filepath.Join(stateDir, "engine"), f)
	return a
}

func (a *app) dbPath() string { return filepath.Join(a.stateDir, "splitroute.db") }

// settings returns the settings database, opening it on first use and filling
// it with the defaults when it is new.
func (a *app) settings() (*store.Store, error) {
	a.dbMu.Lock()
	defer a.dbMu.Unlock()
	if a.db != nil {
		return a.db, nil
	}
	s, err := store.Open(a.dbPath())
	if err != nil {
		return nil, err
	}
	if _, err := s.Config(); errors.Is(err, store.ErrNotInitialized) {
		_, err = s.Init(config.Default(), "")
		if err != nil {
			s.Close()
			return nil, err
		}
	} else if err != nil {
		s.Close()
		return nil, err
	}
	a.db = s
	return s, nil
}

func (a *app) closeSettings() {
	a.dbMu.Lock()
	defer a.dbMu.Unlock()
	if a.db != nil {
		a.db.Close()
		a.db = nil
	}
}

func (a *app) wake() {
	select {
	case a.reload <- struct{}{}:
	default: // a refresh is already pending
	}
}

func (a *app) setErr(err error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.lastErr = ""
	if err != nil {
		a.lastErr = err.Error()
	}
}

// ---- api.Backend ----

func (a *app) LoadConfig() (config.Config, error) {
	s, err := a.settings()
	if err != nil {
		return config.Config{}, err
	}
	return s.Config()
}

// UpdateConfig changes the settings with f in one database transaction and
// asks the loop to apply them.
func (a *app) UpdateConfig(f func(config.Config) (config.Config, error)) (config.Config, error) {
	s, err := a.settings()
	if err != nil {
		return config.Config{}, err
	}
	cfg, err := s.Update(f)
	if err != nil {
		return config.Config{}, err
	}
	a.wake()
	return cfg, nil
}

func (a *app) AvailableLists() ([]string, error) {
	cfg, err := a.LoadConfig()
	if err != nil {
		return nil, err
	}
	return lists.Available(cfg.ListsURL())
}

// RefreshImport asks for an import to be downloaded on the next pass.
func (a *app) RefreshImport(name string) error {
	s, err := a.settings()
	if err != nil {
		return err
	}
	if err := s.ForceImport(name); err != nil {
		return err
	}
	a.wake()
	return nil
}

// Restart asks the loop to stop the tunnels and exit, so the service manager
// starts the updated binary (app upgrades). The exit waits a moment so the
// socket reply goes out first.
func (a *app) Restart() error {
	time.AfterFunc(300*time.Millisecond, func() {
		select {
		case a.restart <- struct{}{}:
		default:
		}
	})
	return nil
}

func (a *app) Status() (api.Status, error) {
	s := api.Status{Version: version, Lists: []api.ListCount{}}
	cfg, err := a.LoadConfig()
	if err != nil {
		return s, err
	}
	s.Enabled = !cfg.Disabled
	running, connected, warns, herr := a.host.engineStatus()
	s.Running, s.Connected = running, connected
	a.mu.Lock()
	s.Fetched, s.Lists = a.fetched, slices.Clone(a.counts)
	s.Warnings = append(slices.Clone(a.listWarn), warns...)
	s.Error = a.lastErr
	a.mu.Unlock()
	if s.Error == "" {
		s.Error = herr
	}
	if db, err := a.settings(); err == nil {
		sts, err := db.Imports()
		if err != nil {
			return s, err
		}
		for _, st := range sts {
			s.Imports = append(s.Imports, api.ImportStatus{Name: st.Name, URL: st.URL, Entries: st.Entries, Skipped: st.Skipped,
				FetchedAt: st.FetchedAt, CheckedAt: st.CheckedAt, Error: st.LastError})
		}
	}
	return s, nil
}

// ---- lists ----

// listID is the engine's ID for a list. Names can hold spaces and any script;
// the engine's IDs go into file names, so the ID is a hash of the name.
func listID(name string) string {
	h := sha256.Sum256([]byte(name))
	return "l-" + hex.EncodeToString(h[:6])
}

// refresh downloads what is due, reads every list, writes each as a sing-box
// rule-set (the engine reloads rewritten files without restarting) and tells the
// host which lists to apply. A failure keeps what the engine runs now.
func (a *app) refresh() {
	err := a.refreshLists(context.Background())
	a.setErr(err)
	if err != nil {
		log.Printf("refresh: %v", err)
	}
}

func (a *app) refreshLists(ctx context.Context) error {
	iwarn := a.refreshImports(ctx)
	cfg, err := a.LoadConfig()
	if err != nil {
		return err
	}
	data, warn, err := a.fetchLists(cfg)
	warn = append(iwarn, warn...)
	for _, w := range warn {
		log.Print("warning: ", w)
	}
	if err != nil {
		return err
	}
	dir := ruleset.Dir(a.host.workDir)
	var hl []hostList
	var counts []api.ListCount
	for _, l := range cfg.Lists {
		d := data[l.Name]
		id := listID(l.Name)
		if w, err := ruleset.Write(dir, id, l.Action, d.es); err != nil {
			return fmt.Errorf("list %s: %w", l.Name, err)
		} else if w != "" {
			warn = append(warn, l.Name+": "+w)
		}
		counts = append(counts, api.ListCount{Name: l.Name, Action: l.Action, Entries: entryCount(d.es)})
		hl = append(hl, hostList{ID: id, Name: l.Name, Action: l.Action, Tunnel: l.Tunnel})
	}
	if cfg.Disabled {
		hl = nil // lists off: everything goes through the default tunnel
	}
	a.mu.Lock()
	a.fetched, a.counts, a.listWarn = time.Now().UTC(), counts, warn
	a.mu.Unlock()
	a.host.setLists(hl)
	if err := a.reconcile(); err != nil { // lists may name OpenVPN tunnels the engine must load
		log.Printf("reconcile: %v", err)
	}
	return nil
}

// settingsChanged reports whether another connection changed the settings since the last call.
func (a *app) settingsChanged() bool {
	s, err := a.settings()
	if err != nil {
		return false
	}
	c, err := s.Changed()
	if err != nil {
		log.Printf("warning: settings database: %v", err)
	}
	return c
}

// ---- the loop ----

// run applies the lists and runs the tunnels until ctx ends or a restart is asked for.
func (a *app) run(ctx context.Context) error {
	defer a.host.close() // the engine's tun goes away with the service
	a.cleanupLegacy()
	a.settingsChanged() // baseline
	a.startAutoConnect()
	a.refresh()
	last := time.Now()
	t := time.NewTicker(checkEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-a.restart:
			log.Print("restarting to run the updated binary")
			return nil
		case <-a.reload:
		case <-t.C:
			if !a.settingsChanged() && time.Since(last) < refreshEvery && !a.importsDue() {
				continue
			}
		}
		a.refresh()
		last = time.Now()
	}
}

// writePrivate writes a file only root can read.
func writePrivate(path string, b []byte) error {
	return os.WriteFile(path, b, 0o600)
}
