#!/usr/bin/env bash
set -euo pipefail
export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
export AWS_DEFAULT_REGION=us-east-1
ENDPOINT="--endpoint-url=http://localhost:4566"

aws $ENDPOINT opensearch delete-domain --domain-name le-demo-search 2>/dev/null || true

echo "→ verifying teardown"
if aws $ENDPOINT opensearch describe-domain --domain-name le-demo-search 2>/dev/null | grep -q DomainName; then
  echo "  LEAK: domain still exists"
  exit 1
fi
echo "  clean: nothing left behind"
