#!/usr/bin/env bash
# Shared helpers for the IAM least-privilege tutorial.

set -Eeuo pipefail

# ---- LocalEmu endpoint + ROOT credentials -----------------------------------
# LocalEmu treats AKIAIOSFODNN7EXAMPLE as a ROOT key by default, so these
# calls bypass IAM_ENFORCEMENT. The Lambda we create runs under STS-derived
# session credentials that ARE enforced: that's what the test loop hits.
: "${AWS_ENDPOINT_URL:=http://localhost:4566}"
: "${AWS_REGION:=us-east-1}"
: "${AWS_DEFAULT_REGION:=us-east-1}"
: "${AWS_ACCESS_KEY_ID:=AKIAIOSFODNN7EXAMPLE}"
: "${AWS_SECRET_ACCESS_KEY:=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY}"
export AWS_ENDPOINT_URL AWS_REGION AWS_DEFAULT_REGION
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

TUTORIAL_ROOT="${TUTORIAL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${STATE_DIR:-${TUTORIAL_ROOT}/.state}"
mkdir -p "${STATE_DIR}"
export TUTORIAL_ROOT STATE_DIR

# ---- Logging ----------------------------------------------------------------
_color() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
log()  { _color '36' "[$(date +%H:%M:%S)] $*"; }
ok()   { _color '32' "  ✓ $*"; }
warn() { _color '33' "  ! $*"; }
fail() { _color '31' "  ✗ $*"; exit 1; }

bold() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

# ---- AWS CLI wrapper --------------------------------------------------------
awsx() {
  aws --endpoint-url "${AWS_ENDPOINT_URL}" --region "${AWS_REGION}" "$@"
}

# ---- Health + IAM_ENFORCEMENT check -----------------------------------------
need_healthy_localemu() {
  if ! curl -s -m 3 "${AWS_ENDPOINT_URL}/_localemu/health" >/dev/null; then
    fail "LocalEmu is not responding at ${AWS_ENDPOINT_URL}. Start it with: IAM_ENFORCEMENT=1 localemu start"
  fi
}

# ---- State helpers ----------------------------------------------------------
state_set()  { printf 'export %s=%q\n' "$1" "$2" >> "${STATE_DIR}/ids.env"; }
state_load() { [[ -f "${STATE_DIR}/ids.env" ]] && source "${STATE_DIR}/ids.env" || true; }

# ---- Invoke the Lambda and return its JSON payload --------------------------
# Usage: invoke_lambda <function-name> <payload-json>
# Prints the raw JSON response to stdout. Uses fileb:// for the payload
# so it works with both AWS CLI v1 and v2 (v2 otherwise base64-decodes
# --payload unless --cli-binary-format is set).
invoke_lambda() {
  local fn="$1"; local payload="$2"
  local payload_file="${STATE_DIR}/invoke.payload.json"
  local out="${STATE_DIR}/invoke.out"
  printf '%s' "${payload}" > "${payload_file}"
  awsx lambda invoke \
    --function-name "${fn}" \
    --payload "fileb://${payload_file}" \
    "${out}" >/dev/null
  cat "${out}"
}
