//go:build darwin || linux

package main

import (
	"fmt"
	"path/filepath"

	"github.com/split-route/core/lists"
	"github.com/split-route/core/rules"
	"github.com/split-route/macos/daemon/internal/config"
)

// listData is one list's entries.
type listData struct {
	es rules.Entries
}

func entryCount(es rules.Entries) int {
	return len(es.V4) + len(es.V6) + len(es.Domains) + len(es.Suffixes)
}

// fetchLists downloads the configured release lists and reads the imports and
// custom lists, keyed by name. A failed release download keeps the last good
// copy (lists.Fetch's cache) and warns; a list that can't be read at all is an error.
func (a *app) fetchLists(cfg config.Config) (map[string]listData, []string, error) {
	var names, warn []string
	data := map[string]listData{}
	for _, l := range cfg.Lists {
		switch {
		case l.Import != nil:
			es, w, err := a.importEntries(l.Name)
			if err != nil {
				return nil, warn, err
			}
			if w != "" {
				warn = append(warn, w)
			}
			data[l.Name] = listData{es: es}
		case l.Custom:
			es, err := rules.ParseEntries(l.Entries)
			if err != nil {
				return nil, nil, err // validated on load; unreachable
			}
			data[l.Name] = listData{es: es}
		default:
			names = append(names, l.Name)
		}
	}
	files, fwarn, err := lists.Fetch(cfg.ListsURL(), filepath.Join(a.stateDir, "lists"), names, true)
	warn = append(warn, fwarn...)
	if err != nil {
		return nil, warn, err
	}
	for _, n := range names {
		es, _, err := lists.Parse(files[n])
		if err != nil {
			return nil, warn, fmt.Errorf("%s.list: %w", n, err)
		}
		data[n] = listData{es: es}
	}
	return data, warn, nil
}
