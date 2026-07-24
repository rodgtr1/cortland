#!/bin/bash

# Build and package Cortland.app for macOS

set -e

# Official builds link the private Pro package; a clone of this repo alone
# builds the free app. CORTLAND_PRO_PATH is the switch Package.swift reads —
# see docs/pro-split.md. It defaults to ../cortland-pro so a machine with both
# checkouts side by side needs no environment at all, and CORTLAND_PRO=0 forces
# a free build for testing what a public clone gets.
if [ "${CORTLAND_PRO:-1}" = "0" ]; then
    unset CORTLAND_PRO_PATH
    echo "🔨 Building Cortland (free — CORTLAND_PRO=0)..."
else
    : "${CORTLAND_PRO_PATH:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../cortland-pro" 2>/dev/null && pwd || true)}"
    if [ -z "${CORTLAND_PRO_PATH}" ] || [ ! -f "${CORTLAND_PRO_PATH}/Package.swift" ]; then
        echo "❌ No Pro package found."
        echo "   Expected a checkout of cortland-pro beside this repo, or"
        echo "   CORTLAND_PRO_PATH pointing at one. Set CORTLAND_PRO=0 to build"
        echo "   the free app deliberately."
        exit 1
    fi
    export CORTLAND_PRO_PATH
    echo "🔨 Building Cortland (Pro — ${CORTLAND_PRO_PATH})..."
fi

# Build the Swift package
swift build --configuration release

# Create app bundle structure
APP_NAME="Cortland"
BUNDLE_NAME="${APP_NAME}.app"
BUILD_DIR="build"

echo "📦 Creating app bundle structure..."

# Clean and create bundle directory
rm -rf "${BUILD_DIR}/${BUNDLE_NAME}"
mkdir -p "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS"
mkdir -p "${BUILD_DIR}/${BUNDLE_NAME}/Contents/Resources"
mkdir -p "${BUILD_DIR}/${BUNDLE_NAME}/Contents/Frameworks"

# Copy executable
echo "📋 Copying executable..."
cp ".build/release/${APP_NAME}" "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS/${APP_NAME}"

# Copy Info.plist
echo "📋 Copying Info.plist..."
cp "Info.plist" "${BUILD_DIR}/${BUNDLE_NAME}/Contents/Info.plist"

# Embed Sparkle. SwiftPM links the XCFramework but does not embed it, so the
# framework is copied in by hand; ditto (not cp) because the framework is a
# versioned bundle held together by symlinks. The main binary already carries
# an @loader_path/../Frameworks rpath (see Package.swift) so it resolves here.
echo "📋 Embedding Sparkle.framework..."
SPARKLE_FRAMEWORK=".build/release/Sparkle.framework"
if [ ! -d "${SPARKLE_FRAMEWORK}" ]; then
    echo "❌ ${SPARKLE_FRAMEWORK} not found — run swift build --configuration release first."
    exit 1
fi
rm -rf "${BUILD_DIR}/${BUNDLE_NAME}/Contents/Frameworks/Sparkle.framework"
ditto "${SPARKLE_FRAMEWORK}" "${BUILD_DIR}/${BUNDLE_NAME}/Contents/Frameworks/Sparkle.framework"

# Copy app icon
echo "🎨 Copying app icon..."
if [ -f "Resources/icon.png" ]; then
    # Create iconset from PNG
    ICONSET_DIR="${BUILD_DIR}/AppIcon.iconset"
    mkdir -p "${ICONSET_DIR}"

    # Generate different sizes for iconset
    sips -z 16 16 Resources/icon.png --out "${ICONSET_DIR}/icon_16x16.png" 2>/dev/null
    sips -z 32 32 Resources/icon.png --out "${ICONSET_DIR}/icon_16x16@2x.png" 2>/dev/null
    sips -z 32 32 Resources/icon.png --out "${ICONSET_DIR}/icon_32x32.png" 2>/dev/null
    sips -z 64 64 Resources/icon.png --out "${ICONSET_DIR}/icon_32x32@2x.png" 2>/dev/null
    sips -z 128 128 Resources/icon.png --out "${ICONSET_DIR}/icon_128x128.png" 2>/dev/null
    sips -z 256 256 Resources/icon.png --out "${ICONSET_DIR}/icon_128x128@2x.png" 2>/dev/null
    sips -z 256 256 Resources/icon.png --out "${ICONSET_DIR}/icon_256x256.png" 2>/dev/null
    sips -z 512 512 Resources/icon.png --out "${ICONSET_DIR}/icon_256x256@2x.png" 2>/dev/null
    sips -z 512 512 Resources/icon.png --out "${ICONSET_DIR}/icon_512x512.png" 2>/dev/null
    cp Resources/icon.png "${ICONSET_DIR}/icon_512x512@2x.png" 2>/dev/null

    # Convert to icns
    iconutil -c icns "${ICONSET_DIR}" -o "${BUILD_DIR}/${BUNDLE_NAME}/Contents/Resources/AppIcon.icns"
    rm -rf "${ICONSET_DIR}"
    echo "✅ Icon created from Resources/icon.png"
