#!/usr/bin/env bash
# Step 01: build the network plane:
#   * 4 VPCs: shared-services (10.0), prod-app (10.1), prod-data (10.2),
#     mgmt (10.99). One /24 subnet per VPC in us-east-1a.
#   * 1 Transit Gateway with shared / prod-app / prod-data attached.
#   * 1 VPC peering connection mgmt <-> shared-services (auto-accepted).
#   * Security groups that let peer CIDRs in. Kept permissive
#     intentionally (this is a networking demo, not a hardening guide).

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

need_healthy_localemu
rm -f "${STATE_DIR}/ids.env"

log "== Step 01: network plane =="

# ---- VPCs + subnets ---------------------------------------------------------

create_vpc_with_subnet() {
  local name="$1" cidr="$2" subnet_cidr="$3"
  local vpc_id sub_id
  vpc_id=$(awsx ec2 create-vpc --cidr-block "${cidr}" \
             --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${name}}]" \
             --query 'Vpc.VpcId' --output text)
  sub_id=$(awsx ec2 create-subnet --vpc-id "${vpc_id}" \
             --cidr-block "${subnet_cidr}" \
             --availability-zone "${AWS_REGION}a" \
             --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${name}-subnet}]" \
             --query 'Subnet.SubnetId' --output text)
  printf '%s %s\n' "${vpc_id}" "${sub_id}"
}

log "Creating VPC shared-services (10.0.0.0/16)"
read -r SHARED_VPC SHARED_SUBNET < <(create_vpc_with_subnet "shared-services" 10.0.0.0/16 10.0.1.0/24)
ok "shared-services ${SHARED_VPC}, subnet ${SHARED_SUBNET}"

log "Creating VPC prod-app (10.1.0.0/16)"
read -r APP_VPC APP_SUBNET < <(create_vpc_with_subnet "prod-app" 10.1.0.0/16 10.1.1.0/24)
ok "prod-app ${APP_VPC}, subnet ${APP_SUBNET}"

log "Creating VPC prod-data (10.2.0.0/16)"
read -r DATA_VPC DATA_SUBNET < <(create_vpc_with_subnet "prod-data" 10.2.0.0/16 10.2.1.0/24)
ok "prod-data ${DATA_VPC}, subnet ${DATA_SUBNET}"

log "Creating VPC mgmt (10.99.0.0/16)"
read -r MGMT_VPC MGMT_SUBNET < <(create_vpc_with_subnet "mgmt" 10.99.0.0/16 10.99.1.0/24)
ok "mgmt ${MGMT_VPC}, subnet ${MGMT_SUBNET}"

state_set SHARED_VPC   "${SHARED_VPC}"
state_set SHARED_SUBNET "${SHARED_SUBNET}"
state_set APP_VPC      "${APP_VPC}"
state_set APP_SUBNET   "${APP_SUBNET}"
state_set DATA_VPC     "${DATA_VPC}"
state_set DATA_SUBNET  "${DATA_SUBNET}"
state_set MGMT_VPC     "${MGMT_VPC}"
state_set MGMT_SUBNET  "${MGMT_SUBNET}"

# ---- Security groups --------------------------------------------------------
# One SG per VPC, open to the supernet 10.0.0.0/8 for ICMP + TCP demo ports.

open_sg() {
  local vpc_id="$1" name="$2"
  local sg_id
  sg_id=$(awsx ec2 create-security-group \
            --group-name "${name}" --description "${name}" \
            --vpc-id "${vpc_id}" \
            --query 'GroupId' --output text)
  awsx ec2 authorize-security-group-ingress --group-id "${sg_id}" \
    --ip-permissions "IpProtocol=icmp,FromPort=-1,ToPort=-1,IpRanges=[{CidrIp=10.0.0.0/8}]" >/dev/null
  awsx ec2 authorize-security-group-ingress --group-id "${sg_id}" \
    --ip-permissions "IpProtocol=tcp,FromPort=8080,ToPort=8080,IpRanges=[{CidrIp=10.0.0.0/8}]" >/dev/null
  awsx ec2 authorize-security-group-ingress --group-id "${sg_id}" \
    --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=10.0.0.0/8}]" >/dev/null
  printf '%s\n' "${sg_id}"
}

log "Creating security groups"
SHARED_SG=$(open_sg "${SHARED_VPC}" sg-shared)
APP_SG=$(open_sg    "${APP_VPC}"    sg-app)
DATA_SG=$(open_sg   "${DATA_VPC}"   sg-data)
MGMT_SG=$(open_sg   "${MGMT_VPC}"   sg-mgmt)
ok "SGs: shared=${SHARED_SG} app=${APP_SG} data=${DATA_SG} mgmt=${MGMT_SG}"

state_set SHARED_SG "${SHARED_SG}"
state_set APP_SG    "${APP_SG}"
state_set DATA_SG   "${DATA_SG}"
state_set MGMT_SG   "${MGMT_SG}"

