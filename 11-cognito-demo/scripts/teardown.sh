#!/usr/bin/env bash
set -euo pipefail
export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
export AWS_DEFAULT_REGION=us-east-1
ENDPOINT="--endpoint-url=http://localhost:4566"

HERE="$(cd "$(dirname "$0")/.." && pwd)"
POOL_ID_FILE="$HERE/.pool_id"

if [[ ! -f "$POOL_ID_FILE" ]]; then
  echo "no .pool_id file found; nothing to remove"
  exit 0
fi

POOL_ID=$(cat "$POOL_ID_FILE")
echo "→ deleting user pool $POOL_ID"
aws $ENDPOINT cognito-idp delete-user-pool --user-pool-id "$POOL_ID" 2>/dev/null || true

rm -f "$POOL_ID_FILE"

echo "→ verifying teardown"
if aws $ENDPOINT cognito-idp describe-user-pool --user-pool-id "$POOL_ID" 2>/dev/null; then
  echo "  LEAK: pool $POOL_ID still exists"
  exit 1
fi
echo "  clean: nothing left behind"
