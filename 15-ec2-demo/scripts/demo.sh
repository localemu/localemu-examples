#!/usr/bin/env bash
# End-to-end EC2 walkthrough: create key pair, security group with SSH
# ingress, launch a Docker-backed Ubuntu instance with user-data, SSH in
# and verify the user-data ran, stop/start/terminate.
#
# Requires: LocalEmu started with EC2_VM_MANAGER=docker
set -euo pipefail

export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
export AWS_DEFAULT_REGION=us-east-1
ENDPOINT="--endpoint-url=http://localhost:4566"

KEY=/tmp/le-ec2-demo-key.pem
HERE="$(cd "$(dirname "$0")/.." && pwd)"

bold() { printf "\n\033[1;36m== %s ==\033[0m\n" "$1"; }

# Clean slate: kill any previous instance + key pair + security group
aws $ENDPOINT ec2 describe-instances --filters Name=tag-key,Values=le-demo \
  --query 'Reservations[].Instances[?State.Name!=`terminated`].InstanceId' --output text 2>/dev/null \
  | xargs -n1 -r -I{} aws $ENDPOINT ec2 terminate-instances --instance-ids {} >/dev/null 2>&1 || true
OLD_SG=$(aws $ENDPOINT ec2 describe-security-groups --group-names le-demo-ssh \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
if [[ -n "${OLD_SG:-}" && "$OLD_SG" != "None" ]]; then
  aws $ENDPOINT ec2 delete-security-group --group-id "$OLD_SG" 2>/dev/null || true
fi
aws $ENDPOINT ec2 delete-key-pair --key-name le-demo-key 2>/dev/null || true
rm -f "$KEY"
sleep 1

bold "1. Create key pair"
aws $ENDPOINT ec2 create-key-pair --key-name le-demo-key \
  --query KeyMaterial --output text > "$KEY"
chmod 400 "$KEY"
echo "   key saved to $KEY ($(wc -c < "$KEY") bytes)"

bold "2. Create security group + allow SSH (0.0.0.0/0:22)"
SG_ID=$(aws $ENDPOINT ec2 create-security-group \
  --group-name le-demo-ssh \
  --description "ssh open for the ec2 demo" \
  --query 'GroupId' --output text)
echo "   SG_ID=$SG_ID"
aws $ENDPOINT ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0 \
  --query 'Return'

bold "3. Launch instance with user-data"
INSTANCE_ID=$(aws $ENDPOINT ec2 run-instances \
  --image-id ami-ubuntu-22.04 \
  --instance-type t2.micro \
  --count 1 \
  --key-name le-demo-key \
  --security-group-ids "$SG_ID" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=le-demo,Value=true}]' \
  --user-data '#!/bin/bash
echo "Hello from LocalEmu EC2" > /tmp/hello.txt
date > /tmp/boot-time.txt' \
  --query 'Instances[0].InstanceId' --output text)
echo "   INSTANCE_ID=$INSTANCE_ID"

bold "4. Wait for running state"
aws $ENDPOINT ec2 wait instance-running --instance-ids "$INSTANCE_ID"
aws $ENDPOINT ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{Id:InstanceId,State:State.Name,Ip:PublicIpAddress,Type:InstanceType,Image:ImageId}'

bold "5. Wait for sshd to come up (apt-get install inside the container takes ~30-60s on first run)"
SSH_PORT=$(aws $ENDPOINT ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].Tags[?Key==`localemu:ssh-port`].Value' \
  --output text)
echo "   SSH port = $SSH_PORT"
for i in $(seq 1 60); do
  if ssh -i "$KEY" -p "$SSH_PORT" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=2 -o LogLevel=ERROR -o BatchMode=yes \
    root@localhost true 2>/dev/null; then
    echo "   sshd ready after ${i} attempts"
    break
  fi
  sleep 2
done

bold "6. Verify Docker container is running"
docker ps --filter "label=localemu.service=ec2" \
  --filter "name=localemu-ec2-$INSTANCE_ID" \
  --format 'table {{.Image}}\t{{.Status}}\t{{.Ports}}'

bold "7. localemu ssh --list (informational)"
localemu ssh --list

SSH() {
  ssh -i "$KEY" -p "$SSH_PORT" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -T \
    root@localhost "$@"
}

bold "8. Read /tmp/hello.txt (user-data output) via direct SSH"
SSH cat /tmp/hello.txt

bold "9. Read /etc/os-release via direct SSH"
SSH cat /etc/os-release | head -5

bold "10. whoami via direct SSH"
SSH whoami

bold "11. Stop -> container gone, then Start -> container back"
aws $ENDPOINT ec2 stop-instances --instance-ids "$INSTANCE_ID" \
  --query 'StoppingInstances[0].{Id:InstanceId,State:CurrentState.Name}'
aws $ENDPOINT ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
docker ps --filter "name=localemu-ec2-$INSTANCE_ID" --format 'names: {{.Names}}' \
  | head -2
aws $ENDPOINT ec2 start-instances --instance-ids "$INSTANCE_ID" \
  --query 'StartingInstances[0].{Id:InstanceId,State:CurrentState.Name}'
aws $ENDPOINT ec2 wait instance-running --instance-ids "$INSTANCE_ID"
docker ps --filter "name=localemu-ec2-$INSTANCE_ID" --format 'names: {{.Names}}' \
  | head -2

bold "12. Terminate + verify container gone"
aws $ENDPOINT ec2 terminate-instances --instance-ids "$INSTANCE_ID" \
  --query 'TerminatingInstances[0].{Id:InstanceId,State:CurrentState.Name}'
sleep 3
if docker ps --filter "name=localemu-ec2-$INSTANCE_ID" --format '{{.Names}}' | grep -q .; then
  echo "  WARNING: container still running"
else
  echo "  container for $INSTANCE_ID is gone"
fi

# Clean helpers
aws $ENDPOINT ec2 delete-key-pair --key-name le-demo-key 2>/dev/null || true
rm -f "$KEY"

echo
echo "→ demo complete."
