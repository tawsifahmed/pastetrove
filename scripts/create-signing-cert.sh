#!/bin/bash
# Creates a self-signed code-signing certificate in the login keychain (once per Mac).
# Builds signed with it keep the same identity, so macOS keeps PasteTrove's
# Accessibility and "Paste from Other Apps" permissions after a rebuild.
set -euo pipefail
NAME="PasteTrove Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "Already exists: $NAME"
    exit 0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CONF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.conf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
LEGACY=$(openssl version | grep -q '^OpenSSL 3' && echo -legacy || true)
openssl pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -passout pass:pastetrove -out "$TMP/identity.p12"
security import "$TMP/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P pastetrove -T /usr/bin/codesign
echo "Created: $NAME"
