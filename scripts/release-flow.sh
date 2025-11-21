#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/release-flow.sh <version> [suffix]
Example: ./scripts/release-flow.sh 4.5.2 2025.11.21

Arguments:
  version   Major/minor/patch for the release, e.g. 4.5.2
  suffix    Optional label appended to the git tag (default: current date YYYYMMDD)

Environment (optional):
  UPSTREAM_REMOTE   remote name for upstream (default: upstream)
  CUSTOM_BRANCH     branch that holds your UI changes (default: custom-ui-fix)
  STABLE_PREFIX     prefix for the stable branch (default: stable-)
  TAG_PREFIX        prefix for the git tag (default: v)
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

VERSION="$1"
SUFFIX="${2:-$(date +%Y.%m.%d)}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
CUSTOM_BRANCH="${CUSTOM_BRANCH:-custom-ui-fix}"
STABLE_PREFIX="${STABLE_PREFIX:-stable-}"
TAG_PREFIX="${TAG_PREFIX:-v}"

STABLE_BRANCH="${STABLE_PREFIX}${VERSION}"
TAG="${TAG_PREFIX}${VERSION}-${SUFFIX}"

git_status() {
  local dirty=false
  if ! git diff --quiet --ignore-submodules; then
    dirty=true
  fi
  if ! git diff --cached --quiet; then
    dirty=true
  fi
  if [[ "${dirty}" == true ]]; then
    echo "Working tree is dirty. Commit or stash changes before running this script."
    exit 1
  fi
}

check_remote() {
  if ! git remote get-url "${UPSTREAM_REMOTE}" >/dev/null 2>&1; then
    echo "Remote \"${UPSTREAM_REMOTE}\" not found. Add it before running this script."
    exit 1
  fi
  if ! git remote get-url origin >/dev/null; then
    echo "Remote \"origin\" is missing. Ensure you can push before running this script."
    exit 1
  fi
}

verify_branch() {
  if ! git show-ref --verify --quiet "refs/heads/${CUSTOM_BRANCH}"; then
    echo "Custom branch \"${CUSTOM_BRANCH}\" does not exist locally."
    exit 1
  fi
}

git_status
check_remote

echo "Fetch ${UPSTREAM_REMOTE}..."
git fetch "${UPSTREAM_REMOTE}"

echo "Update main from ${UPSTREAM_REMOTE}/main..."
git checkout main
if ! git merge --ff-only "${UPSTREAM_REMOTE}/main"; then
  git merge "${UPSTREAM_REMOTE}/main"
fi
git push origin main --force-with-lease

verify_branch

echo "Rebase ${CUSTOM_BRANCH} onto updated main..."
git checkout "${CUSTOM_BRANCH}"
git merge --no-ff main -m "Merge upstream/main into ${CUSTOM_BRANCH} before ${TAG}"

echo "Create ${STABLE_BRANCH} from ${CUSTOM_BRANCH}..."
git checkout -B "${STABLE_BRANCH}" "${CUSTOM_BRANCH}"
git push -u origin "${STABLE_BRANCH}" --force-with-lease

if git rev-parse --verify --quiet "refs/tags/${TAG}"; then
  echo "Tag ${TAG} already exists locally. Delete it before re-running this script."
  exit 1
fi

git tag "${TAG}"
git push origin "${TAG}"

cat <<EOF
Release ready:
  version: ${VERSION}
  branch: ${STABLE_BRANCH}
  tag: ${TAG}
  custom branch: ${CUSTOM_BRANCH}
  upstream: ${UPSTREAM_REMOTE}/main

Next steps:
  - Verify the tagged commit (ci should trigger automatically because of build-image.yml).
  - Deploy the image at bailongctui/mastodon:${TAG} or bailongctui/mastodon:latest.
EOF

