#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DOMAIN="le-rag-kb"

export AWS_DEFAULT_REGION="us-east-1"
export AWS_ENDPOINT_URL="http://localhost:4566"
export AWS_ACCESS_KEY_ID="AKIAIOSFODNN7EXAMPLE"
export AWS_SECRET_ACCESS_KEY="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
export AWS_PAGER=""

# The OpenSearch domain is created here, not by Terraform: the Terraform AWS
# provider sleeps 10 minutes before its first DescribeDomain.
echo "→ creating OpenSearch domain $DOMAIN..."
if ! aws opensearch describe-domain --domain-name "$DOMAIN" >/dev/null 2>&1; then
  aws opensearch create-domain --domain-name "$DOMAIN" --engine-version OpenSearch_2.11 >/dev/null
fi
ENDPOINT=""
for _ in $(seq 1 60); do
  ENDPOINT="$(aws opensearch describe-domain --domain-name "$DOMAIN" \
    --query 'DomainStatus.[Processing,Endpoint]' --output text | awk '$1=="False" && $2!="None" {print $2}')"
  [[ -n "$ENDPOINT" ]] && break
  sleep 5
done
[[ -n "$ENDPOINT" ]] || { echo "OpenSearch domain $DOMAIN never became ready" >&2; exit 1; }
echo "  ready at $ENDPOINT"

cd "$HERE/terraform"
terraform init -upgrade -input=false >/dev/null
terraform apply -auto-approve -input=false -var "opensearch_endpoint=$ENDPOINT"

echo
echo "→ deployed. outputs:"
terraform output

echo
echo "→ seeding knowledge base + orders..."
cd "$HERE"
python3 scripts/seed.py
