#!/usr/bin/env bash
set -euo pipefail

# helm-publish-index.sh - build the Helm repository index this repository
# publishes to GitHub Pages, from its OWN published history.
#
# Why (TXE-4820): the release workflow used to download the upstream project's
# Pages index, `helm repo index --merge` it, and publish the result with
# keep_files: false. Every fork release therefore replaced the fork's chart
# history with upstream's: fork-only versions vanished, overlapping versions
# were redirected to upstream tarballs, and a rerun of an already-published
# version re-indexed a freshly packaged tarball whose digest no longer matched
# the GitHub release asset the entry pointed at.
#
# Rules this script enforces:
#   1. The only source of existing entries is this repository's publish branch
#      (the branch the Pages deploy step pushes to), read through git. A missing
#      branch, or a branch without the index file, is a first release. Any other
#      outcome - unreachable remote, auth failure, unreadable or malformed index
#      - aborts. An error never turns into an empty index.
#   2. Published entries are preserved as they are: digest, urls, created, every
#      field. History is never rewritten, whichever owner an old entry names.
#   3. The entry for the version being released is generated from the canonical
#      GitHub release asset, never from a local repackage, and its URL is derived
#      from the repository identity the workflow runs in.
#   4. If the version is already indexed with the release asset's digest, the
#      index is written back unchanged (idempotent rerun). Any other disagreement
#      - index digest differs from the asset, local chart content differs from
#      the asset, asset is not the version being released - is a conflict and
#      aborts.
#   5. Preservation is checked on the complete text of every published entry,
#      not on a projection: after the merge, each entry's exact lines must
#      appear unchanged in the output. helm re-emits its own index byte for
#      byte, so this holds for anything this workflow published; an index
#      written or edited by another tool must be re-normalized deliberately
#      before this script will build on it. Required fields (chart name,
#      version, sha256 digest, urls) are validated explicitly as well.
#
# Usage:
#   helm-publish-index.sh \
#     --chart-name bifrost --chart-version 2.1.45 --release-tag helm-chart-v2.1.45 \
#     --canonical-chart "$RUNNER_TEMP/helm-release-asset/bifrost-2.1.45.tgz" \
#     --local-chart helm-charts/bifrost-2.1.45.tgz \
#     --repository "$GITHUB_REPOSITORY" --server-url "$GITHUB_SERVER_URL" \
#     --remote origin --publish-branch gh-pages --index-path helm-charts/index.yaml \
#     --output helm-charts/index.yaml \
#     --base-sha-output "$RUNNER_TEMP/helm-index-base-sha"
#
# --base-sha-output records the publish branch commit the index was read from
# (or `none` when the branch did not exist) for helm-publish-pages.sh, which
# publishes on exactly that revision by compare-and-swap.
#
# --local-chart is the tarball packaged from this checkout; it is only compared
# with the release asset (content, not bytes) to catch a version that was
# re-released with different content. Omit it to skip that check.
#
# Exit status is non-zero, and --output is left untouched, on every failure.
# Needs helm, git, tar, diff and sha256sum or shasum. No network beyond git.

CHART_NAME=""
CHART_VERSION=""
RELEASE_TAG=""
CANONICAL=""
LOCAL=""
REPOSITORY=""
SERVER_URL="https://github.com"
REMOTE="origin"
BRANCH="gh-pages"
INDEX_PATH="helm-charts/index.yaml"
OUTPUT=""
BASE_SHA_OUTPUT=""

usage() {
  sed -n '/^# Usage:/,/^# Exit status/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

die() {
  echo "ERROR: helm-publish-index: $*" >&2
  exit 1
}

log() {
  echo "helm-publish-index: $*"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --chart-name) CHART_NAME="${2:-}"; shift 2 ;;
    --chart-version) CHART_VERSION="${2:-}"; shift 2 ;;
    --release-tag) RELEASE_TAG="${2:-}"; shift 2 ;;
    --canonical-chart) CANONICAL="${2:-}"; shift 2 ;;
    --local-chart) LOCAL="${2:-}"; shift 2 ;;
    --repository) REPOSITORY="${2:-}"; shift 2 ;;
    --server-url) SERVER_URL="${2:-}"; shift 2 ;;
    --remote) REMOTE="${2:-}"; shift 2 ;;
    --publish-branch) BRANCH="${2:-}"; shift 2 ;;
    --index-path) INDEX_PATH="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --base-sha-output) BASE_SHA_OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
