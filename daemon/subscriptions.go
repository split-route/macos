//go:build darwin || linux

// Tunnels from share links and subscriptions. A subscription is a URL whose
// body lists many nodes; it is kept (the URL in a root-only file, the nodes as
// tunnels in their own group) so it can be updated later.

package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/split-route/core"
	"github.com/split-route/core/importers/links"
	"github.com/split-route/core/lists"
	"github.com/split-route/macos/daemon/internal/api"
	"github.com/split-route/macos/daemon/internal/store"
)

// A subscription body is a list of links: a few hundred KB at most. The
// downloads of lists allow far more; a body this large is not a subscription.
const maxSubscriptionBody = 8 << 20

func (a *app) subscriptionsDir() string { return filepath.Join(a.stateDir, "subscriptions") }

func (a *app) subscriptionURLPath(id int64) string {
	return filepath.Join(a.subscriptionsDir(), strconv.FormatInt(id, 10), "url")
}

// linkOptions reads a link tunnel's options, checks them against the hash stored
// at import, and asks the core again whether it can run them.
func (a *app) linkOptions(t store.Tunnel) (json.RawMessage, error) {
	data, err := os.ReadFile(a.optionsPath(t.ID))
	if err != nil {
		return nil, fmt.Errorf("options: %w", err)
	}
	if sum := sha256.Sum256(data); hex.EncodeToString(sum[:]) != t.ProfileSHA256 {
		return nil, errors.New("the stored options changed since they were imported; import the tunnel again")
	}
	if err := core.CheckTunnel(t.Kind, data); err != nil {
		return nil, err
	}
	return data, nil
}

// looksLikeURL is a pasted address: one word starting with http:// or https://.
func looksLikeURL(s string) bool {
	return !strings.ContainsAny(s, " \t\r\n") && (strings.HasPrefix(s, "https://") || strings.HasPrefix(s, "http://"))
}

// checkSubscriptionURL refuses what must not be fetched. A subscription URL
// carries a token, so it must not travel in clear; and no message that comes
// back from here repeats it.
func checkSubscriptionURL(raw string) (*url.URL, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return nil, errors.New("that is not a web address")
	}
	if u.Scheme != "https" {
		return nil, errors.New("subscriptions must use https:// (the address carries your token)")
	}
	if u.User != nil {
		return nil, errors.New("put the token in the address path or query, not as a user name and password")
	}
	return u, nil
}

// fetchSubscription downloads a subscription body. Errors name the host and
// never the rest of the address: the path or query is the user's token, and
// these errors reach the log and the app.
func (a *app) fetchSubscription(ctx context.Context, u *url.URL) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, errors.New("that is not a web address")
	}
	// Panels pick the format by User-Agent: a generic one gets the link list.
	req.Header.Set("User-Agent", lists.UserAgent)
	resp, err := a.httpClient.Do(req)
	if err != nil {
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err // *url.Error holds the whole URL
		}
		return nil, fmt.Errorf("could not download from %s: %v", u.Hostname(), redactURLs(err.Error()))
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s answered HTTP %d", u.Hostname(), resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxSubscriptionBody+1))
	if err != nil {
		return nil, fmt.Errorf("could not read the answer from %s: %v", u.Hostname(), redactURLs(err.Error()))
	}
	if len(body) > maxSubscriptionBody {
		return nil, fmt.Errorf("the answer from %s is larger than %d MB: not a subscription", u.Hostname(), maxSubscriptionBody>>20)
	}
	return body, nil
}

// redactURLs removes anything that looks like an address from an error text.
func redactURLs(s string) string {
	words := strings.Fields(s)
	for i, w := range words {
		if strings.Contains(w, "://") {
			words[i] = "<address>"
		}
	}
	return strings.Join(words, " ")
}

