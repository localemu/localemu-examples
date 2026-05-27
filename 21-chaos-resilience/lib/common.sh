#!/usr/bin/env bash
# Shared helpers for the chaos resilience tutorial.

set -Eeuo pipefail

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

_color() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
log()  { _color '36' "[$(date +%H:%M:%S)] $*"; }
ok()   { _color '32' "  ✓ $*"; }
warn() { _color '33' "  ! $*"; }
fail() { _color '31' "  ✗ $*"; exit 1; }
bold() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

awsx() {
  aws --endpoint-url "${AWS_ENDPOINT_URL}" --region "${AWS_REGION}" "$@"
}

need_healthy_localemu() {
  if ! curl -s -m 3 "${AWS_ENDPOINT_URL}/_localemu/health" >/dev/null; then
    fail "LocalEmu is not responding at ${AWS_ENDPOINT_URL}. Start it with: localemu start"
  fi
}

state_set()  { printf 'export %s=%q\n' "$1" "$2" >> "${STATE_DIR}/ids.env"; }
state_load() { [[ -f "${STATE_DIR}/ids.env" ]] && source "${STATE_DIR}/ids.env" || true; }

# Detect what chaos LocalEmu is configured with (best-effort: reads
# the process env). Prints one line per active mode.
detect_chaos() {
  local pid env=""
  pid=$(lsof -tiTCP:4566 -sTCP:LISTEN 2>/dev/null | head -1)
  [[ -z "${pid}" ]] && return 0
  env=$(ps -E -p "${pid}" -o command= 2>/dev/null \
        | tr ' ' '\n' \
        | grep -E '^(SIMULATE_THROTTLING|THROTTLE_RATE|[A-Z]+_THROTTLE_RATE|SIMULATE_LATENCY)=' \
        || true)
  if [[ -n "${env}" ]]; then
    printf '%s\n' "${env}"
  else
    printf 'no chaos flags detected (LocalEmu is in calm-mode)\n'
  fi
}
