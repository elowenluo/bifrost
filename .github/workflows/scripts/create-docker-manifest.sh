#!/usr/bin/env bash
set -euo pipefail

# Validate input argument
if [ "${1:-}" = "" ]; then
  echo "Usage: $0 <version>" >&2
  exit 1
fi

VERSION="$1"
REGISTRY="${REGISTRY:-ghcr.io}"
ACCOUNT="${ACCOUNT:-capsohq}"
IMAGE_NAME="bifrost"
IMAGE="${REGISTRY}/${ACCOUNT}/${IMAGE_NAME}"

# PUBLISH_VERSION_TAG comes from release detection: "true" only when the registry
# confirmed v<version> absent. A published version tag is immutable, so it is never pushed
# again. A retried release still composes the moving latest tag, from architecture images
# reused by digest whether this run built them or an earlier one did.
case "${PUBLISH_VERSION_TAG:-}" in
  true|false) ;;
  *)
    echo "::error::PUBLISH_VERSION_TAG must be true or false, got '${PUBLISH_VERSION_TAG:-}'" >&2
    exit 1
    ;;
esac

# Filter by platform.architecture rather than relying on positional [0]:
# docker/build-push-action with default provenance creates an OCI image index
# containing platform image manifests and provenance attestations.
AMD64_DIGEST=$(docker manifest inspect "${IMAGE}:v${VERSION}-amd64" | jq -er '.manifests[] | select(.platform.architecture == "amd64") | .digest')
ARM64_DIGEST=$(docker manifest inspect "${IMAGE}:v${VERSION}-arm64" | jq -er '.manifests[] | select(.platform.architecture == "arm64") | .digest')

echo "AMD64 digest: ${AMD64_DIGEST}"
echo "ARM64 digest: ${ARM64_DIGEST}"

# Create manifest for versioned tag using digests.
if [ "$PUBLISH_VERSION_TAG" = "true" ]; then
    docker manifest create \
        "${IMAGE}:v${VERSION}" \
        "${IMAGE}@${AMD64_DIGEST}" \
        "${IMAGE}@${ARM64_DIGEST}"

    docker manifest push "${IMAGE}:v${VERSION}"
else
    echo "⏭️ ${IMAGE}:v${VERSION} is already published; leaving it unchanged"
fi

# Create latest manifest only for stable versions.
if [[ "$VERSION" != *-* ]]; then
    docker manifest create \
        "${IMAGE}:latest" \
        "${IMAGE}@${AMD64_DIGEST}" \
        "${IMAGE}@${ARM64_DIGEST}"

    docker manifest push "${IMAGE}:latest"
fi
