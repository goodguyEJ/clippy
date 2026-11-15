#!/bin/zsh
# Creates a self-signed code-signing certificate for building ClipStack, once per Mac.
# Builds signed with it keep the same identity, so macOS keeps ClipStack's Accessibility
# permission across updates. It does not remove Gatekeeper's warning for downloaded copies.
#
#   scripts/make-signing-cert.sh            then: export CLIPSTACK_SIGN_IDENTITY="ClipStack Self-Signed"
#
# Safe to run again: an existing certificate is re-trusted instead of duplicated.
# CLIPSTACK_KEYCHAIN picks another keychain (used for testing); the default is your login keychain.
set -euo pipefail

NAME="${CLIPSTACK_CERT_NAME:-ClipStack Self-Signed}"
KEYCHAIN="${CLIPSTACK_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Captured first: `grep -q` under pipefail can report "no match" when it stops reading early.
identities="$(security find-identity -p codesigning "$KEYCHAIN")"
if print -r -- "$identities" | grep -F "\"$NAME\"" >/dev/null; then
  echo "\"$NAME\" already exists; making sure it's trusted for code signing."
  security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$TMP/cert.pem"
else
  cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
  # The system LibreSSL writes a PKCS#12 that `security import` reads on every supported macOS.
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
  PASSWORD="$(/usr/bin/openssl rand -hex 16)"
  /usr/bin/openssl pkcs12 -export -name "$NAME" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout "pass:$PASSWORD"
  security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
  echo "Created \"$NAME\"."
fi

# A self-signed certificate isn't trusted by default; trusting it for code signing (your account only)
# is what lets codesign use it.
echo "macOS will ask for your password to trust the certificate for code signing."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
echo "\"$NAME\" is trusted for code signing."

echo
echo "Add this to your shell profile (e.g. ~/.zshrc), then run ./build.sh:"
echo "  export CLIPSTACK_SIGN_IDENTITY=\"$NAME\""
echo "The first signed build may ask for your login password to use the key; choose Always Allow."
echo "Switching from an unsigned build means re-granting Accessibility once; after that it sticks."
