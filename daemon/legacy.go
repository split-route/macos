//go:build darwin || linux

package main

import (
	"encoding/json"
	"errors"
	"io/fs"
	"log"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/split-route/macos/daemon/internal/api"
)

// cleanupLegacy removes what earlier versions left on the system and nothing
// else. Versions before 0.11 added kernel routes next to the user's VPN (recorded
// in state.json), applied tunnel addresses, routes and DNS through a helper
// (undo lists in tunnels/net-*.json) and ran engine processes (pid files). This
// version has no route code, so without this those routes would stay until a
// reboot. It runs at every start and is a no-op once the files are gone.
func (a *app) cleanupLegacy() {
	a.cleanupLegacyRoutes()
	a.cleanupLegacyUndo()
	a.cleanupLegacyProcesses()
	if err := os.RemoveAll(filepath.Join(a.stateDir, "rulesets")); err != nil {
		log.Printf("legacy: %v", err)
	}
}

func (a *app) runCmd(name string, args []string, stdin string) error {
	if a.exec != nil {
		return a.exec(name, args, stdin)
	}
	c := exec.Command(name, args...)
	c.Stdin = strings.NewReader(stdin)
	return c.Run()
}

func (a *app) queryCmd(name string, args ...string) (string, error) {
	if a.query != nil {
		return a.query(name, args...)
	}
	out, err := exec.Command(name, args...).Output()
	return string(out), err
}

// cleanupLegacyRoutes deletes the routes state.json lists, by exact prefix.
func (a *app) cleanupLegacyRoutes() {
	path := filepath.Join(a.stateDir, "state.json")
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return
	}
	if err != nil {
		log.Printf("legacy: %v", err)
		return
	}
	var st struct {
		Routes []struct {
			Prefix string `json:"prefix"`
		} `json:"routes"`
	}
	if err := json.Unmarshal(b, &st); err != nil {
		log.Printf("legacy: state.json: %v (leaving it)", err)
		return
	}
	removed := 0
	for _, r := range st.Routes {
		p, err := netip.ParsePrefix(r.Prefix) // never run text that isn't a prefix
		if err != nil {
			continue
		}
		args := []string{"-n", "delete", "-net", p.String()}
		if p.Addr().Is6() {
			args = []string{"-n", "delete", "-inet6", "-net", p.String()}
		}
		if a.runCmd("/sbin/route", args, "") == nil {
			removed++
		}
	}
	log.Printf("legacy: removed %d of %d routes left by an earlier version", removed, len(st.Routes))
	if err := os.Remove(path); err != nil {
		log.Printf("legacy: %v", err)
	}
}

// undoTools are the only programs a recorded undo list may run.
var undoTools = []string{"/sbin/route", "/sbin/ifconfig", "/usr/sbin/scutil"}

// cleanupLegacyUndo runs the undo lists an earlier helper recorded: only the
// three tools above, and only commands that were recorded as safe to fail.
func (a *app) cleanupLegacyUndo() {
	files, _ := filepath.Glob(filepath.Join(a.tunnelsDir(), "net-*.json"))
	for _, f := range files {
		if b, err := os.ReadFile(f); err == nil {
			var l map[string][]struct {
				Name  string   `json:"name"`
				Args  []string `json:"args"`
				Stdin string   `json:"stdin"`
				Soft  bool     `json:"soft"`
			}
			if json.Unmarshal(b, &l) == nil {
				for _, c := range append(l["setup"], l["hosts"]...) {
					if c.Soft && slices.Contains(undoTools, c.Name) {
						_ = a.runCmd(c.Name, c.Args, c.Stdin)
					}
				}
			}
		}
		_ = os.Remove(f)
	}
}

// cleanupLegacyProcesses stops engine processes an earlier service left behind
// (macOS has no parent-death signal). Only a process whose command is the
// engine's copy in the run dir is signaled.
func (a *app) cleanupLegacyProcesses() {
	runDir := filepath.Join(filepath.Dir(api.SockPath("darwin")), "splitroute-tunnels")
	if a.runDir != "" {
		runDir = a.runDir
	}
	pids, _ := filepath.Glob(filepath.Join(runDir, "*.pid"))
	for _, f := range pids {
		if b, err := os.ReadFile(f); err == nil {
			if pid, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil && pid > 1 {
				if out, err := a.queryCmd("ps", "-p", strconv.Itoa(pid), "-o", "command="); err == nil && strings.Contains(out, "splitroute-engine") {
					_ = syscall.Kill(pid, syscall.SIGTERM)
					time.Sleep(200 * time.Millisecond)
					_ = syscall.Kill(pid, syscall.SIGKILL)
				}
			}
		}
		_ = os.Remove(f)
	}
}
