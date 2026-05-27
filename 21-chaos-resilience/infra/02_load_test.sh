#!/usr/bin/env bash
# Step 02: load test the resilient writer against whatever chaos
# LocalEmu is currently configured with. Reports per-scenario:
#   total requests
#   ok / failed
#   total throttle events observed at the SDK layer
#   sum of attempts (1 = first try, >1 = retried)
#   latency p50, p95, p99
#   final DDB item count (== requests if zero data loss)
#
# Concurrency is provided by xargs -P N. Each worker invokes the
# Lambda once and writes its JSON envelope to a per-request file in
# .state/responses/.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

need_healthy_localemu
state_load
: "${FN:?run infra/01_setup.sh first}"

REQUESTS="${REQUESTS:-50}"
CONCURRENCY="${CONCURRENCY:-10}"

bold "4. Load test: ${REQUESTS} requests, ${CONCURRENCY}-way concurrent"

log "LocalEmu chaos config:"
detect_chaos | sed 's/^/      /'

RESP_DIR="${STATE_DIR}/responses"
rm -rf "${RESP_DIR}" && mkdir -p "${RESP_DIR}"

# Run one invocation. $1 = request_id.
_invoke_one() {
  local rid="$1"
  local payload_file="${RESP_DIR}/${rid}.in.json"
  local resp_file="${RESP_DIR}/${rid}.out.json"
  printf '{"request_id":"%s","payload":"chaos-test"}' "${rid}" > "${payload_file}"
  aws --endpoint-url "${AWS_ENDPOINT_URL}" --region "${AWS_REGION}" \
    lambda invoke \
    --function-name "${FN}" \
    --payload "fileb://${payload_file}" \
    "${resp_file}" >/dev/null 2>&1
}
export -f _invoke_one
export AWS_ENDPOINT_URL AWS_REGION RESP_DIR FN

log "Firing ${REQUESTS} invocations…"
START=$(date +%s)
seq 1 "${REQUESTS}" \
  | xargs -P "${CONCURRENCY}" -I{} bash -c '_invoke_one "req-{}"'
ELAPSED=$(( $(date +%s) - START ))
ok "All invocations returned in ${ELAPSED}s wall-clock"

bold "5. Summary"

python3 - "${REQUESTS}" "${RESP_DIR}" <<'PY'
import json, os, sys
n = int(sys.argv[1]); d = sys.argv[2]
oks, fails = 0, 0
throttles = 0
attempts = []
latencies = []
errors = {}
for i in range(1, n + 1):
    p = os.path.join(d, f"req-{i}.out.json")
    try:
        with open(p) as f:
            r = json.load(f)
    except Exception as e:
        fails += 1
        errors.setdefault(f"read-error: {e}", 0)
        errors[f"read-error: {e}"] += 1
        continue
    if r.get("ok"):
        oks += 1
    else:
        fails += 1
        errors.setdefault(r.get("error", "?"), 0)
        errors[r.get("error", "?")] += 1
    throttles += r.get("throttled", 0)
    attempts.append(r.get("attempts", 0))
    latencies.append(r.get("elapsed_ms", 0))

def pct(lst, p):
    if not lst: return 0
    s = sorted(lst); k = int(round((p / 100) * (len(s) - 1)))
    return s[k]

print(f"      requests:        {n}")
print(f"      ok:              {oks}")
print(f"      failed:          {fails}")
print(f"      throttle events: {throttles}")
print(f"      sum(attempts):   {sum(attempts)}  (= {n} means zero retries needed)")
print(f"      latency p50:     {pct(latencies, 50):.0f} ms")
print(f"      latency p95:     {pct(latencies, 95):.0f} ms")
print(f"      latency p99:     {pct(latencies, 99):.0f} ms")
if errors:
    print(f"      error breakdown: {dict(sorted(errors.items()))}")
PY

bold "6. Zero-data-loss assertion"

COUNT=$(awsx dynamodb scan --table-name "${TABLE}" \
  --select COUNT --query 'Count' --output text)
log "DynamoDB table holds ${COUNT} unique items"

if [[ "${COUNT}" == "${REQUESTS}" ]]; then
  ok "Zero data loss: ${COUNT}/${REQUESTS} requests landed in DDB"
else
  warn "  Data loss: only ${COUNT}/${REQUESTS} requests landed in DDB"
  log  "  (this is the failure signal the retry logic was supposed to prevent)"
  exit 1
fi
