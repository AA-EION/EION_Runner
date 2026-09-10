#!/usr/bin/env bash
#
# jitconfig.sh — mint a just-in-time runner configuration.
#
# This is the only way a Runner Forge runner ever registers. There is no
# long-lived registration token anywhere in this product, and no config.sh step:
# a JIT config IS the configuration, and it is valid for exactly one job.
#
# The flow:
#   1. Sign a JWT with the GitHub App private key (RS256, iat -60s, exp +9min).
#      The 60-second backdate absorbs clock skew between this machine and
#      GitHub, which otherwise rejects the token as issued in the future.
#   2. POST /app/installations/{id}/access_tokens  -> an installation token.
#   3. POST /repos/{owner}/{repo}/actions/runners/generate-jitconfig
#      -> a base64 blob that is the runner's whole configuration.
#
# The blob is written to STDOUT and nowhere else, so the caller can pipe it
# straight into `docker run -i` without it ever touching disk:
#
#   scripts/jitconfig.sh --owner o --repo r --app-id 1 --installation-id 2 \
#       --key-file /path/key.pem --class-id linux-util \
#       --labels self-hosted,linux,x64,container,forge \
#     | docker run -i --rm runnerforge/linux-util:1.0.0
#
# The private key never appears in argv — only the PATH to it does. Everything
# this script prints for humans goes to stderr, so stdout carries the blob and
# nothing else.
#
set -euo pipefail

API="${GITHUB_API_URL:-https://api.github.com}"

OWNER=""; REPO=""; APP_ID=""; INSTALLATION_ID=""; KEY_FILE=""
CLASS_ID=""; LABELS=""; RUNNER_NAME=""; RUNNER_GROUP_ID="1"; PRINT_NAME_ONLY=0

usage() {
  cat >&2 <<'USAGE'
Usage: jitconfig.sh --owner <owner> --repo <repo> --app-id <id>
                    --installation-id <id> --class-id <classId>
                    --labels <comma,separated>
                    [--key-file <path> | key on stdin]
                    [--runner-name <name>] [--runner-group-id <n>]
                    [--print-name]

  --key-file        PEM private key path. If omitted the key is read from stdin.
                    The key is never passed as an argument.
  --runner-name     Defaults to forge-<classId>-<shorthost>-<8 hex>.
  --print-name      Print the generated runner name to stderr as well.

Writes the JIT config blob to stdout and nothing else.
Exit codes: 0 ok, 2 usage, 3 missing dependency, 4 GitHub API error.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner)            OWNER="${2:-}"; shift 2 ;;
    --repo)             REPO="${2:-}"; shift 2 ;;
    --app-id)           APP_ID="${2:-}"; shift 2 ;;
    --installation-id)  INSTALLATION_ID="${2:-}"; shift 2 ;;
    --key-file)         KEY_FILE="${2:-}"; shift 2 ;;
    --class-id)         CLASS_ID="${2:-}"; shift 2 ;;
    --labels)           LABELS="${2:-}"; shift 2 ;;
    --runner-name)      RUNNER_NAME="${2:-}"; shift 2 ;;
    --runner-group-id)  RUNNER_GROUP_ID="${2:-}"; shift 2 ;;
    --print-name)       PRINT_NAME_ONLY=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage; exit 2 ;;
  esac
done

need() { [[ -n "${2}" ]] || { echo "error: $1 is required" >&2; usage; exit 2; }; }
need --owner "$OWNER"
need --repo "$REPO"
need --app-id "$APP_ID"
need --installation-id "$INSTALLATION_ID"
need --class-id "$CLASS_ID"
need --labels "$LABELS"

for tool in curl jq openssl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is required but not on PATH" >&2; exit 3; }
done

# --- the private key --------------------------------------------------------
# Held in a shell variable and never written to disk by this script.
if [[ -n "$KEY_FILE" ]]; then
  [[ -r "$KEY_FILE" ]] || { echo "error: cannot read key file: $KEY_FILE" >&2; exit 2; }
  PRIVATE_KEY="$(cat "$KEY_FILE")"
else
  [[ ! -t 0 ]] || { echo "error: no --key-file given and stdin is a terminal" >&2; exit 2; }
  PRIVATE_KEY="$(cat)"
fi

case "$PRIVATE_KEY" in
  *"-----BEGIN "*"PRIVATE KEY-----"*) : ;;
  *) echo "error: the supplied key is not a PEM private key" >&2; exit 2 ;;
