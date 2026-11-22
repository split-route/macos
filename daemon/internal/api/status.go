//go:build darwin || linux

package api

import (
	"time"

	"github.com/split-route/core/rules"
)

// Status is what the control socket returns for `status`.
type Status struct {
	Version string `json:"version"`
	// Enabled is whether the lists are applied (config.Disabled is false). Off,
	// connected tunnels carry all traffic.
	Enabled bool `json:"enabled"`
	// Running is whether the engine is up (at least one tunnel was asked for);
	// Connected is how many tunnels are connected right now.
	Running   bool           `json:"running"`
	Connected int            `json:"connected"`
	Lists     []ListCount    `json:"lists"`
	Fetched   time.Time      `json:"fetched"`
	Warnings  []string       `json:"warnings,omitempty"`
	Error     string         `json:"error,omitempty"` // the last list refresh or engine start failed
	Imports   []ImportStatus `json:"imports,omitempty"`
}

// ImportStatus is an import's download state.
type ImportStatus struct {
	Name      string    `json:"name"`
	URL       string    `json:"url"`
	Entries   int       `json:"entries"`
	Skipped   int       `json:"skipped,omitempty"` // lines in the last download that were skipped
	FetchedAt time.Time `json:"fetched_at,omitzero"`
	CheckedAt time.Time `json:"checked_at,omitzero"`
	Error     string    `json:"error,omitempty"` // last attempt failed; the entries are from FetchedAt
}

// ListCount is how many entries a list holds.
type ListCount struct {
	Name    string       `json:"name"`
	Action  rules.Action `json:"action"`
	Entries int          `json:"entries"`
}
