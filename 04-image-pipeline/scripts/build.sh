#!/usr/bin/env bash
# Build the Lambda zip with Pillow's Linux wheels, regardless of host OS.
# Uses pip's --platform flag to grab manylinux2014_x86_64 wheels directly,
# so no Docker is required.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$HERE/build"

rm -rf "$BUILD"
mkdir -p "$BUILD/pkg"

pip install --quiet \
  --platform manylinux2014_x86_64 \
  --only-binary=:all: \
  --python-version 3.12 \
  --target "$BUILD/pkg" \
  -r "$HERE/src/requirements.txt"

cp "$HERE/src/handler.py" "$BUILD/pkg/"

( cd "$BUILD/pkg" && zip -qr "$BUILD/lambda.zip" . )

size=$(du -h "$BUILD/lambda.zip" | awk '{print $1}')
echo "→ built $BUILD/lambda.zip ($size)"
