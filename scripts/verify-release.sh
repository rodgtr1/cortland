#!/bin/bash

# Verify a published Cortland release the way a downloader experiences it:
# fetch the public assets from GitHub, then check the signatures, the
# notarization, and the appcast against each other. Run it after every
# `gh release create` (see docs/release.md, step 5).
#
#   ./scripts/verify-release.sh v0.7.0
#
# It fails when any of the following is true, because each one ships a broken
# download or a broken in-app update:
#
#   - Cortland.dmg, Cortland-<version>.dmg, or appcast.xml is missing
#   - either DMG is unsigned, or Gatekeeper won't assess it as notarized
#   - either DMG, or the app inside it, has no stapled notarization ticket —
#     an unstapled download needs Apple's service reachable on first launch,
#     which is exactly the case docs/release.md promises works offline
#   - the app inside either DMG fails codesign --verify --deep --strict, or
#     Gatekeeper won't assess it for execution
#   - the appcast's build/version disagrees with the mounted app
#   - the appcast's enclosure URL doesn't serve a file
#   - the release carries an asset outside the supported three (a stray
#     Cortland.zip is the usual one; see docs/release.md)
#
# Run it on a normal macOS host, as the release operator, from a login shell.
# `spctl --assess` reads the machine's Gatekeeper state: inside a restricted
# sandbox, a locked-down MDM profile, or over a bare ssh session the
# assessment can fail on a release that is perfectly fine. That is a reason to
# run it somewhere normal, never a reason to skip it.
#
# Nothing here touches the repo or the release: assets download into a fresh
# temp directory that is removed (and any DMG unmounted) on the way out.

set -euo pipefail

REPO="${CORTLAND_REPO:-rodgtr1/cortland}"
TAG="${1:-}"

if [ -z "${TAG}" ]; then
    echo "usage: $0 <tag>        e.g. $0 v0.7.0"
    exit 2
fi

VERSION="${TAG#v}"
PLAIN_DMG="Cortland.dmg"
VERSIONED_DMG="Cortland-${VERSION}.dmg"
APPCAST="appcast.xml"

for tool in gh hdiutil codesign spctl plutil curl xcrun; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "❌ ${tool} not found on PATH — it is required to verify a release."
        exit 2
    fi
done

WORKDIR=""
MOUNTS=()
FAILURES=0

cleanup() {
    for mount in ${MOUNTS[@]+"${MOUNTS[@]}"}; do
        [ -n "${mount}" ] && hdiutil detach "${mount}" -quiet >/dev/null 2>&1 || true
    done
    [ -n "${WORKDIR}" ] && rm -rf "${WORKDIR}"
}
trap cleanup EXIT

fail() {
    echo "❌ $*"
    FAILURES=$((FAILURES + 1))
}

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/cortland-verify.XXXXXX")"
echo "🔍 Verifying ${REPO} ${TAG} in ${WORKDIR}"

# 1. The release carries exactly the three supported assets.

if ! ASSETS="$(gh release view "${TAG}" --repo "${REPO}" --json assets \
        --jq '.assets[].name' 2>/dev/null)"; then
    echo "❌ No release ${TAG} on ${REPO} (or gh is not authenticated)."
    exit 1
fi

for asset in "${PLAIN_DMG}" "${VERSIONED_DMG}" "${APPCAST}"; do
    if ! printf '%s\n' "${ASSETS}" | grep -qx "${asset}"; then
        fail "${TAG} has no ${asset} — the release is incomplete."
    fi
done

while IFS= read -r asset; do
    [ -z "${asset}" ] && continue
    case "${asset}" in
        "${PLAIN_DMG}"|"${VERSIONED_DMG}"|"${APPCAST}") ;;
        *) fail "${TAG} carries an unsupported asset: ${asset}. Build it from the same stapled app and verify it, or remove it (see docs/release.md)." ;;
    esac
done <<< "${ASSETS}"

# 2. Download what's there. A missing asset is already a failure above; keep
#    going so the operator sees every problem in one run.

for asset in "${PLAIN_DMG}" "${VERSIONED_DMG}" "${APPCAST}"; do
    printf '%s\n' "${ASSETS}" | grep -qx "${asset}" || continue
    echo "⬇️  ${asset}"
    gh release download "${TAG}" --repo "${REPO}" --dir "${WORKDIR}" \
        --pattern "${asset}" >/dev/null
done

# 3. Each DMG: signed, notarized, and carrying an app that is both.
#    Sets APP_VERSION / APP_BUILD from the mounted bundle.

APP_VERSION=""
APP_BUILD=""

