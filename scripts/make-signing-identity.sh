#!/usr/bin/env bash
# Creates "linkC Local Signing", the self-signed code-signing identity build-app.sh and the
# in-app update sign with, in the login keychain. A stable identity keeps macOS privacy grants
# (Screen Recording, notifications) across rebuilds; an ad-hoc signature changes every build.
# It never leaves this Mac and needs no Apple account. Refuses to make a second one: two
# identities with one name make codesign fail as ambiguous.
set -euo pipefail

NAME="linkC Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

IDENTITIES="$(security find-identity -p codesigning)"
if [[ "$IDENTITIES" == *"\"$NAME\""* ]]; then
  echo "\"$NAME\" is already in the keychain — nothing to do."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF
PASS="$(openssl rand -hex 16)"
if ! openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>"$WORK/req.err"; then
  echo "ERROR: openssl couldn't make the certificate:" >&2
  cat "$WORK/req.err" >&2
  exit 1
fi
# 3DES/SHA1 PKCS#12: what `security import` reads from both LibreSSL and OpenSSL 3.
openssl pkcs12 -export -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" -out "$WORK/id.p12" -passout "pass:$PASS"
# -T puts codesign on the key's access list, so builds can sign with it.
security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
echo "Created \"$NAME\". Rebuild with ./build-app.sh; macOS asks for linkC's permissions once more, then keeps them."
