// Package config is the daemon's settings model: lists, their actions and
// tunnels, validation, presets and the pure edits the socket applies.
package config

import (
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/split-route/core/rules"
)

// List is one routing-rules release list (by its name without ".list"), a
// custom list of the user's own entries (see rules.ParseEntry for the
// syntax), or an import of a third-party list by URL. An import's entries
// live only in the settings database, never in Config.
type List struct {
	Name    string       `json:"name"`
	Action  rules.Action `json:"action"`
	Tunnel  string       `json:"tunnel,omitempty"` // action tunnel only: the tunnel's name; empty means the default tunnel
	Custom  bool         `json:"custom,omitempty"`
	Entries []string     `json:"entries,omitempty"` // custom lists only: "1.2.3.0/24", "example.com", "full:a.example.com", "AS13335"
	Import  *Import      `json:"import,omitempty"`
}

// Import is where an import list comes from.
type Import struct {
	URL          string `json:"url"`
	RefreshHours int    `json:"refresh_hours,omitempty"` // 0: DefaultRefreshHours
}

const (
	DefaultRefreshHours = 24
	MaxRefreshHours     = 7 * 24
	maxURLLen           = 2048
)

// Refresh is how often the import is downloaded again.
func (i Import) Refresh() time.Duration {
	h := i.RefreshHours
	if h == 0 {
		h = DefaultRefreshHours
	}
	return time.Duration(h) * time.Hour
}

// ValidateImportURL accepts https URLs without credentials. The settings
// database is readable by every local user, so a password in the URL would
// leak.
func ValidateImportURL(raw string) error {
	if len(raw) > maxURLLen {
		return fmt.Errorf("import URL longer than %d characters", maxURLLen)
	}
	u, err := url.Parse(raw)
	switch {
	case err != nil:
		return fmt.Errorf("import URL %q: %v", raw, err)
	case u.Scheme != "https" || u.Host == "":
		return fmt.Errorf("import URL %q: must be https://host/...", raw)
	case u.User != nil:
		return fmt.Errorf("import URL %q: no user or password in the URL (every local user can read the settings)", u.Redacted())
	}
	return nil
}

// Config is the daemon's configuration. Disabled keeps the service running
// with no routes (the menu bar app's off switch).
type Config struct {
	BaseURL  string `json:"base_url,omitempty"`
	Disabled bool   `json:"disabled,omitempty"`
	Lists    []List `json:"lists"`
}

const (
	DefaultBaseURL = "https://github.com/aliraghebi/routing-rules/releases/latest/download"
	maxNameLen     = 64
)

// Default is used when the config file does not exist.
func Default() Config {
	return Config{Lists: []List{{Name: "ir-cidr", Action: rules.Direct}}}
}

var listName = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)

// Validate checks everything that comes from the config file or the socket.
func (c Config) Validate() error {
	if c.BaseURL != "" && !strings.HasPrefix(c.BaseURL, "https://") {
		return errors.New("base_url must be https")
	}
	seen := map[string]bool{}
	for _, l := range c.Lists {
		switch {
		case l.Name == "" || len(l.Name) > maxNameLen || strings.TrimSpace(l.Name) != l.Name:
			return fmt.Errorf("list name %q: 1-%d characters, no leading or trailing spaces", l.Name, maxNameLen)
		case l.Custom && l.Import != nil:
			return fmt.Errorf("list %q: a list is custom or an import, not both", l.Name)
		case !l.Custom && l.Import == nil && !listName.MatchString(l.Name):
			return fmt.Errorf("invalid list name %q", l.Name)
		case !l.Custom && len(l.Entries) > 0:
			return fmt.Errorf("list %q: only custom lists have entries", l.Name)
		case l.Action != rules.Direct && l.Action != rules.Block && l.Action != rules.Tunnel:
			return fmt.Errorf("list %q: action must be direct, block or tunnel, not %q", l.Name, l.Action)
		case l.Tunnel != "" && l.Action != rules.Tunnel:
			return fmt.Errorf("list %q: only a tunnel list can name a tunnel", l.Name)
		case len(l.Tunnel) > maxNameLen || strings.TrimSpace(l.Tunnel) != l.Tunnel:
			return fmt.Errorf("list %q: tunnel name %q: 1-%d characters, no leading or trailing spaces", l.Name, l.Tunnel, maxNameLen)
		case seen[l.Name]:
			return fmt.Errorf("list %q listed twice", l.Name)
		}
		seen[l.Name] = true
		if l.Import != nil {
			if err := ValidateImportURL(l.Import.URL); err != nil {
				return fmt.Errorf("list %q: %w", l.Name, err)
			}
			if h := l.Import.RefreshHours; h < 0 || h > MaxRefreshHours {
				return fmt.Errorf("list %q: refresh_hours must be 1-%d (0 for the default, %d)", l.Name, MaxRefreshHours, DefaultRefreshHours)
			}
		}
		if len(l.Entries) > MaxEntries {
			return fmt.Errorf("list %q has %d lines; the limit is %d entries", l.Name, len(l.Entries), MaxEntries)
		}
		if l.Custom {
			if _, err := rules.ParseEntries(l.Entries); err != nil {
				return fmt.Errorf("list %q: %w", l.Name, err)
			}
		}
	}
	return nil
}

// ListsURL is the release download URL, without a trailing slash.
func (c Config) ListsURL() string {
	if c.BaseURL == "" {
		return DefaultBaseURL
	}
	return strings.TrimSuffix(c.BaseURL, "/")
}
