#!/usr/bin/env bash
#
# Canary — build the macOS .pkg and .dmg.
#
# Produces exactly one .pkg and one .dmg, which is what the artifact contract in
# docs/VERIFICATION.md requires of the {p}-macos-installer artifact.
#
# Signing and notarization are deliberately NOT done here — that is
# scripts/sign-macos-artifact.sh's job, so that an unsigned local build and a
# signed CI build produce byte-identical package layouts.
#
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: build_installer.sh --build-dir <dir> --version <x.y.z> --output-dir <dir>
                          [--identifier <bundle id>] [--product-name <name>]

  --build-dir      Canary_artefacts/Release directory holding VST3/, AU/, CLAP/, Standalone/
  --version        Version string used in the package and file names
  --output-dir     Where the .pkg and .dmg are written
  --identifier     Base bundle identifier (default: com.eionstudios.canary)
  --product-name   Product name (default: Canary)
  -h, --help       Show this help

Exits non-zero if any required input is missing or if either package fails to build.
USAGE
}

BUILD_DIR=""
VERSION=""
OUTPUT_DIR=""
IDENTIFIER="com.eionstudios.canary"
PRODUCT_NAME="Canary"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir)    BUILD_DIR="${2:-}"; shift 2 ;;
    --version)      VERSION="${2:-}"; shift 2 ;;
    --output-dir)   OUTPUT_DIR="${2:-}"; shift 2 ;;
    --identifier)   IDENTIFIER="${2:-}"; shift 2 ;;
    --product-name) PRODUCT_NAME="${2:-}"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

require_arg() {
  local value="$1" flag="$2"
  if [[ -z "$value" ]]; then
    echo "error: $flag is required" >&2
    usage >&2
    exit 2
  fi
}

require_arg "$BUILD_DIR"  "--build-dir"
require_arg "$VERSION"    "--version"
require_arg "$OUTPUT_DIR" "--output-dir"

if [[ ! -d "$BUILD_DIR" ]]; then
  echo "error: build dir does not exist: $BUILD_DIR" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/canary-pkg.XXXXXX")"
cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

# --- lay out the payload exactly where macOS expects each format -------------
VST3_ROOT="$STAGING/vst3/Library/Audio/Plug-Ins/VST3"
AU_ROOT="$STAGING/au/Library/Audio/Plug-Ins/Components"
CLAP_ROOT="$STAGING/clap/Library/Audio/Plug-Ins/CLAP"
APP_ROOT="$STAGING/app/Applications"
mkdir -p "$VST3_ROOT" "$AU_ROOT" "$CLAP_ROOT" "$APP_ROOT"

copied_any=0

copy_if_present() {
  local src="$1" dest="$2" label="$3"
  if [[ -e "$src" ]]; then
    # -R preserves the bundle's symlinks, which a plain cp would flatten.
    cp -R "$src" "$dest/"
    echo "  staged $label"
    copied_any=1
  else
    echo "  skipped $label (not built: $src)"
  fi
}

echo "Staging payload from $BUILD_DIR"
copy_if_present "$BUILD_DIR/VST3/${PRODUCT_NAME}.vst3"           "$VST3_ROOT" "VST3"
copy_if_present "$BUILD_DIR/AU/${PRODUCT_NAME}.component"        "$AU_ROOT"   "AU"
copy_if_present "$BUILD_DIR/CLAP/${PRODUCT_NAME}.clap"           "$CLAP_ROOT" "CLAP"
copy_if_present "$BUILD_DIR/Standalone/${PRODUCT_NAME}.app"      "$APP_ROOT"  "Standalone"

if [[ "$copied_any" -eq 0 ]]; then
  echo "error: nothing was staged — no plugin formats found under $BUILD_DIR" >&2
  echo "       this would produce an empty installer, which the artifact contract forbids" >&2
  exit 1
fi

# --- component packages ------------------------------------------------------
COMPONENTS_DIR="$STAGING/components"
mkdir -p "$COMPONENTS_DIR"

build_component() {
  local root="$1" id_suffix="$2" install_location="$3" out="$4"
  # An empty payload root produces a valid but useless package; skip it.
  if [[ -z "$(find "$root" -mindepth 1 -maxdepth 4 -print -quit 2>/dev/null)" ]]; then
    return 0
  fi
  pkgbuild \
    --root "$root" \
    --identifier "${IDENTIFIER}.${id_suffix}" \
    --version "$VERSION" \
    --install-location "$install_location" \
    "$out"
}

build_component "$STAGING/vst3" "vst3"       "/" "$COMPONENTS_DIR/vst3.pkg"
build_component "$STAGING/au"   "au"         "/" "$COMPONENTS_DIR/au.pkg"
build_component "$STAGING/clap" "clap"       "/" "$COMPONENTS_DIR/clap.pkg"
build_component "$STAGING/app"  "standalone" "/" "$COMPONENTS_DIR/app.pkg"

# --- distribution package ----------------------------------------------------
DIST="$STAGING/distribution.xml"
{
  echo '<?xml version="1.0" encoding="utf-8"?>'
  echo '<installer-gui-script minSpecVersion="2">'
  echo "  <title>${PRODUCT_NAME} ${VERSION}</title>"
  echo '  <options customize="allow" require-scripts="false" hostArchitectures="arm64,x86_64"/>'
  echo '  <choices-outline>'
  for component in "$COMPONENTS_DIR"/*.pkg; do
    [[ -e "$component" ]] || continue
    echo "    <line choice=\"$(basename "$component" .pkg)\"/>"
  done
  echo '  </choices-outline>'
  for component in "$COMPONENTS_DIR"/*.pkg; do
    [[ -e "$component" ]] || continue
    name="$(basename "$component" .pkg)"
    echo "  <choice id=\"${name}\" title=\"${name}\" visible=\"true\"><pkg-ref id=\"${IDENTIFIER}.${name}\"/></choice>"
    echo "  <pkg-ref id=\"${IDENTIFIER}.${name}\" version=\"${VERSION}\">${name}.pkg</pkg-ref>"
  done
  echo '</installer-gui-script>'
} > "$DIST"

PKG_PATH="$OUTPUT_DIR/${PRODUCT_NAME}-${VERSION}-macos.pkg"
productbuild \
  --distribution "$DIST" \
  --package-path "$COMPONENTS_DIR" \
  "$PKG_PATH"

echo "built $PKG_PATH"

# --- disk image --------------------------------------------------------------
DMG_STAGING="$STAGING/dmg"
mkdir -p "$DMG_STAGING"
cp "$PKG_PATH" "$DMG_STAGING/"

DMG_PATH="$OUTPUT_DIR/${PRODUCT_NAME}-${VERSION}-macos.dmg"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "${PRODUCT_NAME} ${VERSION}" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "built $DMG_PATH"

# --- prove both exist and are non-empty --------------------------------------
for produced in "$PKG_PATH" "$DMG_PATH"; do
  if [[ ! -s "$produced" ]]; then
    echo "error: $produced is missing or empty" >&2
    exit 1
  fi
  printf '  %10d bytes  %s\n' "$(stat -f%z "$produced" 2>/dev/null || stat -c%s "$produced")" "$produced"
done
