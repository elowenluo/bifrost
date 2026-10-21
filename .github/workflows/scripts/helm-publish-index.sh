#!/usr/bin/env bash
set -euo pipefail

# RED baseline: the "Update Helm repository index" step of helm-release.yml as it
# stood on main (39b04fbe0), lifted verbatim behind the CLI the regression test
# drives. The only parametrisation is HELM_INDEX_URL (defaulting to the upstream
# Pages index the step downloaded) so the test can hand it a fixture instead of
# the network. Nothing else is fixed here on purpose: this commit exists so the
# test run against it records which behaviours the fix has to change.

CHART_NAME=""; CHART_VERSION=""; RELEASE_TAG=""; CANONICAL=""; LOCAL=""
REPOSITORY=""; SERVER_URL=""; REMOTE=""; BRANCH=""; INDEX_PATH=""; OUTPUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --chart-name) CHART_NAME="$2"; shift 2 ;;
    --chart-version) CHART_VERSION="$2"; shift 2 ;;
    --release-tag) RELEASE_TAG="$2"; shift 2 ;;
    --canonical-chart) CANONICAL="$2"; shift 2 ;;
    --local-chart) LOCAL="$2"; shift 2 ;;
    --repository) REPOSITORY="$2"; shift 2 ;;
    --server-url) SERVER_URL="$2"; shift 2 ;;
    --remote) REMOTE="$2"; shift 2 ;;
    --publish-branch) BRANCH="$2"; shift 2 ;;
    --index-path) INDEX_PATH="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/helm-index-legacy.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# The step ran inside helm-charts/, which holds the freshly packaged tarball and
# a committed, stale index.yaml - so `[ -f index.yaml ]` was always true.
cp "$LOCAL" "$WORK/"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../../../helm-charts/index.yaml" ]; then
  cp "$SCRIPT_DIR/../../../helm-charts/index.yaml" "$WORK/index.yaml"
fi
cd "$WORK"

# Download existing index if it exists
curl -sLO "${HELM_INDEX_URL:-https://maximhq.github.io/bifrost/helm-charts/index.yaml}" || true
# Merge with new chart only if index.yaml exists
if [ -f index.yaml ]; then
  helm repo index . --url "https://github.com/capsohq/bifrost/releases/download/${RELEASE_TAG}" --merge index.yaml
else
  helm repo index . --url "https://github.com/capsohq/bifrost/releases/download/${RELEASE_TAG}"
fi

cp index.yaml "$OUTPUT"
