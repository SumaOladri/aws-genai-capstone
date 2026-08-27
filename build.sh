#!/usr/bin/env bash
set -euo pipefail

BUILD_DIR="build"

echo "Cleaning previous build..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "Installing dependencies for the Lambda runtime..."
uv export --no-dev --no-emit-project --format requirements-txt > "$BUILD_DIR/requirements.txt"

uv pip install \
  --requirement "$BUILD_DIR/requirements.txt" \
  --target "$BUILD_DIR" \
  --python-platform x86_64-manylinux2014 \
  --python-version 3.12 \
  --only-binary=:all:

rm "$BUILD_DIR/requirements.txt"

echo "Copying application code..."
cp -r app "$BUILD_DIR/"
cp lambda_handler.py "$BUILD_DIR/"

echo "Removing bundled boto3 (provided by the Lambda runtime)..."
rm -rf "$BUILD_DIR"/boto3* "$BUILD_DIR"/botocore* "$BUILD_DIR"/s3transfer*

find "$BUILD_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

echo "Build complete: $(du -sh "$BUILD_DIR" | cut -f1)"