done

for required in CHART_NAME CHART_VERSION RELEASE_TAG CANONICAL REPOSITORY SERVER_URL REMOTE BRANCH INDEX_PATH OUTPUT; do
  if [ -z "${!required}" ]; then
    usage
    die "--$(echo "$required" | tr '[:upper:]_' '[:lower:]-') is required"
  fi
done
case "$REPOSITORY" in
  */*/*|*/|/*|*' '*) die "--repository must be OWNER/NAME, got '$REPOSITORY'" ;;
  */*) ;;
  *) die "--repository must be OWNER/NAME, got '$REPOSITORY'" ;;
esac
SERVER_URL="${SERVER_URL%/}"
[ -f "$CANONICAL" ] || die "release asset not found: $CANONICAL"
if [ -n "$LOCAL" ] && [ ! -f "$LOCAL" ]; then
  die "local chart package not found: $LOCAL"
fi

for tool in helm git tar diff; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool missing: $tool"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/helm-publish-index.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# chart_meta TGZ KEY -> the top-level Chart.yaml scalar inside the package.
# Top-level keys only: helm sorts the output, so a nested key with the same
# name (a maintainer's `name:`) comes first and must not be taken for it.
chart_meta() {
  helm show chart "$1" | awk -v k="$2" '$0 ~ "^" k ": " { v = substr($0, length(k) + 3); gsub(/^"|"$/, "", v); print v; exit }'
}

# index_entries INDEX -> one line per entry: chart name, version, digest and
# the urls list joined with commas, tab-separated (empty where missing). Walks
# the layout helm writes (two-space indent, one entry per "  - " item); the
# caller cross-checks the result against helm's own re-emission of the file.
index_entries() {
  awk '
    function flush() {
      if (started) printf "%s\t%s\t%s\t%s\n", name, ver, digest, urls
      started = 0; ver = ""; digest = ""; urls = ""
    }
    function kv(line,   k, v) {
      k = line; sub(/:.*/, "", k)
      v = line; sub(/^[^:]*:[ ]*/, "", v); gsub(/^"|"$/, "", v)
      list = (v == "") ? k : ""
      if (k == "version") ver = v
      else if (k == "digest") digest = v
    }
    /^entries:/ { inentries = 1; next }
    /^[^ ]/ { if (inentries) { flush(); inentries = 0 }; next }
    !inentries { next }
    /^  [^ -][^:]*:[ ]*$/ { flush(); name = $0; sub(/^  /, "", name); sub(/:[ ]*$/, "", name); next }
    /^  - / { flush(); started = 1; line = $0; sub(/^  - /, "", line); kv(line); next }
    /^    - / { if (list == "urls") { u = $0; sub(/^    - /, "", u); urls = (urls == "") ? u : urls "," u }; next }
    /^    [^ ][^:]*:/ { line = $0; sub(/^    /, "", line); kv(line); next }
    END { flush() }
  ' "$1" | LC_ALL=C sort
}

# validate_entries ENTRIES LABEL: every entry needs a chart name, a version, a
# sha256 digest and at least one url. Anything less cannot be served or
# verified, so it is reported rather than carried along or dropped.
validate_entries() {
  local bad
  bad="$(awk -F'\t' '
    $1 == "" || $2 == "" || $3 !~ /^[0-9a-f]{64}$/ || $4 == "" {
      printf "  %s %s:", ($1 == "" ? "(no chart name)" : $1), ($2 == "" ? "(no version)" : $2)
      if ($3 !~ /^[0-9a-f]{64}$/) printf " digest=%s", ($3 == "" ? "(missing)" : $3)
      if ($4 == "") printf " urls=(missing)"
      printf "\n"
    }' "$1")"
  if [ -n "$bad" ]; then
    printf '%s\n' "$bad" >&2
    die "$2 has entries without a chart name, version, sha256 digest or urls; refusing to build on it"
  fi
}