// TunnelsAdd imports share links, or a subscription: from text (pasted links, a
// subscription body, or one address), or from rawURL, which is kept as a
// subscription named name (default: the address's host). Nodes the engine can't
// run are skipped with a reason; one bad node never rejects the rest.
func (a *app) TunnelsAdd(text []byte, rawURL, name string) (api.AddResult, error) {
	s, err := a.tunnelStore()
	if err != nil {
		return api.AddResult{}, err
	}
	if rawURL == "" {
		if t := strings.TrimSpace(string(text)); looksLikeURL(t) {
			rawURL, text = t, nil
		}
	}
	var u *url.URL
	if rawURL != "" {
		if u, err = checkSubscriptionURL(strings.TrimSpace(rawURL)); err != nil {
			return api.AddResult{}, err
		}
		if text, err = a.fetchSubscription(context.Background(), u); err != nil {
			return api.AddResult{}, err
		}
	}
	parsed, err := links.Parse(text)
	if err != nil {
		if u != nil {
			return api.AddResult{}, fmt.Errorf("%s did not return a subscription: %w", u.Hostname(), err)
		}
		return api.AddResult{}, err
	}
	var res api.AddResult
	for _, sk := range parsed.Skipped {
		res.Skipped = append(res.Skipped, api.Skipped{Label: sk.Label, Reason: sk.Reason})
	}
	type nodeFile struct{ data []byte }
	var rows []store.Tunnel
	var files []nodeFile
	for _, n := range parsed.Nodes {
		data, err := json.Marshal(n.Options)
		if err == nil {
			err = core.CheckTunnel(n.Protocol, data)
		}
		if err != nil {
			res.Skipped = append(res.Skipped, api.Skipped{Label: n.Name, Reason: err.Error()})
			continue
		}
		sum := sha256.Sum256(data)
		rows = append(rows, store.Tunnel{Name: n.Name, Kind: n.Protocol, ProfileSHA256: hex.EncodeToString(sum[:]),
			Remotes: []string{n.Server}, Warning: n.Warning})
		files = append(files, nodeFile{data})
	}
	if len(rows) == 0 {
		return res, nil // nothing to store; the app shows why each was skipped
	}

	tunnelMu.Lock()
	defer tunnelMu.Unlock()
	var sub store.Subscription
	var added []store.Tunnel
	if u != nil {
		if name == "" {
			name = u.Hostname()
		}
		sub, added, err = s.AddSubscription(name, rows)
	} else {
		added, err = s.AddTunnels(rows)
	}
	if err != nil {
		return api.AddResult{}, err
	}
	undo := func() {
		for _, t := range added {
			_ = os.RemoveAll(filepath.Dir(a.optionsPath(t.ID)))
		}
		if sub.ID != 0 {
			_ = os.RemoveAll(filepath.Dir(a.subscriptionURLPath(sub.ID)))
			_ = s.RemoveSubscription(sub.ID)
			return
		}
		for _, t := range added {
			_ = s.RemoveTunnel(t.ID)
		}
	}
	for i, t := range added {
		if err := a.writeTunnelFile(t.ID, a.optionsPath(t.ID), files[i].data); err != nil {
			undo()
			return api.AddResult{}, err
		}
	}
	if sub.ID != 0 {
		if err := secureDir(a.subscriptionsDir()); err != nil {
			undo()
			return api.AddResult{}, err
		}
		if err := secureDir(filepath.Dir(a.subscriptionURLPath(sub.ID))); err != nil {
			undo()
			return api.AddResult{}, err
		}
		if err := writePrivate(a.subscriptionURLPath(sub.ID), []byte(u.String())); err != nil {
			undo()
			return api.AddResult{}, err
		}
		res.Group = sub.Name
	}
	res.Added = len(added)
	if err := a.reconcile(); err != nil { // the VPN is on: the new tunnels join the engine
		log.Printf("reconcile: %v", err)
	}
	return res, nil
}

// TunnelGroupRemove removes a subscription and its tunnels. It refuses while a
// list uses one of them, and changes nothing then.
func (a *app) TunnelGroupRemove(name string) error {
	s, err := a.tunnelStore()
	if err != nil {
		return err
	}
	tunnelMu.Lock()
	defer tunnelMu.Unlock()
	subs, err := s.Subscriptions()
	if err != nil {
		return err
	}
	var sub *store.Subscription
	for i := range subs {
		if strings.EqualFold(subs[i].Name, name) {
			sub = &subs[i]
		}
	}
	if sub == nil {
		return fmt.Errorf("no subscription named %q", name)
	}
	// Refuse before touching anything: tunnels that lists use stay whole.
	if using, err := s.ListsUsingSubscription(sub.ID); err != nil {
		return err
	} else if len(using) > 0 {
		return store.ErrSubscriptionInUse(using)
	}
	ts, err := s.SubscriptionTunnels(sub.ID)
	if err != nil {
		return err
	}
	var ids []int64
	for _, t := range ts {
		ids = append(ids, t.ID)
	}
	if err := selectedGuard(s, ids...); err != nil {
		return fmt.Errorf("the selected tunnel is in this group, and the VPN is on: select a tunnel outside it or turn the VPN off first")
	}
	for _, t := range ts {
		a.host.forget(tunnelID(t.ID)) // stops wanting it
	}
	// Files first: if one fails the rows stay and the removal can be retried.
	for _, t := range ts {
		if err := os.RemoveAll(filepath.Dir(a.optionsPath(t.ID))); err != nil {
			return err
		}
	}
	if err := os.RemoveAll(filepath.Dir(a.subscriptionURLPath(sub.ID))); err != nil {
		return err
	}
	if err := s.RemoveSubscription(sub.ID); err != nil {
		return err
	}
	return a.reconcile()
}
