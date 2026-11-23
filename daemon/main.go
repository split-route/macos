//go:build darwin || linux

// Command splitroute is the Split Route service: it runs as root (the tun needs
// it), runs the core engine for what the menu bar app asks (the app owns the
// settings; this keeps none), and answers the app on a control socket. The binary
// and the launchd label keep their old names so an updated app finds its service.
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"syscall"

	"github.com/split-route/macos/daemon/internal/api"
)

const usage = `splitroute is the Split Route service. The app starts it (launchd: "splitroute watch").

usage:
  splitroute watch      run the service (root)
  splitroute killswitch off   remove the kill switch's firewall rules (root)
  splitroute version
`

// lock keeps two services from running at once.
func lock(dir string) (*os.File, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(filepath.Join(dir, "lock"), os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, errors.New("another splitroute service is already running")
	}
	return f, nil
}

func main() {
	log.SetFlags(0)
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	switch os.Args[1] {
	case "version", "-version", "--version":
		fmt.Println(version)
	case "watch", "daemon":
		if os.Geteuid() != 0 {
			log.Fatal("splitroute: the service needs root (it creates the tunnel device)")
		}
		if err := serve(); err != nil {
			log.Fatalf("splitroute: %v", err)
		}
	case "killswitch":
		if len(os.Args) != 3 || os.Args[2] != "off" || os.Geteuid() != 0 {
			fmt.Fprint(os.Stderr, usage)
			os.Exit(2)
		}
		if err := killSwitchOff(); err != nil {
			log.Fatalf("splitroute: %v", err)
		}
		fmt.Println("kill switch rules removed; turn it off in the app too, or the next change puts them back")
	default:
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
}

func serve() error {
	l, err := lock(defaultState)
	if err != nil {
		return err
	}
	defer l.Close()
	a := newApp(defaultState, coreEngine)
	if ln, err := api.Listen(runtime.GOOS); err != nil {
		log.Printf("warning: control socket: %v (the menu bar app can't connect)", err)
	} else {
		defer ln.Close()
		go api.Serve(ln, a)
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	return a.run(ctx)
}
