#!/bin/bash

# Notarize a release build: submit to Apple, staple tickets, and assess the
# results with Gatekeeper. Run after `RELEASE=1 ./build-app.sh`.
#
# One-time setup (interactive; needs an app-specific password from
# https://account.apple.com):
#   xcrun notarytool store-credentials sidekick-notary \
#       --apple-id <apple-id> --team-id 2UWZ923R8C
#
# Flow: notarize the app archive first and staple the .app, so both the DMG
# and the zip end up carrying an app whose ticket travels with it (offline
# first launch works). Then rebuild both containers from the stapled app,
# notarize the DMG, and staple that too.

set -e

PROFILE="${NOTARY_PROFILE:-sidekick-notary}"
BUILD_DIR="build"
APP="${BUILD_DIR}/Cortland.app"
DMG="${BUILD_DIR}/Cortland.dmg"
ZIP="${BUILD_DIR}/Cortland.zip"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: TRAVIS KEITH RODGERS (2UWZ923R8C)}"

if [ ! -d "${APP}" ]; then
    echo "❌ ${APP} not found — run RELEASE=1 ./build-app.sh first."
    exit 1
fi
if ! codesign -dvv "${APP}" 2>&1 | grep -q "Authority=Developer ID"; then
    echo "❌ ${APP} is not signed with a Developer ID identity."
    echo "   Rebuild with: RELEASE=1 ./build-app.sh"
    exit 1
fi

echo "📤 Submitting app archive for notarization..."
NOTARIZE_ZIP="${BUILD_DIR}/notarize-upload.zip"
ditto -c -k --keepParent "${APP}" "${NOTARIZE_ZIP}"
xcrun notarytool submit "${NOTARIZE_ZIP}" \
    --keychain-profile "${PROFILE}" --wait
rm -f "${NOTARIZE_ZIP}"

echo "📎 Stapling ticket to ${APP}..."
xcrun stapler staple "${APP}"

echo "📦 Rebuilding distribution zip from the stapled app..."
ditto -c -k --keepParent "${APP}" "${ZIP}"

echo "💿 Rebuilding DMG from the stapled app..."
DMG_STAGING="${BUILD_DIR}/dmg-staging"
rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}"
cp -R "${APP}" "${DMG_STAGING}/Cortland.app"
ln -s /Applications "${DMG_STAGING}/Applications"
rm -f "${DMG}"
hdiutil create -volname "Cortland" -srcfolder "${DMG_STAGING}" -ov -format UDZO "${DMG}"
rm -rf "${DMG_STAGING}"
codesign --sign "${SIGN_IDENTITY}" --timestamp "${DMG}"

echo "📤 Submitting DMG for notarization..."
xcrun notarytool submit "${DMG}" --keychain-profile "${PROFILE}" --wait

echo "📎 Stapling ticket to ${DMG}..."
xcrun stapler staple "${DMG}"

echo "🔍 Assessing with Gatekeeper..."
spctl --assess --type exec --verbose "${APP}"
spctl --assess --type open --context context:primary-signature --verbose "${DMG}"

echo "✅ Notarized and stapled: ${APP}, ${DMG}, ${ZIP}"
echo "   If a submission is rejected, inspect it with:"
echo "   xcrun notarytool log <submission-id> --keychain-profile ${PROFILE}"
