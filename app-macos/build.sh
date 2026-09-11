#!/usr/bin/env bash
#
# Assembles RunnerForge.app from the SwiftPM build products.
#
# SwiftPM builds a bare Mach-O executable; macOS needs a bundle with an
# Info.plist, and Gatekeeper needs that bundle signed and — for anything
# distributed — notarized and stapled. This script does the assembly and, when
# credentials are present, the signing.
#
# Usage:
#   ./build.sh                      release build, ad-hoc signed, no notarization
#   ./build.sh --configuration debug
#   ./build.sh --sign "Developer ID Application: Example (TEAMID)" --notarize
#
# Notarization additionally needs, in the environment:
#   APPLE_ASC_ISSUER_ID, APPLE_ASC_KEY_ID, APPLE_ASC_PRIVATE_KEY (the .p8 text)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIGURATION="release"
SIGN_IDENTITY=""
NOTARIZE=0
OUT_DIR="${SCRIPT_DIR}/dist"

usage() {
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration) CONFIGURATION="$2"; shift 2 ;;
        --sign)          SIGN_IDENTITY="$2"; shift 2 ;;
        --notarize)      NOTARIZE=1; shift ;;
        --out)           OUT_DIR="$2"; shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "build.sh: this builds a macOS .app and only runs on macOS." >&2
    exit 1
fi

APP="${OUT_DIR}/RunnerForge.app"
CONTENTS="${APP}/Contents"

echo "==> swift build -c ${CONFIGURATION}"
swift build --package-path "${SCRIPT_DIR}" -c "${CONFIGURATION}"
BIN="$(swift build --package-path "${SCRIPT_DIR}" -c "${CONFIGURATION}" --show-bin-path)"

# SwiftPM names the binary after the executable PRODUCT, but the target name is
# a plausible fallback and guessing wrong here would produce an .app with no
# executable, which macOS reports only as "the application quit unexpectedly".
EXECUTABLE=""
for candidate in RunnerForge RunnerForgeApp; do
    if [[ -x "${BIN}/${candidate}" ]]; then
        EXECUTABLE="${BIN}/${candidate}"
        break
    fi
done

if [[ -z "${EXECUTABLE}" ]]; then
    echo "build.sh: no executable found in ${BIN}. Contents:" >&2
    ls -l "${BIN}" >&2
    exit 1
fi
echo "    executable: ${EXECUTABLE}"

echo "==> assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"

cp "${EXECUTABLE}" "${CONTENTS}/MacOS/RunnerForge"
cp "${SCRIPT_DIR}/Sources/RunnerForge/Resources/Info.plist" "${CONTENTS}/Info.plist"
printf 'APPL????' > "${CONTENTS}/PkgInfo"

# The scripts and templates are resources of the product. The app looks for them
# under Bundle.main.resourceURL, so a user who moves the .app keeps a working
# install rather than one that silently loses its Export page.
if [[ -d "${REPO_ROOT}/scripts" ]]; then
    mkdir -p "${CONTENTS}/Resources/scripts"
    cp "${REPO_ROOT}"/scripts/*.sh "${CONTENTS}/Resources/scripts/"
    chmod +x "${CONTENTS}/Resources/scripts/"*.sh
fi
if [[ -d "${REPO_ROOT}/templates" ]]; then
    mkdir -p "${CONTENTS}/Resources/templates"
    cp "${REPO_ROOT}"/templates/*.tmpl "${CONTENTS}/Resources/templates/"
fi

echo "==> signing"
if [[ -n "${SIGN_IDENTITY}" ]]; then
    # Sign inside-out. NEVER --deep: it is deprecated and re-signs nested code
    # with the OUTER bundle's entitlements, which produces a bundle that passes
    # codesign and fails notarization.
    find "${CONTENTS}/Resources" -type f -perm -u+x -print0 |
        while IFS= read -r -d '' nested; do
            codesign --force --timestamp --options runtime \
                --sign "${SIGN_IDENTITY}" "${nested}"
        done

    codesign --force --timestamp --options runtime \
        --entitlements "${SCRIPT_DIR}/Sources/RunnerForge/Resources/RunnerForge.entitlements" \
        --sign "${SIGN_IDENTITY}" "${APP}"

    codesign --verify --strict --verbose=2 "${APP}"
else
    # Ad-hoc signing so the app runs on the machine that built it. It is NOT
    # distributable: Gatekeeper rejects it anywhere else, by design.
    codesign --force --sign - \
        --entitlements "${SCRIPT_DIR}/Sources/RunnerForge/Resources/RunnerForge.entitlements" "${APP}"
    echo "    ad-hoc signed (no --sign identity given): runs here, not elsewhere."
fi

echo "==> building DMG"
DMG="${OUT_DIR}/RunnerForge.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

cp -R "${APP}" "${STAGE}/RunnerForge.app"
ln -s /Applications "${STAGE}/Applications"

rm -f "${DMG}"
hdiutil create -volname "Runner Forge" -srcfolder "${STAGE}" \
    -ov -format UDZO "${DMG}" >/dev/null

if [[ -n "${SIGN_IDENTITY}" ]]; then
    codesign --force --timestamp --sign "${SIGN_IDENTITY}" "${DMG}"
fi

if [[ "${NOTARIZE}" -eq 1 ]]; then
    : "${APPLE_ASC_ISSUER_ID:?--notarize needs APPLE_ASC_ISSUER_ID}"
    : "${APPLE_ASC_KEY_ID:?--notarize needs APPLE_ASC_KEY_ID}"
    : "${APPLE_ASC_PRIVATE_KEY:?--notarize needs APPLE_ASC_PRIVATE_KEY}"

    KEY_FILE="$(mktemp)"
    chmod 600 "${KEY_FILE}"
    printf '%s' "${APPLE_ASC_PRIVATE_KEY}" > "${KEY_FILE}"
    trap 'rm -rf "${STAGE}"; rm -f "${KEY_FILE}"' EXIT

    echo "==> notarizing"
    xcrun notarytool submit "${DMG}" \
        --issuer "${APPLE_ASC_ISSUER_ID}" \
        --key-id "${APPLE_ASC_KEY_ID}" \
        --key "${KEY_FILE}" \
        --wait

    # Stapling is not optional. Without the ticket stapled INTO the artifact,
    # every machine but this one has to ask Apple at launch, and fails closed
    # when it cannot.
    echo "==> stapling"
    xcrun stapler staple "${DMG}"
    xcrun stapler validate "${DMG}"
fi

echo
echo "app: ${APP}"
echo "dmg: ${DMG}"
ls -l "${DMG}"
