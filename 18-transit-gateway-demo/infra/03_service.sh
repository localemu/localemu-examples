#!/usr/bin/env bash
# Step 03: stand up a tiny HTTP service on shared-services so cross-VPC
# calls have something real to hit. We use ``python3 -m http.server``: no
# package install, no wait for apt, no external image download. Serving a
# simple identity file is enough to prove the packet made it end to end.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

need_healthy_localemu
state_load
: "${SHARED_INST:?run infra/02_compute.sh first}"

log "== Step 03: bring up HTTP service on shared-services =="

log "Writing content"
ssm_run "${SHARED_INST}" "echo 'hello from shared-services (10.0.1.0/24)' > /tmp/index.html && ls /tmp/index.html" >/dev/null
ok "Content written"

log "Starting http server on :8080 (background, via nohup)"
start_output=$(ssm_run "${SHARED_INST}" "cd /tmp && pkill -f 'http.server 8080' >/dev/null 2>&1 || true; nohup python3 -m http.server 8080 >/tmp/http.log 2>&1 & sleep 1; (ss -tln 2>/dev/null || netstat -tln 2>/dev/null) | grep -q ':8080' && echo SERVER_UP")
printf '      %s\n' "${start_output}"
[[ "${start_output}" == *"SERVER_UP"* ]] || fail "server did not bind to :8080"
ok "Server listening on 0.0.0.0:8080"

log "Self-check: curl from shared-services itself"
out=$(ssm_run "${SHARED_INST}" "curl -sS --max-time 3 http://127.0.0.1:8080/index.html")
printf '      %s\n' "${out}"
[[ "${out}" == *"hello from shared-services"* ]] || fail "self-check failed: ${out}"
ok "Service healthy"
