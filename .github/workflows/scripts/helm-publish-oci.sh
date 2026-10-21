#!/usr/bin/env bash
set -euo pipefail

# helm-publish-oci.sh - publish the released chart to the repository owner's
# GHCR namespace, idempotently and fail-closed.
#
# The registry is asked on every attempt whether this chart version is already
# there, using helm itself as the client:
#   - a definite "not found" means absent: the canonical release asset is
#     pushed, then pulled back and compared byte for byte;
#   - a version that is present with the asset's exact bytes is left alone;
#   - a version that is present with different bytes is a conflict and fails;
#   - any other answer (refused token, network, registry error) fails. An
#     unanswered lookup is never read as absence.
# A push never runs against a version the registry confirmed present, so a
# published artifact is never overwritten. Note `helm push` itself overwrites
# an existing tag, which is why the lookup comes first. A misread of "not
# visible to this token" as "absent" is harmless: the same token cannot push
# to a package it cannot read, so the push fails rather than overwriting.
#
# Usage:
#   helm-publish-oci.sh --chart-name bifrost --chart-version 2.1.45 \
#     --canonical-chart "$RUNNER_TEMP/helm-release-asset/bifrost-2.1.45.tgz" \
#     --registry ghcr.io --owner "$GITHUB_REPOSITORY_OWNER" --repository-path helm-charts
#
# Publishes to oci://<registry>/<owner, lowercased>/<repository-path>/<chart-name>:<version>.
# Needs helm (already logged in to the registry) and sha256sum or shasum.

CHART_NAME=""
CHART_VERSION=""
CANONICAL=""
REGISTRY="ghcr.io"
OWNER=""
REPOSITORY_PATH="helm-charts"

die() {
  echo "ERROR: helm-publish-oci: $*" >&2
  exit 1
}

log() {
  echo "helm-publish-oci: $*"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --chart-name) CHART_NAME="${2:-}"; shift 2 ;;
    --chart-version) CHART_VERSION="${2:-}"; shift 2 ;;
    --canonical-chart) CANONICAL="${2:-}"; shift 2 ;;
    --registry) REGISTRY="${2:-}"; shift 2 ;;
    --owner) OWNER="${2:-}"; shift 2 ;;
    --repository-path) REPOSITORY_PATH="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
for required in CHART_NAME CHART_VERSION CANONICAL REGISTRY OWNER REPOSITORY_PATH; do
  if [ -z "${!required}" ]; then
    die "--$(echo "$required" | tr '[:upper:]_' '[:lower:]-') is required"
  fi
done
[ -f "$CANONICAL" ] || die "release asset not found: $CANONICAL"
command -v helm >/dev/null 2>&1 || die "required tool missing: helm"

OWNER_LC="$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]')"
if ! printf '%s' "$OWNER_LC" | grep -qE '^[a-z0-9][a-z0-9-]*$'; then
  die "--owner '$OWNER' is not a registry namespace"
fi
REPO_URL="oci://$REGISTRY/$OWNER_LC/$REPOSITORY_PATH"
CHART_URL="$REPO_URL/$CHART_NAME"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/helm-publish-oci.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

chart_meta() {
  helm show chart "$1" | awk -v k="$2:" '$1 == k { v = $2; gsub(/^"|"$/, "", v); print v; exit }'
}

# pull_version DIR -> 0 present (tarball in DIR), 1 absent, 2 unknown (stderr in DIR.err)
pull_version() {
  local dir="$1"
  mkdir -p "$dir"
  if helm pull "$CHART_URL" --version "$CHART_VERSION" --destination "$dir" >"$dir.out" 2>"$dir.err"; then
    [ -f "$dir/$CHART_NAME-$CHART_VERSION.tgz" ] || return 2
    return 0
  fi
  if grep -qE '(: not found$|: not found |manifest unknown|MANIFEST_UNKNOWN|NAME_UNKNOWN)' "$dir.err"; then
    return 1
  fi
  return 2
}

# --- 1. The asset is the version it claims to be ---------------------------

asset_name="$(chart_meta "$CANONICAL" name)" || die "cannot read chart metadata from $CANONICAL"
asset_version="$(chart_meta "$CANONICAL" version)" || die "cannot read chart metadata from $CANONICAL"
if [ "$asset_name" != "$CHART_NAME" ] || [ "$asset_version" != "$CHART_VERSION" ]; then
  die "release asset $CANONICAL is $asset_name $asset_version, not $CHART_NAME $CHART_VERSION"
fi
CANON_DIGEST="$(sha256_of "$CANONICAL")"
log "release asset $CANONICAL: $CHART_NAME $CHART_VERSION, sha256 $CANON_DIGEST"

# --- 2. Ask the registry ---------------------------------------------------

set +e
pull_version "$WORK/existing"
state=$?
set -e
case "$state" in
  0)
    existing_digest="$(sha256_of "$WORK/existing/$CHART_NAME-$CHART_VERSION.tgz")"
    if [ "$existing_digest" = "$CANON_DIGEST" ]; then
      log "$CHART_URL:$CHART_VERSION is already published with the release asset's bytes; leaving it unchanged"
      exit 0
    fi
    die "conflict: $CHART_URL:$CHART_VERSION is published with sha256 $existing_digest but the release asset has $CANON_DIGEST; refusing to overwrite a published chart"
    ;;
  1)
    log "$CHART_URL:$CHART_VERSION is not published yet"
    ;;
  *)
    cat "$WORK/existing.err" >&2
    die "cannot determine whether $CHART_URL:$CHART_VERSION is published; not publishing"
    ;;
esac

# --- 3. Publish the canonical asset and read it back -----------------------

if ! helm push "$CANONICAL" "$REPO_URL" >"$WORK/push.out" 2>"$WORK/push.err"; then
  cat "$WORK/push.err" >&2
  die "helm push of $CHART_NAME $CHART_VERSION to $REPO_URL failed"
fi
cat "$WORK/push.out"

set +e
pull_version "$WORK/verify"
state=$?
set -e
if [ "$state" -ne 0 ]; then
  cat "$WORK/verify.err" >&2 2>/dev/null || true
  die "pushed $CHART_NAME $CHART_VERSION to $REPO_URL but cannot read it back; publication unverified"
fi
verify_digest="$(sha256_of "$WORK/verify/$CHART_NAME-$CHART_VERSION.tgz")"
if [ "$verify_digest" != "$CANON_DIGEST" ]; then
  die "pushed $CHART_NAME $CHART_VERSION to $REPO_URL but the registry serves sha256 $verify_digest, not the asset's $CANON_DIGEST"
fi
log "published $CHART_URL:$CHART_VERSION (sha256 $CANON_DIGEST) and verified it reads back identically"
