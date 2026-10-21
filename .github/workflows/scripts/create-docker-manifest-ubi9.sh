#!/usr/bin/env bash
set -euo pipefail

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
# confirmed v<version>-ubi9 absent. A published version tag is immutable, so it is never pushed
# again. A retried release still composes the moving latest tag, from architecture images
# reused by digest whether this run built them or an earlier one did.
case "${PUBLISH_VERSION_TAG:-}" in
  true|false) ;;
  *)
    echo "::error::PUBLISH_VERSION_TAG must be true or false, got '${PUBLISH_VERSION_TAG:-}'" >&2
    exit 1
    ;;
esac

# Filter by platform.architecture rather than positional [0]: buildx may include
# provenance attestations in the OCI index and ordering is not stable.
AMD64_DIGEST=$(docker manifest inspect "${IMAGE}:v${VERSION}-ubi9-amd64" | jq -er '.manifests[] | select(.platform.architecture == "amd64") | .digest')
ARM64_DIGEST=$(docker manifest inspect "${IMAGE}:v${VERSION}-ubi9-arm64" | jq -er '.manifests[] | select(.platform.architecture == "arm64") | .digest')

echo "UBI9 AMD64 digest: ${AMD64_DIGEST}"
echo "UBI9 ARM64 digest: ${ARM64_DIGEST}"

if [ "$PUBLISH_VERSION_TAG" = "true" ]; then
    docker manifest create \
        "${IMAGE}:v${VERSION}-ubi9" \
        "${IMAGE}@${AMD64_DIGEST}" \
        "${IMAGE}@${ARM64_DIGEST}"

    docker manifest push "${IMAGE}:v${VERSION}-ubi9"
else
    echo "⏭️ ${IMAGE}:v${VERSION}-ubi9 is already published; leaving it unchanged"
fi

if [[ "$VERSION" != *-* ]]; then
    docker manifest create \
        "${IMAGE}:latest-ubi9" \
        "${IMAGE}@${AMD64_DIGEST}" \
        "${IMAGE}@${ARM64_DIGEST}"

    docker manifest push "${IMAGE}:latest-ubi9"
fi
