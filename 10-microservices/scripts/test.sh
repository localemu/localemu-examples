#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

AWS_ENDPOINT_URL=http://localhost:4566 \
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE \
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY \
AWS_DEFAULT_REGION=us-east-1 \
  pytest tests/ -xvs
