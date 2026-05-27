#!/usr/bin/env bash
set -euo pipefail
TARGET="${1:-local}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

TARGET="$TARGET" PYTHONPATH="$HERE/tests" pytest -xvs tests/
