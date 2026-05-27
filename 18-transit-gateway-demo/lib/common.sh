#!/usr/bin/env bash
# Shared helpers for the tutorial scripts. Sourced by every infra/*.sh.

# Fail fast, preserve pipe exit codes, surface undefined variables.
set -Eeuo pipefail

# ---- LocalEmu endpoint ------------------------------------------------------

: "${AWS_ENDPOINT_URL:=http://localhost:4566}"
: "${AWS_REGION:=us-east-1}"
: "${AWS_DEFAULT_REGION:=us-east-1}"
: "${AWS_ACCESS_KEY_ID:=AKIAIOSFODNN7EXAMPLE}"
: "${AWS_SECRET_ACCESS_KEY:=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY}"
export AWS_ENDPOINT_URL AWS_REGION AWS_DEFAULT_REGION
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

# ---- State ------------------------------------------------------------------
# Each script writes ids into $STATE_DIR/*.env so later scripts can source them
# without re-querying AWS.

TUTORIAL_ROOT="${TUTORIAL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export TUTORIAL_ROOT
STATE_DIR="${STATE_DIR:-${TUTORIAL_ROOT}/.state}"
export STATE_DIR
mkdir -p "${STATE_DIR}"

# ---- Logging ----------------------------------------------------------------
# Prefix every line so mixed step output is readable when piped together.

_color() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
log()   { _color '36' "[$(date +%H:%M:%S)] $*"; }
ok()    { _color '32' "  ✓ $*"; }
warn()  { _color '33' "  ! $*"; }
fail()  { _color '31' "  ✗ $*"; exit 1; }

# ---- AWS CLI wrapper --------------------------------------------------------
# Always targets the LocalEmu endpoint. Use instead of `aws` directly.

awsx() {
  aws --endpoint-url "${AWS_ENDPOINT_URL}" --region "${AWS_REGION}" "$@"
}

# ---- Retry primitive --------------------------------------------------------
# retry <max_tries> <sleep_seconds> <cmd...>
# Runs the command up to max_tries times with a short delay between attempts.
# Exits 0 on first success, non-zero if all attempts fail.

retry() {
  local max="$1"; local delay="$2"; shift 2
  local attempt=1 rc
  while true; do
    if "$@"; then return 0; fi
    rc=$?
    if (( attempt >= max )); then
      return "${rc}"
    fi
    sleep "${delay}"
    attempt=$(( attempt + 1 ))
  done
}

# ---- Wait-for helpers -------------------------------------------------------

wait_instance_running() {
  local iid="$1"; local timeout="${2:-60}"
  local deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    local s
    s=$(awsx ec2 describe-instances --instance-ids "${iid}" \
          --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "?")
    [[ "${s}" == "running" ]] && return 0
    sleep 1
  done
  return 1
}

# ---- SSM exec ---------------------------------------------------------------
# ssm_run <instance-id> <shell-cmd>
#   Sends a shell command to the instance via SSM. Prints stdout only when
#   the invocation finishes Success; non-zero exit with stderr otherwise.
#   Usage: out=$(ssm_run i-abc "hostname")

ssm_run() {
  local iid="$1"; shift
  local cmd="$*"
  local cid
  cid=$(awsx ssm send-command \
          --document-name AWS-RunShellScript \
          --instance-ids "${iid}" \
          --parameters "commands=[$(printf '%s' "${cmd}" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))')]" \
          --query 'Command.CommandId' --output text)
  local deadline=$(( $(date +%s) + 30 ))
  while (( $(date +%s) < deadline )); do
    local status output rc
    status=$(awsx ssm get-command-invocation \
              --command-id "${cid}" --instance-id "${iid}" \
              --query 'Status' --output text 2>/dev/null || echo "Pending")
    case "${status}" in
      Success)
        awsx ssm get-command-invocation \
          --command-id "${cid}" --instance-id "${iid}" \
          --query 'StandardOutputContent' --output text
        return 0
        ;;
      Failed|TimedOut|Cancelled)
        output=$(awsx ssm get-command-invocation \
                  --command-id "${cid}" --instance-id "${iid}" \
                  --query 'StandardErrorContent' --output text 2>/dev/null || echo "")
        rc=$(awsx ssm get-command-invocation \
                  --command-id "${cid}" --instance-id "${iid}" \
                  --query 'ResponseCode' --output text 2>/dev/null || echo "-1")
        echo "${output}" >&2
        return "${rc}"
        ;;
    esac
    sleep 1
  done
  echo "SSM timeout" >&2
  return 124
}

# ---- Kick-off helpers -------------------------------------------------------

need_healthy_localemu() {
  if ! curl -s -m 3 "${AWS_ENDPOINT_URL}/_localemu/health" >/dev/null; then
    fail "LocalEmu is not responding at ${AWS_ENDPOINT_URL}. Start it first: 'localemu start'"
  fi
}

state_set() { printf 'export %s=%q\n' "$1" "$2" >> "${STATE_DIR}/ids.env"; }
state_load() { [[ -f "${STATE_DIR}/ids.env" ]] && source "${STATE_DIR}/ids.env" || true; }
