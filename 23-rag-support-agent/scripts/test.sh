#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

PYTHONPATH="$HERE/tests" pytest -xvs tests/
