#!/bin/bash
set -euo pipefail

CUSTOM_DIR="${1:-.custom}"
SOURCE_DIR="${2:-.}"

echo "==> Applying core custom patches to $SOURCE_DIR from $CUSTOM_DIR"

for patch in "$CUSTOM_DIR/patches/"*.patch; do
  [ -f "$patch" ] || continue
  echo "  Applying patch: $(basename "$patch")"
  git -C "$SOURCE_DIR" apply "$patch" --verbose
done

echo "==> Core customizations applied successfully"
