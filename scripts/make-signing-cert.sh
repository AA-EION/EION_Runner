#!/usr/bin/env bash
#
# make-signing-cert.sh — create a SELF-SIGNED code-signing certificate on macOS.
#
# This exists for one situation: you want to sign an AAX plugin with wraptool and
# you do not (yet) have an Apple Developer ID Application certificate. PACE's own
# guidance is explicit that this is a LEARNING AND TESTING step, not a shipping
# one — see docs/SIGNING.md, which spells out exactly what a self-signed
# certificate can and cannot do for a plugin you hand to someone else.
#
# The certificate is built with the settings PACE's Signing Resources page
# specifies for a self-signed certificate:
#
#   Identity Type ............ Self Signed Root
#   Certificate Type ......... Code Signing
#   Key Size / Algorithm ..... 2048-bit RSA
#   Extended Key Usage ....... Code Signing
#   Basic Constraints ........ NOT included
#   Subject Alternate Name ... NOT included
#   Keychain ................. login (by default; --keychain overrides)
#
# Those last two "NOT included" lines are why this uses an explicit OpenSSL
# extensions section rather than the default one: OpenSSL's stock `v3_ca`
# section adds `basicConstraints=critical,CA:true`, which is precisely what the
# SDK tells you to leave out.
#
# WHERE THE PRIVATE KEY GOES: into the keychain, and nowhere else. It is NEVER
# written next to the plugin and NEVER shipped inside the bundle. A signing key
# that travels with the artifact is not a signing key, it is a published key —
# anyone holding it can sign anything as you.
#
set -euo pipefail

NAME=""
KEYCHAIN=""
DAYS=1095          # 3 years, matching the Windows twin's -NotAfter default
EXPORT_P12=""
FORCE=0

usage() {
  cat <<'USAGE'
make-signing-cert.sh — create a self-signed code-signing certificate (macOS).

Usage:
  make-signing-cert.sh --name "My Plugin Signing" [options]

  --name <string>      Certificate common name. This exact string is what you
                       pass to wraptool as --signid, so choose it deliberately.
  --keychain <path>    Keychain to import into. Default: the login keychain.
  --days <n>           Validity in days. Default: 1095 (3 years).
  --export-p12 <path>  Also write a PKCS#12 backup. The export password is read
                       from P12_PASSWORD in the environment, never from argv.
  --force              Replace an existing identity of the same name.
  --help

Exit codes: 0 ok, 2 usage, 3 environment/prerequisite problem, 4 failure.

After it runs, confirm the identity the way PACE documents:
  security find-identity -p codesigning
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)       NAME="${2:-}"; shift 2 ;;
    --keychain)   KEYCHAIN="${2:-}"; shift 2 ;;
    --days)       DAYS="${2:-}"; shift 2 ;;
    --export-p12) EXPORT_P12="${2:-}"; shift 2 ;;
    --force)      FORCE=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

log() { printf '[make-signing-cert] %s\n' "$*"; }

[[ -n "$NAME" ]] || { echo "error: --name is required" >&2; usage >&2; exit 2; }

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: this is the macOS generator. On Windows use scripts/make-signing-cert.ps1." >&2
  exit 3
fi

command -v openssl  >/dev/null 2>&1 || { echo "error: openssl not found on PATH"  >&2; exit 3; }
command -v security >/dev/null 2>&1 || { echo "error: security not found on PATH" >&2; exit 3; }

if [[ -z "$KEYCHAIN" ]]; then
  KEYCHAIN="$(security default-keychain | tr -d ' "')"
fi
log "keychain: $KEYCHAIN"

# An identity that already exists is not silently replaced: two identities with
# the same name make --signid ambiguous, and wraptool picks one without telling
# you which.
if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -qF "\"$NAME\""; then
  if [[ "$FORCE" -eq 0 ]]; then
    echo "error: a code-signing identity named \"$NAME\" already exists in $KEYCHAIN." >&2
    echo "       Two identities with one name make --signid ambiguous. Pass --force to" >&2
    echo "       replace it, or choose a different --name." >&2
    exit 3
  fi
  log "--force given: deleting the existing certificate named \"$NAME\""
  while security delete-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; do :; done
fi

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

CONFIG="$WORK/openssl.cnf"
cat > "$CONFIG" <<CONF
[req]
distinguished_name = dn
prompt             = no

[dn]
CN = ${NAME}

# Exactly the extensions the PACE Signing Resources page asks for, and nothing
# else. No basicConstraints, no subjectAltName.
[codesign]
keyUsage             = critical, digitalSignature
extendedKeyUsage     = critical, codeSigning
subjectKeyIdentifier = hash
CONF

