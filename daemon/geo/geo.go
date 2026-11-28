// Package geo says which country an IP address is in, from a database embedded in the service (DB-IP Lite Country, see
// NOTICE). Nothing is downloaded and nothing is asked of a third party: a server's address never leaves this Mac.
package geo

import (
	"bytes"
	"compress/gzip"
	_ "embed"
	"io"
	"net"
	"net/netip"

	"github.com/oschwald/maxminddb-golang"
)

//go:embed dbip-country-lite.mmdb.gz
var dbGz []byte

// DB is the opened database. It holds the unpacked file (about 8 MB): open it for a batch of lookups and close it.
type DB struct{ r *maxminddb.Reader }

// Open unpacks the embedded database in memory.
func Open() (*DB, error) {
	zr, err := gzip.NewReader(bytes.NewReader(dbGz))
	if err != nil {
		return nil, err
	}
	raw, err := io.ReadAll(zr)
	if err != nil {
		return nil, err
	}
	r, err := maxminddb.FromBytes(raw)
	if err != nil {
		return nil, err
	}
	return &DB{r: r}, nil
}

func (d *DB) Close() { _ = d.r.Close() }

// CDN is what Country answers for an address behind Cloudflare: not a country (XC is in the range ISO leaves for private use,
// so it can't be one), so the app shows a cloud and not a flag.
const CDN = "XC"

// Country is the two-letter code of the country `ip` is in. It is CDN for a Cloudflare address (the edge is not the server),
// and "" for what says nothing about where a server is: an address that isn't public (a poisoned or private answer) and
// one the database doesn't know.
func (d *DB) Country(ip netip.Addr) string {
	ip = ip.Unmap()
	if !public(ip) {
		return ""
	}
	if cdn(ip) {
		return CDN
	}
	var rec struct {
		Country struct {
			ISO string `maxminddb:"iso_code"`
		} `maxminddb:"country"`
	}
	if err := d.r.Lookup(net.IP(ip.AsSlice()), &rec); err != nil || !validCode(rec.Country.ISO) {
		return ""
	}
	return rec.Country.ISO
}

func validCode(s string) bool {
	return len(s) == 2 && s[0] >= 'A' && s[0] <= 'Z' && s[1] >= 'A' && s[1] <= 'Z' && s != "ZZ"
}

var bogons = prefixes(
	"0.0.0.0/8", "100.64.0.0/10", "192.0.0.0/24", "192.0.2.0/24", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "240.0.0.0/4",
	"2001:db8::/32", "64:ff9b::/96",
)

// public reports whether ip could be a server on the internet.
func public(ip netip.Addr) bool {
	if !ip.IsValid() || !ip.IsGlobalUnicast() || ip.IsPrivate() {
		return false
	}
	return !inAny(bogons, ip)
}

// cloudflare is Cloudflare's published address ranges (https://www.cloudflare.com/ips/), as of 2026-11. A server behind
// them is reached through an edge that can be anywhere; its own country is not in the address.
var cloudflare = prefixes(
	"173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22", "141.101.64.0/18", "108.162.192.0/18",
	"190.93.240.0/20", "188.114.96.0/20", "197.234.240.0/22", "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
	"104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22",
	"2400:cb00::/32", "2606:4700::/32", "2803:f800::/32", "2405:b500::/32", "2405:8100::/32", "2a06:98c0::/29", "2c0f:f248::/32",
)

func cdn(ip netip.Addr) bool { return inAny(cloudflare, ip) }

func prefixes(s ...string) []netip.Prefix {
	out := make([]netip.Prefix, len(s))
	for i, p := range s {
		out[i] = netip.MustParsePrefix(p)
	}
	return out
}

func inAny(ps []netip.Prefix, ip netip.Addr) bool {
	for _, p := range ps {
		if p.Contains(ip) {
			return true
		}
	}
	return false
}
