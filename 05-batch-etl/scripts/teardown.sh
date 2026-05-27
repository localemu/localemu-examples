#!/usr/bin/env bash
set -euo pipefail
TARGET="${1:-local}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE/terraform"

terraform destroy -auto-approve -input=false -var "target=$TARGET"

echo
echo "→ verifying teardown for prefix 'le-etl' on $TARGET"

if [[ "$TARGET" == "local" ]]; then
  ENDPOINT_FLAG="--endpoint-url http://localhost:4566"
  REGION="us-east-1"
  ACCT="000000000000"
else
  ENDPOINT_FLAG=""
  REGION="${AWS_REGION:-us-east-1}"
  ACCT=$(aws sts get-caller-identity --query Account --output text)
fi

leaks=0
if aws s3api head-bucket --bucket "le-etl-input" $ENDPOINT_FLAG --region "$REGION" 2>/dev/null; then
  echo "  LEAK: s3 bucket le-etl-input still exists"
  leaks=$((leaks+1))
fi
if aws dynamodb describe-table --table-name "le-etl-orders" $ENDPOINT_FLAG --region "$REGION" 2>/dev/null; then
  echo "  LEAK: dynamodb table le-etl-orders still exists"
  leaks=$((leaks+1))
fi
SFN_ARN="arn:aws:states:${REGION}:${ACCT}:stateMachine:le-etl-etl"
if aws stepfunctions describe-state-machine --state-machine-arn "$SFN_ARN" $ENDPOINT_FLAG --region "$REGION" 2>/dev/null; then
  echo "  LEAK: stepfunctions le-etl-etl still exists"
  leaks=$((leaks+1))
fi

if [[ $leaks -eq 0 ]]; then
  echo "  clean: nothing left behind"
fi
exit $leaks
