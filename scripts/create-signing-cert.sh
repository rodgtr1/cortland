#!/bin/bash
#
# Create a STABLE self-signed code-signing certificate for Cortland.
#
# Run this ONCE. After that, build-app.sh signs every build with this same
# identity, so macOS keeps your "Allow folder/app access" (TCC) grants across
# rebuilds instead of re-prompting each time.
#
# Re-running is safe: it's a no-op if the cert already exists.
#
# The certificate keeps its original "Sidekick Dev" name through the Cortland
# rename: renaming it would invalidate every TCC grant already tied to it, which
# is exactly what this cert exists to preserve.

set -e

CERT_NAME="Sidekick Dev"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning -v | grep -q "${CERT_NAME}"; then
    echo "✅ Code-signing identity '${CERT_NAME}' already exists. Nothing to do."
    exit 0
fi

echo "🔐 Creating self-signed code-signing certificate '${CERT_NAME}'..."

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# OpenSSL config with the Code Signing extended key usage that codesign requires.
cat > "${TMP}/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[ dn ]
CN = ${CERT_NAME}

[ ext ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
EOF

# 10-year self-signed cert + key.
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${TMP}/key.pem" \
    -out "${TMP}/cert.pem" \
    -days 3650 \
    -config "${TMP}/cert.cnf" >/dev/null 2>&1

# Bundle into a PKCS#12. Use legacy encryption + SHA1 MAC, which Apple's
# Security framework accepts (OpenSSL 3.x defaults fail "MAC verification").
# Empty-password p12s also fail to import, so use a throwaway password.
openssl pkcs12 -export -legacy -macalg sha1 \
    -inkey "${TMP}/key.pem" \
    -in "${TMP}/cert.pem" \
    -out "${TMP}/identity.p12" \
    -name "${CERT_NAME}" \
    -passout pass:cortland >/dev/null 2>&1

# Import key + cert into the login keychain, allowing codesign to use it.
security import "${TMP}/identity.p12" \
    -k "${KEYCHAIN}" \
    -P "cortland" \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null 2>&1

# Trust the cert for code signing so it shows up as a valid identity.
# Login-keychain trust needs no sudo and no admin password.
security add-trusted-cert -r trustRoot \
    -p codeSign \
    -k "${KEYCHAIN}" \
    "${TMP}/cert.pem" >/dev/null 2>&1

# Let codesign read the private key without the interactive "allow" dialog.
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "" "${KEYCHAIN}" >/dev/null 2>&1 || true

echo ""
if security find-identity -p codesigning -v | grep -q "${CERT_NAME}"; then
    echo "✅ Created code-signing identity '${CERT_NAME}'."
    echo "   build-app.sh will now sign every build with it."
    echo "   Run ./build-app.sh, approve the folder/app prompts once, and they'll stick."
else
    echo "⚠️  Identity not reported as valid yet."
    echo "   Open Keychain Access → 'login' → find '${CERT_NAME}' → Get Info →"
    echo "   Trust → 'Code Signing: Always Trust'. Then re-run this script."
fi
