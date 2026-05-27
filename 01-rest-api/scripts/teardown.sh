#!/usr/bin/env bash
set -euo pipefail
TARGET="${1:-local}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE/terraform"

terraform destroy -auto-approve -input=false -var "target=$TARGET"

echo
echo "→ verifying teardown for prefix 'le-notes' on $TARGET"

if [[ "$TARGET" == "local" ]]; then
  ENDPOINT_FLAG="--endpoint-url http://localhost:4566"
else
  ENDPOINT_FLAG=""
fi

leaks=0
if aws dynamodb describe-table --table-name "le-notes-notes" $ENDPOINT_FLAG --region us-east-1 2>/dev/null; then
  echo "  LEAK: dynamodb table le-notes-notes still exists"
  leaks=$((leaks+1))
fi
if aws lambda get-function --function-name "le-notes-api" $ENDPOINT_FLAG --region us-east-1 2>/dev/null; then
  echo "  LEAK: lambda function le-notes-api still exists"
  leaks=$((leaks+1))
fi

if [[ $leaks -eq 0 ]]; then
  echo "  clean: nothing left behind"
fi
exit $leaks
