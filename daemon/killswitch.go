//go:build darwin || linux

// Kill switch: while the VPN is on, a pf anchor blocks every outbound packet that
// isn't the engine's own (root's sockets: tunnel servers and direct lists), the
// tun, loopback or, if asked, the local network. The rules live in the kernel, so
// they outlive the engine, this service and the app: a dropped tunnel blocks
// traffic instead of leaking it. They go away only when Apply is told to turn
// them off (the VPN switch or the kill switch) or by `splitroute killswitch off`.
// pf starts empty at boot, so the service keeps one marker file while the rules
// should be in force and loads them again at start, before the app sends anything.
//
// ponytail: root-owned sockets pass, so any root process (sudo curl) bypasses it;
// pf matches users, not programs. A Network Extension (includeAllNetworks) replaces
// this file.

package main

import (
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
)

const (
	pfctlPath = "/sbin/pfctl"
	// Apple's pf.conf evaluates only anchors under com.apple/.
	ksAnchor = "com.apple/250.splitroute"
	// ksMarker is the file in the state directory that exists while the rules should be loaded:
	// "lan" or "nolan". It is the one thing the service keeps on disk (root, 0600).
	ksMarker = "killswitch"
)

// pfRunner runs pfctl with stdin and returns its combined output.
type pfRunner func(args []string, stdin string) (string, error)

func realPF(args []string, stdin string) (string, error) {
	c := exec.Command(pfctlPath, args...)
	c.Stdin = strings.NewReader(stdin)
	out, err := c.CombinedOutput()
	return string(out), err
}

// killSwitchRules is the anchor's ruleset. It is fixed text: nothing from the
// socket reaches it but the LAN flag. utun is the interface group, so the rules
// hold when the engine's tun is recreated under another number.
func killSwitchRules(lan bool) string {
	r := []string{
		"pass quick on lo0 all",
		"pass out quick on utun all",
		"pass out quick proto { tcp, udp } from any to any user 0",
		"pass out quick inet6 proto icmp6 from any to any icmp6-type { routersol, routeradv, neighbrsol, neighbradv }",
	}
	if lan {
		r = append(r,
			"pass out quick inet from any to { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4 }",
			"pass out quick inet6 from any to { fe80::/10, fc00::/7, ff00::/8 }")
	}
	return strings.Join(append(r, "block drop out quick all"), "\n") + "\n"
}

var pfToken = regexp.MustCompile(`Token\s*:\s*(\d+)`)

// killSwitch owns the anchor. Apply is its only caller, under applyMu.
type killSwitch struct {
	run    func(args []string, stdin string) (string, error)
	marker string // path of the marker file

	mu     sync.Mutex
	token  string // our pf enable reference; released on disarm, never `pfctl -d`
	armed  bool
	synced bool // the anchor's state was set by this run: a restarted service doesn't know what the last one left
	err    string
}

func newKillSwitch(stateDir string) *killSwitch {
	return &killSwitch{run: realPF, marker: filepath.Join(stateDir, ksMarker)}
}

// set makes the anchor match the snapshot. Arming reloads the rules every time
// (cheap, and it undoes a flush by another tool or `killswitch off`).
func (k *killSwitch) set(on, lan bool) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	var err error
	switch {
	case on:
		err = k.arm(lan)
	case k.armed || !k.synced:
		err = k.disarm()
	}
	k.err = ""
	if err != nil {
		k.err = err.Error()
	}
	return err
}

// writeMarker is atomic, so a crash leaves the old marker or the new one, never half of one.
func (k *killSwitch) writeMarker(lan bool) error {
	body := "nolan\n"
	if lan {
		body = "lan\n"
	}
	if err := os.MkdirAll(filepath.Dir(k.marker), 0o755); err != nil {
		return err
	}
	tmp := k.marker + ".tmp"
	if err := os.WriteFile(tmp, []byte(body), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, k.marker)
}

// restore loads the rules again if a marker says the last run left them in force: pf is empty
// after a reboot, and the network must not be open until the app sends its snapshot. An
// unreadable marker arms too (without the LAN): when in doubt, block.
func (k *killSwitch) restore() {
	b, err := os.ReadFile(k.marker)
	if errors.Is(err, fs.ErrNotExist) {
		return
	}
	k.mu.Lock()
	defer k.mu.Unlock()
	if err := k.arm(err == nil && strings.TrimSpace(string(b)) == "lan"); err != nil {
		k.err = err.Error()
		log.Printf("%v", err)
		return
	}
	log.Print("kill switch: rules restored from the marker")
}

func (k *killSwitch) arm(lan bool) error {
	// The marker first: rules without one would not survive a reboot, so refuse to start unprotected.
	if err := k.writeMarker(lan); err != nil {
		return fmt.Errorf("kill switch: write marker: %w", err)
	}
	if k.token == "" {
		out, err := k.run([]string{"-E"}, "")
		if err != nil {
			return fmt.Errorf("kill switch: enable pf: %w: %s", err, strings.TrimSpace(out))
		}
		if m := pfToken.FindStringSubmatch(out); m != nil {
			k.token = m[1]
		}
	}
	if out, err := k.run([]string{"-a", ksAnchor, "-f", "-"}, killSwitchRules(lan)); err != nil {
		return fmt.Errorf("kill switch: load rules: %w: %s", err, strings.TrimSpace(out))
	}
	k.armed, k.synced = true, true
	return nil
}

func (k *killSwitch) disarm() error {
	if out, err := k.run([]string{"-a", ksAnchor, "-F", "all"}, ""); err != nil {
		return fmt.Errorf("kill switch: flush rules: %w: %s", err, strings.TrimSpace(out))
	}
	if err := os.Remove(k.marker); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("kill switch: remove marker: %w", err) // the rules are gone but a reboot would load them: report it
	}
	k.armed, k.synced = false, true
	if k.token != "" {
		_, _ = k.run([]string{"-X", k.token}, "")
		k.token = ""
	}
	return nil
}

func (k *killSwitch) status() (armed bool, err string) {
	k.mu.Lock()
	defer k.mu.Unlock()
	return k.armed, k.err
}

// killSwitchOff is `splitroute killswitch off`: the way out when the app can't
// be reached. The app re-arms on its next snapshot unless its setting is off too.
func killSwitchOff() error {
	out, err := realPF([]string{"-a", ksAnchor, "-F", "all"}, "")
	if err != nil {
		return fmt.Errorf("%w: %s", err, strings.TrimSpace(out))
	}
	if err := os.Remove(filepath.Join(defaultState, ksMarker)); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return nil
}
