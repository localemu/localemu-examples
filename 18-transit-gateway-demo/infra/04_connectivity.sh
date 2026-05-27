#!/usr/bin/env bash
# Step 04: run the cross-VPC connectivity matrix. Each call is issued
# from an EC2 inside a VPC, targeting the private IP of an EC2 inside a
# different VPC. We assert what MUST work and what MUST NOT, so the demo
# doubles as a smoke test for LocalEmu's TGW + peering data plane.
#
# Matrix:
#   [allow] app     -> data    via TGW        (spoke -> spoke)
#   [allow] app     -> shared  via TGW        (spoke -> hub-spoke)
#   [allow] data    -> shared  via TGW        (spoke -> hub-spoke)
#   [allow] mgmt    -> shared  via peering    (peer -> peer)
#   [deny ] mgmt    -> app                    (non-transitive: peering
#                                              does not propagate to TGW)
#   [deny ] mgmt    -> data                   (same reason)

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

need_healthy_localemu
state_load
: "${APP_IP:?run infra/02_compute.sh first}"

log "== Step 04: connectivity matrix =="

# Assertions:  allow => rc=0, deny => rc!=0.

assert_reachable() {
  local from_name="$1" from_iid="$2" to_name="$3" to_ip="$4"
  local out
  if out=$(ssm_run "${from_iid}" "ping -c 2 -W 2 ${to_ip} >/dev/null 2>&1 && echo OK || echo FAIL"); then
    if [[ "${out}" == *"OK"* ]]; then
      ok "[allow] ${from_name} -> ${to_name} (${to_ip})"
      return 0
    fi
  fi
  fail "[allow] ${from_name} -> ${to_name} (${to_ip}) should have worked"
}

assert_unreachable() {
  local from_name="$1" from_iid="$2" to_name="$3" to_ip="$4"
  local out
  out=$(ssm_run "${from_iid}" "ping -c 2 -W 2 ${to_ip} >/dev/null 2>&1 && echo REACH || echo BLOCKED")
  if [[ "${out}" == *"BLOCKED"* ]]; then
    ok "[deny ] ${from_name} -> ${to_name} (${to_ip}) correctly blocked"
    return 0
  fi
  fail "[deny ] ${from_name} -> ${to_name} (${to_ip}) should have been blocked"
}

# ---- TGW paths --------------------------------------------------------------
log "-- TGW fabric (spoke ↔ spoke) --"
assert_reachable "app"    "${APP_INST}"    "data"    "${DATA_IP}"
assert_reachable "app"    "${APP_INST}"    "shared"  "${SHARED_IP}"
assert_reachable "data"   "${DATA_INST}"   "shared"  "${SHARED_IP}"
assert_reachable "data"   "${DATA_INST}"   "app"     "${APP_IP}"

# ---- Peering path -----------------------------------------------------------
log "-- VPC peering mgmt ↔ shared --"
assert_reachable "mgmt"   "${MGMT_INST}"   "shared"  "${SHARED_IP}"
assert_reachable "shared" "${SHARED_INST}" "mgmt"    "${MGMT_IP}"

# ---- Non-transitive guard ---------------------------------------------------
# AWS peering is non-transitive: traffic from mgmt cannot cross shared's TGW
# attachment into app/data. LocalEmu honors this: peering rewrites run only
# between the two peered VPCs, the TGW fabric has no route for mgmt's CIDR.
log "-- Non-transitive peering (must deny) --"
assert_unreachable "mgmt" "${MGMT_INST}"   "app"     "${APP_IP}"
assert_unreachable "mgmt" "${MGMT_INST}"   "data"    "${DATA_IP}"

# ---- Application path: app hits the service on shared via TGW ---------------
log "-- Application call (curl via TGW) --"
app_resp=$(ssm_run "${APP_INST}" "curl -sS --max-time 5 http://${SHARED_IP}:8080/index.html")
printf '      %s\n' "${app_resp}"
[[ "${app_resp}" == *"hello from shared-services"* ]] \
  || fail "app did not get the expected body via TGW"
ok "prod-app read content from shared-services through TGW"

log "-- Operations call (curl via peering) --"
mgmt_resp=$(ssm_run "${MGMT_INST}" "curl -sS --max-time 5 http://${SHARED_IP}:8080/index.html")
printf '      %s\n' "${mgmt_resp}"
[[ "${mgmt_resp}" == *"hello from shared-services"* ]] \
  || fail "mgmt did not get the expected body via peering"
ok "mgmt read content from shared-services through peering"

log "All connectivity assertions passed."
