#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/release-flow.sh <version> [suffix]

Example: ./scripts/release-flow.sh 4.5.2 2025.11.21

This script:
  1. Syncs main with upstream/main
  2. Merges main into your custom branch (default: custom-ui-fix)
  3. Creates a stable-<version> branch
  4. Tags it v<version> (or v<version>-<suffix> if suffix provided)
  5. Pushes everything to trigger build-image.yml workflow

Arguments:
  version   Major.minor.patch for the release, e.g. 4.5.2
            Note: For v4.5.x tags, workflow will also tag as :latest
  suffix    Optional suffix appended to the git tag (default: none)
            If provided, tag will be v<version>-<suffix>
            Example: v4.5.2-2025.11.21

Environment (optional):
  UPSTREAM_REMOTE   remote name for upstream (default: upstream)
  CUSTOM_BRANCH     branch that holds your UI changes (default: custom-ui-fix)
  STABLE_PREFIX    prefix for the stable branch (default: stable-)
  TAG_PREFIX       prefix for the git tag (default: v)
  PUSH_CUSTOM      push to custom branch to trigger latest build (default: true)
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

VERSION="$1"
SUFFIX="${2:-}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
CUSTOM_BRANCH="${CUSTOM_BRANCH:-custom-ui-fix}"
STABLE_PREFIX="${STABLE_PREFIX:-stable-}"
TAG_PREFIX="${TAG_PREFIX:-v}"
PUSH_CUSTOM="${PUSH_CUSTOM:-true}"

STABLE_BRANCH="${STABLE_PREFIX}${VERSION}"
if [[ -n "${SUFFIX}" ]]; then
  TAG="${TAG_PREFIX}${VERSION}-${SUFFIX}"
else
  TAG="${TAG_PREFIX}${VERSION}"
fi

# Check if version matches v4.5.x pattern for latest tag
if [[ "${VERSION}" =~ ^4\.5\. ]]; then
  LATEST_ENABLED=true
  echo "✓ Version ${VERSION} matches v4.5.x pattern - :latest tag will be created"
else
  LATEST_ENABLED=false
  echo "⚠ Version ${VERSION} does not match v4.5.x pattern - :latest tag will NOT be created"
fi

git_status() {
  local dirty=false
  if ! git diff --quiet --ignore-submodules; then
    dirty=true
  fi
  if ! git diff --cached --quiet; then
    dirty=true
  fi
  if [[ "${dirty}" == true ]]; then
    echo "❌ Working tree is dirty. Commit or stash changes before running this script."
    exit 1
  fi
}

check_remote() {
  if ! git remote get-url "${UPSTREAM_REMOTE}" >/dev/null 2>&1; then
    echo "❌ Remote \"${UPSTREAM_REMOTE}\" not found. Add it before running this script."
    echo "   Run: git remote add upstream https://github.com/mastodon/mastodon.git"
    exit 1
  fi
  if ! git remote get-url origin >/dev/null; then
    echo "❌ Remote \"origin\" is missing. Ensure you can push before running this script."
    exit 1
  fi
}

verify_branch() {
  if ! git show-ref --verify --quiet "refs/heads/${CUSTOM_BRANCH}"; then
    echo "❌ Custom branch \"${CUSTOM_BRANCH}\" does not exist locally."
    echo "   Create it first: git checkout -b ${CUSTOM_BRANCH}"
    exit 1
  fi
}

git_status
check_remote

echo ""
echo "🚀 Starting release flow for version ${VERSION}..."
echo ""

echo "📥 Fetching ${UPSTREAM_REMOTE}..."
git fetch "${UPSTREAM_REMOTE}"

echo "🔄 Updating main from ${UPSTREAM_REMOTE}/main..."
git checkout main
if ! git merge --ff-only "${UPSTREAM_REMOTE}/main" 2>/dev/null; then
  echo "   Fast-forward not possible, performing merge..."
  git merge "${UPSTREAM_REMOTE}/main" -m "Merge upstream/main"
fi
echo "📤 Pushing main to origin..."
git push origin main --force-with-lease

verify_branch

echo "🔀 Merging main into ${CUSTOM_BRANCH}..."
git checkout "${CUSTOM_BRANCH}"
if git merge --no-ff main -m "Merge upstream/main into ${CUSTOM_BRANCH} before ${TAG}" 2>&1 | grep -q "Already up to date"; then
  echo "   ${CUSTOM_BRANCH} is already up to date with main"
else
  echo "   Merge completed"
fi

if [[ "${PUSH_CUSTOM}" == "true" ]]; then
  echo "📤 Pushing ${CUSTOM_BRANCH} to trigger latest build..."
  git push origin "${CUSTOM_BRANCH}" --force-with-lease
fi

echo "🌿 Creating ${STABLE_BRANCH} branch from ${CUSTOM_BRANCH}..."
if git show-ref --verify --quiet "refs/heads/${STABLE_BRANCH}"; then
  echo "   Branch ${STABLE_BRANCH} already exists, resetting to ${CUSTOM_BRANCH}..."
  git checkout -B "${STABLE_BRANCH}" "${CUSTOM_BRANCH}"
else
  git checkout -b "${STABLE_BRANCH}" "${CUSTOM_BRANCH}"
fi

echo "📤 Pushing ${STABLE_BRANCH} to origin..."
git push -u origin "${STABLE_BRANCH}" --force-with-lease

if git rev-parse --verify --quiet "refs/tags/${TAG}"; then
  echo "❌ Tag ${TAG} already exists locally. Delete it before re-running this script."
  echo "   Run: git tag -d ${TAG} && git push origin :refs/tags/${TAG}"
  exit 1
fi

if git ls-remote --tags origin | grep -q "refs/tags/${TAG}$"; then
  echo "❌ Tag ${TAG} already exists on origin. Delete it before re-running this script."
  echo "   Run: git push origin :refs/tags/${TAG}"
  exit 1
fi

echo "🏷️  Creating tag ${TAG}..."
git tag "${TAG}"

echo "📤 Pushing tag ${TAG} to trigger version build..."
git push origin "${TAG}"

echo ""
echo "✅ Release flow completed!"
echo ""
cat <<EOF
Summary:
  Version:     ${VERSION}
  Tag:         ${TAG}
  Stable branch: ${STABLE_BRANCH}
  Custom branch: ${CUSTOM_BRANCH}
  Latest tag:  ${LATEST_ENABLED:+✓ Enabled (v4.5.x pattern)}${LATEST_ENABLED:-✗ Disabled}

Next steps:
  - GitHub Actions workflow should be triggered automatically
  - Check Actions tab for build progress
  - Images will be available at:
    * bailongctui/mastodon:${TAG}
    * bailongctui/mastodon-streaming:${TAG}
    ${LATEST_ENABLED:+* bailongctui/mastodon:latest*}
    ${LATEST_ENABLED:+* bailongctui/mastodon-streaming:latest*}
  - Deploy using: docker pull bailongctui/mastodon:${TAG}
EOF