verify_dmg() {
    local dmg="${WORKDIR}/$1"
    [ -f "${dmg}" ] || return 0

    echo "🔏 $1"
    codesign --verify --verbose=2 "${dmg}" 2>&1 | sed 's/^/   /' \
        || fail "$1 has no valid signature."
    spctl --assess --type open --context context:primary-signature --verbose "${dmg}" 2>&1 | sed 's/^/   /' \
        || fail "$1 was not assessed as notarized."
    # Stapled, not merely notarized: without the ticket attached, first launch
    # needs Apple reachable. `stapler validate` is the only check that reads it.
    xcrun stapler validate "${dmg}" 2>&1 | sed 's/^/   /' \
        || fail "$1 carries no stapled notarization ticket."

    # -mountrandom keeps the mount inside the temp directory, so a stale
    # /Volumes/Cortland from a previous run can't be mistaken for this one.
    local attach mount
    if ! attach="$(hdiutil attach "${dmg}" -nobrowse -readonly -mountrandom "${WORKDIR}" 2>&1)"; then
        fail "$1 could not be mounted: ${attach}"
        return 0
    fi
    mount="$(printf '%s\n' "${attach}" | awk -F'\t' '$NF ~ /^\// { print $NF }' | tail -1)"
    if [ -z "${mount}" ]; then
        fail "$1 mounted but no mount point was reported."
        return 0
    fi
    MOUNTS+=("${mount}")

    local app="${mount}/Cortland.app"
    if [ ! -d "${app}" ]; then
        fail "$1 does not contain Cortland.app."
        return 0
    fi

    codesign --verify --deep --strict --verbose=2 "${app}" 2>&1 | sed 's/^/   /' \
        || fail "Cortland.app inside $1 failed codesign --verify --deep --strict."
    spctl --assess --type exec --verbose "${app}" 2>&1 | sed 's/^/   /' \
        || fail "Cortland.app inside $1 was not assessed by Gatekeeper."
    xcrun stapler validate "${app}" 2>&1 | sed 's/^/   /' \
        || fail "Cortland.app inside $1 carries no stapled notarization ticket."

    local short build
    short="$(plutil -extract CFBundleShortVersionString raw "${app}/Contents/Info.plist" 2>/dev/null || true)"
    build="$(plutil -extract CFBundleVersion raw "${app}/Contents/Info.plist" 2>/dev/null || true)"
    if [ -z "${short}" ] || [ -z "${build}" ]; then
        fail "Cortland.app inside $1 has no readable version keys."
        return 0
    fi
    echo "   version ${short} build ${build}"
    if [ "${short}" != "${VERSION}" ]; then
        fail "Cortland.app inside $1 is version ${short}, but the tag says ${VERSION}."
    fi
    if [ -n "${APP_VERSION}" ] && { [ "${short}" != "${APP_VERSION}" ] || [ "${build}" != "${APP_BUILD}" ]; }; then
        fail "The two DMGs carry different builds (${APP_VERSION}/${APP_BUILD} vs ${short}/${build})."
    fi
    APP_VERSION="${short}"
    APP_BUILD="${build}"
    # Left mounted on purpose: the trap detaches every mount on the way out,
    # including the ones an early failure skipped past.
}

verify_dmg "${PLAIN_DMG}"
verify_dmg "${VERSIONED_DMG}"

# 4. The appcast has to describe the app that just mounted, and its enclosure
#    has to be fetchable — that URL is every existing install's update path.

appcast_value() {
    sed -n "s|.*<$1>\([^<]*\)</$1>.*|\1|p" "${WORKDIR}/${APPCAST}" | head -1
}

if [ -f "${WORKDIR}/${APPCAST}" ]; then
    echo "📄 ${APPCAST}"
    FEED_BUILD="$(appcast_value 'sparkle:version')"
    FEED_VERSION="$(appcast_value 'sparkle:shortVersionString')"
    ENCLOSURE="$(sed -n 's|.*<enclosure[^>]*url="\([^"]*\)".*|\1|p' "${WORKDIR}/${APPCAST}" | head -1)"
    echo "   advertises ${FEED_VERSION} build ${FEED_BUILD}"

    if [ -z "${FEED_BUILD}" ] || [ -z "${FEED_VERSION}" ]; then
        fail "${APPCAST} does not advertise a version."
    elif [ -n "${APP_VERSION}" ]; then
        [ "${FEED_VERSION}" = "${APP_VERSION}" ] \
            || fail "${APPCAST} advertises ${FEED_VERSION}, the app is ${APP_VERSION}."
        [ "${FEED_BUILD}" = "${APP_BUILD}" ] \
            || fail "${APPCAST} advertises build ${FEED_BUILD}, the app is build ${APP_BUILD}."
    fi

    if ! grep -q 'sparkle:edSignature=' "${WORKDIR}/${APPCAST}"; then
        fail "${APPCAST} has no EdDSA signature — every client refuses an unsigned item."
    fi

    if [ -z "${ENCLOSURE}" ]; then
        fail "${APPCAST} has no enclosure URL."
    else
        echo "   enclosure ${ENCLOSURE}"
        case "${ENCLOSURE}" in
            */"${TAG}/${VERSIONED_DMG}") ;;
            *) fail "The enclosure URL does not point at ${TAG}/${VERSIONED_DMG}." ;;
        esac
        # HEAD first; some CDNs answer a ranged GET but not a HEAD, so a
        # single-byte range is the fallback before calling the URL dead.
        STATUS="$(curl -sIL --max-time 60 -o /dev/null -w '%{http_code}' "${ENCLOSURE}" || echo 000)"
        if [ "${STATUS}" != "200" ]; then
            STATUS="$(curl -sL --max-time 60 -r 0-0 -o /dev/null -w '%{http_code}' "${ENCLOSURE}" || echo 000)"
        fi
        case "${STATUS}" in
            200|206) ;;
            *) fail "The enclosure URL returned HTTP ${STATUS} — in-app updates are broken." ;;
        esac
    fi
fi

echo ""
if [ "${FAILURES}" -gt 0 ]; then
    echo "❌ ${TAG} failed ${FAILURES} check(s). Fix the release before telling anyone about it."
    exit 1
fi
echo "✅ ${TAG} verified: both DMGs signed, notarized, and stapled; appcast matches build ${APP_BUILD}."