else
    echo "⚠️  Warning: Resources/icon.png not found"
fi

# Set executable permissions
chmod +x "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS/${APP_NAME}"

# Sign with a stable identity so macOS keeps TCC (folder/app access) grants
# across rebuilds. Without this the app is ad-hoc signed and its cdhash
# changes every build, so macOS re-prompts for every permission.
# Run ./scripts/create-signing-cert.sh once to create the identity.
#
# RELEASE=1 switches to the Developer ID identity with secure timestamps,
# which notarization requires (see scripts/notarize.sh for the next step).
if [ "${RELEASE:-0}" = "1" ]; then
    SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: TRAVIS KEITH RODGERS (2UWZ923R8C)}"
    TIMESTAMP_FLAG="--timestamp"
else
    # Still "Sidekick Dev" after the Cortland rename — the whole point of this
    # identity is a cdhash that outlives rebuilds, and renaming it would drop
    # every TCC grant it holds.
    SIGN_IDENTITY="${SIGN_IDENTITY:-Sidekick Dev}"
    TIMESTAMP_FLAG=""
fi

# Create cortland-ctl CLI tool in bundle
echo "📋 Adding cortland-ctl CLI..."
cp ".build/release/cortland-ctl" "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS/cortland-ctl"
chmod +x "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS/cortland-ctl"

# Create cortland-agent-status CLI tool in bundle
echo "📋 Adding cortland-agent-status CLI..."
cp ".build/release/cortland-agent-status" "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS/cortland-agent-status"
chmod +x "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS/cortland-agent-status"

# Create cortland-mcp MCP server in bundle (Model Context Protocol)
echo "📋 Adding cortland-mcp MCP server..."
cp ".build/release/cortland-mcp" "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS/cortland-mcp"
chmod +x "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS/cortland-mcp"

# Create cortland-telemetry helper in bundle (Stop-hook token/cost reporter)
echo "📋 Adding cortland-telemetry helper..."
cp ".build/release/cortland-telemetry" "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS/cortland-telemetry"
chmod +x "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS/cortland-telemetry"

# Bundle the cortland-panes agent skill (must land before the signing step
# below, which seals Contents/Resources). Preferences -> Agents installs it into
# ~/.claude/skills etc. from here, and InstalledSkillRefresher re-syncs it on
# every launch — so an app-only user, with no repo and no scripts, still gets
# the skill their agents read, and still gets it updated.
echo "📋 Adding cortland-panes skill..."
SKILL_SOURCE=".claude/skills/cortland-panes"
SKILL_DEST="${BUILD_DIR}/${BUNDLE_NAME}/Contents/Resources/skills/cortland-panes"
mkdir -p "${SKILL_DEST}/agents"
cp "${SKILL_SOURCE}/SKILL.md" "${SKILL_DEST}/SKILL.md"
cp "${SKILL_SOURCE}/agents/openai.yaml" "${SKILL_DEST}/agents/openai.yaml"

