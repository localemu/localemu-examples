#!/usr/bin/env bash
# Teardown. Best-effort: we swallow errors per resource so a partial state
# from a failed demo still gets cleaned up.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"
need_healthy_localemu
state_load

log "== Cleanup =="

try() { "$@" 2>/dev/null || true; }

if [[ -n "${SHARED_INST:-}" ]]; then
  try ssm_run "${SHARED_INST}" "pkill -f 'http.server 8080' || true" >/dev/null
fi

log "Terminating EC2 instances"
for iid in "${SHARED_INST:-}" "${APP_INST:-}" "${DATA_INST:-}" "${MGMT_INST:-}"; do
  [[ -n "${iid}" ]] && try awsx ec2 terminate-instances --instance-ids "${iid}" >/dev/null
done
sleep 2

log "Deleting TGW attachments"
for att in "${SHARED_TGW_ATT:-}" "${APP_TGW_ATT:-}" "${DATA_TGW_ATT:-}"; do
  [[ -n "${att}" ]] && try awsx ec2 delete-transit-gateway-vpc-attachment \
      --transit-gateway-attachment-id "${att}" >/dev/null
done

log "Deleting VPC peering"
[[ -n "${PCX_ID:-}" ]] && try awsx ec2 delete-vpc-peering-connection \
    --vpc-peering-connection-id "${PCX_ID}" >/dev/null

log "Deleting TGW"
[[ -n "${TGW_ID:-}" ]] && try awsx ec2 delete-transit-gateway \
    --transit-gateway-id "${TGW_ID}" >/dev/null

log "Deleting subnets + VPCs"
for sub in "${SHARED_SUBNET:-}" "${APP_SUBNET:-}" "${DATA_SUBNET:-}" "${MGMT_SUBNET:-}"; do
  [[ -n "${sub}" ]] && try awsx ec2 delete-subnet --subnet-id "${sub}" >/dev/null
done
for vpc in "${SHARED_VPC:-}" "${APP_VPC:-}" "${DATA_VPC:-}" "${MGMT_VPC:-}"; do
  [[ -n "${vpc}" ]] && try awsx ec2 delete-vpc --vpc-id "${vpc}" >/dev/null
done

log "Deleting key pair"
[[ -n "${KEY_NAME:-}" ]] && try awsx ec2 delete-key-pair --key-name "${KEY_NAME}" >/dev/null

rm -rf "${STATE_DIR}"
ok "Cleanup complete."
