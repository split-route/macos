package main

import (
	"context"
	"sort"
	"sync"
	"time"

	"github.com/split-route/core"
	"github.com/split-route/macos/daemon/internal/api"
)

// The traffic log: while recording is on, the service adds what the engine carries to 5-minute buckets, with the time they
// happened, and keeps the last 92 days in memory only (nothing is written to disk). The app asks for the buckets after the last
// one it stored, so a period the app was closed arrives as the buckets it was, not as one lump. A service restart empties the log.

const (
	trafficBucketSeconds = 300
	trafficKeep          = 92 * 24 * time.Hour
)

type trafficLog struct {
	mu      sync.Mutex
	buckets map[int64]*api.TrafficBucket
	last    core.Stats // the counters at the last sample: the delta is what came since (same engine start), or all of it (a new one)
}

func newTrafficLog() *trafficLog { return &trafficLog{buckets: map[int64]*api.TrafficBucket{}} }

func bucketOf(t time.Time) int64 { return t.Unix() / trafficBucketSeconds }

// add puts what came since the last sample into the bucket of `now`. The counters begin at zero when the engine starts, so a new
// start time means all of `st` is new. A counter never goes back within one start; a smaller number adds nothing.
func (l *trafficLog) add(now time.Time, st core.Stats) {
	l.mu.Lock()
	defer l.mu.Unlock()
	prev := l.last
	if !prev.Since.Equal(st.Since) {
		prev = core.Stats{Since: st.Since}
	}
	d := func(a, b int64) int64 { return max(a-b, 0) }
	b := l.buckets[bucketOf(now)]
	if b == nil {
		b = &api.TrafficBucket{Bucket: bucketOf(now)}
		l.buckets[b.Bucket] = b
	}
	b.DirectDown += d(st.DirectDown, prev.DirectDown)
	b.DirectUp += d(st.DirectUp, prev.DirectUp)
	b.ProxyDown += d(st.ProxyDown, prev.ProxyDown)
	b.ProxyUp += d(st.ProxyUp, prev.ProxyUp)
	b.PeakDown = max(b.PeakDown, st.PeakDown)
	b.PeakUp = max(b.PeakUp, st.PeakUp)
	l.last = st
}

// since is the buckets from `bucket` on, oldest first.
func (l *trafficLog) since(bucket int64) []api.TrafficBucket {
	l.mu.Lock()
	defer l.mu.Unlock()
	out := []api.TrafficBucket{}
	for n, b := range l.buckets {
		if n >= bucket {
			out = append(out, *b)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Bucket < out[j].Bucket })
	return out
}

// prune forgets what is older than the 92 days.
func (l *trafficLog) prune(now time.Time) {
	cutoff := bucketOf(now.Add(-trafficKeep))
	l.mu.Lock()
	defer l.mu.Unlock()
	for n := range l.buckets {
		if n < cutoff {
			delete(l.buckets, n)
		}
	}
}

// recordTraffic samples the engine once a second until ctx ends (and drops old buckets every hour). With recording off or the
// engine stopped there is nothing to sample; the last counters are kept, so the same engine start carries on from where it was.
func (a *app) recordTraffic(ctx context.Context) {
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	pruned := time.Now()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-tick.C:
			if st, ok := a.host.engineStats(); ok {
				a.traffic.add(now, st)
			}
			if now.Sub(pruned) > time.Hour {
				a.traffic.prune(now)
				pruned = now
			}
		}
	}
}
