#!/usr/bin/env bash
# Packages the Theia SwiftPM executable into a proper .app bundle suitable for
# direct distribution.
#
# Env vars (all optional):
#   CONFIG            = release | debug   (default: release)
#   SIGNING_IDENTITY  = Developer ID Application certificate name → enables codesign
#   SIGNER_NAME       = signer's name as it appears on the cert; if set (and
#                       SIGNING_IDENTITY is not), the identity is built as
#                       "Developer ID Application: ${SIGNER_NAME} (${TEAM_ID})"
#   TEAM_ID           = Apple Developer Team ID (default: Z77NN7UQG6, José Vines)
#   NOTARY_PROFILE    = keychain profile name → enables notarytool submit + stapler
#   MAKE_DMG          = 1 → produce a .dmg via hdiutil after assembly
#
# A signed + notarized + stapled .app is ready for Gatekeeper-free distribution.
#
# Release recipe (once enrolled + Developer ID cert installed):
#   # one-time: store notarization credentials under a keychain profile
#   xcrun notarytool store-credentials fitsviewer \
#       --apple-id <apple-id-email> --team-id Z77NN7UQG6 --password <app-specific-pw>
#   # then build → sign → notarize → staple → DMG in one shot:
#   SIGNER_NAME="Jose Vines" NOTARY_PROFILE=fitsviewer MAKE_DMG=1 ./scripts/package.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-release}"
APP_NAME="Theia"
APP_DIR="dist/${APP_NAME}.app"
BIN_NAME="Theia"

# Apple Developer Team ID (José Vines). Used to construct the default signing
# identity below and documented for the one-time notarytool credential setup.
TEAM_ID="${TEAM_ID:-Z77NN7UQG6}"
# Convenience: build the standard Developer ID identity from SIGNER_NAME + TEAM_ID
# when an explicit SIGNING_IDENTITY wasn't given.
if [ -z "${SIGNING_IDENTITY:-}" ] && [ -n "${SIGNER_NAME:-}" ]; then
    SIGNING_IDENTITY="Developer ID Application: ${SIGNER_NAME} (${TEAM_ID})"
fi

echo "Building (-c ${CONFIG})..."
swift build -c "${CONFIG}"

BUILD_DIR=".build/${CONFIG}"
RESOURCE_BUNDLE="Theia_FITSRender.bundle"

if [ ! -x "${BUILD_DIR}/${BIN_NAME}" ]; then
    echo "error: ${BUILD_DIR}/${BIN_NAME} not found after build" >&2
    exit 1
fi

echo "Assembling ${APP_DIR}..."
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BUILD_DIR}/${BIN_NAME}" "${APP_DIR}/Contents/MacOS/${BIN_NAME}"
if [ ! -x "${BUILD_DIR}/theia-remote-helper" ]; then
    echo "error: ${BUILD_DIR}/theia-remote-helper not found after build" >&2
    exit 1
fi
cp "${BUILD_DIR}/theia-remote-helper" "${APP_DIR}/Contents/MacOS/theia-remote-helper"
cp "scripts/Info.plist" "${APP_DIR}/Contents/Info.plist"
printf "APPL????" > "${APP_DIR}/Contents/PkgInfo"

# Bundle the xpans name server next to the main executable. The app prepends
# Contents/MacOS to PATH at launch, so libxpa finds it to register the
# DS9-compatible XPA access points. Without this, XPA name lookup won't work.
if [ -f "${BUILD_DIR}/xpans" ]; then
    cp "${BUILD_DIR}/xpans" "${APP_DIR}/Contents/MacOS/xpans"
else
    echo "warning: ${BUILD_DIR}/xpans not found — XPA name registration will not work" >&2
fi

if [ -d "${BUILD_DIR}/${RESOURCE_BUNDLE}" ]; then
    cp -R "${BUILD_DIR}/${RESOURCE_BUNDLE}" "${APP_DIR}/Contents/Resources/${RESOURCE_BUNDLE}"
fi

# App icon: regenerate if missing, then copy into Resources.
if [ ! -f "dist/AppIcon.icns" ]; then
    "${ROOT}/scripts/make_icon.sh"
fi
cp "dist/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"

if [ -n "${SIGNING_IDENTITY:-}" ]; then
    echo "Codesigning with: ${SIGNING_IDENTITY}"
    SIGN_OPTS=(--force --options runtime --timestamp --sign "${SIGNING_IDENTITY}")
    # Sign inside-out: notarization requires every nested Mach-O to be signed with
    # Developer ID + hardened runtime, and the outer app signed last so its seal
    # covers the already-signed nested code. The bundled xpans name server is a
    # second executable — sign it first. (The FITSRender resource bundle holds no
    # Mach-O, just the .metal shader, so it is sealed by the outer app, not signed
    # directly — codesign rejects signing a resource-only bundle.)
    if [ -f "${APP_DIR}/Contents/MacOS/xpans" ]; then
        codesign "${SIGN_OPTS[@]}" "${APP_DIR}/Contents/MacOS/xpans"
    fi
    codesign "${SIGN_OPTS[@]}" "${APP_DIR}/Contents/MacOS/theia-remote-helper"
    # Outer app last (signs the main executable + seals nested resources).
    codesign "${SIGN_OPTS[@]}" "${APP_DIR}"
    # Fail fast on a malformed signature before the slow notarytool round-trip.
    codesign --verify --deep --strict --verbose=2 "${APP_DIR}"
else
    echo "(skipping codesign; set SIGNING_IDENTITY to enable)"
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
    if [ -z "${SIGNING_IDENTITY:-}" ]; then
        echo "error: NOTARY_PROFILE requires SIGNING_IDENTITY for codesigning" >&2
        exit 1
    fi
    echo "Notarizing via keychain profile: ${NOTARY_PROFILE}"
    ZIP_PATH="dist/${BIN_NAME}-notarize.zip"
    rm -f "${ZIP_PATH}"
    ditto -c -k --keepParent "${APP_DIR}" "${ZIP_PATH}"

    set +e
    xcrun notarytool submit "${ZIP_PATH}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait
    NOTARY_RC=$?
    set -e
    rm -f "${ZIP_PATH}"
    if [ "${NOTARY_RC}" -ne 0 ]; then
        echo "error: notarytool failed (rc=${NOTARY_RC})" >&2
        exit "${NOTARY_RC}"
    fi

    echo "Stapling notarization ticket..."
    xcrun stapler staple "${APP_DIR}"
else
    echo "(skipping notarization; set NOTARY_PROFILE to enable)"
fi

# Refresh Launch Services so Finder picks up the UTI declarations.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "${LSREGISTER}" ]; then
    "${LSREGISTER}" -f "${APP_DIR}" >/dev/null 2>&1 || true
fi

if [ "${MAKE_DMG:-0}" = "1" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "${APP_DIR}/Contents/Info.plist" 2>/dev/null || echo "0.1.0")"
    DMG_PATH="dist/Theia-${VERSION}.dmg"
    rm -f "${DMG_PATH}"
    echo "Building ${DMG_PATH}..."
    hdiutil create -volname "${APP_NAME}" \
        -srcfolder "${APP_DIR}" \
        -ov -format UDZO \
        "${DMG_PATH}" >/dev/null
    echo "Built: ${DMG_PATH}"
fi

echo "Built: ${APP_DIR}"
