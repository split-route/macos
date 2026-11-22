//go:build darwin || linux

// Downloading imports.

package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"time"

	"github.com/split-route/core/lists"
	"github.com/split-route/core/rules"
	"github.com/split-route/macos/daemon/internal/store"
)

// importEntries reads an import's downloaded entries, with a warning when it
// has none yet or its last download failed.
func (a *app) importEntries(name string) (rules.Entries, string, error) {
	s, err := a.settings()
	if err != nil {
		return rules.Entries{}, "", err
	}
	es, err := s.ImportEntries(name)
	if err != nil {
		return rules.Entries{}, "", err
	}
	sts, err := s.Imports()
	if err != nil {
		return rules.Entries{}, "", err
	}
	for _, st := range sts {
		switch {
		case st.Name != name:
		case st.FetchedAt.IsZero() && st.LastError != "":
			return es, fmt.Sprintf("import %s: not downloaded: %s", name, st.LastError), nil
		case st.FetchedAt.IsZero():
			return es, fmt.Sprintf("import %s: not downloaded yet", name), nil
		case st.LastError != "":
			return es, fmt.Sprintf("import %s: last download failed (%s); using the copy from %s", name, st.LastError, st.FetchedAt.Local().Format(time.DateTime)), nil
		}
	}
	return es, "", nil
}

// refreshImports downloads every import that is due and returns warnings for
// the ones that failed. A failure keeps the import's last good entries.
func (a *app) refreshImports(ctx context.Context) []string {
	s, err := a.settings()
	if err != nil {
		return nil // reported by the config read that follows
	}
	sts, err := s.Imports()
	if err != nil {
		return []string{fmt.Sprintf("imports: %v", err)}
	}
	var warn []string
	now := time.Now()
	for _, st := range sts {
		if !st.Due(now) {
			continue
		}
		if err := a.downloadImport(ctx, s, st); err != nil {
			if errors.Is(err, store.ErrImportChanged) {
				continue // removed or re-pointed meanwhile; the next pass handles it
			}
			warn = append(warn, fmt.Sprintf("import %s: %v (keeping the last good copy)", st.Name, err))
		}
	}
	return warn
}

func (a *app) downloadImport(ctx context.Context, s *store.Store, st store.ImportState) error {
	f, err := lists.FetchImport(ctx, a.httpClient, st.URL, st.ETag, st.LastModified)
	if err == nil && !f.NotModified {
		sum := sha256.Sum256(f.Body)
		hash := hex.EncodeToString(sum[:])
		if hash == st.SHA256 && st.Entries > 0 {
			f.NotModified = true // same bytes; skip parsing and rewriting
		} else {
			var d store.Download
			var ps lists.Stats
			d.Entries, ps, err = lists.ParseText(f.Body)
			if err == nil {
				n := len(d.Entries.V4) + len(d.Entries.V6) + len(d.Entries.Domains) + len(d.Entries.Suffixes) + len(d.Entries.ASNs)
				if err = lists.CheckImport(n, ps); err == nil {
					d.ETag, d.LastModified, d.SHA256 = f.ETag, f.LastModified, hash
					d.Skipped = ps.Reserved + ps.Invalid + ps.Other
					if err = s.SaveDownload(st.Name, st.URL, d); err == nil {
						log.Printf("import %s: %d entries (%d lines skipped)", st.Name, n, d.Skipped)
						return nil
					}
					if errors.Is(err, store.ErrImportChanged) {
						return err
					}
				}
			}
		}
	}
	msg := ""
	if err != nil {
		msg = err.Error()
	}
	if merr := s.MarkChecked(st.Name, st.URL, f.ETag, f.LastModified, msg); merr != nil && err == nil {
		err = merr
	}
	return err
}

// importsDue reports whether a refresh pass should run now.
func (a *app) importsDue() bool {
	s, err := a.settings()
	if err != nil {
		return false
	}
	due, err := s.ImportsDue(time.Now())
	if err != nil {
		log.Printf("warning: imports: %v", err)
	}
	return due
}
