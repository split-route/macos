#!/bin/sh
# Creates the certificate that signs Splitroute builds, once. Without an Apple developer account the app is signed
# with this self-signed certificate instead of ad hoc: an ad-hoc signature's identity is a hash of that exact build, so
# every update looks like a different app to macOS (Keychain "always allow", the service's approval in Login Items). With a
# certificate the identity is the bundle ID plus the certificate's fingerprint, which stays the same from build to build.
#
#   scripts/make-signing-cert.sh [backup.p12]     (default: ~/splitroute-signing.p12)
#
# The private key goes into your login keychain and into the backup, protected by the passphrase you type. KEEP THE BACKUP
# SAFE (a password manager): whoever has the key can sign updates as you, and if it is lost the next release changes identity
# again. The first signing asks once to let codesign use the key: choose Always Allow.
set -eu
NAME=${SIGN_IDENTITY:-Splitroute Signing}
KEYCHAIN=${SIGN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}
BACKUP=${1:-$HOME/splitroute-signing.p12}

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
  echo "A certificate named \"$NAME\" is already in that keychain. Nothing was changed." >&2
  exit 1
fi
[ ! -e "$BACKUP" ] || { echo "$BACKUP already exists. Pick another backup path." >&2; exit 1; }
if [ -z "${P12_PASS:-}" ]; then
  printf 'Passphrase for the backup file: '
  stty -echo; read -r P12_PASS; stty echo; echo
fi
[ -n "$P12_PASS" ] || { echo "The passphrase can't be empty." >&2; exit 1; }
export P12_PASS

T=$(mktemp -d)
cat > "$T/req.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/key.pem" -out "$T/cert.pem" -days 3650 -config "$T/req.cnf" 2>/dev/null
# A failed run leaves no half-made backup behind.
trap 'rm -rf "$T"; [ -n "${OK:-}" ] || rm -f "$BACKUP"' EXIT
# OpenSSL 3 writes a newer PKCS#12 that `security` can't read; -legacy (OpenSSL 3 only) writes the older one.
( umask 077
  openssl pkcs12 -export -legacy -inkey "$T/key.pem" -in "$T/cert.pem" -out "$BACKUP" -passout env:P12_PASS 2>/dev/null ||
  openssl pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -out "$BACKUP" -passout env:P12_PASS )
security import "$BACKUP" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign >/dev/null
OK=1
FP=$(openssl x509 -in "$T/cert.pem" -outform der | shasum | cut -d' ' -f1)
echo "Created \"$NAME\" (valid 10 years). Fingerprint: $FP"
echo "Backup: $BACKUP  (keep it somewhere safe; it holds the private key)"
echo "build-app.sh signs with it automatically. macOS lists it as not trusted: that is expected, nothing needs it trusted."
