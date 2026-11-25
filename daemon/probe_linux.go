//go:build linux

package main

import (
	"context"
	"errors"
	"net/netip"
	"syscall"
	"time"
)

// The service is built for macOS; on Linux (development) the tests run without a bound interface and without ping.

func physicalInterface() (int, error) { return 0, nil }

func bindControl(int) func(network, address string, c syscall.RawConn) error { return nil }

func pingOnce(context.Context, netip.Addr, int) (time.Duration, error) {
	return 0, errors.New("ping isn't supported on this system")
}
