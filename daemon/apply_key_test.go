//go:build darwin || linux

package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"strings"
	"testing"

	"github.com/split-route/macos/daemon/internal/api"
)

// A profile whose client key is passphrase-protected (the old OpenSSL PEM form, made here so no key sits in the repo).
func encryptedKeyProfile(t *testing.T, password string) string {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalECPrivateKey(k)
	if err != nil {
		t.Fatal(err)
	}
	b, err := x509.EncryptPEMBlock(rand.Reader, "EC PRIVATE KEY", der, []byte(password), x509.PEMCipherAES256) //nolint:staticcheck
	if err != nil {
		t.Fatal(err)
	}
	const cert = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
	return "client\ndev tun\nremote vpn.example.com 443 tcp\n<ca>\n" + cert + "</ca>\n<cert>\n" + cert + "</cert>\n<key>\n" + string(pem.EncodeToMemory(b)) + "</key>\n"
}

func TestEncryptedClientKeyImportsWaitsForItsPasswordThenConnects(t *testing.T) {
	a, f := testApp(t)
	profile := encryptedKeyProfile(t, "pw")
	c, err := a.CheckProfile(profile)
	if err != nil || !c.KeyEncrypted || c.Refused != "" {
		t.Fatalf("an encrypted key must import: %+v, %v", c, err)
	}
	tun := api.TunnelSpec{ID: "t1", Name: "Work", Protocol: api.ProtocolOpenVPN, Profile: profile}
	s := api.Snapshot{VPN: true, Selected: "t1", Tunnels: []api.TunnelSpec{tun}}
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	if st := a.Status().Tunnels["t1"]; st.State != api.NeedsAuth {
		t.Fatalf("no key password: %+v", st)
	}
	s.Tunnels[0].KeyPassword = "wrong"
	_ = a.Apply(s)
	if st := a.Status().Tunnels["t1"]; st.State != api.Failed || !strings.Contains(st.Error, "key password") {
		t.Fatalf("wrong key password: %+v", st)
	}
	s.Tunnels[0].KeyPassword = "pw"
	s.Retry = []string{"t1"}
	if err := a.Apply(s); err != nil {
		t.Fatal(err)
	}
	opts := string(applied(t, a, f).Tunnels[0].Options)
	if !strings.Contains(opts, "BEGIN EC PRIVATE KEY") || strings.Contains(opts, "ENCRYPTED") || strings.Contains(opts, "DEK-Info") {
		t.Errorf("the engine must get the plain key:\n%s", opts)
	}
}
