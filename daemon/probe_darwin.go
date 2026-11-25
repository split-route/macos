//go:build darwin

package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"net"
	"net/netip"
	"strings"
	"syscall"
	"time"

	"golang.org/x/net/icmp"
	"golang.org/x/net/ipv4"
	"golang.org/x/net/route"
	"golang.org/x/sys/unix"
)

// physicalInterface is the index of the interface the Mac reaches the internet by when the engine's tun is up: the one
// the original default route (0.0.0.0/0 through a gateway) leaves from. The engine's own routes are split in two halves
// (0/1 and 128/1), so this one stays and is told apart by its empty netmask. Tunnel and loopback interfaces don't count.
func physicalInterface() (int, error) {
	rib, err := route.FetchRIB(syscall.AF_UNSPEC, route.RIBTypeRoute, 0)
	if err != nil {
		return 0, err
	}
	msgs, err := route.ParseRIB(route.RIBTypeRoute, rib)
	if err != nil {
		return 0, err
	}
	for _, m := range msgs {
		rm, ok := m.(*route.RouteMessage)
		if !ok || rm.Flags&syscall.RTF_GATEWAY == 0 || len(rm.Addrs) <= syscall.RTAX_NETMASK {
			continue
		}
		dst, ok := rm.Addrs[syscall.RTAX_DST].(*route.Inet4Addr)
		if !ok || dst.IP != [4]byte{} {
			continue
		}
		if mask, ok := rm.Addrs[syscall.RTAX_NETMASK].(*route.Inet4Addr); ok && mask.IP != [4]byte{} {
			continue // a half of the address space, not the default route
		}
		ifi, err := net.InterfaceByIndex(rm.Index)
		if err != nil || ifi.Flags&net.FlagUp == 0 || strings.HasPrefix(ifi.Name, "utun") || ifi.Flags&net.FlagLoopback != 0 {
			continue
		}
		return rm.Index, nil
	}
	return 0, errors.New("no network interface carries the default route")
}

// bindControl binds a socket to the interface (IP_BOUND_IF), so it leaves there whatever the routing table says. Nil (no
// binding) for index 0.
func bindControl(ifIndex int) func(network, address string, c syscall.RawConn) error {
	if ifIndex == 0 {
		return nil
	}
	return func(network, address string, c syscall.RawConn) error {
		var serr error
		if err := c.Control(func(fd uintptr) {
			if strings.HasSuffix(network, "6") {
				serr = unix.SetsockoptInt(int(fd), unix.IPPROTO_IPV6, unix.IPV6_BOUND_IF, ifIndex)
			} else {
				serr = unix.SetsockoptInt(int(fd), unix.IPPROTO_IP, unix.IP_BOUND_IF, ifIndex)
			}
		}); err != nil {
			return err
		}
		return serr
	}
}

// pingOnce sends one ICMP echo to ip over an unprivileged datagram socket and times the reply. The reply is matched by
// a random payload, not the ID (the kernel may rewrite it). A timeout is context.DeadlineExceeded.
func pingOnce(ctx context.Context, ip netip.Addr, bound int) (time.Duration, error) {
	if !ip.Is4() {
		return 0, errors.New("ping works with IPv4 addresses only")
	}
	fd, err := unix.Socket(unix.AF_INET, unix.SOCK_DGRAM, unix.IPPROTO_ICMP)
	if err != nil {
		return 0, err
	}
	defer unix.Close(fd)
	if bound != 0 {
		if err := unix.SetsockoptInt(fd, unix.IPPROTO_IP, unix.IP_BOUND_IF, bound); err != nil {
			return 0, err
		}
	}
	nonce := make([]byte, 8)
	if _, err := rand.Read(nonce); err != nil {
		return 0, err
	}
	b, err := (&icmp.Message{Type: ipv4.ICMPTypeEcho, Body: &icmp.Echo{ID: 1, Seq: 1, Data: nonce}}).Marshal(nil)
	if err != nil {
		return 0, err
	}
	start := time.Now()
	if err := unix.Sendto(fd, b, 0, &unix.SockaddrInet4{Addr: ip.As4()}); err != nil {
		return 0, err
	}
	buf := make([]byte, 1500)
	for {
		left := time.Duration(1<<62 - 1)
		if dl, ok := ctx.Deadline(); ok {
			left = time.Until(dl)
		}
		if ctx.Err() != nil || left <= 0 {
			return 0, context.DeadlineExceeded
		}
		tv := unix.NsecToTimeval(int64(min(left, time.Hour)))
		if err := unix.SetsockoptTimeval(fd, unix.SOL_SOCKET, unix.SO_RCVTIMEO, &tv); err != nil {
			return 0, err
		}
		n, _, err := unix.Recvfrom(fd, buf, 0)
		if err != nil {
			if errors.Is(err, unix.EAGAIN) || errors.Is(err, unix.EINTR) {
				continue // the loop's deadline check ends it
			}
			return 0, err
		}
		data := buf[:n]
		if n >= 20 && data[0]>>4 == 4 { // some systems hand over the IP header too
			if ihl := int(data[0]&0xf) * 4; ihl <= n {
				data = data[ihl:]
			}
		}
		m, err := icmp.ParseMessage(1, data)
		if err != nil {
			continue
		}
		switch body := m.Body.(type) {
		case *icmp.Echo:
			if m.Type == ipv4.ICMPTypeEchoReply && bytes.Equal(body.Data, nonce) {
				return time.Since(start), nil
			}
		case *icmp.DstUnreach:
			return 0, errors.New("the server can't be reached")
		}
	}
}
