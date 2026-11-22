package config

import (
	"reflect"
	"strings"
	"testing"

	"github.com/split-route/core/rules"
)

func base() Config {
	return Config{Lists: []List{
		{Name: "ir-cidr", Action: rules.Direct},
		{Name: "Work", Custom: true, Action: rules.Direct, Entries: []string{"# office", "203.0.113.7", "example.com"}},
		{Name: "malware", Action: rules.Block},
	}}
}

func names(c Config) string {
	var n []string
	for _, l := range c.Lists {
		n = append(n, l.Name)
	}
	return strings.Join(n, ",")
}

func TestListEdits(t *testing.T) {
	orig := base()
	cases := []struct {
		name string
		edit func(Config) (Config, error)
		want string // list names after, or "" for an expected error
	}{
		{"create", func(c Config) (Config, error) { return CreateList(c, "Home", rules.Block) }, "ir-cidr,Work,malware,Home"},
		{"create duplicate", func(c Config) (Config, error) { return CreateList(c, "Work", rules.Block) }, ""},
		{"create bad action", func(c Config) (Config, error) { return CreateList(c, "Home", "teleport") }, ""},
		{"create padded name", func(c Config) (Config, error) { return CreateList(c, " Home", rules.Direct) }, ""},
		{"enable release", func(c Config) (Config, error) { return EnableRelease(c, "telegram", rules.Tunnel) }, "ir-cidr,Work,malware,telegram"},
		{"enable bad release name", func(c Config) (Config, error) { return EnableRelease(c, "Telegram!", rules.Tunnel) }, ""},
		{"remove", func(c Config) (Config, error) { return RemoveList(c, "ir-cidr") }, "Work,malware"},
		{"remove missing", func(c Config) (Config, error) { return RemoveList(c, "nope") }, ""},
		{"rename", func(c Config) (Config, error) { return RenameList(c, "Work", "Office") }, "ir-cidr,Office,malware"},
		{"rename to self", func(c Config) (Config, error) { return RenameList(c, "Work", "Work") }, "ir-cidr,Work,malware"},
		{"rename onto another", func(c Config) (Config, error) { return RenameList(c, "Work", "malware") }, ""},
		{"rename release", func(c Config) (Config, error) { return RenameList(c, "malware", "bad") }, ""},
		{"move to front", func(c Config) (Config, error) { return MoveList(c, "malware", 0) }, "malware,ir-cidr,Work"},
		{"move to end", func(c Config) (Config, error) { return MoveList(c, "ir-cidr", 2) }, "Work,malware,ir-cidr"},
		{"move out of range", func(c Config) (Config, error) { return MoveList(c, "ir-cidr", 3) }, ""},
		{"move negative", func(c Config) (Config, error) { return MoveList(c, "ir-cidr", -1) }, ""},
		{"set action", func(c Config) (Config, error) { return SetAction(c, "Work", rules.Block, "") }, "ir-cidr,Work,malware"},
		{"set bad action", func(c Config) (Config, error) { return SetAction(c, "Work", "drop", "") }, ""},
		{"set tunnel", func(c Config) (Config, error) { return SetAction(c, "Work", rules.Tunnel, "Office") }, "ir-cidr,Work,malware"},
		{"tunnel name with another action", func(c Config) (Config, error) { return SetAction(c, "Work", rules.Direct, "Office") }, ""},
		{"tunnel name with spaces", func(c Config) (Config, error) { return SetAction(c, "Work", rules.Tunnel, " Office") }, ""},
	}
	for _, c := range cases {
		got, err := c.edit(orig)
		switch {
		case c.want == "" && err == nil:
			t.Errorf("%s: want error, got %s", c.name, names(got))
		case c.want != "" && (err != nil || names(got) != c.want):
			t.Errorf("%s: got %s, %v; want %s", c.name, names(got), err, c.want)
		}
		if !reflect.DeepEqual(orig, base()) {
			t.Fatalf("%s modified its input", c.name)
		}
	}
	if got, _ := SetAction(orig, "Work", rules.Block, ""); got.Lists[1].Action != rules.Block {
		t.Error("set action had no effect")
	}
}

