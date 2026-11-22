// Package catalog describes the routing-rules release lists for people: titles,
// descriptions and the action most people want. It is content for the app, not
// part of the engine.
package catalog

import "github.com/split-route/core/rules"

// Info describes a release list for people: the file name stays the list's
// key, the title and description are what the app and CLI show.
type Info struct {
	Name        string       `json:"name"`
	Title       string       `json:"title"`
	Description string       `json:"description"`
	Action      rules.Action `json:"action"` // suggested when adding it
}

// Catalog describes the routing-rules release lists (see its sources.yaml).
// The suggested action is the usual choice from Iran: Block for unwanted
// traffic, Direct for Iranian services, VPN for services that are filtered in
// Iran or refuse Iranian addresses (VPN keeps them on the tunnel even when a
// Direct list such as a CDN overlaps).
var Catalog = []Info{
	{"ir-cidr", "Iran IP ranges", "Addresses registered in Iran. Direct keeps Iranian sites off the VPN.", rules.Direct},
	{"ir-domains", "Iranian websites", "Iranian domains, .ir and sites hosted in Iran.", rules.Direct},
	{"ir-injected", "Iran block pages", "Addresses Iran's DNS returns for filtered sites.", rules.Block},
	{"private", "Local networks", "Private and special-use ranges, such as your home network.", rules.Direct},
	{"malware", "Malware", "Known malware and command servers.", rules.Block},
	{"phishing", "Phishing", "Sites that imitate others to steal passwords.", rules.Block},
	{"cryptominers", "Crypto miners", "In-browser cryptocurrency miners.", rules.Block},
	{"ads", "Ads and trackers", "Ad networks and trackers, Iranian ones included.", rules.Block},
	{"ads-lite", "Ads and trackers (lite)", "A smaller ads list for low-memory devices.", rules.Block},
	{"tracking", "Device telemetry", "Telemetry from Windows, phones and smart TVs.", rules.Block},
	{"sanctioned", "Sites that block Iran", "Services that refuse Iranian IP addresses.", rules.Tunnel},
	{"social", "Social networks", "Major social networks and their apps.", rules.Tunnel},
	{"nsfw", "Adult content", "Adult websites.", rules.Block},
	{"arvancloud", "ArvanCloud", "Iranian CDN and cloud, including its servers abroad.", rules.Direct},
	{"parspack", "ParsPack", "Iranian hosting and cloud servers.", rules.Direct},
	{"derak", "Derak Cloud", "Iranian CDN.", rules.Direct},
	{"cloudflare", "Cloudflare", "Cloudflare's CDN and services.", rules.Tunnel},
	{"cloudfront", "Amazon CloudFront", "Amazon's CDN.", rules.Tunnel},
	{"fastly", "Fastly", "Fastly's CDN.", rules.Tunnel},
	{"gcore", "Gcore", "Gcore's CDN and cloud.", rules.Tunnel},
	{"telegram", "Telegram", "Telegram's servers.", rules.Tunnel},
	{"tor-exit", "Tor exit nodes", "Addresses Tor traffic leaves the Tor network from.", rules.Tunnel},
	{"netflix", "Netflix", "Netflix's own network.", rules.Tunnel},
}

// Describe returns the catalog entry for name, or one with the bare name as
// its title for a list the release added after this build.
func Describe(name string) Info {
	for _, i := range Catalog {
		if i.Name == name {
			return i
		}
	}
	return Info{Name: name, Title: name, Action: rules.Direct}
}
