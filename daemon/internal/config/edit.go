package config

import (
	"fmt"
	"slices"
	"strings"

	"github.com/split-route/core/rules"
)

// Edits on the configured lists. Each returns a new Config (cfg is never
// modified, its slices are not shared) that has passed Validate.

// MaxEntries caps a custom list. Hand-made lists are far smaller; big
// third-party lists belong in imports.
const MaxEntries = 100_000

func (c Config) index(name string) int {
	return slices.IndexFunc(c.Lists, func(l List) bool { return l.Name == name })
}

func (c Config) clone() Config {
	c.Lists = slices.Clone(c.Lists)
	return c
}

func (c Config) find(name string) (Config, int, error) {
	i := c.index(name)
	if i < 0 {
		return c, -1, fmt.Errorf("no list named %q", name)
	}
	return c.clone(), i, nil
}

func (c Config) add(l List) (Config, error) {
	if c.index(l.Name) >= 0 {
		return c, fmt.Errorf("list %q already exists", l.Name)
	}
	c = c.clone()
	c.Lists = append(c.Lists, l)
	return c, c.Validate()
}

// CreateList appends an empty custom list.
func CreateList(c Config, name string, a rules.Action) (Config, error) {
	return c.add(List{Name: name, Action: a, Custom: true})
}

// EnableRelease appends a routing-rules release list. Whether the release
// has it is checked when the lists are downloaded.
func EnableRelease(c Config, name string, a rules.Action) (Config, error) {
	return c.add(List{Name: name, Action: a})
}

// ImportList appends an import of the list at url. It is downloaded by the
// service (or the next `up`).
func ImportList(c Config, name string, a rules.Action, url string) (Config, error) {
	return c.add(List{Name: name, Action: a, Import: &Import{URL: url}})
}

// RemoveList removes a list of any kind.
func RemoveList(c Config, name string) (Config, error) {
	c, i, err := c.find(name)
	if err != nil {
		return c, err
	}
	c.Lists = slices.Delete(c.Lists, i, i+1)
	return c, c.Validate()
}

// RenameList renames a list. Release lists are named by the release, so only
// custom lists and imports can be renamed.
func RenameList(c Config, name, newName string) (Config, error) {
	c, i, err := c.find(name)
	if err != nil {
		return c, err
	}
	if !c.Lists[i].Custom && c.Lists[i].Import == nil {
		return c, fmt.Errorf("%q is a release list; only custom lists and imports can be renamed", name)
	}
	if newName != name && c.index(newName) >= 0 {
		return c, fmt.Errorf("list %q already exists", newName)
	}
	c.Lists[i].Name = newName
	return c, c.Validate()
}

// SetAction changes what happens to a list's traffic. tunnel names the tunnel
// for the tunnel action; empty means the default tunnel, and it must be empty
// for the other actions.
func SetAction(c Config, name string, a rules.Action, tunnel string) (Config, error) {
	c, i, err := c.find(name)
	if err != nil {
		return c, err
	}
	c.Lists[i].Action, c.Lists[i].Tunnel = a, tunnel
	return c, c.Validate()
}

// MoveList moves a list to index pos (0-based) in the config order.
func MoveList(c Config, name string, pos int) (Config, error) {
	c, i, err := c.find(name)
	if err != nil {
		return c, err
	}
	if pos < 0 || pos >= len(c.Lists) {
		return c, fmt.Errorf("position %d is out of range (1-%d)", pos+1, len(c.Lists))
	}
	l := c.Lists[i]
	c.Lists = slices.Insert(slices.Delete(c.Lists, i, i+1), pos, l)
	return c, c.Validate()
}

// EntryEdit reports what AddEntries or RemoveEntries did.
type EntryEdit struct {
	Added      int      `json:"added,omitempty"`
	Duplicates int      `json:"duplicates,omitempty"` // already in the list
	Removed    int      `json:"removed,omitempty"`
	NotFound   []string `json:"not_found,omitempty"`
	Skipped    int      `json:"skipped,omitempty"` // lines of an imported text that aren't entries
}

