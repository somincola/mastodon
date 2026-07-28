#!/bin/bash
set -euo pipefail

CUSTOM_DIR="${1:-.custom}"
SOURCE_DIR="${2:-.}"

echo "==> Applying core custom patches to $SOURCE_DIR from $CUSTOM_DIR"

shopt -s nullglob
PATCHES=("$CUSTOM_DIR"/patches/*.patch)

if [ "${#PATCHES[@]}" -eq 0 ]; then
  echo "ERROR: No custom patches found in $CUSTOM_DIR/patches" >&2
  exit 1
fi

echo "==> Preflight-checking ${#PATCHES[@]} patch(es)"
git -C "$SOURCE_DIR" apply --check "${PATCHES[@]}"

for patch in "${PATCHES[@]}"; do
  echo "  Queued patch: $(basename "$patch")"
done

git -C "$SOURCE_DIR" apply --verbose "${PATCHES[@]}"

echo "==> Core customizations applied successfully"
