#!/usr/bin/env bash
set -euo pipefail
TARGET="${1:-local}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE/terraform"

terraform destroy -auto-approve -input=false -var "target=$TARGET"

echo
echo "→ verifying teardown for prefix 'le-images' on $TARGET"

if [[ "$TARGET" == "local" ]]; then
  ENDPOINT_FLAG="--endpoint-url http://localhost:4566"
else
  ENDPOINT_FLAG=""
fi

leaks=0
for b in le-images-incoming le-images-processed; do
  if aws s3api head-bucket --bucket "$b" $ENDPOINT_FLAG --region us-east-1 2>/dev/null; then
    echo "  LEAK: s3 bucket $b still exists"
    leaks=$((leaks+1))
  fi
done
if aws lambda get-function --function-name "le-images-processor" $ENDPOINT_FLAG --region us-east-1 2>/dev/null; then
  echo "  LEAK: lambda le-images-processor still exists"
  leaks=$((leaks+1))
fi

if [[ $leaks -eq 0 ]]; then
  echo "  clean: nothing left behind"
fi
exit $leaks