# index_blocks INDEX DIR: the exact text of every entry, one file per entry
# named <chart>@<version>, for byte-for-byte preservation checks.
index_blocks() {
  mkdir -p "$2"
  awk -v dir="$2" '
    function flush(  file) {
      if (buf != "") {
        file = dir "/" name "@" ver
        printf "%s", buf > file
        close(file)
      }
      buf = ""; ver = ""
    }
    /^entries:/ { inentries = 1; next }
    /^[^ ]/ { if (inentries) { flush(); inentries = 0 }; next }
    !inentries { next }
    /^  [^ -][^:]*:[ ]*$/ { flush(); name = $0; sub(/^  /, "", name); sub(/:[ ]*$/, "", name); next }
    /^  - / { flush(); buf = $0 "\n"; next }
    buf != "" {
      buf = buf $0 "\n"
      if ($0 ~ /^    version: /) { ver = $0; sub(/^    version: */, "", ver); gsub(/^"|"$/, "", ver) }
    }
    END { flush() }
  ' "$1"
}

# lookup ENTRIES NAME VERSION -> the matching entry lines.
lookup() {
  awk -F'\t' -v n="$2" -v v="$3" '$1 == n && $2 == v' "$1"
}

count_lines() {
  wc -l <"$1" | tr -d ' '
}

write_output() {
  mkdir -p "$(dirname "$OUTPUT")"
  cp "$1" "$OUTPUT.tmp.$$"
  mv -f "$OUTPUT.tmp.$$" "$OUTPUT"
  log "wrote $OUTPUT"
}

# --- 1. The release asset is the version it claims to be -------------------

asset_name="$(chart_meta "$CANONICAL" name)" || die "cannot read chart metadata from release asset $CANONICAL"
asset_version="$(chart_meta "$CANONICAL" version)" || die "cannot read chart metadata from release asset $CANONICAL"
if [ "$asset_name" != "$CHART_NAME" ] || [ "$asset_version" != "$CHART_VERSION" ]; then
  die "release asset $CANONICAL is $asset_name $asset_version, not $CHART_NAME $CHART_VERSION"
fi
CANON_DIGEST="$(sha256_of "$CANONICAL")"
log "release asset $CANONICAL: $CHART_NAME $CHART_VERSION, sha256 $CANON_DIGEST"

# --- 2. The chart in this checkout is what was released --------------------
# Bytes differ between helm builds, so compare the packaged content.

if [ -n "$LOCAL" ]; then
  local_name="$(chart_meta "$LOCAL" name)" || die "cannot read chart metadata from local package $LOCAL"
  local_version="$(chart_meta "$LOCAL" version)" || die "cannot read chart metadata from local package $LOCAL"
  if [ "$local_name" != "$CHART_NAME" ] || [ "$local_version" != "$CHART_VERSION" ]; then
    die "local package $LOCAL is $local_name $local_version, not $CHART_NAME $CHART_VERSION"
  fi
  mkdir -p "$WORK/canonical" "$WORK/local"
  tar -xzf "$CANONICAL" -C "$WORK/canonical" || die "cannot extract release asset $CANONICAL"
  tar -xzf "$LOCAL" -C "$WORK/local" || die "cannot extract local package $LOCAL"
  if ! diff -r "$WORK/canonical" "$WORK/local" >"$WORK/content.diff" 2>&1; then
    head -n 20 "$WORK/content.diff" >&2
    die "chart content in this checkout differs from the published release asset for $RELEASE_TAG; bump Chart.yaml's version instead of re-releasing $CHART_VERSION"
  fi
  log "local package matches the release asset's content"
fi

# --- 3. Read the published index from this repository's publish branch -----

