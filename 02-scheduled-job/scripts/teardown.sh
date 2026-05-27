#!/usr/bin/env bash
set -euo pipefail
TARGET="${1:-local}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE/terraform"

terraform destroy -auto-approve -input=false -var "target=$TARGET"

echo
echo "→ verifying teardown for prefix 'le-rotcheck' on $TARGET"

if [[ "$TARGET" == "local" ]]; then
  ENDPOINT_FLAG="--endpoint-url http://localhost:4566"
else
  ENDPOINT_FLAG=""
fi

leaks=0
if aws dynamodb describe-table --table-name "le-rotcheck-audit" $ENDPOINT_FLAG --region us-east-1 2>/dev/null; then
  echo "  LEAK: dynamodb table le-rotcheck-audit still exists"
  leaks=$((leaks+1))
fi
if aws lambda get-function --function-name "le-rotcheck-check" $ENDPOINT_FLAG --region us-east-1 2>/dev/null; then
  echo "  LEAK: lambda le-rotcheck-check still exists"
  leaks=$((leaks+1))
fi
if aws scheduler get-schedule --name "le-rotcheck-hourly" $ENDPOINT_FLAG --region us-east-1 2>/dev/null; then
  echo "  LEAK: schedule le-rotcheck-hourly still exists"
  leaks=$((leaks+1))
fi

if [[ $leaks -eq 0 ]]; then
  echo "  clean: nothing left behind"
fi
exit $leaks