# Code-sign the bundle (helpers first, main app last) with a stable identity.
if security find-identity -p codesigning -v 2>/dev/null | grep -q "${SIGN_IDENTITY}"; then
    echo "🔏 Signing with '${SIGN_IDENTITY}'..."
    # Sparkle arrives signed by the Sparkle project, so re-sign it with our
    # identity, innermost first. Its helpers keep their own entitlements
    # (--preserve-metadata) rather than inheriting Cortland's: Autoupdate
    # carries a Sparkle application-identifier that is not ours to rewrite.
    SPARKLE_VERSION_DIR="${BUILD_DIR}/${BUNDLE_NAME}/Contents/Frameworks/Sparkle.framework/Versions/B"
    for SPARKLE_PART in \
        "XPCServices/Downloader.xpc" \
        "XPCServices/Installer.xpc" \
        "Autoupdate" \
        "Updater.app"; do
        if [ -e "${SPARKLE_VERSION_DIR}/${SPARKLE_PART}" ]; then
            codesign --force --options runtime ${TIMESTAMP_FLAG} \
                --preserve-metadata=entitlements \
                --sign "${SIGN_IDENTITY}" \
                "${SPARKLE_VERSION_DIR}/${SPARKLE_PART}"
        fi
    done
    codesign --force --options runtime ${TIMESTAMP_FLAG} \
        --sign "${SIGN_IDENTITY}" \
        "${BUILD_DIR}/${BUNDLE_NAME}/Contents/Frameworks/Sparkle.framework"

    for HELPER in cortland-ctl cortland-agent-status cortland-mcp cortland-telemetry; do
        codesign --force --options runtime ${TIMESTAMP_FLAG} \
            --entitlements Cortland.entitlements \
            --sign "${SIGN_IDENTITY}" \
            "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS/${HELPER}"
    done
    codesign --force --options runtime ${TIMESTAMP_FLAG} \
        --entitlements Cortland.entitlements \
        --sign "${SIGN_IDENTITY}" \
        "${BUILD_DIR}/${BUNDLE_NAME}"
    codesign --verify --deep --strict --verbose=2 "${BUILD_DIR}/${BUNDLE_NAME}"
    echo "✅ Signed. TCC grants will persist across rebuilds."
elif [ "${RELEASE:-0}" = "1" ]; then
    echo "❌ RELEASE=1 but signing identity '${SIGN_IDENTITY}' is not in the keychain."
    exit 1
else
    echo "⚠️  No '${SIGN_IDENTITY}' identity found — app is ad-hoc signed and macOS"
    echo "    will re-prompt for folder/app access on every rebuild."
    echo "    Fix once with: ./scripts/create-signing-cert.sh"
fi

# Zip for handing to another Mac. scp/USB transfers skip the quarantine
# flag entirely; browser/AirDrop transfers need right-click -> Open (or
# System Settings -> Privacy & Security -> Open Anyway) on first launch.
echo "📦 Creating distribution zip..."
ditto -c -k --keepParent "${BUILD_DIR}/${BUNDLE_NAME}" "${BUILD_DIR}/Cortland.zip"

# DMG for the standard drag-to-Applications install experience. Built from a
# staging dir so the mounted volume shows the app next to an Applications
# shortcut, same layout as most macOS app installers.
echo "💿 Creating distribution DMG..."
DMG_STAGING="${BUILD_DIR}/dmg-staging"
rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}"
cp -R "${BUILD_DIR}/${BUNDLE_NAME}" "${DMG_STAGING}/${BUNDLE_NAME}"
ln -s /Applications "${DMG_STAGING}/Applications"
rm -f "${BUILD_DIR}/Cortland.dmg"
hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_STAGING}" -ov -format UDZO "${BUILD_DIR}/Cortland.dmg"
rm -rf "${DMG_STAGING}"

# Release DMGs get their own Developer ID signature so Gatekeeper can vouch
# for the container, not just the app inside it.
if [ "${RELEASE:-0}" = "1" ]; then
    echo "🔏 Signing DMG..."
    codesign --sign "${SIGN_IDENTITY}" --timestamp "${BUILD_DIR}/Cortland.dmg"
fi

echo "✅ App bundle created at: ${BUILD_DIR}/${BUNDLE_NAME}"
echo "✅ Distribution DMG at:   ${BUILD_DIR}/Cortland.dmg"
echo "✅ Distribution zip at:   ${BUILD_DIR}/Cortland.zip"
echo ""
echo "📱 To install:"
echo "   open ${BUILD_DIR}/Cortland.dmg   # then drag Cortland to Applications"
echo "   # or, without the DMG:"
echo "   cp -r ${BUILD_DIR}/${BUNDLE_NAME} /Applications/"
echo ""
echo "🚀 To run:"
echo "   open ${BUILD_DIR}/${BUNDLE_NAME}"
echo "   # or"
echo "   /Applications/${BUNDLE_NAME}/Contents/MacOS/${APP_NAME}"
echo ""
echo "🛠️  To add CLI tools to PATH:"
echo "   ln -sf /Applications/${BUNDLE_NAME}/Contents/MacOS/cortland-ctl /usr/local/bin/cortland-ctl"
echo "   ln -sf /Applications/${BUNDLE_NAME}/Contents/MacOS/cortland-agent-status /usr/local/bin/cortland-agent-status"
echo ""
echo "🔌 To register the MCP server with Claude Code:"
echo "   claude mcp add --scope user cortland /Applications/${BUNDLE_NAME}/Contents/MacOS/cortland-mcp"
