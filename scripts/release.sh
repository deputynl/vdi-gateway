#!/usr/bin/env bash
# Commit, build (multi-arch), and publish a new vdi-gateway release.
#
# Usage:
#   scripts/release.sh "Description of what changed"
#
# The description is used as the commit message (if there are staged/unstaged
# changes to commit) and as the GitHub release notes. Always pass something
# specific — it ends up in git history and the release page.
set -euo pipefail

cd "$(dirname "$0")/.."

DESCRIPTION="${1:-}"
if [[ -z "$DESCRIPTION" ]]; then
  echo "Usage: $0 \"description of the changes\"" >&2
  exit 1
fi

REPO_URL="https://github.com/deputynl/vdi-gateway"
REMOTE_IMAGE="ghcr.io/deputynl/vdi-gateway"
PLATFORMS="linux/amd64,linux/arm64"  # the Dockerfile only supports these two

git remote get-url origin >/dev/null 2>&1 || {
  echo "No 'origin' remote; create the GitHub repo first" >&2
  exit 1
}

if [[ -n "$(git status --porcelain)" ]]; then
  echo "==> Committing changes"
  git add -A
  git commit -m "$DESCRIPTION"
else
  echo "==> No local changes to commit, skipping"
fi

echo "==> Pushing to origin main"
git push origin main

echo "==> Building and pushing multi-arch image"
docker buildx use multiarch-builder

TAG=$(date -u +%Y%m%d%H%M%S)
# The source label links the GHCR package to the repo (README, permissions).
docker buildx build --platform "$PLATFORMS" \
  --label "org.opencontainers.image.source=$REPO_URL" \
  --label "org.opencontainers.image.url=$REPO_URL" \
  --label "org.opencontainers.image.title=vdi-gateway" \
  --label "org.opencontainers.image.description=Browser access to one fixed RDP host via KasmVNC + FreeRDP 3" \
  --label "org.opencontainers.image.licenses=MIT" \
  --label "org.opencontainers.image.version=$TAG" \
  --label "org.opencontainers.image.revision=$(git rev-parse HEAD)" \
  --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --annotation "index:org.opencontainers.image.source=$REPO_URL" \
  --annotation "index:org.opencontainers.image.description=Browser access to one fixed RDP host via KasmVNC + FreeRDP 3" \
  --annotation "index:org.opencontainers.image.licenses=MIT" \
  -t "$REMOTE_IMAGE:latest" \
  -t "$REMOTE_IMAGE:$TAG" \
  --push .

echo "==> Tagging release $TAG"
git tag -a "$TAG" -m "Release $TAG"
git push origin "$TAG"

echo "==> Creating GitHub release"
gh release create "$TAG" --title "$TAG" --notes "$(cat <<NOTES
$DESCRIPTION

Image: \`$REMOTE_IMAGE:$TAG\` (also tagged \`:latest\`)
Platforms: ${PLATFORMS//,/, }
NOTES
)"

echo "==> Done: $TAG"
