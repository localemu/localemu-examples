#!/usr/bin/env bash
set -euo pipefail
export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
export AWS_DEFAULT_REGION=us-east-1
ENDPOINT="--endpoint-url=http://localhost:4566"

for id in my-postgres my-mysql; do
  aws $ENDPOINT rds delete-db-instance --db-instance-identifier "$id" --skip-final-snapshot 2>/dev/null || true
done
sleep 2

echo "→ verifying teardown"
if docker ps --filter "label=localemu.service=rds" --format '{{.Names}}' | grep -q .; then
  echo "  LEAK: rds containers still running"
  exit 1
fi
echo "  clean: nothing left behind"
