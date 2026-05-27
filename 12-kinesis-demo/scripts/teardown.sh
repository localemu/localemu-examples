#!/usr/bin/env bash
set -euo pipefail
export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
export AWS_DEFAULT_REGION=us-east-1
ENDPOINT="--endpoint-url=http://localhost:4566"

for s in my-stream events; do
  aws $ENDPOINT kinesis delete-stream --stream-name "$s" 2>/dev/null || true
done

echo "→ verifying teardown"
leaks=0
for s in my-stream events; do
  if aws $ENDPOINT kinesis describe-stream --stream-name "$s" 2>/dev/null | grep -q StreamName; then
    echo "  LEAK: stream $s still exists"
    leaks=$((leaks+1))
  fi
done
if [[ $leaks -eq 0 ]]; then
  echo "  clean: nothing left behind"
fi
exit $leaks
