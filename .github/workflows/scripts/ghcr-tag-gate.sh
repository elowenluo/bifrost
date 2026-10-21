#!/usr/bin/env bash
set -euo pipefail

# Decide, right before a publishing job pushes, whether its tag may be published.
# Usage: ghcr-tag-gate.sh <owner/name> <tag>
#
# Release detection runs once per workflow run, but GitHub re-runs a failed job with the
# outputs detection wrote the first time. A job that pushed its tag and then failed - in a
# cache export, a post step, or a manifest script pushing latest after the version tag -
# would push again on the re-run. So every publishing job asks the registry itself, on every
# attempt, and gates its pushes on this answer alone.
#
# Writes publish=true to GITHUB_OUTPUT only when the registry confirmed the tag absent,
# publish=false when it exists, and fails the step on any other answer.

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <owner/name> <tag>" >&2
  exit 1
fi
REPOSITORY="$1"
TAG="$2"

for tool in curl jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "::error::$tool is required to check ghcr.io/${REPOSITORY}:${TAG} before publishing" >&2
    exit 1
  fi
done

# shellcheck source=ghcr-tags.sh
source "$(dirname "${BASH_SOURCE[0]}")/ghcr-tags.sh"

if ! STATE=$(ghcr_tag_states "$REPOSITORY" "$TAG"); then
  echo "❌ Could not establish whether ghcr.io/${REPOSITORY}:${TAG} exists; not publishing it" >&2
  exit 1
fi
case "$STATE" in
  "${TAG} present")
    echo "⏭️ ghcr.io/${REPOSITORY}:${TAG} is already published; this attempt leaves it unchanged"
    PUBLISH="false" ;;
  "${TAG} absent")
    echo "🆕 ghcr.io/${REPOSITORY}:${TAG} is confirmed absent; publishing it"
    PUBLISH="true" ;;
  *)
    echo "::error::unexpected GHCR state for ${TAG}" >&2
    exit 1 ;;
esac

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "publish=${PUBLISH}" >> "$GITHUB_OUTPUT"
fi