# ---- Transit Gateway --------------------------------------------------------

log "Creating Transit Gateway"
TGW_ID=$(awsx ec2 create-transit-gateway \
           --description "enterprise-hub-${RANDOM}" \
           --options 'AmazonSideAsn=64512,AutoAcceptSharedAttachments=enable,DefaultRouteTableAssociation=enable,DefaultRouteTablePropagation=enable' \
           --query 'TransitGateway.TransitGatewayId' --output text)
ok "TGW ${TGW_ID}"
state_set TGW_ID "${TGW_ID}"

log "Attaching shared-services, prod-app, prod-data to TGW"
attach_vpc_to_tgw() {
  local vpc="$1" sub="$2"
  awsx ec2 create-transit-gateway-vpc-attachment \
    --transit-gateway-id "${TGW_ID}" --vpc-id "${vpc}" --subnet-ids "${sub}" \
    --query 'TransitGatewayVpcAttachment.TransitGatewayAttachmentId' --output text
}
SHARED_TGW_ATT=$(attach_vpc_to_tgw "${SHARED_VPC}" "${SHARED_SUBNET}")
APP_TGW_ATT=$(attach_vpc_to_tgw    "${APP_VPC}"    "${APP_SUBNET}")
DATA_TGW_ATT=$(attach_vpc_to_tgw   "${DATA_VPC}"   "${DATA_SUBNET}")
ok "TGW attachments: shared=${SHARED_TGW_ATT} app=${APP_TGW_ATT} data=${DATA_TGW_ATT}"
state_set SHARED_TGW_ATT "${SHARED_TGW_ATT}"
state_set APP_TGW_ATT    "${APP_TGW_ATT}"
state_set DATA_TGW_ATT   "${DATA_TGW_ATT}"

# ---- VPC peering mgmt <-> shared-services -----------------------------------

log "Creating VPC peering mgmt <-> shared-services"
PCX_ID=$(awsx ec2 create-vpc-peering-connection \
           --vpc-id "${MGMT_VPC}" --peer-vpc-id "${SHARED_VPC}" \
           --query 'VpcPeeringConnection.VpcPeeringConnectionId' --output text)
awsx ec2 accept-vpc-peering-connection --vpc-peering-connection-id "${PCX_ID}" >/dev/null
ok "VPC peering ${PCX_ID} established"
state_set PCX_ID "${PCX_ID}"

# ---- Route tables -----------------------------------------------------------
# Each VPC has a default main route table. We add routes so the kernel in
# the EC2 container knows how to reach the peer CIDRs. LocalEmu wires the
# actual forwarding via Docker networks; these routes make the describe
# output match what Terraform/CFN users expect to see.

main_rt_of() {
  awsx ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$1" "Name=association.main,Values=true" \
    --query 'RouteTables[0].RouteTableId' --output text
}

log "Programming routing tables"
SHARED_RT=$(main_rt_of "${SHARED_VPC}")
APP_RT=$(main_rt_of    "${APP_VPC}")
DATA_RT=$(main_rt_of   "${DATA_VPC}")
MGMT_RT=$(main_rt_of   "${MGMT_VPC}")

# TGW routes: shared/app/data reach each other's CIDRs via TGW
awsx ec2 create-route --route-table-id "${SHARED_RT}" --destination-cidr-block 10.1.0.0/16 --transit-gateway-id "${TGW_ID}" >/dev/null
awsx ec2 create-route --route-table-id "${SHARED_RT}" --destination-cidr-block 10.2.0.0/16 --transit-gateway-id "${TGW_ID}" >/dev/null
awsx ec2 create-route --route-table-id "${APP_RT}"    --destination-cidr-block 10.0.0.0/16 --transit-gateway-id "${TGW_ID}" >/dev/null
awsx ec2 create-route --route-table-id "${APP_RT}"    --destination-cidr-block 10.2.0.0/16 --transit-gateway-id "${TGW_ID}" >/dev/null
awsx ec2 create-route --route-table-id "${DATA_RT}"   --destination-cidr-block 10.0.0.0/16 --transit-gateway-id "${TGW_ID}" >/dev/null
awsx ec2 create-route --route-table-id "${DATA_RT}"   --destination-cidr-block 10.1.0.0/16 --transit-gateway-id "${TGW_ID}" >/dev/null
# Peering routes: mgmt <-> shared
awsx ec2 create-route --route-table-id "${SHARED_RT}" --destination-cidr-block 10.99.0.0/16 --vpc-peering-connection-id "${PCX_ID}" >/dev/null
awsx ec2 create-route --route-table-id "${MGMT_RT}"   --destination-cidr-block 10.0.0.0/16  --vpc-peering-connection-id "${PCX_ID}" >/dev/null
ok "Routes wired"

log "Network plane ready. Ids in ${STATE_DIR}/ids.env"
