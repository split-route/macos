//go:build darwin || linux

package api

import (
	"strings"
	"testing"
	"time"
)

func TestTestOptionsValidate(t *testing.T) {
	for _, tc := range []struct {
		name string
		o    TestOptions
		ok   bool
	}{
		{"zero value", TestOptions{}, true},
		{"tcp", TestOptions{Method: TestTCP}, true},
		{"https url", TestOptions{URL: "https://www.gstatic.com/generate_204"}, true},
		{"http url", TestOptions{URL: "http://example.com/x"}, false},
		{"file url", TestOptions{URL: "file:///etc/passwd"}, false},
		{"no scheme", TestOptions{URL: "example.com"}, false},
		{"user info", TestOptions{URL: "https://u:p@example.com/"}, false},
		{"no host", TestOptions{URL: "https:///x"}, false},
		{"too long", TestOptions{URL: "https://example.com/" + strings.Repeat("a", 3000)}, false},
		{"unknown method", TestOptions{Method: "udp"}, false},
	} {
		if err := tc.o.Validate(); (err == nil) != tc.ok {
			t.Errorf("%s: %v", tc.name, err)
		}
	}
}

func TestTestOptionsTimeoutIsClamped(t *testing.T) {
	def := 5 * time.Second
	for ms, want := range map[int]time.Duration{0: def, -4: def, 1: time.Second, 3000: 3 * time.Second, 999999: 30 * time.Second} {
		if got := (TestOptions{TimeoutMS: ms}).Timeout(def); got != want {
			t.Errorf("%d ms: %v, want %v", ms, got, want)
		}
	}
}