func TestAddEntries(t *testing.T) {
	orig := base()
	got, ed, err := AddEntries(orig, "Work", []string{"# lab", "198.51.100.9/24", "Example.COM", "203.0.113.7/32", "", "AS13335"})
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(ed, EntryEdit{Added: 2, Duplicates: 2}) {
		t.Errorf("edit %+v", ed)
	}
	want := []string{"# office", "203.0.113.7", "example.com", "# lab", "198.51.100.0/24", "AS13335"}
	if !reflect.DeepEqual(got.Lists[1].Entries, want) {
		t.Errorf("entries %q", got.Lists[1].Entries)
	}
	if !reflect.DeepEqual(orig, base()) {
		t.Fatal("modified its input")
	}
	for _, bad := range []struct {
		list  string
		lines []string
	}{
		{"Work", []string{"198.51.100.0/24", "10.0.0.1"}}, // one bad entry fails all
		{"ir-cidr", []string{"198.51.100.0/24"}},          // release list
		{"nope", []string{"198.51.100.0/24"}},
	} {
		if _, _, err := AddEntries(orig, bad.list, bad.lines); err == nil {
			t.Errorf("%s %q: want error", bad.list, bad.lines)
		}
	}
	if !reflect.DeepEqual(orig, base()) {
		t.Fatal("failed edit modified its input")
	}
}

func TestAddEntriesCap(t *testing.T) {
	c, _ := CreateList(Config{}, "big", rules.Block)
	lines := make([]string, 0, MaxEntries+1)
	for i := range MaxEntries + 1 {
		lines = append(lines, "h"+strings.Repeat("a", i%5)+string(rune('a'+i%26))+itoa(i)+".example.com")
	}
	if _, _, err := AddEntries(c, "big", lines); err == nil || !strings.Contains(err.Error(), "limit") {
		t.Fatalf("over the cap: %v", err)
	}
	if _, _, err := AddEntries(c, "big", lines[:MaxEntries]); err != nil {
		t.Fatalf("at the cap: %v", err)
	}
}

func itoa(i int) string {
	s := ""
	for {
		s = string(rune('0'+i%10)) + s
		if i /= 10; i == 0 {
			return s
		}
	}
}

func TestSetEntries(t *testing.T) {
	orig := base()
	got, ed, err := SetEntries(orig, "Work", []string{"# lab", "198.51.100.9/24", "example.com", "Example.COM", "", "# todo", "  "})
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(ed, EntryEdit{Added: 2, Duplicates: 1}) {
		t.Errorf("edit %+v", ed)
	}
	if want := []string{"# lab", "198.51.100.0/24", "example.com", "# todo"}; !reflect.DeepEqual(got.Lists[1].Entries, want) {
		t.Errorf("entries %q", got.Lists[1].Entries)
	}
	if got, _, err := SetEntries(orig, "Work", nil); err != nil || len(got.Lists[1].Entries) != 0 {
		t.Errorf("clear: %q, %v", got.Lists[1].Entries, err)
	}
	for _, bad := range []struct {
		list  string
		lines []string
	}{
		{"Work", []string{"198.51.100.0/24", "10.0.0.1"}},
		{"ir-cidr", []string{"198.51.100.0/24"}},
		{"nope", nil},
	} {
		if _, _, err := SetEntries(orig, bad.list, bad.lines); err == nil {
			t.Errorf("%s %q: want error", bad.list, bad.lines)
		}
	}
	if !reflect.DeepEqual(orig, base()) {
		t.Fatal("modified its input")
	}
}

func TestRemoveEntries(t *testing.T) {
	orig := base()
	got, ed, err := RemoveEntries(orig, "Work", []string{"203.0.113.7/32", "EXAMPLE.org", "# ignored"})
	if err != nil {
		t.Fatal(err)
	}
	// The removed entry's note goes with it.
	if !reflect.DeepEqual(got.Lists[1].Entries, []string{"example.com"}) {
		t.Errorf("entries %q", got.Lists[1].Entries)
	}
	if ed.Removed != 1 || !reflect.DeepEqual(ed.NotFound, []string{"EXAMPLE.org"}) {
		t.Errorf("edit %+v", ed)
	}
	if !reflect.DeepEqual(orig, base()) {
		t.Fatal("modified its input")
	}
	// Trailing notes stay.
	c := Config{Lists: []List{{Name: "x", Custom: true, Action: rules.Block, Entries: []string{"203.0.113.7", "# end"}}}}
	if got, _, _ := RemoveEntries(c, "x", []string{"203.0.113.7"}); !reflect.DeepEqual(got.Lists[0].Entries, []string{"# end"}) {
		t.Errorf("trailing note: %q", got.Lists[0].Entries)
	}
	if _, _, err := RemoveEntries(orig, "Work", []string{"not valid!"}); err == nil {
		t.Error("invalid entry: want error")
	}
	if _, _, err := RemoveEntries(orig, "malware", []string{"203.0.113.7"}); err == nil {
		t.Error("release list: want error")
	}
}
