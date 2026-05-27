#!/usr/bin/env bash
# Delete the bucket + table created by the tests.
set -euo pipefail
export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
export AWS_DEFAULT_REGION=us-east-1
ENDPOINT="--endpoint-url=http://localhost:4566"

aws $ENDPOINT s3 rb s3://uploads --force 2>/dev/null || true
aws $ENDPOINT dynamodb delete-table --table-name processed-records 2>/dev/null || true

echo "→ verifying teardown"
leaks=0
if aws $ENDPOINT s3api head-bucket --bucket uploads 2>/dev/null; then
  echo "  LEAK: s3 bucket uploads still exists"
  leaks=$((leaks+1))
fi
if aws $ENDPOINT dynamodb describe-table --table-name processed-records 2>/dev/null; then
  echo "  LEAK: dynamodb table processed-records still exists"
  leaks=$((leaks+1))
fi
if [[ $leaks -eq 0 ]]; then
  echo "  clean: nothing left behind"
fi
exit $leaks
