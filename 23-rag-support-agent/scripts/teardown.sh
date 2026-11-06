#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE/terraform"

export AWS_DEFAULT_REGION="us-east-1"
export AWS_ENDPOINT_URL="http://localhost:4566"
export AWS_ACCESS_KEY_ID="AKIAIOSFODNN7EXAMPLE"
export AWS_SECRET_ACCESS_KEY="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
export AWS_PAGER=""

terraform destroy -auto-approve -input=false -var "opensearch_endpoint=unused"

# The domain was created by deploy.sh, not by Terraform (see deploy.sh).
aws opensearch delete-domain --domain-name le-rag-kb >/dev/null 2>&1 || true

echo
echo "→ verifying teardown for prefix 'le-rag'"

leaks=0
if aws dynamodb describe-table --table-name "le-rag-orders" --region us-east-1 2>/dev/null; then
  echo "  LEAK: dynamodb table le-rag-orders still exists"
  leaks=$((leaks+1))
fi
if aws opensearch describe-domain --domain-name "le-rag-kb" >/dev/null 2>&1; then
  echo "  LEAK: opensearch domain le-rag-kb still exists"
  leaks=$((leaks+1))
fi
if aws lambda get-function --function-name "le-rag-agent" --region us-east-1 2>/dev/null; then
  echo "  LEAK: lambda le-rag-agent still exists"
  leaks=$((leaks+1))
fi

if [[ $leaks -eq 0 ]]; then
  echo "  clean: nothing left behind"
fi
exit $leaks
