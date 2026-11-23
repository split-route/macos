//go:build darwin || linux

package main

import (
	"encoding/json"
	"strings"
	"testing"
)

// The app decodes lists as an array: a fresh service must send [], never null.
func TestStatusListsAreNeverNull(t *testing.T) {
	a := newApp(t.TempDir(), nil)
	b, err := json.Marshal(a.Status())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), `"lists":[]`) {
		t.Fatalf("status = %s", b)
	}
}
