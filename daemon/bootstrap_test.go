//go:build darwin || linux

package main

import (
	"context"
	"sync/atomic"
	"testing"

	"github.com/split-route/macos/daemon/internal/api"
)

func pickerWith(answers map[string]bool) (*bootstrapPicker, *atomic.Int32) {
	var calls atomic.Int32
	p := newBootstrapPicker()
	p.probe = func(_ context.Context, ip string) bool { calls.Add(1); return answers[ip] }
	return p, &calls
}

func TestBootstrapPickerTakesTheFirstResolverThatAnswersInPreferenceOrder(t *testing.T) {
	for name, tc := range map[string]struct {
		answers map[string]bool
		want    string
	}{
		"all answer: Cloudflare first": {map[string]bool{"1.1.1.1": true, "8.8.8.8": true, "9.9.9.9": true}, "1.1.1.1"},
		"Cloudflare blocked":           {map[string]bool{"8.8.8.8": true, "9.9.9.9": true}, "8.8.8.8"},
		"only Quad9":                   {map[string]bool{"9.9.9.9": true}, "9.9.9.9"},
		"none answer: the system one":  {map[string]bool{}, "system"},
	} {
		p, _ := pickerWith(tc.answers)
		if got := p.choose(false, ""); got != tc.want {
			t.Errorf("%s: chose %q, want %q", name, got, tc.want)
		}
	}
}

func TestBootstrapPickerAsksOncePerConnection(t *testing.T) {
	p, calls := pickerWith(map[string]bool{"8.8.8.8": true})
	p.choose(false, "")
	n := calls.Load()
	if got := p.choose(false, ""); got != "8.8.8.8" || calls.Load() != n {
		t.Errorf("a second ask probed again: chose %q, %d probes then %d", got, n, calls.Load())
	}
	p.reset()
	p.choose(false, "")
	if calls.Load() == n {
		t.Error("after reset it must ask again")
	}
}

// A probe sent while the engine runs goes through its tun and finds everything reachable, so it is not trusted.
func TestBootstrapPickerDoesNotProbeThroughARunningEngine(t *testing.T) {
	p, calls := pickerWith(map[string]bool{"1.1.1.1": true})
	if got := p.choose(true, "9.9.9.9"); got != "9.9.9.9" || calls.Load() != 0 {
		t.Errorf("chose %q with %d probes: it must keep the current resolver and not probe", got, calls.Load())
	}
}

func TestBootstrapForUsesTheChoiceOnlyWhenAutomatic(t *testing.T) {
	a, _ := testApp(t)
	a.boot.probe = func(_ context.Context, ip string) bool { return ip == "9.9.9.9" }
	on := api.Snapshot{VPN: true}
	if got := a.bootstrapFor(on); got != "9.9.9.9" {
		t.Errorf("automatic chose %q", got)
	}
	on.Bootstrap = "1.1.1.1"
	if got := a.bootstrapFor(on); got != "1.1.1.1" {
		t.Errorf("an explicit choice must win, got %q", got)
	}
	if got := a.bootstrapFor(api.Snapshot{}); got != "" {
		t.Errorf("with the connection down nothing is asked, got %q", got)
	}
}
