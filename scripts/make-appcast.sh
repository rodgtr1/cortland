#!/bin/bash

# Generate the Sparkle appcast for a release. Run after ./scripts/notarize.sh,
# so the DMG the appcast points at is the stapled one users will actually get.
#
# The feed lives at the fixed URL
#   https://github.com/rodgtr1/cortland/releases/latest/download/appcast.xml
# which GitHub always resolves to the newest release's attachment. Sparkle only
# ever needs the newest item from a feed, so this generates a single-item
# appcast per release rather than carrying history forward — nothing to keep in
# sync, and no stale entry can point at a deleted asset.
#
# Signing: generate_appcast reads the private EdDSA key from the login Keychain
# (Sparkle's default, created once by generate_keys). The key is never written
# to disk, never passed on the command line, and never in this repo.
#
# Output: build/appcast.xml and build/Cortland-<version>.dmg. Attach BOTH to
# the GitHub release — the versioned DMG is what the appcast's enclosure URL
# names. See docs/release.md.

set -e

BUILD_DIR="build"
APP="${BUILD_DIR}/Cortland.app"
DMG="${BUILD_DIR}/Cortland.dmg"
REPO_URL="${CORTLAND_REPO_URL:-https://github.com/rodgtr1/cortland}"

if [ ! -d "${APP}" ]; then
    echo "❌ ${APP} not found — run RELEASE=1 ./build-app.sh first."
    exit 1
fi
if [ ! -f "${DMG}" ]; then
    echo "❌ ${DMG} not found — run RELEASE=1 ./build-app.sh first."
    exit 1
fi

# Sparkle's tools ship inside the SwiftPM artifact bundle, so they only exist
# after a build has resolved the dependency.
SPARKLE_BIN="$(find .build/artifacts -type d -path '*/Sparkle/bin' -not -path '*/index-build/*' 2>/dev/null | head -1)"
if [ -z "${SPARKLE_BIN}" ] || [ ! -x "${SPARKLE_BIN}/generate_appcast" ]; then
    echo "❌ Sparkle's generate_appcast not found under .build/artifacts."
    echo "   Run: swift build --configuration release"
    exit 1
fi

# The version the appcast advertises comes off the built bundle, never a
# hand-typed argument, so the feed cannot disagree with what it ships.
VERSION="$(plutil -extract CFBundleShortVersionString raw "${APP}/Contents/Info.plist")"
BUILD_NUM="$(plutil -extract CFBundleVersion raw "${APP}/Contents/Info.plist")"
TAG="${CORTLAND_RELEASE_TAG:-v${VERSION}}"

echo "📄 Generating appcast for ${VERSION} (build ${BUILD_NUM}), tag ${TAG}..."

# A scratch directory per run: generate_appcast keys off filenames, and a
# leftover archive from a previous version would end up back in the feed.
ARCHIVES="${BUILD_DIR}/appcast-archives"
rm -rf "${ARCHIVES}"
mkdir -p "${ARCHIVES}"

# Versioned filename so the enclosure URL is unambiguous across releases; the
# plain Cortland.dmg stays as the human-facing download.
ARCHIVE_NAME="Cortland-${VERSION}.dmg"
cp "${DMG}" "${ARCHIVES}/${ARCHIVE_NAME}"

# Optional release notes: docs/release-notes/<version>.md gets embedded in the
# item Sparkle shows before installing. Absent is fine.
NOTES="docs/release-notes/${VERSION}.md"
if [ -f "${NOTES}" ]; then
    echo "📝 Embedding release notes from ${NOTES}"
    cp "${NOTES}" "${ARCHIVES}/Cortland-${VERSION}.md"
fi

"${SPARKLE_BIN}/generate_appcast" \
    --download-url-prefix "${REPO_URL}/releases/download/${TAG}/" \
    --full-release-notes-url "${REPO_URL}/blob/main/CHANGELOG.md" \
    --link "${REPO_URL}" \
    --embed-release-notes \
    "${ARCHIVES}"

cp "${ARCHIVES}/appcast.xml" "${BUILD_DIR}/appcast.xml"
cp "${ARCHIVES}/${ARCHIVE_NAME}" "${BUILD_DIR}/${ARCHIVE_NAME}"
rm -rf "${ARCHIVES}"

# Fail loudly rather than shipping a feed Sparkle will reject: an unsigned item
# is one every client refuses, and a version mismatch means the wrong DMG.
if ! grep -q 'sparkle:edSignature=' "${BUILD_DIR}/appcast.xml"; then
    echo "❌ ${BUILD_DIR}/appcast.xml has no EdDSA signature."
    exit 1
fi
if ! grep -q "<sparkle:version>${BUILD_NUM}</sparkle:version>" "${BUILD_DIR}/appcast.xml"; then
    echo "❌ ${BUILD_DIR}/appcast.xml does not advertise build ${BUILD_NUM}."
    exit 1
fi

echo "✅ Appcast at:      ${BUILD_DIR}/appcast.xml"
echo "✅ Versioned DMG at: ${BUILD_DIR}/${ARCHIVE_NAME}"
echo ""
echo "📤 Attach both to the ${TAG} release (see docs/release.md)."
