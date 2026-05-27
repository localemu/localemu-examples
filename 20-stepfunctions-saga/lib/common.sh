#!/usr/bin/env bash
# Shared helpers for the Step Functions saga tutorial.

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

# ---- Step Functions helpers -------------------------------------------------

# Start an execution and wait until it leaves RUNNING. Prints the final
# status (SUCCEEDED|FAILED|TIMED_OUT|ABORTED) to stdout.
start_and_wait() {
  local sm_arn="$1"; local payload="$2"; local timeout="${3:-30}"
  local exec_arn
  exec_arn=$(awsx stepfunctions start-execution \
    --state-machine-arn "${sm_arn}" \
    --input "${payload}" \
    --query 'executionArn' --output text)
  printf 'EXEC=%s\n' "${exec_arn}" >&2
  local deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    local status
    status=$(awsx stepfunctions describe-execution \
      --execution-arn "${exec_arn}" \
      --query 'status' --output text 2>/dev/null || echo "?")
    case "${status}" in
      RUNNING) sleep 1 ;;
      *) printf '%s\n' "${status}"; return 0 ;;
    esac
  done
  printf 'TIMEOUT\n'
  return 1
}

# DynamoDB item exists?  Returns 0 if present, 1 otherwise.
ddb_has() {
  local table="$1"; local key="$2"
  local item
  item=$(awsx dynamodb get-item \
    --table-name "${table}" \
    --key "{\"order_id\":{\"S\":\"${key}\"}}" \
    --query 'Item' --output text 2>/dev/null || echo "None")
  [[ "${item}" != "None" && -n "${item}" ]]
}
