#!/usr/bin/env bash
set -euo pipefail
export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
export AWS_DEFAULT_REGION=us-east-1
ENDPOINT="--endpoint-url=http://localhost:4566"

CLUSTER=le-demo-eks

aws $ENDPOINT eks delete-cluster --name "$CLUSTER" 2>/dev/null || true
k3d cluster delete "localemu-eks-$CLUSTER" 2>/dev/null || true
rm -f /tmp/le-demo-eks.kubeconfig

echo "→ verifying teardown"
if k3d cluster list | awk 'NR>1' | grep -q "localemu-eks-$CLUSTER"; then
  echo "  LEAK: k3d cluster still present"
  exit 1
fi
echo "  clean: nothing left behind"
