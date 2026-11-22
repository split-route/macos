package store

import (
	"errors"
	"net/netip"
	"reflect"
	"testing"
	"time"

	"github.com/split-route/core/rules"
	"github.com/split-route/macos/daemon/internal/config"
)

const adsURL = "https://example.com/ads.txt"

func withImport(t *testing.T) *Store {
	t.Helper()
	s, _ := openTemp(t)
	cfg := config.Config{Lists: []config.List{
		{Name: "Work", Custom: true, Action: rules.Direct, Entries: []string{"203.0.113.7"}},
		{Name: "Ads", Action: rules.Block, Import: &config.Import{URL: adsURL}},
	}}
	if _, err := s.Init(cfg, ""); err != nil {
		t.Fatal(err)
	}
	return s
}

func download(n int) Download {
	var es rules.Entries
	for i := range n {
		es.Add(rules.Entry{Kind: rules.Domain, Name: "h" + itoa(i) + ".example.com"})
	}
	es.Add(rules.Entry{Kind: rules.CIDR, Prefix: netip.MustParsePrefix("198.51.100.0/24")})
	es.Add(rules.Entry{Kind: rules.DomainSuffix, Name: "ads.example"})
	es.Add(rules.Entry{Kind: rules.ASN, AS: 13335})
	return Download{ETag: `"v1"`, SHA256: "abc", Entries: es, Skipped: 2}
}

