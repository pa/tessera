#!/usr/bin/env bash
#
# Create a self-signed code-signing certificate for Tessera so the macOS
# Accessibility (TCC) grant persists across rebuilds.
#
# Why: ad-hoc signing (`codesign -s -`) produces a fresh signature every build,
# so macOS treats each rebuild as a new app and re-prompts for Accessibility.
# A stable signing identity gives the app a fixed Designated Requirement, which
# TCC keys the grant to — grant once, and it sticks across rebuilds.
#
# This is self-contained and non-interactive: it creates a DEDICATED keychain
# with a password the script sets itself (no login-keychain password needed),
# imports the identity there, and adds it to the user keychain search list so
# `codesign` can find it. The signature is not Gatekeeper-trusted (it's
# self-signed) — that's fine for local development, exactly like ad-hoc.
#
# Idempotent: re-running reuses the existing identity if present.
#
# Teardown:
#   security delete-keychain "$HOME/Library/Keychains/tessera-signing.keychain-db"
#   (then remove it from the search list, or just re-run `security list-keychains`)
#
set -euo pipefail

IDENTITY_NAME="${CODESIGN_IDENTITY:-Tessera Code Signing}"
KEYCHAIN_NAME="tessera-signing.keychain"
KEYCHAIN_PATH="$HOME/Library/Keychains/${KEYCHAIN_NAME}-db"
KEYCHAIN_PASSWORD="tessera-signing"

# Already have it? Nothing to do.
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    echo "Signing identity \"$IDENTITY_NAME\" already exists. Nothing to do."
    echo "Build with: CODESIGN_IDENTITY=\"$IDENTITY_NAME\" ./scripts/build-app.sh"
    exit 0
fi

# Use the system LibreSSL, not a Homebrew OpenSSL 3.x on PATH: OpenSSL 3
# defaults to a PKCS#12 MAC that macOS's `security import` can't verify
# ("MAC verification failed"). LibreSSL emits the legacy format macOS expects.
OPENSSL="/usr/bin/openssl"
# A real (non-empty) passphrase on the .p12 — empty-password bundles also trip
# up `security import` on recent macOS.
P12_PASSWORD="tessera-p12"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> generating self-signed code-signing cert ($IDENTITY_NAME)"
cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = ${IDENTITY_NAME}
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1

# Bundle key + cert into a PKCS#12 for `security import`. macOS's `security`
# expects the legacy PKCS#12 format that LibreSSL (the system openssl) emits.
"$OPENSSL" pkcs12 -export \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$IDENTITY_NAME" \
    -out "$WORK/identity.p12" -passout pass:"$P12_PASSWORD" >/dev/null 2>&1

echo "==> creating dedicated keychain: $KEYCHAIN_NAME"
# Recreate cleanly so a half-finished prior run doesn't linger.
security delete-keychain "$KEYCHAIN_NAME" 2>/dev/null || true
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
# Keep it unlocked and don't auto-lock on a timer, so builds never stall.
security set-keychain-settings "$KEYCHAIN_NAME"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"

echo "==> importing identity (allowing codesign to use it)"
security import "$WORK/identity.p12" -k "$KEYCHAIN_NAME" -P "$P12_PASSWORD" \
    -T /usr/bin/codesign >/dev/null

# Grant codesign non-interactive access to the private key (no UI prompt).
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME" >/dev/null 2>&1 || true

echo "==> adding keychain to the user search list"
# Preserve the existing list; only add ours if it isn't already present.
CURRENT="$(security list-keychains -d user | sed -e 's/^[[:space:]]*//' -e 's/"//g')"
if ! grep -q "$KEYCHAIN_NAME" <<<"$CURRENT"; then
    # shellcheck disable=SC2086
    security list-keychains -d user -s "$KEYCHAIN_PATH" $CURRENT
fi

echo ""
if security find-identity -p codesigning | grep -q "$IDENTITY_NAME"; then
    echo "✅ Created code-signing identity: \"$IDENTITY_NAME\""
    echo "   Build a persistently-granted app with:"
    echo "     CODESIGN_IDENTITY=\"$IDENTITY_NAME\" ./scripts/build-app.sh"
else
    echo "⚠️  Identity created but not listed by 'security find-identity -p codesigning'."
    echo "   codesign may still accept it by name; try the build and check."
fi