esac

# --- runner name ------------------------------------------------------------
if [[ -z "$RUNNER_NAME" ]]; then
  SHORTHOST="$(hostname -s 2>/dev/null || hostname)"
  SHORTHOST="$(printf '%s' "$SHORTHOST" | tr -cd '[:alnum:]-' | cut -c1-16)"
  SUFFIX="$(openssl rand -hex 4)"
  RUNNER_NAME="forge-${CLASS_ID}-${SHORTHOST}-${SUFFIX}"
fi
[[ "$PRINT_NAME_ONLY" -eq 1 ]] && echo "runner name: $RUNNER_NAME" >&2

# --- 1. the app JWT ---------------------------------------------------------
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

NOW="$(date +%s)"
HEADER='{"alg":"RS256","typ":"JWT"}'
# iat is backdated 60s for clock skew; exp is 9 minutes, inside GitHub's 10
# minute maximum.
PAYLOAD="$(jq -cn --argjson iat "$((NOW - 60))" --argjson exp "$((NOW + 540))" \
                  --arg iss "$APP_ID" '{iat:$iat, exp:$exp, iss:$iss}')"

SIGNING_INPUT="$(printf '%s' "$HEADER" | b64url).$(printf '%s' "$PAYLOAD" | b64url)"

SIGNATURE="$(printf '%s' "$SIGNING_INPUT" \
  | openssl dgst -sha256 -sign <(printf '%s\n' "$PRIVATE_KEY") -binary \
  | b64url)" || { echo "error: failed to sign the JWT — is the key a valid RSA private key?" >&2; exit 2; }

JWT="${SIGNING_INPUT}.${SIGNATURE}"
PRIVATE_KEY=""; unset PRIVATE_KEY

# --- 2. the installation token ---------------------------------------------
api_post() {
  # $1 url, $2 auth header value, $3 body ("" for none)
  local url="$1" auth="$2" body="${3:-}"
  local response http
  if [[ -n "$body" ]]; then
    response="$(curl -sS --max-time 60 -w $'\n%{http_code}' -X POST \
      -H "Authorization: $auth" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -H "Content-Type: application/json" \
      -d "$body" "$url")"
  else
    response="$(curl -sS --max-time 60 -w $'\n%{http_code}' -X POST \
      -H "Authorization: $auth" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$url")"
  fi
  http="$(printf '%s' "$response" | tail -n1)"
  printf '%s' "$response" | sed '$d'
  [[ "$http" =~ ^2 ]] || return 1
}

TOKEN_JSON="$(api_post "${API}/app/installations/${INSTALLATION_ID}/access_tokens" "Bearer ${JWT}")" || {
  # The GitHub error body is surfaced verbatim: guessing at what a 401 means
  # wastes far more time than reading what GitHub actually said.
  echo "error: could not mint an installation token. GitHub said:" >&2
  printf '%s\n' "$TOKEN_JSON" >&2
  exit 4
}
JWT=""; unset JWT

INSTALLATION_TOKEN="$(printf '%s' "$TOKEN_JSON" | jq -r '.token // empty')"
[[ -n "$INSTALLATION_TOKEN" ]] || { echo "error: response contained no token" >&2; exit 4; }

# --- 3. the JIT config ------------------------------------------------------
LABELS_JSON="$(printf '%s' "$LABELS" | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0))')"
BODY="$(jq -cn --arg name "$RUNNER_NAME" \
               --argjson labels "$LABELS_JSON" \
               --argjson group "$RUNNER_GROUP_ID" \
               '{name:$name, runner_group_id:$group, labels:$labels}')"

JIT_JSON="$(api_post "${API}/repos/${OWNER}/${REPO}/actions/runners/generate-jitconfig" \
                     "Bearer ${INSTALLATION_TOKEN}" "$BODY")" || {
  echo "error: could not generate a JIT config. GitHub said:" >&2
  printf '%s\n' "$JIT_JSON" >&2
  exit 4
}
INSTALLATION_TOKEN=""; unset INSTALLATION_TOKEN

BLOB="$(printf '%s' "$JIT_JSON" | jq -r '.encoded_jit_config // empty')"
[[ -n "$BLOB" ]] || { echo "error: response contained no encoded_jit_config" >&2; exit 4; }

echo "minted a JIT config for ${RUNNER_NAME} (${#BLOB} bytes)" >&2

# stdout carries the blob and nothing else.
printf '%s\n' "$BLOB"
