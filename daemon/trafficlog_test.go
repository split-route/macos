package main

import (
	"testing"
	"time"

	"github.com/split-route/core"
)

func at(sec int64) time.Time { return time.Unix(sec, 0) }

// What came in is put in the bucket of the time it came, with the delta since the last sample of the same engine start.
func TestTrafficLogBucketsByTimeAndAddsOnlyWhatIsNew(t *testing.T) {
	l := newTrafficLog()
	start := time.UnixMilli(1_000)
	base := int64(3000) // bucket 10 starts at second 3000
	l.add(at(base+10), core.Stats{Since: start, DirectDown: 100, ProxyDown: 1000, ProxyUp: 50, PeakDown: 400})
	l.add(at(base+11), core.Stats{Since: start, DirectDown: 130, ProxyDown: 1600, ProxyUp: 50, PeakDown: 700, PeakUp: 9})
	l.add(at(base+301), core.Stats{Since: start, DirectDown: 130, ProxyDown: 1700, ProxyUp: 80, PeakDown: 100}) // the next bucket
	got := l.since(0)
	if len(got) != 2 || got[0].Bucket != 10 || got[1].Bucket != 11 {
		t.Fatalf("%+v", got)
	}
	if b := got[0]; b.DirectDown != 130 || b.ProxyDown != 1600 || b.ProxyUp != 50 || b.PeakDown != 700 || b.PeakUp != 9 {
		t.Errorf("first bucket: %+v (the totals add up to the counters; the peak is the highest)", b)
	}
	if b := got[1]; b.DirectDown != 0 || b.ProxyDown != 100 || b.ProxyUp != 30 || b.PeakDown != 100 {
		t.Errorf("second bucket: %+v (only what came after the first)", b)
	}
	if n := len(l.since(11)); n != 1 {
		t.Errorf("from bucket 11: %d buckets", n)
	}
}

// A new engine start counts from zero; a counter below the last (it can't happen in one start) adds nothing, never a negative.
func TestTrafficLogHandlesAnEngineRestartAndNeverGoesNegative(t *testing.T) {
	l := newTrafficLog()
	l.add(at(3000), core.Stats{Since: time.UnixMilli(1), ProxyDown: 9_000})
	l.add(at(3001), core.Stats{Since: time.UnixMilli(2), ProxyDown: 40}) // restarted: 40 is new
	l.add(at(3002), core.Stats{Since: time.UnixMilli(2), ProxyDown: 10}) // below the last: nothing
	if b := l.since(0)[0]; b.ProxyDown != 9_040 {
		t.Errorf("%d, want 9040", b.ProxyDown)
	}
}

// A period with no samples (the engine off, recording off) leaves no buckets; the same start carries on from where it was.
func TestTrafficLogHasNoBucketsForTimeWithoutSamples(t *testing.T) {
	l := newTrafficLog()
	start := time.UnixMilli(5)
	l.add(at(3000), core.Stats{Since: start, ProxyDown: 100})
	l.add(at(3000+3*300), core.Stats{Since: start, ProxyDown: 150}) // 15 minutes later: only 50 more
	got := l.since(0)
	if len(got) != 2 || got[0].Bucket != 10 || got[1].Bucket != 13 || got[1].ProxyDown != 50 {
		t.Errorf("%+v", got)
	}
}

func TestTrafficLogForgetsWhatIsOlderThan92Days(t *testing.T) {
	l := newTrafficLog()
	now := at(1_800_000_000)
	l.add(now.Add(-93*24*time.Hour), core.Stats{Since: time.UnixMilli(1), ProxyDown: 1})
	l.add(now.Add(-91*24*time.Hour), core.Stats{Since: time.UnixMilli(1), ProxyDown: 3})
	l.prune(now)
	got := l.since(0)
	if len(got) != 1 || got[0].ProxyDown != 2 {
		t.Errorf("%+v", got)
	}
}