EXISTING=""
BRANCH_SHA=""
set +e
git ls-remote --exit-code "$REMOTE" "refs/heads/$BRANCH" >"$WORK/ls-remote.out" 2>"$WORK/ls-remote.err"
rc=$?
set -e
case "$rc" in
  0) ;;
  2) log "publish branch '$BRANCH' does not exist on '$REMOTE': first release" ;;
  *)
    cat "$WORK/ls-remote.err" >&2
    die "cannot query '$REMOTE' for refs/heads/$BRANCH (git ls-remote exit $rc); refusing to publish without the existing index"
    ;;
esac
if [ "$rc" -eq 0 ]; then
  git fetch --no-tags --quiet "$REMOTE" "refs/heads/$BRANCH" || die "cannot fetch $BRANCH from $REMOTE"
  BRANCH_SHA="$(git rev-parse --verify --quiet FETCH_HEAD)" || die "fetched $BRANCH from $REMOTE but FETCH_HEAD is unreadable"
  # Only a successful, empty lookup means the index is not there. A lookup
  # that fails (unreadable tree, broken object store) says nothing and must
  # never turn into a first release that replaces the published history.
  if ! tree_entry="$(git ls-tree "$BRANCH_SHA" -- "$INDEX_PATH")"; then
    die "cannot read the tree of $BRANCH@$BRANCH_SHA to look for $INDEX_PATH; refusing to treat an unreadable branch as a first release"
  fi
  if [ -n "$tree_entry" ]; then
    git show "$BRANCH_SHA:$INDEX_PATH" >"$WORK/existing.yaml" || die "cannot read $INDEX_PATH from $BRANCH@$BRANCH_SHA"
    EXISTING="$WORK/existing.yaml"
    log "existing index: $BRANCH@${BRANCH_SHA:0:12}:$INDEX_PATH ($(wc -c <"$EXISTING" | tr -d ' ') bytes)"
  else
    log "$BRANCH@${BRANCH_SHA:0:12} has no $INDEX_PATH: first release"
  fi
fi
if [ -n "$BASE_SHA_OUTPUT" ]; then
  mkdir -p "$(dirname "$BASE_SHA_OUTPUT")"
  printf '%s\n' "${BRANCH_SHA:-none}" >"$BASE_SHA_OUTPUT"
  log "recorded publish branch revision ${BRANCH_SHA:-none} in $BASE_SHA_OUTPUT"
fi

# --- 4. The published index must be a valid Helm index we can read ---------
# helm re-emitting the file through an empty-directory merge both validates it
# and gives a canonical layout; the parser must see the same entries in both,
# otherwise an entry it cannot see could be silently overridden below.

if [ -n "$EXISTING" ]; then
  grep -qE '^apiVersion: v1[ ]*$' "$EXISTING" || die "existing index $BRANCH:$INDEX_PATH does not declare 'apiVersion: v1'; refusing to replace it"
  grep -qE '^entries:' "$EXISTING" || die "existing index $BRANCH:$INDEX_PATH has no 'entries' map; refusing to replace it"
  mkdir -p "$WORK/validate"
  if ! helm repo index "$WORK/validate" --merge "$EXISTING" >"$WORK/validate.log" 2>&1; then
    cat "$WORK/validate.log" >&2
    die "existing index $BRANCH:$INDEX_PATH is not a valid Helm repository index; refusing to replace it"
  fi
  index_entries "$EXISTING" >"$WORK/existing.entries"
  validate_entries "$WORK/existing.entries" "existing index $BRANCH:$INDEX_PATH"
  index_entries "$WORK/validate/index.yaml" >"$WORK/existing.normalized.entries"
  if ! cmp -s "$WORK/existing.entries" "$WORK/existing.normalized.entries"; then
    diff "$WORK/existing.entries" "$WORK/existing.normalized.entries" >&2 || true
    die "existing index $BRANCH:$INDEX_PATH is not in the layout helm writes, or helm dropped entries from it; refusing to merge what cannot be verified"
  fi
  log "existing index holds $(count_lines "$WORK/existing.entries") chart version(s)"
fi

# --- 5. Already published? Leave the index exactly as it is ---------------

