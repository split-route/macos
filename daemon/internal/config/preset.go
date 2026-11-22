package config

import (
	"fmt"

	"github.com/split-route/core/rules"
)

// Preset is a named set of release lists and actions.
type Preset struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Lists []List `json:"lists"`
}

// Presets only use lists that have IPv4 ranges; domain-only lists (ads, nsfw)
// do nothing with routes.
var Presets = []Preset{
	{ID: "iran", Name: "Iran", Lists: []List{
		{Name: "ir-cidr", Action: rules.Direct},
		{Name: "malware", Action: rules.Block},
		{Name: "phishing", Action: rules.Block},
	}},
	{ID: "security", Name: "Block malware and phishing", Lists: []List{
		{Name: "malware", Action: rules.Block},
		{Name: "phishing", Action: rules.Block},
	}},
}

// WithPreset replaces cfg's release lists with the preset's and keeps the
// custom lists and imports, after them.
func WithPreset(cfg Config, id string) (Config, error) {
	for _, p := range Presets {
		if p.ID != id {
			continue
		}
		lists := append([]List{}, p.Lists...)
		for _, l := range cfg.Lists {
			if l.Custom || l.Import != nil {
				lists = append(lists, l)
			}
		}
		cfg.Lists = lists
		return cfg, cfg.Validate()
	}
	return cfg, fmt.Errorf("unknown preset %q", id)
}