func TestImportLifecycle(t *testing.T) {
	s := withImport(t)
	cfg, err := s.Config()
	if err != nil || cfg.Lists[1].Import == nil || cfg.Lists[1].Import.URL != adsURL || cfg.Lists[1].Entries != nil {
		t.Fatalf("config %+v, %v", cfg, err)
	}
	sts, _ := s.Imports()
	if len(sts) != 1 || sts[0].Entries != 0 || !sts[0].Due(time.Now()) || sts[0].Refresh != 24*time.Hour {
		t.Fatalf("new import %+v", sts)
	}

	if err := s.SaveDownload("Ads", adsURL, download(3)); err != nil {
		t.Fatal(err)
	}
	es, err := s.ImportEntries("Ads")
	if err != nil || len(es.Domains) != 3 || len(es.V4) != 1 || len(es.Suffixes) != 1 || len(es.ASNs) != 1 {
		t.Fatalf("entries %+v, %v", es, err)
	}
	sts, _ = s.Imports()
	if st := sts[0]; st.Entries != 6 || st.ETag != `"v1"` || st.Skipped != 2 || st.FetchedAt.IsZero() || st.Due(time.Now()) {
		t.Fatalf("after download %+v", st)
	}

	// Config edits leave the import's entries alone.
	if _, err := s.Update(func(c config.Config) (config.Config, error) {
		return config.SetAction(c, "Ads", rules.Direct, "")
	}); err != nil {
		t.Fatal(err)
	}
	if c, _ := s.Config(); len(c.Lists[0].Entries) != 1 || c.Lists[1].Entries != nil {
		t.Fatalf("custom entries lost or import entries leaked into config: %+v", c)
	}
	if es, _ := s.ImportEntries("Ads"); len(es.Domains) != 3 {
		t.Fatal("config edit dropped import entries")
	}

	// A failure keeps the last good entries and retries sooner.
	if err := s.MarkChecked("Ads", adsURL, "", "", "GET: 503"); err != nil {
		t.Fatal(err)
	}
	sts, _ = s.Imports()
	if st := sts[0]; st.LastError != "GET: 503" || st.Entries != 6 || st.ETag != `"v1"` ||
		st.Due(time.Now()) || !st.Due(time.Now().Add(RetryAfterError)) {
		t.Fatalf("after failure %+v", st)
	}
	// Not modified clears the error.
	if err := s.MarkChecked("Ads", adsURL, `"v2"`, "", ""); err != nil {
		t.Fatal(err)
	}
	if sts, _ = s.Imports(); sts[0].LastError != "" || sts[0].ETag != `"v2"` {
		t.Fatalf("after 304 %+v", sts[0])
	}

	// Force.
	if err := s.ForceImport("Ads"); err != nil {
		t.Fatal(err)
	}
	if sts, _ = s.Imports(); !sts[0].Due(time.Now()) {
		t.Fatal("forced import not due")
	}
	if err := s.ForceImport("Work"); err == nil {
		t.Fatal("forced a custom list")
	}

	// A download from the old URL after a URL change is discarded; the new URL
	// starts empty and due.
	const newURL = "https://example.org/ads.txt"
	if _, err := s.Update(func(c config.Config) (config.Config, error) {
		c.Lists[1].Import = &config.Import{URL: newURL, RefreshHours: 6}
		return c, nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.SaveDownload("Ads", adsURL, download(1)); !errors.Is(err, ErrImportChanged) {
		t.Fatalf("stale download: %v", err)
	}
	sts, _ = s.Imports()
	if st := sts[0]; st.URL != newURL || st.Entries != 0 || st.ETag != "" || !st.Due(time.Now()) || st.Refresh != 6*time.Hour {
		t.Fatalf("after URL change %+v", st)
	}

	// Removing the list removes its entries and source.
	if err := s.SaveDownload("Ads", newURL, download(2)); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Update(func(c config.Config) (config.Config, error) { return config.RemoveList(c, "Ads") }); err != nil {
		t.Fatal(err)
	}
	var n int
	s.db.QueryRow("SELECT (SELECT count(*) FROM entries) + (SELECT count(*) FROM import_sources)").Scan(&n)
	if n != 1 { // Work's one entry
		t.Fatalf("%d rows left", n)
	}
	if err := s.SaveDownload("Ads", newURL, download(1)); !errors.Is(err, ErrImportChanged) {
		t.Fatalf("download for a removed import: %v", err)
	}
}

// A custom list turned into an import (same name) drops its entries; an
// import turned custom drops its source.
func TestImportKindChange(t *testing.T) {
	s := withImport(t)
	if err := s.SaveDownload("Ads", adsURL, download(2)); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Update(func(c config.Config) (config.Config, error) {
		c.Lists[0] = config.List{Name: "Work", Action: rules.Block, Import: &config.Import{URL: adsURL}}
		c.Lists[1] = config.List{Name: "Ads", Custom: true, Action: rules.Block, Entries: []string{"example.com"}}
		return c, nil
	}); err != nil {
		t.Fatal(err)
	}
	c, _ := s.Config()
	if c.Lists[0].Import == nil || !reflect.DeepEqual(c.Lists[1].Entries, []string{"example.com"}) {
		t.Fatalf("config %+v", c)
	}
	if es, _ := s.ImportEntries("Work"); len(es.V4) != 0 {
		t.Fatal("custom entries became import entries")
	}
	sts, _ := s.Imports()
	if len(sts) != 1 || sts[0].Name != "Work" {
		t.Fatalf("imports %+v", sts)
	}
}

func TestDue(t *testing.T) {
	now := time.Now()
	for _, c := range []struct {
		st   ImportState
		want bool
	}{
		{ImportState{Refresh: time.Hour}, true},
		{ImportState{Refresh: time.Hour, CheckedAt: now.Add(-59 * time.Minute)}, false},
		{ImportState{Refresh: time.Hour, CheckedAt: now.Add(-time.Hour)}, true},
		{ImportState{Refresh: 24 * time.Hour, CheckedAt: now.Add(-time.Minute), Force: true}, true},
		{ImportState{Refresh: 24 * time.Hour, CheckedAt: now.Add(-14 * time.Minute), LastError: "x"}, false},
		{ImportState{Refresh: 24 * time.Hour, CheckedAt: now.Add(-15 * time.Minute), LastError: "x"}, true},
		{ImportState{Refresh: 5 * time.Minute, CheckedAt: now.Add(-5 * time.Minute), LastError: "x"}, true},
	} {
		if got := c.st.Due(now); got != c.want {
			t.Errorf("%+v: due %v", c.st, got)
		}
	}
}

func TestBigImport(t *testing.T) {
	s := withImport(t)
	start := time.Now()
	if err := s.SaveDownload("Ads", adsURL, download(200_000)); err != nil {
		t.Fatal(err)
	}
	saved := time.Since(start)
	start = time.Now()
	es, err := s.ImportEntries("Ads")
	if err != nil || len(es.Domains) != 200_000 {
		t.Fatalf("%d, %v", len(es.Domains), err)
	}
	t.Logf("200k entries: save %v, read %v", saved, time.Since(start))
}
