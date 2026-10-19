#!/usr/bin/env bash
set -euo pipefail
TARGET="${1:-local}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE/terraform"

terraform destroy -auto-approve -input=false -var "target=$TARGET"

echo
echo "→ verifying teardown for prefix 'le-analytics' on $TARGET"

if [[ "$TARGET" == "local" ]]; then
  ENDPOINT_FLAG="--endpoint-url http://localhost:4566"
else
  ENDPOINT_FLAG=""
fi

leaks=0
if aws firehose describe-delivery-stream --delivery-stream-name "le-analytics-events" $ENDPOINT_FLAG --region us-east-1 2>/dev/null; then
  echo "  LEAK: firehose delivery stream le-analytics-events still exists"
  leaks=$((leaks+1))
fi
if aws glue get-database --name "retail_analytics_db" $ENDPOINT_FLAG --region us-east-1 2>/dev/null; then
  echo "  LEAK: glue database retail_analytics_db still exists"
  leaks=$((leaks+1))
fi

if [[ $leaks -eq 0 ]]; then
  echo "  clean: nothing left behind"
fi
exit $leaks
