#!/usr/bin/env bash
set -euo pipefail
TARGET="${1:-local}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE/terraform"

terraform init -upgrade -input=false >/dev/null
terraform apply -auto-approve -input=false -var "target=$TARGET"

echo
echo "→ deployed to $TARGET. outputs:"
terraform output

echo
echo "→ seeding knowledge base + orders..."
cd "$HERE"
TARGET="$TARGET" python3 scripts/seed.py
