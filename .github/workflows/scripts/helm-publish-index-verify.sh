#!/usr/bin/env bash
set -euo pipefail

# helm-publish-index-verify.sh - right before the Pages deploy, confirm the
# publish branch is still at the revision helm-publish-index.sh read the
# index from.
#
# The release job is serialized by a concurrency group, so two runs of this
# workflow never race. A writer outside the workflow (a manual push to the
# publish branch) could still land between the index read and the deploy
# step's own clone, and the deploy would then replace that writer's index with
# ours. This narrows that window to the deploy step itself and fails loudly
# instead: re-running the job rebuilds the index from the new revision.
#
# Usage:
#   helm-publish-index-verify.sh --remote origin --publish-branch gh-pages \
#     --base-sha-file "$RUNNER_TEMP/helm-index-base-sha"
#
# The base file is what helm-publish-index.sh --base-sha-output wrote: the
# commit the publish branch was at, or `none` when the branch did not exist.
# Exit status is non-zero on any disagreement or on any failure to ask the
# remote; absence of an answer is never treated as "unchanged".

REMOTE="origin"
BRANCH="gh-pages"
BASE_FILE=""

die() {
  echo "ERROR: helm-publish-index-verify: $*" >&2
  exit 1
}

log() {
  echo "helm-publish-index-verify: $*"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --remote) REMOTE="${2:-}"; shift 2 ;;
    --publish-branch) BRANCH="${2:-}"; shift 2 ;;
    --base-sha-file) BASE_FILE="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$REMOTE" ] && [ -n "$BRANCH" ] || die "--remote and --publish-branch are required"
[ -n "$BASE_FILE" ] || die "--base-sha-file is required"
[ -f "$BASE_FILE" ] || die "base revision record not found: $BASE_FILE"

BASE="$(tr -d '[:space:]' <"$BASE_FILE")"
case "$BASE" in
  none) ;;
  *)
    if ! printf '%s' "$BASE" | grep -qE '^[0-9a-f]{40}$'; then
      die "base revision record '$BASE' is neither 'none' nor a commit id"
    fi ;;
esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/helm-publish-index-verify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

set +e
git ls-remote --exit-code "$REMOTE" "refs/heads/$BRANCH" >"$WORK/ls-remote.out" 2>"$WORK/ls-remote.err"
rc=$?
set -e
case "$rc" in
  0) CURRENT="$(cut -f1 <"$WORK/ls-remote.out" | head -n 1)" ;;
  2) CURRENT="none" ;;
  *)
    cat "$WORK/ls-remote.err" >&2
    die "cannot query '$REMOTE' for refs/heads/$BRANCH (git ls-remote exit $rc); refusing to deploy without knowing whether the publish branch moved"
    ;;
esac

if [ "$CURRENT" = "$BASE" ]; then
  log "publish branch '$BRANCH' on '$REMOTE' is still at $BASE; safe to deploy"
  exit 0
fi

case "$BASE" in
  none) die "publish branch '$BRANCH' appeared on '$REMOTE' (now at $CURRENT) after the index was built without it; re-run the job to rebuild the index from it" ;;
  *)
    case "$CURRENT" in
      none) die "publish branch '$BRANCH' disappeared from '$REMOTE' after the index was read from $BASE; refusing to deploy" ;;
      *) die "publish branch '$BRANCH' on '$REMOTE' moved from $BASE to $CURRENT after the index was read; re-run the job to rebuild the index from the current revision" ;;
    esac ;;
esac