log "generating a 2048-bit RSA self-signed code-signing certificate valid for ${DAYS} days"
openssl req -x509 \
  -newkey rsa:2048 \
  -sha256 \
  -days "$DAYS" \
  -nodes \
  -config "$CONFIG" \
  -extensions codesign \
  -keyout "$WORK/key.pem" \
  -out "$WORK/cert.pem" >/dev/null 2>&1 || {
    echo "error: openssl could not generate the certificate" >&2
    exit 4
  }

# Proof rather than assumption: if basicConstraints crept in, say so and stop.
if openssl x509 -in "$WORK/cert.pem" -noout -text | grep -q "X509v3 Basic Constraints"; then
  echo "error: the generated certificate carries a Basic Constraints extension." >&2
  echo "       The PACE SDK explicitly says not to include it. Refusing to import." >&2
  exit 4
fi
openssl x509 -in "$WORK/cert.pem" -noout -text | grep -q "Code Signing" || {
  echo "error: the generated certificate has no Code Signing extended key usage." >&2
  exit 4
}
log "verified: Code Signing EKU present, Basic Constraints absent"

# A transient password for the import only. It never reaches argv: openssl reads
# it from a file descriptor and `security` from an env-backed pass phrase.
IMPORT_PW="$(openssl rand -base64 24)"
printf '%s' "$IMPORT_PW" > "$WORK/pw"
chmod 600 "$WORK/pw"

openssl pkcs12 -export \
  -inkey "$WORK/key.pem" \
  -in "$WORK/cert.pem" \
  -name "$NAME" \
  -out "$WORK/bundle.p12" \
  -passout "file:$WORK/pw" >/dev/null 2>&1 || {
    echo "error: could not package the certificate and key as PKCS#12" >&2
    exit 4
  }

# -T grants the named tools access to the key without a UI prompt at signing
# time. codesign is what wraptool drives on macOS; wraptool itself is granted
# too when it can be located.
IMPORT_ARGS=(-k "$KEYCHAIN" -f pkcs12 -P "$IMPORT_PW" -T /usr/bin/codesign)
for candidate in /Applications/PACEAntiPiracy/Eden/Fusion/Versions/*/bin/wraptool; do
  [[ -x "$candidate" ]] && IMPORT_ARGS+=(-T "$candidate")
done

log "importing into the keychain"
security import "$WORK/bundle.p12" "${IMPORT_ARGS[@]}" >/dev/null || {
  echo "error: security import failed" >&2
  exit 4
}

# Without this, macOS prompts for the keychain password the first time codesign
# touches the key — which is fatal on a runner with nobody at the screen.
if ! security set-key-partition-list \
      -S apple-tool:,apple:,codesign: \
      -s -k "" "$KEYCHAIN" >/dev/null 2>&1; then
  log "NOTE: could not set the key partition list without a keychain password."
  log "      Signing will still work, but macOS may prompt the first time. Run:"
  log "      security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <pw> $KEYCHAIN"
fi

# Trusting the root locally makes `codesign --verify` and Keychain Access stop
# reporting the certificate as untrusted ON THIS MACHINE ONLY. It changes
# nothing anywhere else, which is the whole point of a self-signed root.
if security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" >/dev/null 2>&1; then
  log "trusted for code signing on this machine (local trust only)"
else
  log "NOTE: could not add local trust (this usually needs an administrator)."
  log "      Signing still works; find-identity will report CSSMERR_TP_NOT_TRUSTED."
fi

if [[ -n "$EXPORT_P12" ]]; then
  if [[ -z "${P12_PASSWORD:-}" ]]; then
    echo "error: --export-p12 needs P12_PASSWORD in the environment." >&2
    echo "       It is read from the environment and never from the argument list," >&2
    echo "       because an argument list is readable by any user on this machine." >&2
    exit 2
  fi
  printf '%s' "$P12_PASSWORD" > "$WORK/exportpw"
  chmod 600 "$WORK/exportpw"
  openssl pkcs12 -export \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$EXPORT_P12" -passout "file:$WORK/exportpw" >/dev/null 2>&1 || {
      echo "error: could not write the PKCS#12 backup" >&2
      exit 4
    }
  chmod 600 "$EXPORT_P12"
  log "PKCS#12 backup written to $EXPORT_P12 (mode 600)"
  log "KEEP IT OUT OF THE PLUGIN AND OUT OF GIT. It contains the private key."
fi

echo
log "done. The signing identity is:"
echo
security find-identity -p codesigning "$KEYCHAIN" | grep -F "\"$NAME\"" || true
echo
log "Pass it to wraptool as:  --signid \"$NAME\""
