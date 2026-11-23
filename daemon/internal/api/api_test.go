//go:build darwin || linux

package api

import (
	"encoding/json"
	"net"
	"strings"
	"testing"
)

type fake struct {
	Backend
	applied *Snapshot
}

func (f *fake) Status() Status         { return Status{Version: "x", BootID: "b1"} }
func (f *fake) Apply(s Snapshot) error { f.applied = &s; return nil }
func (f *fake) Logs() []string         { return []string{"a"} }
func (f *fake) CanonEntries(l []string) []Canon {
	return []Canon{{Line: l[0], Entry: strings.ToLower(l[0])}}
}

func TestRespond(t *testing.T) {
	f := &fake{}
	for _, tc := range []struct {
		req  Request
		ok   bool
		want string
	}{
		{Request{Cmd: "status"}, true, ""},
		{Request{Cmd: "apply"}, false, "snapshot"},
		{Request{Cmd: "apply", Apply: &Snapshot{VPN: true}}, true, ""},
		{Request{Cmd: "answer"}, false, "tunnel id"},
		{Request{Cmd: "canon_entries", Lines: []string{"A.COM"}}, true, ""},
		{Request{Cmd: "set_config"}, false, "unknown command"}, // the old settings commands are gone
	} {
		r := Respond(f, tc.req)
		if r.OK != tc.ok || !strings.Contains(r.Error, tc.want) {
			t.Errorf("%s: ok=%v error=%q", tc.req.Cmd, r.OK, r.Error)
		}
	}
	if f.applied == nil || !f.applied.VPN {
		t.Error("the snapshot did not reach the backend")
	}
}

func TestHandleRoundTripAndLimit(t *testing.T) {
	f := &fake{}
	ask := func(payload string) Response {
		c1, c2 := net.Pipe()
		go Handle(c2, f)
		go func() { c1.Write([]byte(payload)) }()
		var r Response
		if err := json.NewDecoder(c1).Decode(&r); err != nil {
			t.Fatal(err)
		}
		c1.Close()
		return r
	}
	if r := ask(`{"cmd":"status"}` + "\n"); !r.OK || r.Status.BootID != "b1" {
		t.Errorf("status: %+v", r)
	}
	if r := ask(`{"cmd": nope`); r.OK || !strings.Contains(r.Error, "bad request") {
		t.Errorf("garbage: %+v", r)
	}
}
