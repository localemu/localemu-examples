#!/usr/bin/env bash
set -euo pipefail
export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
export AWS_DEFAULT_REGION=us-east-1
ENDPOINT="--endpoint-url=http://localhost:4566"

# Stop all ecs-backed containers first
docker ps --filter 'label=localemu.service=ecs' --format '{{.Names}}' | xargs -r docker rm -f >/dev/null 2>&1 || true
aws $ENDPOINT ecs delete-cluster --cluster le-demo-ecs 2>/dev/null || true

echo "→ verifying teardown"
if docker ps --filter 'label=localemu.service=ecs' --format '{{.Names}}' | grep -q .; then
  echo "  LEAK: ecs containers still running"
  exit 1
fi
echo "  clean: nothing left behind"
