#!/usr/bin/env bash
# Step 02: launch one Ubuntu EC2 per VPC. A single t2.micro is enough; the
# test matrix in 04_connectivity.sh exercises cross-VPC paths via SSM, not
# large workloads. LocalEmu's Docker VM backend gives each instance a real
# network namespace so the pings we send actually traverse Docker bridges.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

need_healthy_localemu
state_load
: "${SHARED_VPC:?run infra/01_network.sh first}"

log "== Step 02: compute =="

# ---- Key pair (SSH is off by default in this tutorial but we still need one
# to satisfy RunInstances's KeyName requirement for demo parity with real AWS).

KEY_NAME="enterprise-key-${RANDOM}"
log "Creating key pair ${KEY_NAME}"
awsx ec2 create-key-pair --key-name "${KEY_NAME}" \
  --query 'KeyMaterial' --output text > "${STATE_DIR}/${KEY_NAME}.pem"
chmod 600 "${STATE_DIR}/${KEY_NAME}.pem"
ok "Key pair created (pem saved to ${STATE_DIR}/${KEY_NAME}.pem)"
state_set KEY_NAME "${KEY_NAME}"

# ---- RunInstances per VPC ---------------------------------------------------

run_one() {
  local subnet="$1" sg="$2" tag="$3"
  awsx ec2 run-instances \
    --image-id ami-ubuntu-22.04 \
    --instance-type t2.micro \
    --key-name "${KEY_NAME}" \
    --subnet-id "${subnet}" \
    --security-group-ids "${sg}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${tag}}]" \
    --count 1 \
    --query 'Instances[0].InstanceId' --output text
}

log "Launching shared-services host"
SHARED_INST=$(run_one "${SHARED_SUBNET}" "${SHARED_SG}" host-shared)
log "Launching prod-app host"
APP_INST=$(run_one    "${APP_SUBNET}"    "${APP_SG}"    host-app)
log "Launching prod-data host"
DATA_INST=$(run_one   "${DATA_SUBNET}"   "${DATA_SG}"   host-data)
log "Launching mgmt host"
MGMT_INST=$(run_one   "${MGMT_SUBNET}"   "${MGMT_SG}"   host-mgmt)

state_set SHARED_INST "${SHARED_INST}"
state_set APP_INST    "${APP_INST}"
state_set DATA_INST   "${DATA_INST}"
state_set MGMT_INST   "${MGMT_INST}"

# ---- Wait until each instance is in State=running ---------------------------

log "Waiting for instances to reach running state"
for label_iid in \
    "shared:${SHARED_INST}" \
    "app:${APP_INST}" \
    "data:${DATA_INST}" \
    "mgmt:${MGMT_INST}"; do
  label="${label_iid%%:*}"; iid="${label_iid##*:}"
  if wait_instance_running "${iid}" 90; then
    ok "${label} ${iid} running"
  else
    fail "${label} ${iid} did not reach running state in 90s"
  fi
done

# ---- Record private IPs for the later connectivity matrix -------------------

private_ip() {
  awsx ec2 describe-instances --instance-ids "$1" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text
}

state_set SHARED_IP "$(private_ip "${SHARED_INST}")"
state_set APP_IP    "$(private_ip "${APP_INST}")"
state_set DATA_IP   "$(private_ip "${DATA_INST}")"
state_set MGMT_IP   "$(private_ip "${MGMT_INST}")"

# Reload state so the `ok` line below sees the just-written vars.
state_load

ok "Private IPs:"
printf '      shared=%s  app=%s  data=%s  mgmt=%s\n' \
       "${SHARED_IP}" "${APP_IP}" "${DATA_IP}" "${MGMT_IP}"

log "Compute plane ready."
