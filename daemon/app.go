//go:build darwin || linux

// The daemon's app: the network layer and nothing else. It keeps no settings,
// tunnels or lists on disk; the menu bar app owns them and sends the desired
// state (Apply), which the daemon hands to the host (host.go), which runs the
// core engine. It implements the control socket's Backend.

package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"log"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"time"

	"github.com/split-route/core"
	"github.com/split-route/core/ruleset"
	"github.com/split-route/macos/daemon/internal/api"
)

// version is set at build time (-X main.version=...).
var version = "dev"

const defaultState = "/var/db/splitroute"

type app struct {
	stateDir string
	host     *host
	boot     *bootstrapPicker // which resolver finds proxy servers' names
	ks       *killSwitch
	bootID   string // new for every run: the app sends its snapshot when this changes

	// Tests replace these; nil runs the real command.
	exec   func(name string, args []string, stdin string) error
	query  func(name string, args ...string) (string, error)
	runDir string // where an earlier version kept its engine pid files

	restart chan struct{} // exit, so the service manager starts the updated binary

	applyMu   sync.Mutex               // one Apply at a time
	listsSig  string                   // fingerprint of the lists last written, so a repeated snapshot rewrites nothing
	mu        sync.Mutex               // below
	routing   routingState             // what the last snapshot said about lists and routes, for route_test
	endpoints map[string]core.Endpoint // every tunnel's server by ID, as the last snapshot said (a TCP or ping test needs no engine)
	counts    []api.ListCount
	listWarn  []string
	appliedAt time.Time
}

func newApp(stateDir string, f engineFactory) *app {
	var b [8]byte
	_, _ = rand.Read(b[:])
	a := &app{stateDir: stateDir, bootID: hex.EncodeToString(b[:]), restart: make(chan struct{}, 1)}
	a.ks = newKillSwitch(stateDir)
	a.host = newHost(filepath.Join(stateDir, "engine"), f)
	a.boot = newBootstrapPicker()
	return a
}

func (a *app) tunnelsDir() string { return filepath.Join(a.stateDir, "tunnels") }

// ---- api.Backend ----

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

func (a *app) Status() api.Status {
	s := api.Status{Version: version, APIRev: api.APIRevision, BootID: a.bootID, Lists: []api.ListCount{}, Unavailable: engineCheck()}
	running, connected, warns, herr := a.host.engineStatus()
	s.Running, s.Connected, s.Error = running, connected, herr
	s.Tunnels = a.host.tunnelStatuses()
	s.KillSwitch.Armed, s.KillSwitch.Error = a.ks.status()
	a.mu.Lock()
	s.AppliedAt, s.Lists = a.appliedAt, append([]api.ListCount{}, a.counts...) // never null: the app decodes an array
	s.Warnings = append(slices.Clone(a.listWarn), warns...)
	a.mu.Unlock()
	return s
}

func (a *app) Logs() []string { return a.host.logLines() }

// run keeps the service up until ctx ends or a restart is asked for. It has
// nothing to apply at start: the app sends the snapshot once it sees a new boot ID.
func (a *app) run(ctx context.Context) error {
	defer a.host.close() // the engine's tun goes away with the service
	a.ks.restore()       // first: after a reboot the network stays closed until the app sends its snapshot
	a.cleanupLegacy()
	// Rule sets from an earlier run: the next Apply writes the ones it needs.
	if err := os.RemoveAll(ruleset.Dir(a.host.workDir)); err != nil {
		log.Printf("rulesets: %v", err)
	}
	select {
	case <-ctx.Done():
	case <-a.restart:
		log.Print("restarting to run the updated binary")
	}
	return nil
}