if [ -n "$EXISTING" ]; then
  lookup "$WORK/existing.entries" "$CHART_NAME" "$CHART_VERSION" >"$WORK/existing.match"
  matches="$(count_lines "$WORK/existing.match")"
  if [ "$matches" -gt 1 ]; then
    die "existing index lists $CHART_NAME $CHART_VERSION $matches times; refusing to guess which entry is real"
  fi
  if [ "$matches" -eq 1 ]; then
    existing_digest="$(cut -f3 "$WORK/existing.match")"
    existing_urls="$(cut -f4 "$WORK/existing.match")"
    if [ "$existing_digest" = "$CANON_DIGEST" ]; then
      log "$CHART_NAME $CHART_VERSION is already published with the release asset's digest at $existing_urls; index unchanged"
      write_output "$EXISTING"
      exit 0
    fi
    die "conflict: the published index lists $CHART_NAME $CHART_VERSION with digest $existing_digest at $existing_urls, but the release asset for $RELEASE_TAG has digest $CANON_DIGEST; refusing to rewrite a published version"
  fi
fi

# --- 6. Add the release from the canonical asset ---------------------------

URL_BASE="$SERVER_URL/$REPOSITORY/releases/download/$RELEASE_TAG"
mkdir -p "$WORK/stage"
cp "$CANONICAL" "$WORK/stage/$CHART_NAME-$CHART_VERSION.tgz"
if [ -n "$EXISTING" ]; then
  helm repo index "$WORK/stage" --url "$URL_BASE" --merge "$EXISTING" >"$WORK/index.log" 2>&1 ||
    { cat "$WORK/index.log" >&2; die "helm repo index --merge failed"; }
else
  helm repo index "$WORK/stage" --url "$URL_BASE" >"$WORK/index.log" 2>&1 ||
    { cat "$WORK/index.log" >&2; die "helm repo index failed"; }
fi
NEW="$WORK/stage/index.yaml"
index_entries "$NEW" >"$WORK/new.entries"

# --- 7. Nothing published may have changed; the new entry must be right ----
# Every published entry's exact text must reappear in the output. This is a
# whole-entry comparison, not a projection: a field helm re-emits differently
# (or drops) fails here rather than being published silently.

if [ -n "$EXISTING" ]; then
  index_blocks "$EXISTING" "$WORK/existing.blocks"
  index_blocks "$NEW" "$WORK/new.blocks"
  for block in "$WORK/existing.blocks"/*; do
    [ -e "$block" ] || break
    key="$(basename "$block")"
    if [ ! -f "$WORK/new.blocks/$key" ]; then
      die "merging $CHART_NAME $CHART_VERSION lost the published entry $key; refusing to publish"
    fi
    if ! cmp -s "$block" "$WORK/new.blocks/$key"; then
      diff "$block" "$WORK/new.blocks/$key" >&2 || true
      die "merging $CHART_NAME $CHART_VERSION changed the published entry $key (diff above); refusing to publish. If the published index was written by another tool, re-normalize it deliberately before releasing"
    fi
  done
  log "all $(count_lines "$WORK/existing.entries") published entries carried over verbatim"
fi
validate_entries "$WORK/new.entries" "merged index"
lookup "$WORK/new.entries" "$CHART_NAME" "$CHART_VERSION" >"$WORK/new.match"
if [ "$(count_lines "$WORK/new.match")" -ne 1 ]; then
  die "merged index does not list $CHART_NAME $CHART_VERSION exactly once"
fi
new_digest="$(cut -f3 "$WORK/new.match")"
new_urls="$(cut -f4 "$WORK/new.match")"
expected_url="$URL_BASE/$CHART_NAME-$CHART_VERSION.tgz"
[ "$new_digest" = "$CANON_DIGEST" ] || die "merged entry digest $new_digest is not the release asset's $CANON_DIGEST"
[ "$new_urls" = "$expected_url" ] || die "merged entry url '$new_urls' is not '$expected_url'"

log "added $CHART_NAME $CHART_VERSION -> $new_urls (sha256 $new_digest); index now holds $(count_lines "$WORK/new.entries") chart version(s)"
write_output "$NEW"
