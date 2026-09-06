#!/usr/bin/env bash
# Both component builds and image checks must finish before this script runs.
set -euo pipefail
web_digest=${1:?Web digest required}
stream_digest=${2:?Streaming digest required}
[[ "$web_digest" =~ ^sha256:[a-f0-9]{64}$ ]] || exit 2
[[ "$stream_digest" =~ ^sha256:[a-f0-9]{64}$ ]] || exit 2
web=bailongctui/mastodon
stream=bailongctui/mastodon-streaming

digest() {
  docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["digest"])'
}
old_web=$(digest "$web:latest")
old_stream=$(digest "$stream:latest")
[[ "$old_web" =~ ^sha256:[a-f0-9]{64}$ ]] || exit 2
[[ "$old_stream" =~ ^sha256:[a-f0-9]{64}$ ]] || exit 2

restore_on_failure() {
  local rc=$?
  trap - EXIT
  if (( rc != 0 )); then
    echo 'Publication failed; restoring the previous latest pair.' >&2
    docker buildx imagetools create --prefer-index=false --tag "$web:latest" "$web@$old_web" || echo 'ERROR: Web latest restore failed; inspect registry before any deployment.' >&2
    docker buildx imagetools create --prefer-index=false --tag "$stream:latest" "$stream@$old_stream" || echo 'ERROR: Streaming latest restore failed; inspect registry before any deployment.' >&2
  fi
  exit "$rc"
}
trap restore_on_failure EXIT
docker buildx imagetools create --prefer-index=false --tag "$web:latest" "$web@$web_digest"
docker buildx imagetools create --prefer-index=false --tag "$stream:latest" "$stream@$stream_digest"
test "$(digest "$web:latest")" = "$web_digest"
test "$(digest "$stream:latest")" = "$stream_digest"
echo 'Both latest tags match the verified image pair.'
