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
	"slices"
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
func (a *app) fetchSubscription(ctx context.Context, u *url.URL) ([]byte, *api.Usage, error) {
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, nil, errors.New("that is not a web address")
	}
	// Panels pick the format by User-Agent: a generic one gets the link list.
	req.Header.Set("User-Agent", lists.UserAgent)
	resp, err := a.httpClient.Do(req)
	if err != nil {
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err // *url.Error holds the whole URL
		}
		return nil, nil, fmt.Errorf("could not download from %s: %v", u.Hostname(), redactURLs(err.Error()))
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, nil, fmt.Errorf("%s answered HTTP %d", u.Hostname(), resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxSubscriptionBody+1))
	if err != nil {
		return nil, nil, fmt.Errorf("could not read the answer from %s: %v", u.Hostname(), redactURLs(err.Error()))
	}
	if len(body) > maxSubscriptionBody {
		return nil, nil, fmt.Errorf("the answer from %s is larger than %d MB: not a subscription", u.Hostname(), maxSubscriptionBody>>20)
	}
	return body, parseUserinfo(resp.Header.Get("Subscription-Userinfo")), nil
}

// parseUserinfo reads the Subscription-Userinfo header that panels send:
// "upload=0; download=204300000000; total=400000000000; expire=1780000000".
// nil when there is no usable download or total; bad or negative numbers are ignored.
func parseUserinfo(h string) *api.Usage {
	var u api.Usage
	var seen bool
	for _, part := range strings.Split(h, ";") {
		k, v, ok := strings.Cut(strings.TrimSpace(part), "=")
		if !ok {
			continue
		}
		n, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64)
		if err != nil || n < 0 {
			continue
		}
		switch strings.ToLower(strings.TrimSpace(k)) {
		case "upload":
			u.Upload, seen = n, true
		case "download":
			u.Download, seen = n, true
		case "total":
			u.Total, seen = n, true
		case "expire":
			u.Expire = n
		}
	}
	if !seen {
		return nil
	}
	return &u
}

