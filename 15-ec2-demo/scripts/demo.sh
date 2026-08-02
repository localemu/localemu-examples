#!/usr/bin/env bash
# End-to-end EC2 walkthrough: create key pair, security group with SSH
# ingress, launch a Docker-backed Ubuntu instance with user-data, then
# reach it three different ways -- the localemu-ssh docker-exec
# shortcut, real network SSH from an in-VPC client container, and EC2
# Instance Connect's ephemeral-key flow -- plus a keyless SSM command.
# Finishes with stop/start/terminate.
#
# Requires: LocalEmu started with EC2_VM_MANAGER=docker
set -euo pipefail

export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
export AWS_DEFAULT_REGION=us-east-1
ENDPOINT="--endpoint-url=http://localhost:4566"

KEY=/tmp/le-ec2-demo-key.pem
EIC_KEY=/tmp/le-ec2-demo-eic-key
CLIENT="localemu-ec2-demo-client"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

bold() { printf "\n\033[1;36m== %s ==\033[0m\n" "$1"; }

# Clean slate: kill any previous instance + key pair + security group + client
aws $ENDPOINT ec2 describe-instances --filters Name=tag-key,Values=le-demo \
  --query 'Reservations[].Instances[?State.Name!=`terminated`].InstanceId' --output text 2>/dev/null \
  | xargs -n1 -r -I{} aws $ENDPOINT ec2 terminate-instances --instance-ids {} >/dev/null 2>&1 || true
OLD_SG=$(aws $ENDPOINT ec2 describe-security-groups --group-names le-demo-ssh \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
if [[ -n "${OLD_SG:-}" && "$OLD_SG" != "None" ]]; then
  aws $ENDPOINT ec2 delete-security-group --group-id "$OLD_SG" 2>/dev/null || true
fi
aws $ENDPOINT ec2 delete-key-pair --key-name le-demo-key 2>/dev/null || true
docker rm -f "$CLIENT" >/dev/null 2>&1 || true
rm -f "$KEY" "$EIC_KEY" "${EIC_KEY}.pub"
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
  --query 'Reservations[0].Instances[0].{Id:InstanceId,State:State.Name,Private:PrivateIpAddress,Public:PublicIpAddress,Type:InstanceType,Image:ImageId}'
echo "   (no 'localemu:ssh-port' tag any more -- 1.2.0 exposes real port 22"
echo "    on the instance's own IP inside LocalEmu's Docker networks, not"
echo "    a mapped host port. See 'Why there's no ssh -p step' in the README.)"

bold "5. Wait for sshd (baked into ec2-base:v4, comes up in a couple of seconds)"
for i in $(seq 1 30); do
  if docker exec "localemu-ec2-$INSTANCE_ID" pgrep sshd >/dev/null 2>&1; then
    echo "   sshd ready after ${i} attempts"
    break
  fi
  sleep 1
done

bold "6. Verify Docker container is running"
docker ps --filter "label=localemu.service=ec2" \
  --filter "name=localemu-ec2-$INSTANCE_ID" \
  --format 'table {{.Image}}\t{{.Status}}\t{{.Ports}}'

bold "7. localemu ssh (docker-exec shortcut, no networking involved)"
localemu ssh --list
echo
echo "   'localemu ssh $INSTANCE_ID' opens an interactive shell (docker exec -it)"
echo "   -- run it yourself in a real terminal after this script finishes. This"
echo "   script isn't attached to a TTY, so the read-only checks below use"
echo "   'docker exec' directly, the same thing 'localemu ssh <id> <cmd>' does"
echo "   under the hood minus the TTY requirement."
echo "   \$ docker exec localemu-ec2-$INSTANCE_ID cat /tmp/hello.txt"
docker exec "localemu-ec2-$INSTANCE_ID" cat /tmp/hello.txt
echo "   \$ docker exec localemu-ec2-$INSTANCE_ID whoami"
docker exec "localemu-ec2-$INSTANCE_ID" whoami

bold "8. Real network SSH from an in-VPC client container"
PRIVATE_IP=$(aws $ENDPOINT ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
VPC_NET=$(docker inspect --format \
  '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' \
  "localemu-ec2-$INSTANCE_ID" | grep localemu-vpc | head -1)
echo "   PrivateIpAddress=$PRIVATE_IP  vpc-network=$VPC_NET"
echo "   (LocalEmu doesn't open host-to-VPC reachability on your laptop by"
echo "    design -- it's not a Docker port mapper. Real AWS users hit this"
echo "    same wall without a bastion/VPN, so this demo spins up an in-VPC"
echo "    client container, exactly like a bastion host would be.)"

docker run -d --name "$CLIENT" --network "$VPC_NET" \
  --entrypoint sh localemu/ec2-base:v4 \
  -c 'while true; do sleep 3600; done' >/dev/null
docker cp "$KEY" "$CLIENT:/tmp/id_rsa"
docker exec "$CLIENT" chmod 600 /tmp/id_rsa

SSH_OPTS="-i /tmp/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 -o BatchMode=yes"
CLIENT_SSH() { docker exec "$CLIENT" sh -c "ssh $SSH_OPTS ubuntu@$PRIVATE_IP '$*'"; }

echo "   \$ ssh ubuntu@$PRIVATE_IP whoami   (from the client container)"
CLIENT_SSH whoami
echo "   \$ ssh ubuntu@$PRIVATE_IP cat /etc/os-release"
CLIENT_SSH cat /etc/os-release | head -5

bold "9. EC2 Instance Connect: push a 60s ephemeral key"
ssh-keygen -t ed25519 -f "$EIC_KEY" -N "" -q
aws $ENDPOINT ec2-instance-connect send-ssh-public-key \
  --instance-id "$INSTANCE_ID" --instance-os-user ubuntu \
  --ssh-public-key "file://${EIC_KEY}.pub"
docker exec "localemu-ec2-$INSTANCE_ID" \
  grep -q "localemu-eic BEGIN " /home/ubuntu/.ssh/authorized_keys \
  && echo "   ephemeral key installed (marked localemu-eic BEGIN/END, expires in 60s)"
docker cp "$EIC_KEY" "$CLIENT:/tmp/id_eic"
docker exec "$CLIENT" chmod 600 /tmp/id_eic
EIC_SSH_OPTS="-i /tmp/id_eic -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 -o BatchMode=yes"
echo "   \$ ssh -i <eic-key> ubuntu@$PRIVATE_IP hostname   (within the 60s TTL)"
docker exec "$CLIENT" sh -c "ssh $EIC_SSH_OPTS ubuntu@$PRIVATE_IP hostname"

bold "10. aws ssm send-command (keyless, the AWS-native path)"
CMD_ID=$(aws $ENDPOINT ssm send-command \
  --document-name AWS-RunShellScript \
  --instance-ids "$INSTANCE_ID" \
  --parameters 'commands=["cat /tmp/hello.txt"]' \
  --query 'Command.CommandId' --output text)
for i in $(seq 1 15); do
  STATUS=$(aws $ENDPOINT ssm get-command-invocation \
    --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query 'Status' --output text 2>/dev/null || echo Pending)
  [[ "$STATUS" == "Success" ]] && break
  sleep 1
done
echo "   status=$STATUS"
aws $ENDPOINT ssm get-command-invocation \
  --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query 'StandardOutputContent' --output text

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
docker rm -f "$CLIENT" >/dev/null 2>&1 || true
rm -f "$KEY" "$EIC_KEY" "${EIC_KEY}.pub"

echo
echo "-> demo complete."
