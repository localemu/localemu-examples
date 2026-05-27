#!/usr/bin/env bash
set -euo pipefail
TARGET="${1:-local}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

# Build the Lambda zip if missing or stale.
if [[ ! -f "$HERE/build/lambda.zip" \
      || "$HERE/src/handler.py" -nt "$HERE/build/lambda.zip" \
      || "$HERE/src/requirements.txt" -nt "$HERE/build/lambda.zip" ]]; then
  "$HERE/scripts/build.sh"
fi

cd "$HERE/terraform"
terraform init -upgrade -input=false >/dev/null
terraform apply -auto-approve -input=false -var "target=$TARGET"

echo
echo "→ deployed to $TARGET. outputs:"
terraform output
