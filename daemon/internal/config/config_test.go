package config

import (
	"reflect"
	"testing"

	"github.com/split-route/core/rules"
)

func TestWithPreset(t *testing.T) {
	custom := List{Name: "Work", Custom: true, Action: rules.Direct, Entries: []string{"203.0.113.0/24"}}
	cfg := Config{Disabled: true, Lists: []List{{Name: "telegram", Action: rules.Direct}, custom}}
	got, err := WithPreset(cfg, "security")
	if err != nil {
		t.Fatal(err)
	}
	want := Config{Disabled: true, Lists: []List{{Name: "malware", Action: rules.Block}, {Name: "phishing", Action: rules.Block}, custom}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v", got)
	}
	if _, err := WithPreset(cfg, "nope"); err == nil {
		t.Error("unknown preset: want error")
	}
	for _, p := range Presets {
		if err := (Config{Lists: p.Lists}).Validate(); err != nil {
			t.Errorf("preset %s: %v", p.ID, err)
		}
	}
}