func (c Config) custom(name string) (Config, int, error) {
	c, i, err := c.find(name)
	switch {
	case err != nil:
	case c.Lists[i].Import != nil:
		err = fmt.Errorf("%q is an import; its entries come from %s", name, c.Lists[i].Import.URL)
	case !c.Lists[i].Custom:
		err = fmt.Errorf("%q is a release list; entries can only be changed in custom lists", name)
	}
	return c, i, err
}

// AddEntries appends entries (rules.ParseEntry syntax) to a custom list in
// canonical form. Entries already in the list are skipped; "#" lines are
// notes for the entry after them. One invalid entry fails the whole edit.
func AddEntries(c Config, name string, lines []string) (Config, EntryEdit, error) {
	var ed EntryEdit
	c, i, err := c.custom(name)
	if err != nil {
		return c, ed, err
	}
	have := map[string]bool{}
	for _, l := range c.Lists[i].Entries {
		if e, err := rules.ParseEntry(l); err == nil {
			have[e.String()] = true
		}
	}
	entries := slices.Clone(c.Lists[i].Entries)
	var notes []string
	for _, l := range lines {
		l = strings.TrimSpace(l)
		switch {
		case l == "":
		case strings.HasPrefix(l, "#"):
			notes = append(notes, l)
		default:
			e, err := rules.ParseEntry(l)
			if err != nil {
				return c, EntryEdit{}, err
			}
			if have[e.String()] {
				ed.Duplicates++
				notes = nil
				continue
			}
			have[e.String()] = true
			entries = append(append(entries, notes...), e.String())
			notes = nil
			ed.Added++
		}
	}
	if len(have) > MaxEntries {
		return c, EntryEdit{}, fmt.Errorf("list %q would have %d entries; the limit is %d (use an import for big lists)", name, len(have), MaxEntries)
	}
	c.Lists[i].Entries = entries
	return c, ed, c.Validate()
}

// SetEntries replaces a custom list's entries, as AddEntries would add them
// to an empty list (canonical form, duplicates dropped, one invalid entry
// fails the edit). "#" notes after the last entry are kept at the end.
func SetEntries(c Config, name string, lines []string) (Config, EntryEdit, error) {
	c, i, err := c.custom(name)
	if err != nil {
		return c, EntryEdit{}, err
	}
	c.Lists[i].Entries = nil
	c, ed, err := AddEntries(c, name, lines)
	if err != nil {
		return c, ed, err
	}
	var tail []string
	for _, l := range slices.Backward(lines) {
		l = strings.TrimSpace(l)
		if l == "" {
			continue
		}
		if !strings.HasPrefix(l, "#") {
			break
		}
		tail = append([]string{l}, tail...)
	}
	c.Lists[i].Entries = append(c.Lists[i].Entries, tail...)
	return c, ed, c.Validate()
}

// RemoveEntries removes entries from a custom list, matched in canonical form
// (so "Example.COM" removes "example.com"), together with the "#" notes just
// before them.
func RemoveEntries(c Config, name string, lines []string) (Config, EntryEdit, error) {
	var ed EntryEdit
	c, i, err := c.custom(name)
	if err != nil {
		return c, ed, err
	}
	drop := map[string]string{} // canonical → as given
	for _, l := range lines {
		l = strings.TrimSpace(l)
		if l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		e, err := rules.ParseEntry(l)
		if err != nil {
			return c, EntryEdit{}, err
		}
		drop[e.String()] = l
	}
	var out, notes []string
	for _, l := range c.Lists[i].Entries {
		t := strings.TrimSpace(l)
		if strings.HasPrefix(t, "#") || t == "" {
			notes = append(notes, l)
			continue
		}
		if e, err := rules.ParseEntry(t); err == nil {
			if _, ok := drop[e.String()]; ok {
				delete(drop, e.String())
				ed.Removed++
				notes = nil
				continue
			}
		}
		out = append(append(out, notes...), l)
		notes = nil
	}
	out = append(out, notes...)
	for _, given := range drop {
		ed.NotFound = append(ed.NotFound, given)
	}
	slices.Sort(ed.NotFound)
	c.Lists[i].Entries = out
	return c, ed, c.Validate()
}