// writePrivateAtomic replaces path with a root-only file, so a crash never
// leaves half an address.
func writePrivateAtomic(path string, b []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func (a *app) subscriptionInfoPath(id int64) string {
	return filepath.Join(a.subscriptionsDir(), strconv.FormatInt(id, 10), "info.json")
}

// saveUsage keeps what the provider reported; nil removes an older report so a
// stale number is never shown.
func (a *app) saveUsage(id int64, u *api.Usage) {
	path := a.subscriptionInfoPath(id)
	if u == nil {
		_ = os.Remove(path)
		return
	}
	b, _ := json.Marshal(u)
	if err := writePrivateAtomic(path, b); err != nil {
		log.Printf("subscription %d: usage: %v", id, err)
	}
}

func (a *app) loadUsage(id int64) *api.Usage {
	b, err := os.ReadFile(a.subscriptionInfoPath(id))
	if err != nil {
		return nil
	}
	var u api.Usage
	if json.Unmarshal(b, &u) != nil {
		return nil
	}
	return &u
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
	var usage *api.Usage
	if rawURL != "" {
		if u, err = checkSubscriptionURL(strings.TrimSpace(rawURL)); err != nil {
			return api.AddResult{}, err
		}
		if text, usage, err = a.fetchSubscription(context.Background(), u); err != nil {
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
	rows, datas, skipped := prepareNodes(parsed)
	res.Skipped = skipped
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
		if err := a.writeTunnelFile(t.ID, a.optionsPath(t.ID), datas[i]); err != nil {
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
		a.saveUsage(sub.ID, usage)
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
	if err := os.RemoveAll(filepath.Dir(a.subscriptionURLPath(sub.ID))); err != nil { // the url and the usage
		return err
	}
	if err := s.RemoveSubscription(sub.ID); err != nil {
		return err
	}
	return a.reconcile()
}

// prepareNodes checks every parsed node against the engine. Nodes it can't run
// are skipped with a reason; one bad node never rejects the rest. datas[i] is
// the options file of rows[i].
func prepareNodes(parsed links.Result) (rows []store.Tunnel, datas [][]byte, skipped []api.Skipped) {
	for _, sk := range parsed.Skipped {
		skipped = append(skipped, api.Skipped{Label: sk.Label, Reason: sk.Reason})
	}
	for _, n := range parsed.Nodes {
		data, err := json.Marshal(n.Options)
		if err == nil {
			err = core.CheckTunnel(n.Protocol, data)
		}
		if err != nil {
			skipped = append(skipped, api.Skipped{Label: n.Name, Reason: err.Error()})
			continue
		}
		sum := sha256.Sum256(data)
		rows = append(rows, store.Tunnel{Name: n.Name, Kind: n.Protocol, ProfileSHA256: hex.EncodeToString(sum[:]),
			Remotes: []string{n.Server}, Warning: n.Warning})
		datas = append(datas, data)
	}
	return rows, datas, skipped
}

// findSubscription looks a subscription up by name, ignoring case.
func findSubscription(s *store.Store, name string) (store.Subscription, error) {
	subs, err := s.Subscriptions()
	if err != nil {
		return store.Subscription{}, err
	}
	for _, sub := range subs {
		if strings.EqualFold(sub.Name, name) {
			return sub, nil
		}
	}
	return store.Subscription{}, fmt.Errorf("no subscription named %q", name)
}

func (a *app) savedSubscriptionURL(id int64) (*url.URL, error) {
	raw, err := os.ReadFile(a.subscriptionURLPath(id))
	if err != nil {
		return nil, errors.New("the saved address of this subscription can't be read; set it again")
	}
	return checkSubscriptionURL(strings.TrimSpace(string(raw)))
}

// TunnelGroupURL returns the saved address. It carries the user's token; the
// socket is root:admin, like the rest of the control API.
func (a *app) TunnelGroupURL(name string) (string, error) {
	s, err := a.tunnelStore()
	if err != nil {
		return "", err
	}
	sub, err := findSubscription(s, name)
	if err != nil {
		return "", err
	}
	raw, err := os.ReadFile(a.subscriptionURLPath(sub.ID))
	if err != nil {
		return "", errors.New("the saved address of this subscription can't be read")
	}
	return strings.TrimSpace(string(raw)), nil
}

// TunnelGroupEdit renames a subscription and/or replaces its address. The new
// address is checked like a new one but not downloaded: Update does that. A new
// address drops the old usage report and error: they belong to the old one.
func (a *app) TunnelGroupEdit(name, newName, rawURL string) error {
	s, err := a.tunnelStore()
	if err != nil {
		return err
	}
	tunnelMu.Lock()
	defer tunnelMu.Unlock()
	sub, err := findSubscription(s, name)
	if err != nil {
		return err
	}
	var u *url.URL
	if rawURL = strings.TrimSpace(rawURL); rawURL != "" {
		if u, err = checkSubscriptionURL(rawURL); err != nil {
			return err
		}
	}
	newName = strings.TrimSpace(newName)
	rename := newName != "" && newName != sub.Name
	urlPath := a.subscriptionURLPath(sub.ID)
	old, _ := os.ReadFile(urlPath)
	changedURL := u != nil && u.String() != strings.TrimSpace(string(old))
	if changedURL {
		if err := writePrivateAtomic(urlPath, []byte(u.String())); err != nil {
			return err
		}
	}
	if rename {
		if err := s.RenameSubscription(sub.ID, newName); err != nil {
			if changedURL && len(old) > 0 {
				_ = writePrivateAtomic(urlPath, old) // all or nothing
			}
			return err
		}
	}
	if changedURL {
		a.saveUsage(sub.ID, nil)
		_ = s.SetSubscriptionError(sub.ID, "")
	}
	a.wake()
	return nil
}

// TunnelGroupUpdate downloads a subscription again and makes its tunnels match.
// A tunnel the provider still lists keeps its row (so lists and the selection
// stay); new ones are added; dropped ones are removed unless a list uses them or
// they are selected while the VPN is on, which keeps them. A download that
// fails or has no usable node changes nothing and is recorded as the error.
func (a *app) TunnelGroupUpdate(name string) (api.UpdateResult, error) {
	s, err := a.tunnelStore()
	if err != nil {
		return api.UpdateResult{}, err
	}
	// Download without holding the lock: it can take a minute.
	tunnelMu.Lock()
	sub, err := findSubscription(s, name)
	var u *url.URL
	if err == nil {
		u, err = a.savedSubscriptionURL(sub.ID)
	}
	tunnelMu.Unlock()
	if err != nil {
		return api.UpdateResult{}, err
	}
	fail := func(err error) (api.UpdateResult, error) {
		tunnelMu.Lock()
		defer tunnelMu.Unlock()
		if cur, e := a.savedSubscriptionURL(sub.ID); e == nil && cur.String() == u.String() {
			_ = s.SetSubscriptionError(sub.ID, err.Error())
		}
		return api.UpdateResult{}, err
	}
	body, usage, err := a.fetchSubscription(context.Background(), u)
	if err != nil {
		return fail(err)
	}
	parsed, err := links.Parse(body)
	if err != nil {
		return fail(fmt.Errorf("%s did not return a subscription: %w", u.Hostname(), err))
	}
	rows, datas, skipped := prepareNodes(parsed)
	if len(rows) == 0 {
		return fail(fmt.Errorf("%s returned no server this app can run; nothing was changed", u.Hostname()))
	}

	tunnelMu.Lock()
	defer tunnelMu.Unlock()
	// The subscription may have been removed, or its address replaced, during the download.
	subs, err := s.Subscriptions()
	if err != nil {
		return api.UpdateResult{}, err
	}
	found := false
	for _, x := range subs {
		if x.ID == sub.ID {
			found = true
		}
	}
	if !found {
		return api.UpdateResult{}, store.ErrNoSubscription
	}
	if cur, err := a.savedSubscriptionURL(sub.ID); err != nil || cur.String() != u.String() {
		return api.UpdateResult{}, errors.New("the address changed during the download; update again")
	}
	existing, err := s.SubscriptionTunnels(sub.ID)
	if err != nil {
		return api.UpdateResult{}, err
	}
	var sy store.SubscriptionSync
	var res api.UpdateResult
	res.Skipped = skipped

	// Match each node to the tunnel it already is: by name, then by identical options (a renamed
	// tunnel), then by name plus the " N" that an import adds when a name was taken. Names alone
	// would replace every suffixed or renamed tunnel on each update.
	match := make([]int, len(rows)) // index into existing, or -1
	for i := range match {
		match[i] = -1
	}
	used := make([]bool, len(existing))
	pass := func(same func(r store.Tunnel, t store.Tunnel) bool) {
		for i, r := range rows {
			if match[i] >= 0 {
				continue
			}
			for j, t := range existing {
				if !used[j] && same(r, t) {
					match[i], used[j] = j, true
					break
				}
			}
		}
	}
	pass(func(r, t store.Tunnel) bool { return strings.EqualFold(store.CleanName(r.Name), t.Name) })
	pass(func(r, t store.Tunnel) bool { return r.Kind == t.Kind && r.ProfileSHA256 == t.ProfileSHA256 })
	pass(func(r, t store.Tunnel) bool {
		base := strings.ToLower(store.CleanName(r.Name))
		rest, ok := strings.CutPrefix(strings.ToLower(t.Name), base+" ")
		if !ok || rest == "" {
			return false
		}
		_, err := strconv.Atoi(rest)
		return err == nil
	})
	updateData := map[int64][]byte{}
	var addData [][]byte
	for i, r := range rows {
		if j := match[i]; j >= 0 {
			old := existing[j]
			if old.ProfileSHA256 != r.ProfileSHA256 || old.Warning != r.Warning || !slices.Equal(old.Remotes, r.Remotes) {
				r.ID, r.Name = old.ID, old.Name
				sy.Update = append(sy.Update, r)
				updateData[old.ID] = datas[i]
			}
			continue
		}
		sy.Add = append(sy.Add, r)
		addData = append(addData, datas[i])
	}
	for j, t := range existing {
		if used[j] {
			continue
		}
		if using, err := s.ListsUsingTunnel(t.ID); err != nil {
			return api.UpdateResult{}, err
		} else if len(using) > 0 || selectedGuard(s, t.ID) != nil {
			res.Kept++
			continue
		}
		sy.Remove = append(sy.Remove, t.ID)
	}

	// Changed options are written beside the old file and renamed in after the commit, so a failure
	// never leaves a stored hash over a file that doesn't match it.
	newPath := func(id int64) string { return a.optionsPath(id) + ".new" }
	dropNew := func() {
		for id := range updateData {
			_ = os.Remove(newPath(id))
		}
	}
	for id, data := range updateData {
		if err := a.writeTunnelFile(id, newPath(id), data); err != nil {
			dropNew()
			return api.UpdateResult{}, err
		}
	}
	var wrote []int64
	writeFiles := func(added []store.Tunnel) error {
		for i, t := range added {
			wrote = append(wrote, t.ID)
			if err := a.writeTunnelFile(t.ID, a.optionsPath(t.ID), addData[i]); err != nil {
				return err
			}
		}
		return nil
	}
	if _, err := s.SyncSubscription(sub.ID, sy, writeFiles); err != nil {
		dropNew()
		for _, id := range wrote {
			_ = os.RemoveAll(filepath.Dir(a.optionsPath(id)))
		}
		_ = s.SetSubscriptionError(sub.ID, err.Error())
		return api.UpdateResult{}, err
	}
	for id := range updateData {
		if err := os.Rename(newPath(id), a.optionsPath(id)); err != nil {
			log.Printf("tunnel %d: %v", id, err) // the hash check refuses it until the next update
		}
	}
	for _, id := range sy.Remove {
		a.host.forget(tunnelID(id))
		if err := os.RemoveAll(filepath.Dir(a.optionsPath(id))); err != nil {
			log.Printf("tunnel %d: %v", id, err)
		}
	}
	for _, t := range sy.Update {
		a.host.disconnect(tunnelID(t.ID)) // reconcile loads it again with the new options
	}
	a.saveUsage(sub.ID, usage)
	res.Added, res.Updated, res.Removed = len(sy.Add), len(sy.Update), len(sy.Remove)
	if err := a.reconcile(); err != nil {
		log.Printf("reconcile: %v", err)
	}
	return res, nil
}
