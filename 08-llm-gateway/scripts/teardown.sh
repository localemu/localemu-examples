#!/usr/bin/env bash
set -euo pipefail
TARGET="${1:-local}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE/terraform"

terraform destroy -auto-approve -input=false -var "target=$TARGET"

echo
echo "→ verifying teardown for prefix 'le-llmgw' on $TARGET"

if [[ "$TARGET" == "local" ]]; then
  ENDPOINT_FLAG="--endpoint-url http://localhost:4566"
else
  ENDPOINT_FLAG=""
fi

leaks=0
for t in cache incidents scores; do
  if aws dynamodb describe-table --table-name "le-llmgw-$t" $ENDPOINT_FLAG --region us-east-1 2>/dev/null; then
    echo "  LEAK: dynamodb table le-llmgw-$t still exists"
    leaks=$((leaks+1))
  fi
done

if [[ $leaks -eq 0 ]]; then
  echo "  clean: nothing left behind"
fi
exit $leaks
