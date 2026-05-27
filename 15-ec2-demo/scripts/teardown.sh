#!/usr/bin/env bash
set -euo pipefail
export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
export AWS_DEFAULT_REGION=us-east-1
ENDPOINT="--endpoint-url=http://localhost:4566"

# Terminate any instance tagged le-demo=true
aws $ENDPOINT ec2 describe-instances --filters Name=tag:le-demo,Values=true \
  --query 'Reservations[].Instances[?State.Name!=`terminated`].InstanceId' --output text 2>/dev/null \
  | xargs -n1 -r -I{} aws $ENDPOINT ec2 terminate-instances --instance-ids {} >/dev/null 2>&1 || true

aws $ENDPOINT ec2 delete-key-pair --key-name le-demo-key 2>/dev/null || true
rm -f /tmp/le-ec2-demo-key.pem

echo "→ verifying teardown"
if docker ps --filter "label=localemu.service=ec2" --format '{{.Names}}' | grep -q .; then
  echo "  LEAK: ec2 containers still running"
  docker ps --filter "label=localemu.service=ec2" --format '  {{.Names}}'
  exit 1
fi
echo "  clean: nothing left behind"
